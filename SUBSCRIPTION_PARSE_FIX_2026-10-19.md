# 订阅解析两个真机故障的根因与修复（anytls 全红 / 块式 YAML 导入失败）

> 2026-10-19 真机（TunBox 0.4.1，设备 192.168.3.146:39933）定位并修复两个**互相独立**的订阅解析故障。
> 与 `SUBSCRIPTION_PARSING_FIX.md`（丢字段/改坏值类）是**不同类**的问题：那两个是字段被改坏，
> 这两个是**节点被整条丢弃**，症状是「测速全红」和「导入 0 节点」。

---

## 0. 两个故障一览

| # | 用户现象 | 根因 | 修复位置 |
|---|---------|------|---------|
| A | 订阅 `dy5-8.fgqoq.online/lagg/...` **41 个节点测速全部超时/失败**，但代理能连、节点其实可用 | 36 个 `anytls` 节点在生成内核配置前被丢弃（凭据缺失） | `YamlMerger.ets` `STRUCTURED_TYPES` |
| B | 订阅 `mitce.io/modules/servers/v2Net/subscribe/...` **导入失败**（FlClash 正常） | `proxies:` 是裸连字符块序列，切分器只认 `  - ` → 切出 0 个条目 | `YamlMerger.ets` `normalizedSectionLines` / `proxyItemGroups` / `parseProxyItem` |

---

## 1. 故障 A：anytls 节点被整批丢弃 → 测速「全部超时」

### 1.1 现象

- 订阅共 41 节点 = **36 个 `type: anytls`** + 5 个 `type: hysteria2`（其中 3 个是「剩余流量/距离下次重置/套餐到期」信息伪节点）。
- `LatencyEngine` 日志：`latency batch start nodes=41 … measured=0 timeout=5 failed=36`，**36 与 anytls 数量 1:1 吻合**。
- UI 全部标红；用户却反馈「测速显示失败的节点，代理也能正常生效、也能取到出口 IP」。

### 1.2 根因链（逐环有证据）

```
订阅 YAML 含 password
  → YamlMerger.parseProxyItem: anytls 不在 STRUCTURED_TYPES → 走 relayMode(中继透传)
  → applyPair 中继分支只保留 name/type/server/port，password 被塞进 extraOpts
  → ProxyNode.password = ''            （凭据槽位空）
  → ClashConfigGenerator.dropReasonFor: anytls && password.length === 0 → MISSING_CREDENTIAL
  → 36 个节点不写进 mihomo_config.yaml
  → 内核代理表里没有这些名字
  → GET /proxies/{name}/delay → 404 {"message":"Resource not found"}（8~20ms 秒回）
  → ClashApiService.classifyStatusCode: 404 → switch_failed
  → UI 渲染成「超时/失败」
```

**测速全红的真正原因不是网络、不是 gstatic、也不是内核**，而是**被测的节点压根没进内核**。这同时解释了「失败节点实际可用」：用户连的是没被丢的那几个节点，红色状态是同一个生成 bug 造成的假阴性。

### 1.3 关键证据

- 设备日志（决定性）：
  ```
  ClashConfigGenerator: 生成配置丢弃 36 / 154 个节点：协议不支持 0，文本不安全 0，
  缺必需字段 36（其中凭据缺失 36），端口非法 0；示例：🇭🇰 香港Anytls 01…
  ```
- 设备上的 `mihomo_config.yaml` 与实况 `/proxies`：9 个 anytls server 域名 **0 命中**，0 个 anytls。
- 实况内核探测：`🇭🇰 香港Anytls 01` → **404 Resource not found**（8~12ms）；
  `🇭🇰 香港hy2` → **504 Timeout**（2514ms，真超时）；
  另一订阅的 `新加坡01aws` → **200 delay=266**、`日本01aws` → **200 delay=108**（证明内核与测速 URL 正常）。

### 1.4 修复

`YamlMerger.STRUCTURED_TYPES` 加入 `'anytls'`：

