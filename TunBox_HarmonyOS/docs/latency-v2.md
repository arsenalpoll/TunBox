# 测速内核 v2（LatencyProbe / LatencyStore）

> 2026-10-20 · 对照对象：FlClash（内置 mihomo 内核）· 适用范围：`entry/src/main/ets/commons/latency/**`
> 闸门：`scripts/verify-latency-core-v2.mjs`（50 条断言，含负对照）

## 0. 一句话结论

「同一批节点在 FlClash 测得动、在 TunBox 全部失败」**不是节点的问题，是配置口径的问题**：
TunBox 生成的配置写死了 `unified-delay: true`，而 FlClash 从不开启它（mihomo 默认也是关）。
于是 TunBox 的内核对每个节点**连发两次 HEAD**，出口不欢迎第二次 HEAD 时整片节点被判失败。
本模块把测速内核重做成 FlClash 语义（一次请求）+ 单一真源（URL / 分类 / 结论 / 渲染），
并把「失败」拆成**判定**与**非判定**两类 —— 只有判定类失败才允许写进节点结论。

## 1. 与 FlClash 的逐项对照

| 项 | FlClash（基准） | TunBox 旧实现 | TunBox v2（本模块） | 证据 |
| --- | --- | --- | --- | --- |
| 内核 URLTest 请求次数 | **1 次**（HEAD） | **2 次**（HEAD×2，第二次才作数） | **1 次**（探针只发一次；配置侧 `unified-delay: false`） | `adapter.go:259-272`；`ClashConfigGenerator.ets:194` |
| `unified-delay` | 关（mihomo 默认 `atomic.NewBool(false)`） | **开**（生成配置写死） | **关** | `adapter.go`（FlClash 与 mihomo 上游逐行 diff = 0） |
| 上报延迟的来源 | 唯一一次请求的耗时 | **第二次**请求的耗时 | 唯一一次请求的耗时 | 同上 |
| 测速 URL | `https://www.gstatic.com/generate_204`（常量，唯一） | **4 份实现各算各的**（前台批/后台批/smart 组/内核健康检查） | **1 个真源** `LatencyTestUrl.effective()` | FlClash `lib/common/constant.dart:79` |
| 用户自填 http 地址 | 保留 | 有的地方升级成 https，有的地方保留 | **原样保留**（只在「恰好等于历史默认值」时升级为 https） | `LatencyTestUrl.effective()` |
| 非法/空 URL | 常量兜底 | 各处兜底不一致 | 统一兜底到 https 默认 | — |
| 并发度 | client 50（`constant.dart:55`）/ kernel `mBatch=50`（`core/common.go:40`） | 未区分「worker 数」与「在途请求数」 | worker 50 / **在途 ≤ 8**（OHOS 同 host 连接池上限） | 真机 5.6.0 实测 ≈ 8 |
| 排队等待 | 不计入节点超时 | **计入** → 假超时 | 不计入；超过 60s 单列 `queue_timeout`（非判定） | `LatencyProbeLimits` |
| 失败可诊断性 | 内核日志有完整 dial 错误 | 只记 `bodyLen=50` + 240 字符头部 | **完整响应体**（>4096 才截断并标注）+ 状态码 + 耗时 | `LatencyProbe.bodyForLog` |
| 失败分类 | 内核自己分（dial / 超时 / 找不到节点） | 「内核没就绪」与「节点不通」**压成同一种红** | **单一分类表**（见 §2），非判定失败不落结论 | `LatencyProbe.classify` |
| 结论落盘 | 节点级字段存储 | **整单覆盖**（整个 snapshot 序列化写回） | **字段级**：一个 (节点, 字段) 一个槽 | `LatencyStore.persist` |
| 恢复 | 以新为准 | **无条件覆盖** → 旧快照盖掉新结论 | 只在「无记录」或「记录更新」时覆盖 | `LatencyStore.restore` |
| 渲染 | 一套 | **三套**（live / 落盘 / 恢复） | **一张表** | `LatencyStore.describe` |

## 2. 失败分类（单一表）

真源：`LatencyProbe.classify(httpCode, body, transportError)`；
**判定表唯一真源**：`LatencyKinds.LatencyProbeKind.isNonVerdictKind(kind)`（零 import 模块），
正表 `isVerdictKind(kind)` 是它的**派生视图**（`kind === '' ? true : !isNonVerdictKind(kind)`）。

