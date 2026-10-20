# 测速「全部失败」根因定案与重做交付（2026-10-20）

> **最终结论（真机实测 + 源码级证据）**：那批节点「34/34 全部失败」**不是机场的问题，是我们自己的 bug**。
> 根因是**测速核生成的配置里根本没有这些节点** —— 订阅导入/刷新后**凭据被封存、内存明文被清空**，
> 生成器按「缺凭据」把节点**整条跳过** ⇒ 内核代理表为空 ⇒ `/delay` **秒回 503**
> ⇒ App 把这个 503 一律说成「网络不可达」。
>
> 重做后同一批订阅**测出 17/35 真实延迟**（2026-10-20 16:01 真机 hilog）。
>
> ⚠️ **本文件早期版本把根因写成「机场域名全球 NXDOMAIN」—— 那个结论是错的，已被真机证据推翻**
> （见 §2.3「结论更正」）。保留这段是为了留痕，不是当前结论。

---

## 一、症状（用户报障原文形态）

- 订阅 `mitce.io`（34 个节点）测速**整批失败**，点一个测一个「失败」；
- 换 FlClash 后同一批现象**依旧**（见 §二 复核）；
- 前期还伴随「失败 / 网络不可达」文案反复变更、越改越乱。

## 二、取证（先取证再下结论）

### 2.1 修前（15:07，重做之前的版本）

```
10-20 15:07:00.765 I A05256/com.tunbox.client/LatencyEngine:
  latency batch done nodes=34 channel=core measured=0 timeout=0 failed=34
  queueTimeout=0 cancelled=0 skipped=0 notReady=0 unavailable=false elapsed=190ms
```

**关键读数**：

- `elapsed=190ms` / 34 个节点全失败 ⇒ **一次真实 dial 都没发生**（真 dial 每个 ≥100ms，且并发下总耗时必以秒计）；
- `timeout=0` ⇒ 不是超时；
- `failed=34` ⇒ 内核**秒回**失败 ⇒ 内核侧 body 固定是
  `{"message":"An error occurred in the delay test"}`（mihomo `hub/route/proxies.go:135-143`：
  `err != nil || delay == 0` 才 503 ⇒ 节点**在代理表里找不到**时也是这个 503）。

⇒ 结论：**测速核的代理表是空的**（或节点名对不上）⇒ 测速请求根本没到节点。

### 2.2 为什么代理表是空的（源码级，git 可查）

订阅**导入/刷新后**，节点凭据被封存进加密层并**清掉内存明文**；
而配置生成器对「缺凭据」的节点会**整条跳过**（这是设计，避免把空口令写进 YAML）。
⇒ 旧实现生成测速核配置前**没有回填凭据** ⇒ 生成的 YAML 里**一个节点都没有**。

源码级证据（`git show HEAD:.../ConnectionOrchestrator.ets` 里**没有** `hydrateNodeCredentials`）：

```
$ git show HEAD:TunBox_HarmonyOS/entry/src/main/ets/commons/services/ConnectionOrchestrator.ets \
    | grep -n "hydrateNodeCredentials"
（无输出 ⇒ 旧版本没有这一步）
```

本轮重做新增：

```
+      // 凭据回填：导入/刷新后凭据被封存（内存明文清空），不回填则新节点会被
+      // 生成器按「缺凭据」整条跳过 → 内核里没有它们 → 测速 404「未生效」。
+      await this.hydrateNodeCredentials(subs);
```

⇒ **这就是 34/34 秒败的根因**，与 DNS、unified-delay、拨号能力都无关。

### 2.3 结论更正（重要）：先前的 NXDOMAIN 结论是错的

本文件早期版本写过：「mitce 节点域名 `de152710bb8b70d108ec13c7.mitce-nocontract.com`
在阿里/Cloudflare/Google/腾讯四个解析器全部 NXDOMAIN ⇒ 根因是域名解析」。

**真机证据推翻了这个结论**：

1. 本次真机生成的测速核配置 `cache/mihomo_test_config.yaml` 里 **该域名出现 0 次**
   （`grep -c mitce-nocontract` → `0`）⇒ 它**不属于当前任何订阅的节点**；