```ts
private static readonly STRUCTURED_TYPES: Set<string> = new Set<string>([
  'ss', 'ssr', 'vless', 'vmess', 'trojan', 'hysteria2',
  'anytls'   // ← 新增
]);
```

anytls 随即走结构化路径：`password` 落进结构化槽位、`sni` 落进 `servername` 槽位
（`YamlMerger.usesSniKey('anytls')` 本来就返回 true），`ClashConfigGenerator` 的
`proxyType === 'anytls' && n.password.length === 0` 检查自然放行。

> 讽刺点：生成器早就为 anytls 写了「缺 password 就丢弃」的保护（`ClashConfigGenerator.ets:1409`），
> 说明**设计意图是支持 anytls**，是解析层把凭据吞了，保护逻辑反而变成了误伤。

---

## 2. 故障 B：裸连字符块序列 → 导入 0 节点

### 2.1 现象

mitce 订阅的 `proxies:` 段是**块序列**，条目起始行是**裸连字符（无尾随空格）**：

```yaml
proxies:
  -
    name: 'US-N-1 [P]'
    type: vless
    server: de152710bb8b70d108ec13c7.mitce-nocontact.com
    port: 33297
    uuid: 7A3AA165-...
    reality-opts:
      public-key: Z9Gr...
      short-id: d2e2a63f7c6676ac
```

FlClash 用标准 YAML 解析器 → 正常；TunBox 用**自研手写切分器** → 整份切出 **0** 个条目组。

### 2.2 根因（三处配合，全部要改）

| 位置 | 原判定 | 后果 |
|------|--------|------|
| `normalizedSectionLines` | `trimmed.startsWith('- ')` 才计入 `listIndent` | 基准缩进取到最小缩进，条目被额外缩进 |
| `proxyItemGroups` | `line.startsWith('  - ')` 才开新条目 | 裸 `-` 行不被识别为条目起点 |
| `parseProxyItem` 块式分支 | `baseIndent = lineIndent(parseLines[0])` | 裸 `-` 行的缩进是 2，键在 4 → **所有键都被当「缩进子键」跳过** |

Node 复现（修复前）：`_sub2_raw.txt` → item groups = **0**；`_sub_raw.txt`（flow-map 风格）→ 41 组正常。

### 2.3 修复

1. `normalizedSectionLines`：`trimmed === '-'` 也计入 `listIndent`。
2. `proxyItemGroups`：新增 `isBareSequenceItem(lines, line)` —— 该行恰为 `缩进 + '-'`
   **且其后第一个非空行缩进更深**（键由子行承载）才算条目起点。**附加的「更深缩进」条件**是必需的：
   否则块序列里嵌套的 `- ` 数组项会被误当成新节点。
3. `parseProxyItem` 块式分支：条目首行是裸 `-` 时，**基准缩进取首个键行的缩进**，
   否则所有键会被当嵌套子键跳过，节点因缺 name/type/server 被整条丢弃。

---

## 3. 验证

### 3.1 新增回归门禁

`scripts/verify-yaml-merger-parse.mjs`（自动纳入 `verify-all.mjs` 的 `verify-*.mjs` 扫描）：

- 用 **Node 24 原生 TS type-stripping 直接加载 `YamlMerger.ets` 源文件本体**（只把 `@kit.ArkTS` 换成最小垫片，
  被测逻辑一行都不在垫片里重写），对真实的 `proxyItemGroups` / `parseProxyItem` 做行为断言。
- 25 项断言：anytls 凭据回填、块式条目切分与字段回填、reality-opts 不丢、负对照
  （flow-map 风格 / `- name: x` 写法 / ss / vmess / trojan 不受影响）。

**负对照已验证**（`--file` 指向修复前的源码）：

```
node scripts/verify-yaml-merger-parse.mjs --file <修复前的 YamlMerger.ets>
→ PASSED=12 FAILED=13
   FAIL anytls password 已回填 — password: ["",""]
   FAIL 块式条目数（修复前为 0） — expected 2, got 0
```