| 分类 | 触发条件 | 是否节点结论 | 渲染 | 说明 |
| --- | --- | --- | --- | --- |
| `''`（无失败） | 200 且 `delay >= 1` | ✅ 判定 | 绿 + 延迟 | 实测成功 |
| `dns_unresolved` | **我们自己的 DNS 预检**判定该节点域名解析不出来 | ✅ 判定 | 红「域名无法解析（节点域名可能已下线）」 | 2026-10-20 真机：mitce 34 个节点的域名在阿里/Cloudflare/Google/腾讯**四个解析器全部 NXDOMAIN** ⇒ 失败在**域名解析**，不是拨号、不是超时、更不是「网络不可达」 |
| `timeout` | 504（内核明确说这个节点超时） | ✅ 判定 | 红「超时」 | 节点真超时 |
| `network_unreachable` | 503 **且**体内有 dial 类错误 | ✅ 判定 | 红「拨号失败」 | 节点走不通（有 dial 证据） |
| `network_unreachable` | 503 **且**是 mihomo 通用文案 `An error occurred in the delay test` | ✅ 判定 | 红「拨号失败」 | 503 只在 `err!=null \|\| delay==0` 时出现（`hub/route/proxies.go:135-143`）⇒ **必然是节点级事实**；内核没回传 dial 细节，detail 里注明「见内核日志」 |
| `switch_failed` | 404（节点不在内核代理表） | ✅ 判定（配置类） | 黄「未生效」 | 不是节点坏，是配置/内核没同步上 |
| `core_not_ready` | 401 / 403 / 传输层异常 / 压根没拿到 HTTP 响应 | ❌ **非判定** | 灰「未测」 | 这是「我们」的问题（通道/凭证/内核），不是节点的问题 → 沿用上次有效结论 |
| `unknown` | 认不出来的响应（200+非法 delay、503+无法识别的体、其它状态码） | ❌ **非判定** | 灰「--」 | 宁可什么都不写，也不冤枉节点 |
| `queue_timeout` | 排队超过 60s（根本没拨号） | ❌ 非判定 | 灰「排队超时」 | 排队时间不计入节点超时预算 |
| `untested` / `cancelled` / `unsupported` / `port_reachable_only` | 整批硬截止 / 主动取消 / 协议不支持 / 只证明端口可达 | ❌ 非判定 | 灰 | 沿用既有口径 |

**规则**：非判定失败**不产生节点结论** —— 不写进程内结论、不落盘、不参与排序，节点保持上一次的有效结论。
（旧实现没有这个区分，于是「内核一抖，半张列表变红」。）

### 2.1 `dns_unresolved` 必须抢在 mihomo 的 503 之前判定

- mihomo 的 503 body 是**通用句** `An error occurred in the delay test` ⇒ **看不到 DNS 原因**；
  真正的失败原因（NXDOMAIN / 无应答）只有**我们自己的 DoH 预解析**知道
  （当天日志：`DoH pinned 0/135`、`test-core proxy hosts: 0/135` —— 一个都没解析出来）。
- ⇒ 探针接受一份**每节点的 DNS 结论**（`LatencyDnsVerdict`）：
  - `status = unresolved` ⇒ **一次请求都不发**（不打扰内核），直接判 `dns_unresolved`；
  - `status = resolved` / `unknown` ⇒ 照常走内核探测（`unknown` ≠ 失败：**没试过解析**不能算解析失败）。
- ⇒ `LatencyDnsVerdict.fromPins(nodeName, host, pins, attempted)`：DoH 预解析结果 → 结论。
  `pins` 命中 = resolved；**试过**但没命中 = unresolved；没试过 = unknown。
- ⚠ **不许再混**：`dns_unresolved`（域名问题）与 `network_unreachable`（拨号问题）是两件事
  （用户原话：「你就把失败改成网络不可达，你糊弄谁呢」）。

### 判定性的唯一真源

**唯一判定表** = `LatencyKinds.LatencyProbeKind.isNonVerdictKind(kind)`（2026-10-20 lead 拍板：
正表/反表不得并存 ⇒ 只留一张反表，正表由它派生）：

- 非判定 = {core_not_ready, queue_timeout, untested, cancelled, unsupported, port_reachable_only, unknown}；
- 判定 = 其余 + `''`（实测出了延迟 = 一个真结论）= {dns_unresolved, timeout, network_unreachable, switch_failed}。

> ⚠ **`''`（空串）不在非判定表里**：写路径 `LatencyStore.applyProbeResult(name, delayMs>=1, '', atMs)`
> 依赖「空串是结论」⇒ 否则**实测延迟会被整条丢掉**。
> 「空分类 = 旧版记账残留 ⇒ 恢复时按未测处理」是**恢复路径**的规则，不属于判定表。
> `LatencyPolicy.isNonVerdictKind()`（services 层）现已**转调**内核表，不再自带清单。

### 陈旧判定的唯一真源

`LatencyKinds.LatencyProbeKind.isStale(testedAtMs, nowMs, isFailure)`（阈值 `STALE_MS` 也在同一文件）：

- 有时间戳：`nowMs - testedAtMs > STALE_MS` ⇒ 陈旧（UI 灰显「·旧」）；
- **年龄未知**（`testedAtMs <= 0`）：**失败结论算陈旧**（冷启动「刚打开软件就一颗红『超时』」的防线），
  有值但年龄未知**不算**（无法判断，不标「旧」）。

`LatencyStore.describe()`、`LatencyPolicy.isStale`、`LatencyPolicy.isStaleConclusion` 全部转调它
⇒ 陈旧口径只有一份。

## 3. 旧实现为什么「整片失败」

### 3.1 根因一：内核侧的两次请求（配置差异，非代码差异）

