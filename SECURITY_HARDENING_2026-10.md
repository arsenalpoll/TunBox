# 2026-10 安全与稳定性修复（凭据隔离 / DoH 缓存 / 会话快照 / 隧道重建）

> 本轮针对上一轮只读审查确认的问题做**代码级修复**。每项都配可执行的回归断言，
> 全部结论标注证据强度：`EXEC`（真跑被测逻辑）、`SOURCE`（源码级不变量）、
> **真机待验**（平台行为，代码无法自证）。
>
> 验证基线：`assembleHap (debug)` BUILD SUCCESSFUL；新增
> `verify-credential-isolation.mjs` 7/7、`verify-doh-cache-runtime.mjs` 9/9，
> `verify-latency-engine-runtime.mjs` 19/19（新增 TESTING 归属守卫）。
>
> ⚠️ **本文第一版的凭据加固引入过一次严重的性能回归**（订阅页要等很久才显示），
> 已修复并加护栏，详见文末「八、性能回归：订阅页加载变慢」。

---

## 一、凭据持久化隔离（最优先）

### 问题（已确认）

Preferences 是**明文**存储，但节点的 `password` / `uuid` / `protocolParam` /
`obfsParam` / `extraOpts` / `rawUri` 会经同一条序列化路径写进 `nodes_json`，
绕过了 AssetStore 加密层。`extraOpts` 可内嵌 `obfs-password`，`rawUri` 是**整条
节点链接**，与 password 同级敏感，不能按字段名猜测是否安全。

### 改动

| 位置 | 改动 |
|---|---|
| `SubscriptionService.nodesToJson` | 拆出持久化专用 DTO：凭据字段**逐字段**清空 |
| `SubscriptionService.storeCredentials` | 返回 `CredentialMigrationReport`，由报告决定哪些字段可清 |
| `SubscriptionService.initNodes` | 回填 `extraOpts` / `rawUri`（两者已从 Preferences 剥离，必须恢复） |
| `CredentialStore.NODE_CRED_FIELDS` | 纳入 `extraOpts` / `rawTemplate` / `rawUri` |
| `CredentialStore.canonicalize` | 写入前**逐条精确回读**，不再把进程内缓存命中当成入库确认 |
| `SubscriptionService.hasVerifiableStoredCredentials` | 覆盖新纳入的 Asset 字段 |
| `SubscriptionService.scanPlaintextResidue` | 扫描**全部**出现位置，修漏报 |

### 关键设计：fail-closed 的**反面**

清空必须坚持：**没验证过入库就绝不能清**。加密层不可用（probe 失败）或该字段
回读不一致时，Preferences 里那份明文是用户唯一可用的副本 —— 此时**保留明文**，
并由 `credentialMissingCount` 与诊断面板如实告知。

按**字段**而非整节点判定：每个字段在 `initNodes` 里独立回填，没有跨字段依赖，
只清已验证的那些能把明文暴露面压到最小，且不丢任何数据。

> `rawTemplate` 是例外：`YamlMerger.buildRawTemplate` 在构造期就剔除了全部凭据键，
> 它是生成端逐字回写依赖的非敏感模板，**必须**持久化。

### 为什么必须写行为测试

`verify-credential-isolation.mjs` 真跑 `nodesToJson` + 凭据判定（SDK 全部桩化）：
断言"写出去的那份 JSON 长什么样"。这个 bug 是**静默**的 —— 功能照常工作，只有
审计才发现。测试覆盖：确认入库即清空、加密层不可用必须保留、报告为 null 必须保留、
单字段失败只保留该字段、未标记视为未验证、direct 节点不受影响、残留审计不漏报。

---

## 二、DoH 缓存过期失效

### 问题（已确认）

`ensureLoaded` 把过期域名加入 `staleQueue` 后紧接着调用 `cachePut`，而 `cachePut`
**无条件** `staleQueue.delete(domain)` → 队列恒空 → `refreshStale()` 直接返回 0。
另外缓存只存 IP 不存解析时间，落盘时给所有条目统一写当前时间，旧记录被不断"续命"。