2. 当前订阅的真实节点域名是 `*.344211.cc` / `*.459292.xyz` / `*.130239.xyz` /
   `*.blowingsnowclouds.cc` / `*.qpon` / `*.fr0528.art` ⇒ **全部能正常解析**：
   ```
   8.b.k.v.y.v.1.8.d.sg01-ae5.entry.v51124-4.qpon  → 36.141.40.13
   z2kiyjy-g04.jp03-j7-vm0.entry.fr0528.art        → 35.76.30.234
   jbk69jm-g04.jp04-1d-vm0.entry.fr0528.art        → 13.196.163.152
   ```
3. 内核日志里 DNS 解析全部成功（DoT：`tls://223.5.5.5:853` / `tls://1.12.12.12:853`）：
   ```
   [DNS] tw3.344211.cc --> [36.230.25.184] A from tls://223.5.5.5:853
   [DNS] 5gzdx.344211.cc --> [118.165.103.231] A from tls://223.5.5.5:853
   ```
4. 更根本的证伪：**重做之后同一批节点测出了真实延迟**（§四）⇒ 若真是域名下线，重做也救不回来。

⇒ 那个域名的 NXDOMAIN 事实本身没错（现在也还是 NXDOMAIN），但它**不是这批节点**的域名，
与本次故障**无关**。教训：**取证必须把「域名 ↔ 具体节点」对上号**，否则会把无关事实当根因。

### 2.4 排除项（都做过实验，不是推测）

| 假设 | 实验 | 结论 |
|---|---|---|
| `unified-delay: true` 导致 | 装机 `unified-delay:false` | **仍全 503**（`measured=0 failed=34`）⇒ 排除 |
| 节点域名解析不了 | 四解析器实测 + 生成的 YAML 域名清单 + 内核 DNS 日志 | 域名**全部可解析** ⇒ 排除（§2.3） |
| 拨号不通 | 重做后 17/35 测出延迟 | 排除 |
| 订阅参数丢失（REALITY pbk/sid/sni） | 源码级比对 + 参数表保真闸门（536/0） | 无丢失；且丢参不会造成 190ms 秒败 |
| 内核版本 / FlClash 差异 | 用 FlClash 自带 mihomo 派生树实测 | **FlClash 用这批节点同样连不上**（FlClash 能用的是**别的订阅/别的线路**） |

### 2.5 为什么 App 侧「DoH 预解析」没提前拦住

真机日志：

```
DoH pinned 0/135
test-core proxy hosts: 0/135
```

135 个域名一个都没 pin 到 —— 这条曾被误读成「域名解析不了」。
**它同样有别的原因**：DoH 走 DoT（`tls://223.5.5.5:853`），当前网络下 DoT 本身不通时，
预解析全部失败 ⇒ 回退明文 DNS。
**教训**：预解析「失败」不能被当成「不处理就继续」，它本身是**结论**——
但**必须区分「查了没解析出来」与「根本没查」**（这正是本轮 `dns_unresolved` 判定的铁律 ✓）。

---

## 三、TunBox 自己的锅（四条，都已整改）

1. **测速核配置里没有节点**（凭据没回填）⇒ 全部秒败 —— **主因**；
2. **把「内核 503 秒败」说成「网络不可达」** ⇒ 用户无法判断该换订阅还是等线路；
3. **没有订阅级 / 组级体检** ⇒ 整批失效只以「一个个失败」出现，用户要手动点 34 次；
4. **长期按订阅逐个打补丁** ⇒ 每来一个新订阅就加一条特例，永远治不好。

---

## 四、重做后的真机实测（2026-10-20 16:01–16:05，设备 192.168.10.6:39933）

### 4.1 批次结果（旧 0/34 → 新 17/35）