- mihomo 上游与 FlClash 自带内核的 `adapter/adapter.go` **完全一致**（已逐行 diff，0 差异），
  其中 `var UnifiedDelay = atomic.NewBool(false)` —— **默认关**；FlClash 从不打开。
- TunBox 旧生成配置写死 `unified-delay: true` → `adapter.go:259-272` 的 URLTest 分支
  **连发两次 HEAD**，只有第二次的结果作数，且**上报的延迟只算第二次请求的耗时**。
- 后果：出口对第二次 HEAD 不友好（限流/去重/劫持）时，节点被判失败；即便成功，
  延迟数字也系统性偏大（只算了第二次）。

### 3.2 根因二：把「通道坏了」当成「节点坏了」

`adapter.go:166-200` 证明 URLTest 的错误只可能来自 urlToMetadata / DialContext / http.NewRequest /
GetTLSConfig / **第一次 client.Do 失败** —— 也就是说「节点在内核表里但握手失败」= **dial 阶段就炸**。
而旧实现把 401/403/传输层异常与 503/504 一起压成「失败」写进排序快照：
内核中途重启（secret 变更）时，**其余全部节点**都会被写成失败 → 整片变红。

### 3.3 根因三：失败体只记长度

旧实现只写 `bodyLen=50` + 240 字符头部 → 「DNS 解析失败 / REALITY 握手失败 / 出口拒连 /
测速地址不可达」四类原因在日志里长得一模一样，只能靠猜。设备上 14:55 抓到的
`{"message":"An error occurred in the delay test"}`（503）就是这种「知道失败、不知道为什么」。

### 3.4 根因四：请求预算里混进了排队时间

OHOS 的 http 栈对同一 host（内核在 127.0.0.1）有连接数上限（真机实测 ≈ 8）。
并发一旦超过，排队等待被算进请求预算 → **假超时**；同时外层超时没有给内核留
「拆 dial 上下文再回写 504」的余量 → 内核明确的 504 被客户端超时截断 → 变成传输层异常 → 又是「假红」。

### 3.5 根因五：整单覆盖 + 无条件恢复 + 三套渲染

- 落盘是**整单覆盖**（整个 `nodeSortSnapshot` 序列化写回）→ 与自动切换记账
  （写 `failCount/lastOk`）互相覆盖，后写者赢。
- 冷启动恢复**无条件覆盖** → 旧快照抹掉刚测出来的新结论。
- live / 落盘 / 恢复**三套渲染** → 同一个 failKind 在不同页面显示不一样。

### 3.6 根因六：把「域名解析失败」写成「网络不可达」

- 2026-10-20 真机实测（多解析器：阿里/Cloudflare/Google/腾讯）：那批全败节点（mitce 34 个）的
  服务器域名 `de152710bb8b70d108ec13c7.mitce-nocontact.com` **四个解析器全部 NXDOMAIN**；
  仓库 2026-10-19 的真机取证同结论 ⇒ 失败发生在**域名解析**这一步。
- 旧口径把所有非 200 都压成「失败 / network_unreachable」⇒ **把「域名已下线」说成「出口不通」**，
  用户看到的指引（换线路、换节点）完全对不上病根（该换订阅/找机场）。
- 证据链在**我们这边**：mihomo 的 503 是通用句，看不到 DNS 原因；只有 DoH 预解析知道
  （当天 `DoH pinned 0/135` / `test-core proxy hosts: 0/135`）。
- ⇒ 新增 `dns_unresolved` 判定类 + DNS 预检输入（§2.1）+ 组级聚合结论（§4.3）。

## 4. 新内核结构

```
entry/src/main/ets/commons/latency/
├── LatencyTestUrl.ets   # 测速 URL 规则唯一真源（**零 import**，任何层都能安全引）
├── LatencyKinds.ets     # 失败分类表 + **唯一判定表** + 陈旧表 + 探测结果类型（**零 import**；B1 新增）
├── LatencyDnsVerdict.ets# DNS 预检结论（**零 import**）
├── LatencyProbe.ets     # 参数常量区 + 一次请求探针 + DNS 预检短路（再导出上面两个）
└── LatencyStore.ets     # 结论单一真源（进程内 Map + 字段级落盘 + 恢复规则 + 渲染表 + 组级聚合）
```

> ⚠ **为什么分类表要单独一个零 import 文件**（B1 的结构性决定）：
> Node 行为闸门把 `commons/services/*.ets` **扁平暂存**成沙箱再 import，
> 任何 `../latency/*` 的**值**依赖都会因「那一层目录不存在」让整个闸门崩掉
> （ERR_MODULE_NOT_FOUND）⇒ services 侧能值依赖的必须是零 import 的模块。
> 于是 `LatencyProbeKind`（分类常量 + **唯一判定表** `isNonVerdictKind` + 派生正表 `isVerdictKind`
> + `isTimeoutKind` + **陈旧表** `isStale`/`STALE_MS`）与 `LatencyProbeResult` 住在 `LatencyKinds.ets`，
> `LatencyProbe.ets` 再导出它们（**外部 import 路径保持稳定**）。
> ⇒ services 层（`LatencyState` / `LatencyStore` / `LatencyEngine`）都能直接引它，
> **四个「暂存真源码」的 Node 闸门不用加任何桩**（`LatencyKinds.ts` 早就在四份暂存清单里）。