即：**旧代码上该门禁确实失败**（两个 bug 精确复现），新代码上 25/25 通过。

### 3.2 真实订阅复现（修复后的解析器行为）

| 订阅 | 修复前 | 修复后 |
|------|--------|--------|
| `_sub_raw.txt`（dy5-8，flow-map） | 41 组 | 41 组，41/41 节点带 password |
| `_sub2_raw.txt`（mitce，块式） | **0 组** | **34 组**，34/34 拿到 name+type+server+uuid+client-fingerprint |

### 3.3 全量门禁

`node scripts/verify-all.mjs` → **PASS=25 / FAIL=3**：

- `verify-subscription-fidelity.mjs`、`verify-types.mjs` —— 白名单已知基线失败，与本次无关；
- `verify-build-profile.mjs` —— **工作区预先存在**的本机签名材料（`build-profile.json5` 的 `signingConfigs`
  被 DevEco 自动生成签名写入），与本次改动无关；按 `PROJECT_STATUS.md`，发布前需把 `signingConfigs` 恢复为 `[]`。

---

## 4. 遗留项（同日已修完）

### 4.1 同类协议审计：tuic / hysteria v1 —— 已修

**原判断（本次修正）**：不能把 `tuic`/`hysteria` 直接塞进 `STRUCTURED_TYPES`。
原因是 hysteria v1 的 `up`/`down`/`obfs`/`obfs-password` 在结构化生成路径里**不输出**
（只有 hysteria2 块才输出），而 `protocol` 在 hysteria v1 里是**传输协议**
（udp/wechat-video/faketcp），不是 hysteria2 那种混淆协议 —— 塞进结构化路径会**丢字段**。

**最终做法**：对齐 URI 导入路径的既有范式（`ProxyNode.parseHysteria` / `parseTuic`
—— 它们早就把口令进 password 槽、把 up/down 进 hyUp/hyDown），**中继透传时额外回填
结构化槽位**，而不是改变协议分类：

| 改动 | 位置 | 说明 |
|------|------|------|
| `RELAY_CREDENTIAL_SLOTS` 回填表 | `YamlMerger` | 键 → 结构化槽位：`password`/`uuid`/`auth-str`/`auth_str`/`auth`/`up`/`down`/`protocol` |
| 按协议限定回填 | `YamlMerger.applyPair` | 只有**有认证/带宽概念**的中继协议才回填（`RELAY_CREDENTIAL_TYPES` = tuic/hysteria/http/socks5/naive；`RELAY_BANDWIDTH_TYPES` = hysteria）。snell 用 `psk`、wireguard 没有口令概念 → 不塞 `password` |
| `token` **不**回填 | 同上 | tuic v5 的凭据键是 `token`，回填进 password 槽会让内核 v5 收到它不认的键 → 反而生成非法配置。保持透传 |
| tuic 判定放宽 | `ClashConfigGenerator.dropReasonFor` | tuic v4 = uuid+password；**tuic v5 = token**（查 extraOpts）。原判定硬性要求 uuid → v5 节点全被丢 |
| hysteria 判定修正 | 同上 | hysteria v1 只需**口令**（auth-str 回填后进 password 槽）。原判定还要求 `protocol`/`up`/`down` —— 那是 hysteria2 的语义（v1 的 protocol 是传输协议、up/down 有默认值） |
| hysteria 输出 `auth-str` | `ClashConfigGenerator.proxyYamlLine` | 与 URI 路径同口径：mihomo 的 hysteria v1 认 `auth-str`/`auth_str`，`password` 是较新内核的别名 → 三个一起写，缺一个就可能认不出凭据 |

回填**只增加**结构化槽位的值，extraOpts 里的原键仍保留；生成时「与已输出键重名以结构化字段为准」
→ 不会重复输出，未被结构化覆盖的键仍原样透传。

### 4.2 UI 语义：404 与 504 区分显示 —— 已修

