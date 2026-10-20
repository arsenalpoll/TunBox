# 测速「秒开」整改：点了测速要等几秒才开始 —— 根因、整改与真机验收

- 日期：2026-10-20
- 关联文档：`LATENCY_FALSE_TIMEOUT_FIX_2026-10-20.md`（上一轮：冷启动「假超时」根因修复，提交 `7702eaa`）
- 设备：HUAWEI 设备（`192.168.10.6:39933`），包名 `com.tunbox.client`，debug 签名 HAP
- 结论一句话：**「点测速 → 几秒后才开始测速」的延迟来自测速通道的「固定预热等待 + 现场启动内核」；整改后热路径 17ms 起跑，冷路径 3.37s（其中 2.37s 是内核启动的硬成本）。**

---

## 一、现象

用户原话：

> 还有就是为什么点了测速以后，等几秒钟才开始测速

即：点「测速」按钮后，UI 上要过好几秒才有反应/才有结果，用户以为没点上。

**场景前提**：手机**未连接** VPN（`ConnState.DISCONNECTED`）。已连接时走真实隧道 controller，不存在本问题。

---

## 二、根因（真机 hilog 时间线）

### 2.1 旧实现的通道准备链路

`SubscriptionPage.speedTestSub` → `BackgroundLatencyService.testSubscription` → `execute` → `orchestrator.ensureLatencyApi()` → `ensureTestCore()`。

未连接时 `ensureLatencyApi()` 必须现造一个 headless 测速内核：

```
DoH 预解析（~850ms） → 生成/写配置（~55ms） → 停旧扩展（+600ms 固定等待）
  → 启扩展进程 headless（~165ms） → 内核就绪轮询（~190ms）
  → 【固定预热 sleep 1500ms】 → 才发出第一个探测
```

上一轮真机取证（2026-10-20 13:30，未连接场景）：

```
13:30:24.918  latency channel: headless test core ready
13:30:26.421  latency batch start            ← 与 ready 相隔 1503ms（= 固定预热）
13:30:30.822  latency batch done nodes=7 measured=7 elapsed=4401ms
```

连接路径同轮取证：`13:34:12.817 → 13:34:14.546`
（prep=30ms / prelaunch=886ms / launch=1110ms / ready=1709ms / total=1759ms，其中 DoH 段 ≈ 854ms）。

### 2.2 三个可归责的原因

| # | 原因 | 代价 |
|---|---|---|
| A | **`ensureLatencyApi()` 里那句无条件 `await new Promise(setTimeout, 1500)`**。它是「内核刚起来、controller 还冷」的保护窗（真机取证 2026-10-17：`code=2300028 Operation timeout`，整批中止），但被写成**调用方的固定等待** → 连「内核早就热了」的复用路径也白等 1.5s | 每次取通道固定 +1.5s |
| B | **内核在现场才启动**（DoH 预解析 + 写配置 + 停旧扩展 + 启扩展 + 就绪轮询）。这段准备与用户意图无关，完全可以提前做 | 每次取通道 ≈ +2.4s |
| C | **UI 没有区分「正在准备通道」和「正在测速」**，用户点下去后看到的是「没反应」 | 体感上把 1.5~4s 全部算成「卡住」 |

> 结论：tap → 首个探测 ≈ **3~3.5s**（已连接场景 ≈ 1.8s）。

### 2.3 设计返工（重要）

初版整改把 1500ms 的真 `sleep` 放进了 `launchTestCore()` 里。**否决**：
`SingleFlightTestCore` 的启动超时上限是 15s，启动路径内再睡 1.5s 会顶高这个上限 →
DoH 慢时可能「白拆一次再重启」，反而更慢。

定案口径：**预热窗口是内核的属性（`testCoreWarmAt` 时间戳），不是调用方的固定等待**：

- 新鲜启动 → 登记 `warmAt = now + 1500ms`，调用方按**剩余**窗口等（与旧实现同长，总耗时不变）；
- 复用已在服务的内核 → 窗口早已过去 → **一句都不等 → 秒开**；
- **启动路径内不做真实 sleep**（闸门 A2c 钉死这条）。