### 4.1 LatencyProbe

- `LatencyProbeLimits`：**所有**并发/超时/取消数字的集中区（`NODE_TIMEOUT_MS=5000`、
  `OUTER_EXTRA_MS=1200`、`WORKERS=50`、`MAX_INFLIGHT=8`、`QUEUE_WAIT_MAX_MS=60000`、
  `CANCEL_GRACE_MS=500`、`FAILURE_BODY_LOG_MAX=4096`）—— 外部不得散落魔数。
- `LatencyTestUrl.effective(raw)`：URL 规则唯一真源（住在**零 import** 的 `LatencyTestUrl.ets`
  —— `services/` / `pages/` / `models/` 都要引它，若它住在 `LatencyProbe.ets` 里，
  就会经 `models/AppSettings` 形成 services → latency → models → services 的循环依赖）。
- `effectiveTestUrl(settings: AppSettings)`：给「手上有 settings 的调用方」的入口，内部只委托。
- `LatencyProbe.probeOne(..., dns?)`：**一次请求**（不重试、不发第二次），失败时把**完整响应体**写进日志；
  `dns.status = unresolved` 时**一次请求都不发**，直接判 `dns_unresolved`。
- `LatencyProbe.classify(httpCode, body, transportError, dns?)`：失败分类单一表（§2）。
- `LatencyDnsVerdict` / `LatencyDnsStatus`：DNS 预检结论（§2.1）。

### 4.2 LatencyStore

- 进程内结论：`Map<string, LatencyVerdict>`（**单一真源**，UI 读这里）。
- 落盘：`LatencyPersistence` 接口（`loadNode` / `saveField` / `listNodes` / `flush`），
  生产实现 `PreferencesLatencyPersistence`（ArkData preferences，**一个 (节点, 字段) 一个 key**：
  `lv2_<encodeURIComponent(name)>_<field>`），单测实现 `MemoryLatencyPersistence`。
  字段级写**不各自 flush**（一次 persist 三个字段只 flush 一次 ⇒ 200 节点不是 600 次磁盘写）。
- `applyProbeResult(name, delayMs, failKind, testedAt)`：非判定失败 → 返回 `false` 且**不落结论**。
- `restore(name, persisted)`：**只**在「进程内无记录」或「落盘记录更新（testedAt 更大）」时覆盖；
  落盘是非判定失败 → 不恢复成结论。
- `describe(failKind, delayMs, testedAt, nowMs)`：**三套渲染合成的一张表**
  （超时=红「超时」、域名无法解析=红「域名无法解析（节点域名可能已下线）」、
  拨号失败=红「拨号失败」、未生效=黄「未生效」、未测=灰「未测」、排队超时=灰「排队超时」…），
  `stale` 标记转调内核的 `LatencyProbeKind.isStale`（唯一陈旧表，见 §2）。

### 4.3 组级聚合（只读，UI 折叠成一条诊断条用）

- `LatencyStore.aggregateByKind(names: string[]): LatencyKindCount[]`
  —— 按 failKind 统计 + 占比（`kind`：`''` = 测通、`'untested'` = 没有结论、其余 = 具体失败分类）。
- `LatencyStore.summarize(names: string[]): LatencyGroupSummary`
  —— 计数 + 占比 + `dominantKind` + `isUniformFailure` + `conclusion`（**一条**组级结论）。
- 组级文案（同一 kind 整组失败时）：
  - `dns_unresolved` ⇒「34/34 节点域名无法解析，疑似机场域名下线，请联系机场换线路或更换订阅」
  - `network_unreachable` ⇒「N/M 节点拨号失败（出口或节点本身不可达）」
  - `timeout` ⇒「N/M 节点超时」；`switch_failed` ⇒「N/M 节点未在内核生效（配置未同步）」
  - 分类分散 ⇒「失败分类分散（dns_unresolved 2、timeout 1）」——**不硬套单一原因**。
- ⚠ **只读**：不改进程内结论、不落盘（闸门 H11 断言）。

## 5. 闸门

`node scripts/verify-latency-core-v2.mjs`（65 条断言；`--arkts` 额外跑 ArkTS 真编译）。

| 组 | 断言 | 负对照举例 |
| --- | --- | --- |
| A 单 URL 单一真源 | 11 + 3 跨文件收口 | 「用户自填的其它 http **不得**被升级」「绝不把 https 降级成 http」 |
| B 一次请求语义 | 6 | 「失败也不重发（请求数仍为 1）」「源码里 `probeOne` 只有一次 `transport.get`」 |
| C 分类表 + 非判定不落结论 | 17 | 「503 + 无法识别的体 → unknown（非判定）」「非判定失败 `applyProbeResult` 直接丢弃」 |
| D 落盘字段级 | 6 | 「写延迟不覆盖别的写者的字段」「只写一个字段其余原样保留」「没有整单 blob 槽」 |
| E 恢复不覆盖新结论 | 5 | 「进程内结论更新 → 旧快照必须被拒绝」 |
| F 渲染一张表 | 3 | 「非判定失败绝不渲染成红色」 |
| G 参数集中区 | 3 | 「魔数不得出现在常量区之外」 |
| H DNS 预检 + 组级聚合 | 12 | 「DNS resolved + 503 dial → 仍是 network_unreachable」「没试过解析 ≠ 解析失败」「分类分散 ⇒ 不是同因」 |