**原状**：探测侧（`ClashApiService`）早就把 404（内核代理表里没这个节点）/ 504（真超时）/
拨号失败分好类了，但 `LatencyRecord` 只有 `state`（数字），**分类在运行时被整个丢掉**；
持久化层 `NodeLatencyRecord` 虽有 `failKind`，却是**从 state 重新推导**出来的，等于又丢一次。
结果：配置类 bug 在用户侧只能表现为「一片红」。

**改动**：

| 改动 | 位置 | 说明 |
|------|------|------|
| `LatencyRecord.failKind` | `LatencyState.ets` | 运行时记录携带分类 |
| `LatencyPolicy.stateText(state, failKind)` | 同上 | `switch_failed` → **「未生效」**（明确结论，不是含糊的「未测」） |
| `LatencyPolicy.isNotEffective()` | 同上 | 判定 `switch_failed`（用字面量避免与 `ClashApiService` 循环依赖） |
| 配色分离 | `TunBoxTokens` / `UiTokens` | 「未生效」用**警告色**（`#f59e0b`），超时/失败仍是红 → 「配置问题」与「节点问题」视觉上分开 |
| 引擎传分类 | `LatencyEngine` | `LatencyRecord.failed(..., probe.failKind)`；通道不可用的兜底盖章标 `core_not_ready`（`NodeSortPersistence` 已把它列为「非节点判定」，不再把整批写成「全失败」） |
| 持久化优先用分类 | `NodeSelectionPage.toPersistRecord` | 不再从 state 重新盖章 |
| **「测全部」也能区分** | `NodeSelectionPage.runGroupLatency` | 见下 |

**「测全部」这条路径原本分不出来**：它走 mihomo 的 `/group/PROXY/delay`（内核并发测全组，
一次请求），而**组接口只返回成功的节点、不返回状态码** —— 失败节点一律被记成「超时」。
现在的解法：组测后额外拉一次内核代理表（`ClashApiService.proxyTableNames()`，
新增 `GET /proxies` 全名列表）—— **名字不在表里 = 节点根本没进内核配置** → 标 `switch_failed`；
在表里却测不通 → 真超时。测速完成的 toast 也分开报：`可用 N / 超时 M / 未生效 K`。

> 顺带修正：`runGroupLatency` 之前把「不在代理表里」的节点也计入 timeout，
> 所以真机上「测全部」显示的是 `超时 41`，与实际「36 个未生效 + 5 个真超时」完全对不上。

### 4.3 仍未做（需要另行决策）

**信息伪节点**：「剩余流量/距离下次重置/套餐到期」这类 hysteria2 伪节点会参与测速并计为失败，
建议在生成配置前按名称/内容特征过滤，或在 UI 标注为「信息节点，不测速」。
（内核侧已有 `exclude-filter` 过滤自动选择组，但显式 proxies 列表仍会参与测速。）

---

## 4c. 第二轮（用户实测反馈后）

### 4c.1 mitce 订阅「测速全部失败」——不是 TunBox 的问题

用户把修复版推上设备后反馈：mitce 订阅**能解析了**，但测速全失败。真机取证结论：

| 层次 | 证据 | 结论 |
|------|------|------|
| 解析 | 34 个 vless 节点完整落库，生成 `uuid / flow / client-fingerprint / reality-opts(public-key+short-id) / tls / servername` **全部正确** | ✅ 修复生效 |
| 配置生成 | 内核日志 `Bridge: config parsed, 213 proxies` + `Initial configuration complete, total time: 22ms` | ✅ 无错误 |
| 内核代理表 | `AnyTLS: 36`（dy5-8 那 36 个全在）、`Vless: 60`、`Hysteria2: 42`、`Shadowsocks: 34` | ✅ 节点都在 |
| 同内核对照 | 22:08 那批 `nodes=41 measured=28 timeout=8 failed=5`（修复前是 `measured=0 failed=36`）；同内核同时刻 anytls/hysteria2/ss 全部 200 可通 | ✅ 隧道与测速链路正常 |
| 失败节点 | 60 个 vless 里 **17 个 200 / 35 个 503 / 8 个 504**；可通的是**其他订阅**的 vless，失败的是 mitce 的 `[P]` 节点 | ⚠ 只有 mitce 这批连不上 |
| 503 的性质 | 33~334ms **快速失败**（不是 504 超时） | → 连接层立刻被拒 = **DNS 解析失败** |
| DNS 交叉验证 | 34 个 mitce 域名：境内 DNS（223.5.5.5/114）→ NXDOMAIN；境外 DNS（1.1.1.1/8.8.8.8/9.9.9.9）→ 超时黑洞；设备系统 DNS → `Name does not resolve`；**mihomo 走代理的 DoH → 502**（同时对照组 gstatic → 204） | ❌ **域名在公网 DNS 上完全不可达** |