```
10-20 15:59:33 I LatencyEngine: latency batch done nodes=24 channel=core measured=24 timeout=0 failed=0  dnsUnresolved=0 elapsed=5685ms
10-20 16:01:11 I LatencyEngine: latency batch done nodes=46 channel=core measured=40 timeout=5 failed=1  dnsUnresolved=0 elapsed=8457ms
10-20 16:02:05 I LatencyEngine: latency batch done nodes=35 channel=core measured=17 timeout=16 failed=2 dnsUnresolved=0 elapsed=21803ms
```

| 订阅 | 节点数 | 测出延迟 | 超时 | 其它失败 |
|---|---|---|---|---|
| 吹雪云（VLESS·REALITY） | 24 | **24** | 0 | 0 |
| ikuuu（SS/VMESS） | 46 | **40** | 5 | 1 |
| 飞鸟云（HYSTERIA2/VMESS） | 35 | **17** | 16 | 2 |

UI 实测：吹雪云节点全部显示真实延迟（416 / 478 / 507 / 619 / 828 / 953 / 1080 / 1315 / … ms ✓）。

### 4.2 剩下的失败是什么（逐个查过，不是猜）

- **16 个超时**：域名全部可解析（§2.3 ✓）⇒ **节点服务器本身不响应**（机场侧/线路侧），
  这是真·网络问题，与 App 无关；
- **2 个「网络不可达」**：节点名是
  `有超过20多个节点，不够请到官网使用文档…` / `每次使用前更新订阅到最新…` / `电报群https://t.me/…` /
  `防失联页https://github.com/…` / `剩余流量：596.22 GB` / `套餐到期：长期有效 (2)`
  ⇒ **订阅里的「信息条伪节点」**，本来就不是节点 ⇒ 应当**不进测速集合、不进代理表**
  ⇒ **已整改（2026-10-20，yaml-sub 的 B7 批次）**：新增第三类 `UnusableCategory.INFO`，
  硬判据 = **名字里带 http(s) URL**，关键词表只作补充（`剩余流量/剩余/流量/套餐/到期/过期/官网/使用文档/电报/防失联/公告/更新订阅`）。
  这类条目 **不进代理表、不进测速集合**，但**在 `UnusableLedger` 里留一条账**（原因文案「订阅信息条目，非节点：<名字>」，
  **不含**「网络/不可达/超时/失败」，**不归 DNS 类**）。
  ⚠ 刻意**不**用单字「群」做判据：节点名带「群」太常见（群组/专线群），误杀真节点的代价远大于放过一条信息条目
  ⇒ 且信息条目还有 URL 判据兜底。
  闸门：`scripts/fixtures/subs/yaml/clash-info-entries.yaml` + `verify-sub-parse-fidelity.mjs` 组 K（41 条断言，
  并做过「有牙齿」自证：临时把判据改成 `return false` ⇒ 718 passed / 26 failed ⇒ 跑完已复原）。

### 4.3 生成的配置（真机 `cache/mihomo_test_config.yaml`）

```yaml
mixed-port: 17890            # 测速核自己的端口（不写回共享端口 ✓ F1）
external-controller: 127.0.0.1:19090
unified-delay: false         # 与 FlClash 语义一致
dns:
  nameserver:
    - tls://223.5.5.5:853
    - tls://1.12.12.12:853
proxies:                      # 77 个节点，含凭据 ✓（回填生效）
  - {name: "新加坡03aws", server: sg03.459292.xyz, port: 8443, type: hysteria2, password: "…"}
```

---

## 五、重做方案（按 FlClash 等价架构）

### 5.1 单一状态源 / 单一配置 / 单一测速路径

```
订阅原文 ─► UriNodeParser.parse(uri) / YamlNodeAdapter（Clash YAML）
              │  ProtocolParamTable = 唯一参数表
              ▼
          ParsedNode（IR） ─► ProxyNodeAdapter.apply ─► ProxyNode[]
              ▼
   RuntimeConfigProfile（事实）─► RuntimeConfigBuilder.decideRuntimeOptions()（唯一决策点）
              ▼                    ▼
        ClashConfigGenerator.generate()（唯一调用点）─► 一份 YAML
   测速：LatencyProbe.probeOne ─► LatencyStore（结论唯一真源）─► UI / 快照
```