**`--arkts` 模式**：新包还没被入口 import（接线是 UI/引擎侧的事），仓库的 `verify-arkts-compile.mjs`
**看不见**它。该模式在 `entryability/EntryAbility.ets` 临时插一行带标记的 import，跑真编译后
**精确删掉那一行**（不整文件还原，避免覆盖别人的并发改动）。
（2026-10-20 起：UI/引擎侧已接上 `LatencyProbe` / `LatencyStore`，
仓库的总闸 `verify-arkts-compile.mjs` **已经**真编译到本包。）

## 6. 跨团队待接线

| 文件 | 位置 | 现状 | 改法 |
| --- | --- | --- | --- |
| `pages/NodeSelectionPage.ets` | `testUrlForLatency()` | ✅ 已接 `effectiveTestUrl` | — |
| `commons/services/BackgroundLatencyService.ets` | `resolveTestUrl()` | ✅ 已接 `effectiveTestUrl` | — |
| `pages/SettingsPage.ets` | `validateTestUrl()` | ✅ 已接 `LatencyTestUrl.isValid` | — |
| `commons/services/SettingsService.ets` | 原 `effectiveTestUrl()` | ✅ 已删（改为注释指向内核真源） | — |
| `commons/services/ClashConfigGenerator.ets` | smart 组 url（:591）+ `safeGroupUrl()` | ✅ 已接 `LatencyTestUrl.effective`（config-gen 已改） | — |
| `commons/services/ClashApiService.ets` | `testLatencyDetailed()` | ✅ 已委托 `LatencyProbe.probeOne`（旧通道死绝） | — |
| `commons/services/LatencyEngine.ets` | `gatedProbe()` / `probeThroughCore()` | ✅ 已走内核 + 传 DNS 结论 | — |
| `commons/services/ConnectionOrchestrator.ets` | `hostSnapshot()` | ⚠️ 接口已就绪，**口径待修**（见 6.1.4） | `pins` 换成被测通道实际生效的 hosts；`attempted` 换成真正查过的域名 |

`models/AppSettings.upgradeLegacyTestUrl()` 是**加载期迁移**
（把存量落盘的 http 默认值迁到 https），与探测期规则幂等，保留即可。

## 6.1 接线：唯一测速路径（2026-10-20 已接上）

> 这一节回答 lead 的两个问题：**谁在调内核**、**参数从哪来**、**真机怎么 grep**。

### 6.1.1 调用链（一条线，四个点）

```
LatencyEngine.run()                     ← 每批开始：取 DNS 快照（一次）+ 起 worker 池
  └─ worker(lane)                        ← worker 数 = LATENCY_CONCURRENCY(50) = 队列深度
     └─ gatedProbe(node)                 ← 在途闸门（LATENCY_INFLIGHT=8）+ 整批硬截止检查
        └─ ClashApiService.testLatencyDetailed(node, url, timeoutMs, lanes, dnsVerdict)
           └─ LatencyProbe.probeOne(node, url, endpoint, transport, timeoutMs, dnsVerdict)
              ├─ dnsVerdict.status === 'unresolved' ⇒ **一次请求都不发**，直接判 dns_unresolved
              └─ transport.get(...)          ← 唯一的 /delay 请求（ClashApiDelayTransport）
```

* **谁调 `probeOne`**：只有 `ClashApiService.testLatencyDetailed` 一处（闸门 I1 钉死）。
  旧的「API 服务自己发 http、自己分类」的路已经死绝（`http.createHttp()` 不再出现在该方法里）。
* **参数来源**：
  | 参数 | 值 | 来自 |
  | --- | --- | --- |
  | worker 数（队列深度） | `LATENCY_CONCURRENCY = 50` | `LatencyEngine` 常量区 |
  | 同时在途 HTTP | `LATENCY_INFLIGHT = 8` | `LatencyInflightGate`（**排队等待不计入请求超时**） |
  | 排队上限 | `LATENCY_QUEUE_WAIT_MAX_MS = 60000` | 超出 = `queue_timeout`（非判定） |
  | 节点超时 | `timeoutMs`（默认 5000） | 引擎 → API → 内核（内核再加 `OUTER_EXTRA_MS=1200` 外层预算） |
  | 整批硬截止 | `this.deadlineAt` | 批开始时定；到点后剩余节点保持「未测」 |
  | 取消 | `ClashApiService.cancelInflight()` | destroy 已登记的 `http.HttpRequest` |
  | DNS 结论 | `dnsVerdictFor(node)` | 编排器 `hostSnapshot()`（每批一次）→ 每节点现算 |

### 6.1.2 DNS 预检的口径（铁律）