### 改动（`DoHResolver.ets`）

- 缓存值改为 `DoHPin { ip, resolvedAt }`，**时间属于单条查询**。
- 载入不再清除 stale 标记；只有成功查询才更新该条 timestamp。
- 命中时同样检查年龄（长驻进程不能无限使用已失效 IP）；超上限即删除。
- 刷新失败/预算未处理项**留队**，下次继续。
- `ensureLoaded` / `refreshStale` 加单航班，并发调用共享同一任务。
- SDK 的 connect/read timeout 不是共同截止时间，额外定时 `destroy()` 覆盖完整预算。

`verify-doh-cache-runtime.mjs` 用虚拟时钟真跑解析器（HTTP/Preferences 桩）：
9 项覆盖并发载入、stale 真刷新、落盘不续期、硬过期、失败重试、零预算保留、
未来/非法时间戳拒绝、运行中变过期、并发刷新单航班。

---

## 三、会话快照代次覆盖

### 问题（已确认）

`switchNodeHot` 与 `RECONCILE_INTENT` 新建 `ConnectionSnapshot` 却未填
`phase` / `sessionGeneration`，默认值 `disconnected` / `0` 落盘；而自愈入口
会拒绝 `disconnected` 相位 → 热切节点后冷启动不再自愈。`RECONCILE_INTENT` 还拿
`START_OK` 当存活证据，违背"START_OK 仅启动握手"的约定。

### 改动

- 新增 `SettingsService.patchActiveSnapshot(generation, …)`：**同代**更新，
  校验代次与相位后只改运行字段，不重置 `phase` / `generation`；本进程内串行化。
- `switchNodeHot`：先读快照取代次，`selectNode` 后校验 `connectSeq` 与
  `disconnectRequested` 再 patch（防止旧结果覆盖新会话）。
- `RECONCILE_INTENT`：只用心跳租约作存活判据；无有效证据时**保留**用户意图
  而不是抹掉它。

---

## 四、TUN 重建生命周期与保护通道

### 问题（确认的结构缺口）

`rebuildTunnel` 先销毁旧 TUN 再建新 TUN；失败后销毁候选连接却写 `leak-blocked`，
此时**没有任何 TUN 在阻断**。重建路径也缺少热恢复已有的生命周期校验。

### 改动（`VpnExtensionAbility.ets`）

- 全阶段世代门控 `current()`：每次 `await` 后校验 `lifecycleGeneration` / `stopped`
  / `cleanupPromise`，晚到的 create/start 结果不得提交成新连接。
- `cleanupResourcesInternal` 先递增生命周期使旧 await 失效，再**等待在途
  rebuild/recovery flight 收尾**，最后才 stop —— 消除拆建与清理的竞态。
- 重建失败写 `failed`（不再是 `leak-blocked`），语义与实际状态一致；
  `writeStatus` 里 `leak-blocked` 也按"是否真有 TUN"降级为 `recovering` / `failed`。
- 重建补齐 `initProtect` + `startProtectMonitor`（与首次启动/热恢复对齐）。
- **修复保护请求空窗**：重建期间 `this.connection` 为 null，`drainProtectRequests`
  现在回退到 `protectCandidate`，否则 Go 侧 800ms 回执预算耗尽会 fail-open。
- 无 TUN 时不再刷新存活租约（并删除心跳文件），避免 UI 误判"内核还在"。

> **真机待验（不可由代码自证）**：平台是否在销毁 TUN 后仍阻断流量、IPv6 是否
> 真正被丢弃、以及重建窗口内的实际泄漏。已把代码注释里"杜绝 IPv6 绕行"这类
> 言过其实的说法改为如实描述。

---

## 五、附带修复