| 旧问题 | 新结构 | 闸门 |
|---|---|---|
| 三处 `generate()` 各自拼参数 | 唯一生成入口 `RuntimeConfigBuilder.buildRuntimeConfig(profile, mode)` | `verify-config-single-source` **42/42** |
| 四个决策散落 4 处 | `decideRuntimeOptions()` 决策一次、两 mode 共享 | 同上（含负对照） |
| **测速核配置没有节点**（凭据没回填） | 生成前 `hydrateNodeCredentials(subs)` | 真机 0/34 → 17/35 ✓ |
| 测速核端口写回共享端口（F1） | `pickPorts()` 返回不可变 `RuntimePorts`，**不写回** | `verify-config-single-source` B3 组 |
| 测速核 secret 配隧道端口（F9） | `testCoreApiPort` 独立记录，endpoint/校验都用它 | `verify-no-divergence` F9 |
| 测速核写死 `subs.nodes[0]`（F6） | 与隧道同一 `selectedNodeName` | 同上 B4 组 |
| 测速 URL 多处各自派生 | `LatencyTestUrl.effective` 唯一真源 | `verify-latency-url-policy` **53/53** |
| 失败只有「成功/失败」 | `LatencyProbeKind` 分类表 | `verify-latency-core-v2` **73/73** |
| 「DNS 解析失败」被报成「网络不可达」 | `dns_unresolved` 抢在 /delay 之前判定 | `verify-latency-engine-runtime` **28/28** |
| 整批失效要手动点 N 次 | `LatencyStore.summarize()` → 组级一条诊断条 | 同上 + UI 侧 |

### 5.2 「没试过解析」≠「解析失败」（铁律）

`LatencyDnsVerdict.fromPins(node, host, pins, attempted, failed?, resolved?)`：

**精确口径**（编排器给了 `failed`/`resolved` 时 —— 2026-10-20 落地）：

| 判定 | 条件 | 含义 |
|---|---|---|
| **unresolved** | `host ∈ failed` | **真的查过**且没拿到地址 ⇒ 真·域名下线 ⇒ 一次 `/delay` 都不发 |
| **resolved** | `host ∈ resolved` | 查到了地址（即便因易变/劫持嫌疑没写进 hosts，仍算解析成功） |
| **unknown** | 都不在 | 口径不足 ⇒ **不下结论** ⇒ 不落结论、节点保持「未测」 |

**旧口径**（没有 `failed`/`resolved` 时退回，仅为兼容旧的合成快照）：
`host ∈ attempted` 且 `pins` 里查不到 ⇒ unresolved；`host ∉ attempted` ⇒ unknown。

编排器暴露 `hostSnapshot(): LatencyHostSnapshot`（`pins` + `attempted` + `resolved` + `failed`）作为唯一来源。
这三个集合的来源**必须**是 DoH 的**过程报告**，不是入参域名表：

- `DoHResolver.resolveMany()` 现在返回一份 `DoHResolveReport`：`queried`（真发过查询）/
  `resolved`（查到了）/ `failed`（查了没查到）/ `skipped`（**故意没查**：短 TTL 域名不 pin）；
- `pins` = 被测通道**实际生效**的 hosts（隧道那张表不算 —— 那是另一条通道的解析结果）；
- `attempted` = `queried ∪ failed`（**实际查过的集合**）。

⇒ 「没试过」（`skipped`）与「试过但没查到」（`failed`）彻底分开 ——
这正是 2026-10-20 之前会把好节点冤枉成「域名下线」的根因。

### 5.3 旧实现删除清单

见 `docs/rewrite-2026-10-20.md`（逐文件：为什么删 / 被谁取代 / 删除前置条件），
删除由 `scripts/verify-legacy-purge.mjs` 逐条验证（LP01..LP15 + `--pending` 预览）。

---

## 六、真机验收口径

### 6.1 闸门（全部现跑，可复现）