* `attempted` 里有、`pins` 里查不到 ⇒ **unresolved** ⇒ 一次 `/delay` 都不发 ⇒ 判 `dns_unresolved`；
* **没在 `attempted` 里 ⇒ unknown**（不是 unresolved）：「没试过解析」≠「解析不出来」；
* 快照**没有正例**（`pins` 为空）⇒ 口径不可信 ⇒ 保守降级为 unknown
  （`DNS_TRUST_EMPTY_SNAPSHOT = false`，宁可少报也不把好节点冤枉成「域名下线」）；
* 结论只到**节点级**（`dnsVerdictFor(node)` 按节点自己的 `server` 域名现算）⇒ 混合域名订阅逐节点判定。

### 6.1.3 真机 grep 关键字（hilog）

| 关键字 | 含义 | 期望 |
| --- | --- | --- |
| `latency dns snapshot:` | 本批快照规模（`pins=` / `attempted=`） | 每批**一条** |
| `latency dns snapshot: 0 pin /` | 快照无正例 ⇒ 本批不判 dns_unresolved | 危险信号，WARN |
| `latency dns verdict:` | 某节点结论（`status=unresolved`） | 只有判 unresolved 的节点才有 |
| `latency probe skipped (dns)` | **没发 /delay 就判 dns_unresolved** | 命中即达标（**没有**对应 `/delay` 请求） |
| `latency dns unresolved:` | 引擎落 `dns_unresolved` 节点结论 | 与上一条成对出现 |
| `kind=dns_unresolved` | 探针侧分类 | 只在 DNS 短路时出现 |
| `DNS 预检未解析` | 探针 detail 原文 | 同上 |
| `latency non-verdict response:` | 认不出来的响应（unknown）⇒ **不落结论** | 节点保持「未测」 |
| `latency probe failed` | 探针失败全文（含 body 原文） | 排障用 |
| `latency batch done` | 批末汇总（含 `dnsUnresolved=`） | 每批一条 |

验收时同时看两件事：**有 `latency probe skipped (dns)`** 且 **该节点没有 `/delay` 请求行**。

### 6.1.4 编排器侧还差的两件事（lead 范围）

引擎已经按 `hostSnapshot(): { pins, attempted }` 接上，但**当前快照口径还不能直接用**：

1. **`pins` 必须是「被测通道实际生效的 hosts」**。
   现在 `hostSnapshot()` 暴露的是 `lastProxyHosts`（隧道那张表）；测速核自己解析的
   `hosts`（`launchTestCore()` 里 `DoHResolver.resolveMany(...)` 的结果）并不在里面
   ⇒ 测速核解析成功的域名会落进「attempted 但查不到 pins」⇒ **假 dns_unresolved**。
2. **`attempted` 必须是「真正查过的域名」**，不是入参域名表。
   `DoHResolver` 对短 TTL 域名是**故意不 pin**（`isHeldUnpinnable`）的，这些域名
   从没被查过，却会落在 `attempted` 里 ⇒ 同样 **假 dns_unresolved**。

在这两点修好之前，引擎的保守降级（`pins` 为空 ⇒ 不判 unresolved）保证**不会误伤**，
代价是**判不出**真·域名下线；修好后把 `DNS_TRUST_EMPTY_SNAPSHOT` 置 `true` 即可开火。

### 6.1.5 闸门

* `scripts/verify-latency-core-v2.mjs` —— **I 组**（接线 8 条）：API 服务确实委托 `probeOne`、
  引擎确实把 DNS 结论传下去、快照每批只取一次、`unknown` 不落结论、DNS 结论模块零 import。
* `scripts/verify-latency-engine-runtime.mjs` —— **D 组**（行为 6 条）：unresolved 节点
  **零请求**、resolved 节点照常探测、未在 attempted 的域名不误报、unknown 不落结论、
  空快照保守降级。

> ⚠ 结构约束：`commons/latency/LatencyDnsVerdict.ets` **必须零 import**。
> Node 行为闸门把 `commons/services/*.ets` **扁平暂存**成沙箱再 import，
> 任何 `../latency/*` 的**值**依赖都会因「那一层目录不存在」让整个闸门崩掉
> （ERR_MODULE_NOT_FOUND）。所以「结论 + 判定规则」放在零 import 的文件里，
> 闸门只需暂存这一个文件。

## 7. 真机验收口径（待 lead 排期）

1. 一次请求：hilog 里每个节点**只有一次** `/delay` 请求（`elapsed` 与 `inner=5000` 对得上）。
2. 在途 ≤ 8：并发压测时 `MAX_INFLIGHT` 不被突破，排队时间不进节点超时预算。
3. 分类分离：504 / 404 / 503 / 传输层异常四类在日志里各归各的，不再互相污染。
4. 排队超时归 `queue_timeout`（非判定），不参与排序、不把节点标红。
5. 完整失败体：日志里能直接看到 dial 错误原文（而不是 `bodyLen=`）。
6. **DNS 预检优先**：mitce 那批节点（`*.mitce-nocontact.com`，四解析器全 NXDOMAIN）在 hilog 里
   必须是 `latency probe skipped (dns) … kind=dns_unresolved`（**没有** `/delay` 请求），
   节点行显示「域名无法解析（节点域名可能已下线）」，**不是**「失败 / 网络不可达」。
   ⚠ 前置：编排器侧把 `hostSnapshot().pins` 换成被测通道实际生效的 hosts、
   `attempted` 换成真正查过的域名（见 6.1.4），否则本条会看到
   `latency dns snapshot: 0 pin / … attempted` 的保守降级日志（**不误伤，但判不出**）。