**结论**：mitce 的入口域名（`*.mitce-nocontact.com`，且每次订阅都在轮换随机子域）已经
在公网 DNS 上失效。订阅自带 `dns:` 段里的 `proxy-server-nameserver` 也全是公共 DNS
（doh.pub / dns.alidns.com / tls://223.5.5.5），**机场没有提供专属 DNS**。
这是机场侧问题（域名下线/换入口/需要未公开的 DNS），TunBox 侧无代码可修。
→ 用户需向机场确认入口域名，或换一家/换订阅。

**附带澄清**：22:11:50 那批日志是 `channel=offline`（**离线直连**通道），因为当时
App 刚重启、VPN 隧道断开、内核没跑 —— 离线通道只探端口，对 vless 无意义，
所以那批结果本身不可信。内核起来后（22:14）重测才是有效数据。

### 4c.2 测速超时 5s + 并发 88（用户要求）

| 改动 | 位置 | 说明 |
|------|------|------|
| `DEFAULT_TIMEOUT_MS` 2500→**5000** | `LatencyState.ets` | 单节点探测预算（也是发给内核 `/delay` 的 `timeout`） |
| `LATENCY_CONCURRENCY` 50→**88** | `LatencyEngine.ets` | 88 = 客户端 8 并发上限的 11 批；外层超时按 `ceil(lanes/8)*timeoutMs+1200` 自适应，排队中的请求等得起内核的 504 |
| `GROUP_TEST_TIMEOUT_MS` 3000→**5000** | `LatencyEngine.ets` | 组测里这是**每节点**预算，必须与逐节点探测同尺，否则同一节点在「测全部」和「单节点测速」里结论相反 |
| `testLatencyDetailed` 默认 3000→**5000** | `ClashApiService.ets` | 默认值对齐 |
| 离线探测阶段上限 4000/2500/3000→**5000** | `DirectLatencyTester.ets` | 阶段上限原本会截断 QUIC（2.5s），hysteria2 在离线通道被误判超时 |

单批硬上限 `BATCH_DEADLINE_MS` 仍是 90s：88 并发 × 5s 最坏排队约 11×5s=55s，仍在 90s 内；
真超时则剩余节点保持「未测」，不会整批挂死。

**顺带修的测试脆弱点**：`verify-latency-engine-runtime.mjs` 的「硬截止」用例原本靠
`deadline × 并发 / 节点数` 算出一个巨大的单次探测耗时去撞真实 90s 上限 ——
这让测试**同时依赖并发度与节点数的算术关系**，改一次并发度就失效（本次 50→88 确实挂了一次），
而且要真等两分多钟。现在引擎支持注入 `LatencyRunOptions.batchDeadlineMs`（默认仍是 90s，
生产行为不变），测试注入 250ms → **毫秒级且确定性**，耗时从 150s+ 降到 <1s。

### 4c.3 ikuuu 订阅节点协议显示「未知」

**根因**：`NodeProtocolPolicy.protocolKey` 是**白名单**语义 —— 不在白名单里的 `proxyType`
一律返回 `''`，展示层只能显示「未知」。白名单里**没有 `ss`**：

```
ikuuu 订阅 = 46 节点 = 34×ss + 12×vmess
  → proxyType='ss' → 未命中白名单 → '' → '未知'   ✗（34 个节点）
  → proxyType='vmess' → 命中白名单 → 'VMESS'     ✓
```