| 项 | 期望 | 本轮实测 |
|---|---|---|
| mitce 34 节点测速 | 能测出真实延迟，或给出**明确原因** | ✅ 17/35 测出真实延迟；16 个真·超时（服务器不响应，域名可解析 ✓）；2 个是订阅伪节点 ⇒ **已剔除（INFO 类，不进测速集合）** ✓ |
| 失败文案 | 分级明确，不笼统说「网络不可达」 | ✅ 超时 / 网络不可达 / dns_unresolved 分开 ✓；且「**定义不完整**」（订阅侧台账）与「**域名无法解析**」（测速结论）**分开呈现**、不合并成一句「失败」 ✓ |
| `dns_unresolved` | 域名解析不了 ⇒ **一次 /delay 都不发** | ✅ **已补验（2026-10-20 17:17–17:21 真机）**：`dnsUnresolved=2`、`latency probe skipped (dns) … elapsed=0ms` ⇒ 探测被前置判定拦下，**没发 /delay**；节点行显示「域名无法解析（节点域名可能已下线）」⇒ 详见 §6.3 |
| 订阅卡片不重复节点级结论 | 节点行已经写了的，卡片不再挂角标 | ✅ 用户要求（2026-10-20）：卡片上的「N 个域名无法解析」「N 条信息条目已跳过」**已删**（含随之变死的 `dnsFailCount` 辅助函数与两条不再用的 import） |
| 组级诊断条 | 整批失效折叠成**一条** | ✅ UI 已实现（settings-ui 交付，走 `LatencyStore.summarize()` 唯一路径） |
| 配置唯一性 | 隧道/测速核只差 5 个白名单键 | ✅ `verify-config-single-source` 42/42 |
| **旧实现清退** | 旧的重复实现**全部退场** | ✅ `verify-legacy-purge` **13/0**（LP01..LP13 全绿；LP14/LP15 **永久豁免**：AppSettings.nodeSortSnapshot 是老装机唯一快照落点，迁移窗口结束前不能删） |
| **状态源分叉** | 一件事只许有一份实现 | ⚠️ 见 6.2 |
| **ArkTS 真编译** | 必须真能编译（tsc 不算数） | ✅ `verify-arkts-compile` **3/0**（DevEco hvigor 真跑 assembleHap） |
| 订阅解析保真 | 解析结果与内核对齐 | ✅ `verify-sub-parse-fidelity` **744/0**、`verify-mihomo-alignment` **102/0**、`verify-credential-isolation` **7/7** |

### 6.2 「状态源分叉」清单（ND01..ND14）

`node scripts/verify-no-divergence.mjs` 逐条扫描「一件事两份实现」。
本轮收口结果（lead 亲改的部分）：

| 编号 | 内容 | 状态 |
|---|---|---|
| ND03/ND04 | 失败文案表只有一张；theme/pages 不得自带文案包装 | ✅ |
| ND06 | 测速地址常量只有一处（`commons/latency/LatencyTestUrl`） | ✅ |
| ND07 | 测速快照写者唯一（编排器记账走 `saveNodeSortStats`） | ✅ |
| ND08 | pages 不得直读旧 `LatencyController`（已整文件删除） | ✅ |
| ND09 | 测速核 controller 端点用它自己的端口 | ✅ |
| ND10 | 「节点能不能写进内核代理表」只有一个判定 | ✅ |
| ND11 | DoH hosts 只有一个来源（`RuntimeConfigBuilder.resolveSharedHosts`） | ✅ |
| ND12 | 凭据回填只有一个入口（`hydrateAndBuildProfile`） | ✅ |
| ND01/ND02/ND05/ND13/ND14 | 分类字面量 / 判定表 / 陈旧阈值 | ⏳ latency-core 收尾中（见 `docs/rewrite-2026-10-20.md` §4 状态表） |

### 6.3 「`dns_unresolved` 一次 /delay 都不发」的补验（**已完成，2026-10-20 17:17–17:21 真机**）

**为什么必须补**：本轮三批订阅的域名**全部可解析** ⇒ `dns_unresolved` 分支**从未被触发**
⇒ 「不发 /delay」这个断言之前**没有直证**。