7. **组级诊断条**：整批失败时，UI 只出现**一条**组级结论
   （「34/34 节点域名无法解析，疑似机场域名下线…」），不是 34 条同色红条。
8. **零请求可证**：`latency probe skipped (dns)` 出现过的节点，在同批次日志里
   **不得**出现对应的 `/delay` 请求行（两条一起看才算数）。

## 8. B1：旧延迟通道清退后的职责边界（2026-10-20）

### 8.1 一句话

**`LatencyEngine` 只剩批次调度**（worker 池 / 在途闸门 / 进度 / 取消 / DNS 结论下发 /
通道级故障的自愈与作废）；**所有探测与分类都在测速内核**（`LatencyProbe.probeOne`
+ `LatencyKinds.LatencyProbeKind`）。

### 8.2 删掉的东西

| 位置 | 删了什么 | 为什么 |
|---|---|---|
| `ClashApiService.ets` | `testGroupDetailed()`（LP02） | 任何非 200 ⇒ null：把「节点全不通（504）」和「内核不可用（401）」压成同一个 null |
| `ClashApiService.ets` | `testLatency()`（LP03） | 失败 ⇒ -1：同上，且把「超时/不可达/域名死」压成一个数 |
| `ClashApiService.ets` | `export class LatencyFailKind` | 分类表的**副本**（真源在 `LatencyKinds.ets`） |
| `ClashApiService.ets` | `export class LatencyProbeResult` | 结果类型的**副本**（真源在 `LatencyKinds.ets`） |
| `ClashApiService.ets` | `classifyStatusCode()` / `classifyTransportError()` | 旧的状态码/传输层分类口径（真源是内核的 `classify`） |
| `LatencyEngine.ets` | `mapFailure()` | 引擎自带的失败映射（旧口径把 `reset` 归成 network_unreachable、拿 httpCode 兜底判超时） |
| `LatencyEngine.ets` | `class ProbeOutcome` | 引擎自带的 `publishable/notPublishable/deadlineSkipped` 语义（判定权归内核的 `isVerdictKind`） |
| `LatencyEngine.ets` | `probeOffline()` + `DirectLatencyTester` import | **离线直连兜底通道**：测的是「服务器可达」（TCP/TLS 握手），不是代理延迟 |
| `commons/services/DirectLatencyTester.ets` | 整个文件 | 同上（唯一调用方是引擎的 `probeOffline`） |

### 8.3 行为变化（**有代价，说清楚**）

1. **没有内核通道 ⇒ 不探测**（`LatencyEngine.start(null, …)` 直接收尾）：
   节点保持「未测(--)」，不再显示 `≈123ms` 的离线读数。
   ⚠ 旧的 ≈ 读数是**渲染在普通延迟列里**的（`LatencyStore.describe` 的 `≈` 前缀），
   不是独立的一列 ⇒ 删掉之后，「内核没起来」时那一列从「≈123ms」变成「未测(--)」。
   ⇒ 这是**有意的**：服务器近 ≠ 线路快，混进延迟列会把排序带偏。
2. **排队超时不再落节点结论**（内核判定表里 `queue_timeout` 是非判定）：
   这一轮根本没拨号，与节点/出口无关 ⇒ 沿用该节点上一次的有效结论，
   并且**不再计入 `progress.timeout`**（只计 `progress.queueTimeout`）。
   ⚠ 旧实现会把排队超时写成「超时」并盖章 —— 那与「节点真超时」混为一谈。
3. **`unknown` / `unsupported` / `port_reachable_only` 一律不落结论**（同判定表）。

### 8.4 引擎现在长什么样

```
LatencyEngine
├── run()                    整批编排：一次 DNS 快照 → worker 池 → 收尾
├── worker()                 调度：跳过新鲜结果 / 标记 TESTING / 调探测 / 落结论 / 进度
├── gatedProbe()             在途闸门（LATENCY_INFLIGHT=8）+ 排队上限 + 取消 + 整批硬截止
├── probeThroughCore()       探测 + 通道级故障（core_not_ready 重试/连击/自愈/作废整批）
├── recordFor()              **唯一的落结论入口**（判定问内核的 isVerdictKind）
└── clearOwnTestingMarks()   收尾：收回本批的 TESTING 标记
```

### 8.5 闸门

* `scripts/verify-latency-core-v2.mjs` —— I1..I13（I10「旧通道已删」、I11「分类表模块零 import」、
  I12「陈旧判定/阈值只有一份」、I13「唯一判定表的行为钉死」：非判定类一律不落结论、
  `cancelled` 不许再漏、**空串必须是结论**）。
