# SSRVPN 订阅解析根治说明

> 目的：解释「vless/Reality/xhttp 节点导入后测速全部超时、换个订阅又复现」这类问题的**根因**，
> 以及为什么现在的修复是**根治**而不是「来一个订阅补一个」。附验证方法与后续排查清单。

---

## 1. 一句话根因

SSRVPN 不像桌面 Clash 那样**直接用订阅原始 YAML**，而是：

```
订阅原文 →(自研解析器拆成结构化模型)→ ProxyNode →(配置生成器重新拼 YAML)→ 内核
```

只要「解析→重生成」这条链路对**任何一个字段**处理不当，就会静默丢字段或改坏值，
导致内核拿到的配置和订阅原意不一致 → 节点连不上。**每丢一个没预料到的字段，就表现为
「又一个订阅坏了」**——这正是过去逐个订阅打补丁的来源。

---

## 2. 本次暴露出的 4 个「丢字段/改坏值」实例（同一类问题）

| # | 现象 | 丢在哪 | 触发订阅 |
|---|------|--------|----------|
| 1 | xhttp 节点全超时 | `captureExtraOpt` 值长度上限 **512** 太小，`xhttp-opts`(~600+ 字符) 被整键丢弃 | Cloudflare/XHTTP 机场 |
| 2 | 依赖中转的 vless 全超时 | `captureExtraOpt` 字符白名单不含 `( ) ; %`，中转 http 节点的 `headers`(含 User-Agent) 被整键丢弃 → 中转返回 403 | 前置中转类机场 |
| 3 | Reality 节点被判无效 | 裸 YAML `short-id: null` 被当字符串 "null" 存下 → 非法 hex → REALITY 校验误杀整节点 | 雪山 Link 等 |
| 4 | 一个坏节点炸掉整个内核 | 捆绑的旧内核对「解析失败的代理」是**整份配置致命**，而官方新内核是**跳过该节点** | 任何含脏节点的订阅 |

> 结论：这 4 个都不是「某个订阅的专属 bug」，而是「解析器对未知/边界字段处理不一致」的**同一个类**。

---

## 3. 根治方案：逐字透传原始节点行（raw-template passthrough）

核心改动（提交 `14d04e7`）：**不再重新拼已知协议节点的字段**，而是把订阅里那一行原始
flow-map **逐字保留**，生成配置时原样回写，只单独注入两样必须由 app 控制的东西：
`name`（跨订阅去重后的显示名）与 `凭据`（走加密层回填）。

### 数据流

```
YamlMerger.parseProxyItem
  └─ 命中单行 flow-map 写法时，额外产出 rawTemplate：
       = 原始 flow-map 内部键值，剔除 name + 全部凭据键
         (uuid / password / protocol-param / obfs-param / obfs-password)
       —— 因此 rawTemplate 不含任何明文凭据，可安全持久化

ProxyNode.rawTemplate  ←(mergedToNodes / mapNodes 全程携带，落 nodes_json)

ClashConfigGenerator.proxyYamlLine
  └─ 若 rawTemplate 非空：
       输出 = { name: <去重名>, <rawTemplate 逐字>, <uuid/password/… 从模型注入> }
       （再补一个 WS 无 ws-opts 时的默认 path 兜底）
     否则（URI 导入 / 块式写法）：回退旧的结构化生成路径
```

### 为什么这能「一劳永逸」

- 传输/选项字段（`xhttp-opts`、`reality-opts`、`headers`、`dialer-proxy`、`tls`、
  `servername`、`flow`、`client-fingerprint`、`alpn`、`smux`……）**原样进内核**，
  app 不再「理解」它们，也就不会再理解错。
- 面板以后新增任何字段、任何写法（含 null、特殊字符、超长值），只要它本来在原始行里，
  就会被逐字带过去 —— 与桌面 Clash 用原始 YAML 的行为**等价**。
- 凭据仍不落明文：rawTemplate 在**入库前就剥掉了** name/凭据键，生成时才从加密层注入。

---

## 4. 保留下来的兜底层（纵深防御，非主路径）

即使有逐字透传，仍保留结构化路径（URI 导入、块式写法要用）与若干安全网：

1. **`captureExtraOpt` 上限 512→8192 + 字符白名单放宽**（`80654ac`、`b79de8e`）：
   结构化/中继路径不再因长度或 `();%` 丢字段。
2. **裸 YAML `null`/`~`/空 归一化为空串**（`7d74909`）：`decodeScalar` 里统一处理，
   引号形态的 "null" 不受影响（那是真实值）。
3. **REALITY 字段合法性校验**（`733ceb7`）：`dropReasonFor` 里校验
   public-key(43 位 base64url) / short-id(偶数 hex、≤16)，非法节点**按无效丢弃并计数**，
   对齐官方「跳过」语义，绝不让一个坏节点炸掉整份配置。