- **订阅解析 O(N²)**：`dedupName` 每节点重建 `new Set(existing.map(...))`，
  1000 节点约 50 万次 Set 插入。改用 `SubscriptionNameAllocator` 共享一次遍历的
  名称索引（并记住后缀起点）。已对比验证与旧实现在混合重名序列下输出**逐字一致**
  （`A, A 2, A 3, A 2 2, B, A 4, B 2`）。`dedupName` 保留以兼容调用方。
- **测速 TESTING 跨批次竞态**：旧批收尾会清掉新批在同一节点重新打上的 TESTING，
  表现为"正在测速的行突然变成未测"。`LatencyRecord.runId` 记录批次身份，
  `isTestingOwnedBy` 按归属过滤；`runId=0` 保持旧调用点宽松语义。
- **资产下载**：加 `maxLimit` 上限 + 写临时文件 + `fsync` + **原子 rename**，
  失败不再破坏已就绪的旧资产。明确注释魔数只是格式校验、**不是真实性校验**。
- **更新源**：`UpdateChecker` 指向项目约定的主仓库（原为已冻结的 `SSRVPN_Harmony`），
  新增 `check()` 区分"无更新/检查失败/限流"，网络失败不再显示为"已是最新版"。
  （注：当前无 UI 调用点，属可复用能力。）
- **测试门槛**：`verify-subscription-fidelity.mjs` 缺 fixture 时默认**失败**
  （退出码 1），需有意跳过时显式 `--allow-skip`。避免"没跑用例"被当成"通过"。

---

## 六、验证与基线

```
assembleHap (debug)                 BUILD SUCCESSFUL
verify-credential-isolation.mjs     7/7    （新增）
verify-doh-cache-runtime.mjs        9/9    （新增）
verify-latency-engine-runtime.mjs   19/19  （新增 2 项 TESTING 归属守卫）
verify-logic-pure.mjs               228/228
verify-mihomo-alignment.mjs         102/102
verify-latency-cache.mjs            61/61
verify-proxy-name-uniqueness.mjs    15/15
verify-node-sort-persistence.mjs    16/16
verify-vpn-architecture.mjs         全绿
verify-smart-e2e.mjs                全绿
```

**回归守卫已反向验证**：把 `LatencyController` 的 `rec.runId = runId` 删掉后，
新增归属用例**失败**（`record must carry runId, got 0`）；恢复后转绿 —— 它确实
是一条有效防线，不是恒真的装饰。

**基线说明（与本次改动无关）**：以下属既有问题，在未改动的干净树上同样失败 ——
`verify-app-routing.mjs` / `verify-site-routing.mjs` 断言的是含 `\n` 的源码字面量，
而 Windows 检出是 CRLF（未改动的 `HomePage.ets` 同样是 CRLF，可交叉印证）；
`verify-types.mjs` 用裸 `tsc` 解析不了 SDK 的 `.d.ets`；
`verify-shipped-dns-fix.mjs` 需要传入已签名的 HAP 路径。

---

## 七、仍待完成

### 真机验收（必须，代码无法替代）

1. **隧道重建窗口**：注入 `create` / `protect` / `attach` / `start` 失败，
   抓包验证 IPv4 / IPv6 / DNS 实际走向。
2. **重建期间主动断开**：确认晚到的异步结果不会复活连接。
3. **IPv6**：`isIPv6Accepted: false` 究竟是"平台丢弃"还是"绕过隧道"。
4. **加密层回填**：清除应用数据 / 跨设备后，节点凭据能否从 AssetStore 完整回填。

### 尚未实施（本轮范围外）

- 备份的加密模式与订阅 `headerValue` 完整性（当前备份仍是明文 JSON）。
- 订阅自动刷新调度（`autoUpdateSubscription` 字段已有，但无调度接线）。
- 规则命中搜索与"一键修正规则"、节点搜索/收藏、连接阶段进度。
- 大列表虚拟化（`NodeSelectionPage` / `SubscriptionPage`）。
- `Last-Modified` 误作 `If-None-Match`（需同步改 `Subscription` 模型与调用方）。