* `scripts/verify-latency-engine-runtime.mjs` —— D 组（离线通道的两段旧断言改成
  「没有内核通道就不探测」）。
* `scripts/verify-latency-concurrency.mjs` —— A1..A5 + B 组（旧的「兼容接口行为不变」
  改成「旧兼容口已删除」）。
* `scripts/verify-no-divergence.mjs` —— ND02/ND05/ND13/ND14 的「允许清单」随真源搬家改成
  **「真源 + 必须派生/必须转调」**（`methodBody` 取方法体、`delegatesToKernel` 判转调；
  ND14 额外禁「自己算年龄」`nowMs -`）⇒ 比固定白名单更有牙齿：真源里改了、别处没跟着转调也判红。

### 8.6 判定表与陈旧表收敛到一份（2026-10-20 lead 拍板）

| 规则 | 旧形态 | 现形态（唯一真源） | 谁转调 |
|---|---|---|---|
| 「算不算节点结论」 | 正表 `isVerdictKind`（内核）+ 反表 `isNonVerdictKind`（`LatencyPolicy`）**两张表** | `LatencyKinds.LatencyProbeKind.isNonVerdictKind`（**一张反表**）；正表由它派生 | `LatencyStore.isVerdictKind`、`LatencyEngine.recordFor`、`LatencyPolicy.isNonVerdictKind` |
| 「结论陈旧没有」 | `LatencyState.isStale` / `isStaleConclusion` / `LatencyStore.describe` **三条不同规则** | `LatencyKinds.LatencyProbeKind.isStale` + `STALE_MS` | `LatencyStore.describe`、`LatencyPolicy.isStale`、`LatencyPolicy.isStaleConclusion` |

* ⚠ **空串不进非判定表**：`''` = 实测出了延迟 = **一个真结论**
  （写路径 `LatencyStore.applyProbeResult` 依赖它；派生式写错会把实测延迟整条丢掉）。
* ⚠ **`cancelled` 是非判定类**（主动取消不是节点结论）—— 旧正表里它就是非判定，别再漏。
* 「年龄未知（`testedAt<=0`）的**失败结论**算陈旧」这条假红防线**不许丢**
  （`LatencyKinds.isStale` 的 `testedAtMs <= 0 ⇒ return isFailure` 那一支）。
* 文案：`network_unreachable` ⇒ 红「**拨号失败**」（不是「失败」，也不是用户骂过的「网络不可达」）。


---

## 12. `LatencyPolicy` 迁移（2026-10-20 lead 拍板）

`commons/services/LatencyState.ets` 里的 `LatencyPolicy` 长期是「什么都装」的杂货铺，
三类完全不同的东西混在一个类里。本次按职责拆开：

| 类别 | 成员 | 迁往 | `LatencyPolicy` 现在的角色 |
|---|---|---|---|
| 判定表 | `isNonVerdictKind` / `isStale` / `isStaleConclusion` / `STALE_MS` | `latency/LatencyKinds.ets` 的 `LatencyProbeKind` | 转调 getter/别名 |
| 探测策略 | `isValidDelay` / `isBuiltinNode` / `isLoopbackOrLocal` / `isTestableType` | `latency/LatencyKinds.ets` 的 **`LatencyStrategy`（新）** | 转调别名 |
| 超时数值 | `DEFAULT_TIMEOUT_MS` / `MAX_TIMEOUT_MS` | `latency/LatencyKinds.ets` 的 **`LatencyTimeout`（新）** | 转调 getter |
| 记录级排序 | `sortRank` / `compare` | **留在原处** | 唯一实现 |

### 为什么排序不迁

`sortRank` / `compare` 的入参是 `LatencyRecord`（services 层的类型），
而 `LatencyKinds.ets` 是**零 import** 模块（services 侧能值依赖的必须是零 import，
否则 Node 侧「扁平暂存」闸门会 ERR_MODULE_NOT_FOUND）。
把「状态 → 档位」的映射单独下沉也试过，但那只是一张 switch，搬走反而要多传 6 个状态常量
⇒ 判定：排序留原处，并在类注释里写清理由。

### 为什么超时要留两个常量

`LatencyProbeLimits.NODE_TIMEOUT_MS`（探针自身预算）与
`LatencyTimeout.DEFAULT_TIMEOUT_MS`（调用方可见的超时契约）数值必须相同（都是 5000），
但 `LatencyProbe.ets` 会 import `models/AppSettings`，而 `LatencyEngine` 只引
`ClashApiService` —— 为免把 probe 整条依赖链拖进引擎，两边保留独立常量，
由 `verify-latency-core-v2` 断言**数值相等**。

### 迁移后的一致性保证

- `LatencyKinds.ets` 仍然**零 import**（`verify-latency-core-v2` 的 I11 断言）。
- 所有策略/判定只有**一份实现**（`verify-no-divergence` 14/14）。
- `LatencyPolicy` 里**不许再出现** `DEFAULT_TIMEOUT_MS: number = 5000` 这类字面量
  （`verify-latency-display` 新增反例断言）。