---

## 三、整改内容

| 文件 | 改动 |
|---|---|
| `commons/services/ConnectionOrchestrator.ets` | ① 新增常量 `TEST_CORE_WARMUP_MS = 1500`、`TEST_CORE_IDLE_RECYCLE_MS = 90000`（后者独立定义，避免与 `LatencyEngine` 循环 import）；② 新增字段 `testCoreWarmAt`（内核「预计变热」时刻）；③ `launchTestCore()` 就绪分支**只登记** `testCoreWarmAt`，不再 sleep；④ 新增 `awaitTestCoreWarmup()`（按剩余窗口等，复用路径 0 等待）；⑤ `ensureLatencyApi()` 每次取通道都重挂 90s 回收（回收窗口从「最后一次使用」起算，避免预热挂的回收在测速进行中触发）；⑥ `connect()` 在 `stopVpnExtensionAbility` 之前先拆掉测速核（`connect: tearing down test core before starting real tunnel`），保证真实隧道不被测速核占着；⑦ 新增公开 `prewarmLatencyChannel()`（只让内核进入可服务状态，**不产生任何探测**） |
| `commons/services/BackgroundLatencyService.ets` | ① `testSubscription` / `execute` 增加 `onChannelReady` 回调；② 新增 `static prewarmChannel(context)`：init orchestrator/settings/subs → 无节点直接返回 → `orchestrator.prewarmLatencyChannel()`，异常吞掉并记 warn |
| `pages/SubscriptionPage.ets` | ① `bootstrap()` 末尾调 `BackgroundLatencyService.prewarmChannel(ctx)`（进页面即预热）；② `speedTestSub` 改两段式提示：先「准备测速通道…」，通道就绪回调后再切「正在测速…」 |
| `pages/NodeSelectionPage.ets` | ① `bootstrap()` 末尾调 `prewarmChannel(ctx)`；② `runLatency()` / `runGroupLatency()` 改为先 `await orchestrator.ensureLatencyApi()` 再测，顶栏显示「准备测速通道…」状态 |
| `scripts/verify-latency-warmup.mjs` | **新增闸门**（28 条断言 A1~A12 + A2b/A2c）：剥注释双视图匹配 + 花括号配对截方法体 + 常量查表解延迟值；A2c 锁死「启动路径不得出现 ≥1000ms 真实 sleep」 |

### 3.1 为什么预热是安全的

- 已连接/连接中 → 复用真实隧道 controller，不需要预热（`ensureLatencyApi` 内已判）；
- 编排器忙（连接中/断开中/恢复中）→ `ensureTestCore` 内部安全门禁直接拒绝启动（该门禁用**权威判据**复判，不信任进程内 state）；
- 预热**不产生任何网络探测**、不写延迟结论、不动排序快照；
- 预热成功后必须挂回收，否则内核常驻（与批测后的回收同窗口 90s）。

---

## 四、闸门

```
node scripts/verify-all.mjs
```

- 39 个脚本，`PASS=37 FAIL=2`（两个都是**已知基线失败**：缺 fixture 的 `verify-subscription-fidelity`、SDK 语法缺陷的 `verify-types`）→ **真失败 0**，`RESULT: 全部通过（白名单项已核实为既有缺陷）`。
- `verify-latency-warmup.mjs` 新闸门 **28/28 通过**。
- `verify-arkts-compile.mjs`（DevEco hvigor 真编译 `assembleHap`）**3/3 通过** —— ArkTS 有 tsc 查不到的专属规则，真编译是唯一可信判决。
- `verify-build-profile.mjs` **13/13 通过**（提交前已切回 release 签名，`git diff build-profile.json5` 为空）。

---

## 五、真机验收（debug HAP，设备 192.168.10.6:39933）

### 5.1 预热链路（订阅页进入即预热）

```
14:12:00.929  [reconnect] net change gen=1 (init) -> wifi     ← 冷启动
14:12:04.895  点「订阅」进页面                                ← 触发预热
14:12:07.268  headless test core ready                        ← 内核就绪（启动耗时 2.37s）
14:12:08.771  latency channel: test core warm-up wait 1500ms  ← 新鲜启动等满窗口
14:12:08.772  latency channel prewarmed
```