### 本轮的坑

- ArkTS 禁止 `throw` 任意类型（`arkts-limited-throw`），也禁止交叉类型
  （`arkts-no-intersection-types`）：`catch (e)` 里必须 `e as Record<string, Object>`
  取 code，并抛 `new Error(...)`。
- 我最初把明文清理写成"整节点全清或全留"，自测用例直接抓出这会多留已验证的
  敏感字段 → 改为**逐字段**清理（暴露面最小且不丢数据）。
- 首版 DoH/归属测试写成了时序型端到端用例，**反向验证时发现它恒真**（删掉修复
  仍然通过）。已改为对机制本身的确定性断言，并保留反向验证记录。

---

## 八、性能回归：订阅页加载变慢（本文第一版引入，已修复）

### 症状

用户反馈："订阅页加载比以前慢得多，要等很久才能显示之前添加的订阅。"

### 根因（两处，都在本文第一版的凭据加固里）

`CredentialStore.canonicalize` 跑在 `SubscriptionService.doInit()` 里，位置在
**订阅列表渲染之前** —— 它的耗时直接等于"订阅页白屏时长"。

1. **去掉了批量确认快路径**（主因）。第一版为"不把缓存命中当成入库确认"，把
   批量读的判定整个删掉，改成对**每个字段**串行做 `read → 可能 write → read`。
   70 节点 × 7 字段 ≈ **500~1000 次串行 IPC**。
   实测护栏数据：200 节点时 **801 次 IPC**（修复后为常数级）。

   > 关键澄清：被删掉的是 **批量 `asset.query`**，那是**真实的 Asset 读取**，
   > 不是进程内缓存 —— 拿它做入库确认并不违反"绝不把缓存命中当成入库确认"这条
   > 安全要求。真正不能信的是 `aliasCache`（进程内）。第一版把这两者混为一谈，
   > 用性能换了一个并不存在的安全性。

2. **分片粒度过小且逐片串行**。为容纳 `rawTemplate`（最长 8192 字符）新增了
   分片存储，但按 **200 字符**分片、每片写完立即串行回读：
   8192 字符 = 41 次写 + 41 次读 ≈ **82 次 IPC**，再乘以节点数。
   读取端同样逐片串行，`loadAllCredentials` 展开分片时也在循环里逐项 `await`。

### 修复

| 位置 | 改动 |
|---|---|
| `canonicalize` | 恢复"1 次批量读"作为权威判据；仅对**新增/变更/无法批量确认**项做精确读写，且**有界并发**（8 路） |
| `writeAsset` | 分片 200 → **512 字符**；写入与校验都改为有界并发 |
| `readAsset` | 分片回读有界并发，按索引回填保证顺序不变 |
| `loadAllCredentials` | chunked 项收集后**并发展开**，不再在 for 里逐项 await |

安全语义**未削弱**：批量查询不可用的固件（`batchQueryUsable !== true`）自动走
逐条精确读；写入后仍必须精确回读一致才 `markStored`；清单只在全部分片可读后发布。

### 护栏

新增 `verify-credential-ipc-budget.mjs`（3/3），把"稳态 IPC 必须是常数级、
且与节点数无关"钉死为断言。**已反向验证**：把批量快路径改回逐条读后，
断言立刻失败并给出量化证据 —— `IPC 次数必须与节点数无关：10 节点=41，200 节点=801`。

### 教训

- 这个回归**没有任何现有测试能发现**：功能完全正常（凭据照常保存/回填），
  只是慢。性能必须有**可量化的护栏**，否则安全加固很容易用性能付账。
- 做安全加固时，要区分"这条读取路径是不是真的可信来源"，而不是笼统地把
  "批量/cache"一律当成不可信 —— 否则会用性能换一个并不存在的安全性。
- `canonicalize` 位于应用启动的关键路径上；任何加进这个函数的逐条 I/O 都必须
  按"乘以节点数"来估算成本。