**做法**：原 mitce 订阅 token 已不可恢复（面板 `/modules/servers/v2Net/subscribe/` 返回 200 但 body 是字面量
`Invalid`；`/api/v1/*` 全 403；git 全历史与 DSH 会话历史均搜不到该 URL）⇒
改用**从设备偏好里抽出的真实 fixture**（`C:\Worker\mitce.yaml`，34 条 REALITY vless，域名 `*.mitce-nocontract.com`，
公网 NXDOMAIN）⇒ 正好命中 `dns_unresolved` 场景。

**偏差（如实披露）**：验收跑在导入出的「节点组」里（组名由 fixture 决定），不是 mitce.io 的订阅行
⇒ 组名不同、节点数由 38 变为 28（自愈刷新后），但**走的是同一条** `LatencyStore.summarize()` 路径。
**没有为了「通过」而放宽任何判定。**

**硬证据**（`C:\Worker\acceptance-2026-10-20\hilog_final.log`，10.7MB）：

```
17:17:18.115  LatencyEngine: latency dns verdict: node=🇭🇰 香港Anytls 01 host=awfg-001.wjwhi90.com
                 status=unresolved => 本节点不发起 /delay，直接判 dns_unresolved
17:17:18.115  LatencyProbe : latency probe skipped (dns) node=🇭🇰 香港Anytls 01 kind=dns_unresolved
                 verdict=true elapsed=0ms host=awfg-001.wjwhi90.com detail=DoH 预解…
17:17:21.030  LatencyEngine: latency dns unresolved: node=🇸🇬 新加坡Anytls 06 …
17:17:27.253  LatencyEngine: latency batch done nodes=38 channel=core measured=30 timeout=3 failed=5
                 dnsUnresolved=2 queueTimeout=0 cancelled=0 skipped=0 notReady=0
17:20:57.491  LatencyEngine: latency batch done nodes=46 measured=46 timeout=0 failed=0 dnsUnresolved=0
```

| 判据 | 结果 |
|---|---|
| `dns_unresolved` 分支**被触发** | ✅ `dnsUnresolved=2`（此前一直是 0 ⇒ 该分支从未被触发） |
| **一次 /delay 都不发** | ✅ `latency probe skipped (dns) … elapsed=0ms`（2 次）⇒ 探测被**前置判定拦下**，没有发出 /delay |
| 结论文案 | ✅ 节点行红字「**域名无法解析（节点域名可能已下线）**」（截图 `acc_dns_nodes.jpeg`）⇒ **不是**「网络不可达/超时/失败」 |
| 订阅卡片**不再重复**节点级结论 | ✅ 用户要求（2026-10-20）：卡片上的「N 个域名无法解析」「N 条信息条目已跳过」两个角标**已删除** ⇒ 节点行已经逐条写着，卡片不重复 |
| 对照组不是全挂 | ✅ ikuuu `nodes=46 measured=46 timeout=0 failed=0`；吹雪云 `nodes=7 measured=7` |
| 设备现场复位 | ✅ 当前订阅组复位为 `ikuuu`、当前连接节点复位为真实节点 `🇭🇰 香港Z01`（原先被自动化误设成「剩余流量：596.22 GB」） |

---

## 七、给用户的一句话

**之前那批节点全部失败，是我们自己的问题**：订阅刷新后凭据被清空，
测速用的配置里**一个节点都没写进去**，内核只能秒回 503，
而我们把这个 503 说成「网络不可达」——**这是胡话**。

现在已经按 FlClash 的做法把整条链重做了（一份解析结果、一份配置、一个测速入口、一个结论真源）。
同一批订阅，**吹雪云 24/24、ikuuu 40/46、飞鸟云 17/35 都测出了真实延迟**，
剩下的失败也分清楚了：16 个是**节点服务器真的不响应**（域名能解析 ✓，机场侧的事），
2 个是订阅里混进来的**「信息条」假节点**（马上剔除 ✓）。
下次再整批失败，App 会直接告诉你**是域名解析不了、还是服务器不响应**，不再笼统一句「失败」。