### 5.2 热路径（预热完成后点测速）—— 本次整改的目标

```
14:12:36.618  ArkUI 接受点击（CLK RACC, T: Row）
14:12:36.635  latency channel: headless test core ready      ← 复用内核，0 等待
14:12:36.635  latency batch start nodes=32 ... channel=core  ← 与点击相隔 17ms
14:12:37.621  latency batch done nodes=32 measured=5 skipped=27 elapsed=986ms
```

→ **tap → 首个探测发出 = 17ms**（整改前 ≈ 3000~3500ms）。

> `measured=5 skipped=27` 是既有语义（`force=false`：静默批次只补缺失/过期结果；27 个节点的结果是 20s 前刚测的、仍然新鲜），不是失败。

### 5.3 冷路径（内核还没起来就点测速）

```
14:12:06.585  点「测速」（此刻内核仍在启动中）
14:12:07.268  headless test core ready
14:12:08.771  warm-up wait 1500ms
14:12:09.956  latency batch start                             ← 与点击相隔 3.37s
14:12:18.211  latency batch done nodes=32 measured=27 timeout=5 elapsed=8254ms
```

→ 冷路径 3.37s = 内核启动 2.37s + 预热剩余 1.5s。**与整改前同长**（整改前是 2.37s + 固定 1.5s + 现场准备），但预热把这 3.37s 挪到了「进页面时后台做」，用户点下去时通常已经就绪。

### 5.4 前后对比

| 场景 | 整改前 | 整改后 |
|---|---|---|
| 未连接 · 进页面后点测速（热） | ≈ 3.0~3.5s | **17ms** |
| 未连接 · 刚进页面立刻点测速（冷） | ≈ 3.9s | 3.37s（内核启动硬成本 2.37s） |
| 已连接 | ≈ 1.8s | 不变（复用真实隧道 controller） |

---

## 六、遗留（本次未做，需单独立项）

1. **测速核空闲后会「假活」（既有缺陷，本次未引入也未修复）**
   真机观察：内核空闲一段时间后，`/version` 探测仍通过，但 `/delay` 全部超时
   （14:07:22 批次 16/35、14:08:30 批次 1/35，报 `2300028 Operation timeout` / `504`），
   直到 14:09:07 探测彻底失败（`2300007`）才被预热重拉恢复。
   **复用路径本次未改动**，旧实现同样会撞上；但本整改把内核「提前」启动，
   空闲时长分布会变化，建议后续单独立项：复用前做真实健康探测，或缩短内核空闲存活窗口。

2. **冷路径的 2.37s 内核启动成本**
   可做：DoH 预解析结果跨启动缓存 / 把预热从「进订阅页」前移到「应用冷启动」。

3. **手动点「测速」的 force 语义**
   现在手动测速走 `force=false`（只补缺失/过期），结果新鲜时第二次点几乎无事可做（实测只测 5/32），
   用户可能觉得「点了没反应」。是否把手动测速改成 `force=true` 待定。

4. 订阅 tab 测速结果落盘、节点页信息条伪节点排除出测速集合等历史遗留项。

---

## 七、提交纪律

- 白名单暂存：`TunBox_HarmonyOS/AppScope`、`TunBox_HarmonyOS/entry/src`、`TunBox_HarmonyOS/scripts`、`TunBox_HarmonyOS/tools` + `oh-package.json5` / `build-profile.json5` / `hvigorfile.ts`；**不使用 `git add -A`**。
- 永不暂存：`dist/`、`material/`、证书、日志、`skills/`、`.dsh-ops-update-*.lock`。
- 提交前敏感扫描（`Lijx\.820115`、`ghp_[A-Za-z0-9]{20,}`、`BEGIN … PRIVATE KEY`）。
- 提交前签名切回 release（`switch-signing.ps1 -Mode release`）+ `verify-build-profile.mjs` 13/13 + `git diff build-profile.json5` 为空。