---

## 九、真正的根因：固件能力被误判且**永久固化**（真机日志定位）

上面第八节的两项都属于"放大器"，但真机日志显示它们不是主因。**必须用真机日志
定位，而不是继续推测。**

### 真机时间线（130 节点 / 4 订阅，冷启动）

```
16:05:37.147  network watcher init
16:05:39.669  alias cache hydrated from asset store (347 alias(es))   ← 2.52s
16:05:41.328  plaintext seal done for 130 node(s)                     ← 1.66s
16:05:41.393  loaded 5 subscriptions, 130 nodes, 19 proxy groups
```

**4.2 秒全部花在凭据路径**，且走了 `hydrateKnownAliases`（逐条读）分支 ——
说明 `batchQueryUsable === false`。但日志里**从未出现** "Batch secret query is
not supported" —— 这台设备的批量查询其实是**可用**的。

### 根因：删除了一道守卫，形成永久误判

`exportAliasCache` 原本有一道前置守卫：

```js
if (CredentialStore.batchQueryUsable !== false) { return '[]'; }
```

**第一版的子代理编辑把它删掉了**（文档注释还在描述它，代码却已不实现）。
语义是"只有确认批量查询不可用，才持久化别名标记"。删掉后形成闭环：

1. 每次 persist 都无条件写出**全部** 347 个别名标记
2. 下次启动 `importAliasCache` 见到标记 → 推断 `batchQueryUsable = false`
3. `loadAllCredentials` 在 `false` 时**直接 return、永不重试** → 能力固化
4. 永远走 `hydrateKnownAliases` 逐条读 347 次 IPC（≈2.5s）
5. 且 `canonicalize` 同时失去批量快路径 → 再叠加 1.66s

即：一次错误推断变成**永久性**的性能退化，且跨版本自愈不可能。

### 修复

| 位置 | 改动 |
|---|---|
| `exportAliasCache` | **恢复守卫**：能力未确认为不可用时返回 `'[]'` |
| `importAliasCache` | 标记只作"待验证的怀疑"，不再是定论 |
| `loadAllCredentials` | **移除 `false` 时的提前 return**：每次都真试一次（1 次 IPC），以真实结果决定能力 → 可自愈历史误判 |
| 空表分支 | 只有"已知存在凭据"时才判定不可用；全新安装不得被误判 |
| catch 分支 | 自己 `hydrateKnownAliases` 兜底（原先靠已移除的提前 return） |
| `doInit` | 别名键只在内容变化时回写，省两次无谓 IPC |

### 护栏

新增 `verify-credential-capability.mjs`（4/4，跑真 `CredentialStore` +
可编程 Asset 桩模拟"支持/不支持批量查询"两种固件）：

1. 批量可用 → `exportAliasCache` 必须返回空表
2. **历史遗留标记不得固化判定** → 真实查询成功必须自愈为可用
3. 批量确实不可用 → 回落逐条读且不丢凭据
4. 全新安装无凭据 → 不得被误判

**已反向验证**：把守卫删掉后断言立刻失败
（`能力未知/可用时不得持久化别名标记…`）；恢复后转绿。

### 教训（比第八节更重要）

- **性能问题必须用真机日志定位**。第八节我基于静态分析"修"了两处放大器，
  症状依旧 —— 真正的主因（能力误判固化）只有日志时间线能看出来。
- **"能力探测"结论绝不能从持久化标记反推**。这类推断一旦短路重试路径，
  就会把一次错误变成永久状态。能力必须由每次真实探测决定。
- 跨进程/跨版本的状态位要问一句：**这个结论有没有自愈路径？** 没有的话，
  任何一次误判都会成为用户永久承担的代价。
- 子代理的大范围编辑会删掉不起眼的守卫（这里连注释都留着、只删了代码）。
  合并后必须对照 `git diff` 逐条确认**被删除**的行，而不只看新增。