同订阅的 vmess 正常、ss 全"未知" —— 白名单式实现的典型漏法。机场的协议种类不可穷举
（ss/hysteria/snell/mieru/ssh/ss2022/juicity…），白名单等于"每加一个协议就坏一批节点"。

**修复**：`protocolKey` 改成 **别名表 + 原样兜底**（`hy2`→`hysteria2`、`shadow-tls`→`shadowtls`
等别名规范化，其余协议原样返回小写），展示层再补规范 label（SS/HYSTERIA/HYSTERIA2/
SNELL/HTTP/SOCKS5/MIERU/SSH/SS2022/Juicity…）。「未知」只留给**真的**没有协议信息
（`proxyType` 与 `type` 都空）的情况。REALITY 判定不受影响（仍只认 vless + 公钥/短 id）。

### 4c.4 失败分类的两处补正

| 位置 | 改动 |
|------|------|
| `LatencyEngine` 通道不可用的兜底盖章 | 标 `core_not_ready`（`NodeSortPersistence` 已把它列为「非节点判定」）→ 持久化时沿用上次结论，不再把整批写成「全失败」 |
| `LatencyEngine` 离线通道失败 | 标 `port_only` —— 离线探测只能得出**端口级**结论，不是协议级失败，不该和「节点坏了」混同 |

---

## 4b. 回归门禁

| 脚本 | 覆盖 |
|------|------|
| `scripts/verify-yaml-merger-parse.mjs`（新增，48 项） | 用 Node 24 原生 type-stripping **直接加载 `YamlMerger.ets` 源文件本体**做行为断言：anytls 凭据回填、块式裸连字符切分、tuic v4/v5、hysteria v1（auth-str/auth_str）、snell 负对照；生成层规则用文本断言锁定（`dropReasonFor` 判定、`auth-str` 输出、回填表内容） |
| `scripts/verify-latency-display.mjs`（扩到 37 项） | 延迟显示契约：失败分类必须一路带到 UI（`stateText(rec.state, rec.failKind)`）、`switch_failed`→「未生效」、警告色、组测路径用代理表区分、toast 报「未生效」计数；**超时/并发契约**（5s / 88 / 组测 5s / 离线阶段 5s / deadline 可注入） |
| `scripts/verify-node-sort-persistence.mjs`（扩到 22 项） | **真跑** `NodeProtocolPolicy`：ss 不再「未知」、白名单外协议原样回退、别名规范化、REALITY 判定不受影响 |
| `scripts/verify-latency-engine-runtime.mjs`（22 项） | 真跑引擎：并发上限、硬截止、取消、抢占、TESTING 归属、失败分类…（硬截止用例改为注入 deadline，耗时 150s+ → <1s） |

两个新脚本都有**负对照**：`verify-yaml-merger-parse.mjs --file <修复前的 YamlMerger.ets>`
→ 12 通过 / 13 失败（两个 bug 精确复现）。

全量 `node scripts/verify-all.mjs` → **PASS=25 / FAIL=3**（3 个均与本次无关：
2 个白名单已知基线 + `verify-build-profile` 的本机签名材料）。

---

## 5. 复现与排查命令（真机）

```bash
# 抓全量日志
hdc shell hilog -x | grep -iE 'tunbox|mihomo|latency|ClashConfigGenerator'

# 转发内核控制端口（需从 mihomo_config.yaml 取 secret）
hdc fport tcp:19090 tcp:9090
curl -H "Authorization: Bearer <secret>" http://127.0.0.1:19090/proxies
curl -H "Authorization: Bearer <secret>" \
     "http://127.0.0.1:19090/proxies/<节点名>/delay?url=http://www.gstatic.com/generate_204&timeout=2500"

# 拉设备上实际生成的内核配置
hdc shell cat /data/app/el2/100/base/com.tunbox.client/haps/entry/cache/mihomo_config.yaml
```