4. **network 白名单放行 `xhttp`**（`80654ac`）：URI 导入的 xhttp 节点不再被丢。

---

## 5. 验证方法（不靠猜，全部可复现）

项目内置「真实链路」回归工具 `tools/true-chain-harness/`（用 `prepare.mjs` 把**真实 .ets**
转成 Node 可跑的 .ts，解析/合并/映射逻辑一行不改）：

```bash
# 1) 用真实解析链跑任意订阅，看 kept/dropped/模板是否完整
node --experimental-transform-types tools/true-chain-harness/probe_xhttp.mjs <订阅文件> <输出配置>
node tools/true-chain-harness/append_groups.mjs <输出配置> <订阅文件>   # 补 proxy-groups

# 2) 用「手机同款捆绑内核」的 PC 编译版验证配置可解析 + 真实拨号
#    (在 mihomo-build 源码目录 go build 出 windows 版)
mihomo-bundled -t -f <输出配置>          # 配置合法性
node tools/true-chain-harness/delay_probe.mjs   # 逐节点 delay，看真实内核应答

# 3) 安全不变量：rawTemplate 里绝不能有 name/凭据
node --experimental-transform-types tools/true-chain-harness/verify_rawtemplate_security.mjs <订阅文件>

# 4) 真机侧：端口穿透直连手机上的测速内核，读代理表 + /logs 拨号错误
hdc fport tcp:19090 tcp:9090
node tools/true-chain-harness/probe_phone_core.mjs <secret>   # secret 见 hilog A05256
```

本次就是靠 ①真实链路复现丢字段 → ②捆绑内核 PC 版证明「配置对了就能连」→
③真机穿透内核拿到「中转 403 / 缺 headers」的实锤，才定位到根因，而非猜测。

---

## 6. 以后再遇到「某订阅节点连不上」的排查清单

按顺序，大概率 5 分钟内定位：

1. **先跑 `probe_xhttp.mjs`**：看 `kept/dropped`。
   - `dropped>0` 且原因是「缺 uuid/password」→ 多半是**凭据封存/回填**问题（看
     `CredentialStore` 会话缓存是否命中、批量查询是否被固件不支持）。
   - 原因是「无效 REALITY/缺字段」→ 订阅里确有脏节点，已被安全丢弃（正常，看节点数对不对）。
2. **看生成的节点行**：`grep` 出问题的节点，对照订阅原文，确认是不是**逐字模板生效**
   （rawTemplate 命中时字段应与订阅一模一样）。URI 导入 / 块式写法才走结构化路径。
3. **捆绑内核 PC 版 `-t`**：配置解析是否致命（坏节点、未知字段）。
4. **真机 `probe_phone_core.mjs`**：读 `/proxies` 代理表 + 逐节点 delay + `/logs`，
   区分是「节点没进内核(404)」还是「进了但拨号失败(503)」。
5. 拨号失败再分：DNS（域名解析）、握手（TLS/Reality/UTLS）、鉴权（headers/auth）、
   可达性（网络/运营商）。

---

## 7. 关键不变量（改这块代码时务必守住）

- **rawTemplate 不含 name、不含任何凭据**；凭据只在生成时从加密层注入。改剥键逻辑要同步
  `RAW_TEMPLATE_STRIP_KEYS` 与 `proxyYamlLine` 的注入键，二者必须一一对应。
- **坏节点降级、不致命**：任何「一个节点让整份配置解析失败」的字段，都要在 `dropReasonFor`
  里拦成丢弃+计数，别交给内核。
- **null / 特殊字符 / 超长值都是常态**：解析器对面板输出要宽容，宁可逐字透传，不要自作主张重编码。
- **测速「假超时」≠ 节点坏**：并发挤占、单测试 URL 抖动会造成组测假超时；已有「失败二次复测 +
  边测边排序」缓解，判节点可用性以单测/真机内核为准。

---

## 8. 相关提交

| 提交 | 内容 |
|------|------|
| `80654ac` | extras 上限 512→8192；URI 导入放行 network=xhttp |
| `b79de8e` | 放宽 extras 字符白名单，保住中转 http 节点 headers |
| `7d74909` | 裸 YAML null/~ 归一化为空值 |
| `733ceb7` | 无效 REALITY 字段按丢弃处理；凭据会话缓存跨重启持久化 |
| `14d04e7` | **根治：已知协议节点逐字透传原始行（raw-template passthrough）** |

涉及文件：`YamlMerger.ets`、`ProxyNode.ets`、`ClashConfigGenerator.ets`、`SubscriptionService.ets`。
