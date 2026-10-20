# 代理频繁自动断开 —— 真机取证与根因分析

- 日期：2026-10-20
- 设备：HarmonyOS NEXT（HongMeng Kernel 1.13.0，aarch64），`com.tunbox.client`
- 复现窗口：2026-10-20 09:47:46 ~ 09:49:04（真机 hilog + 设备侧配置 + Clash API 交叉取证）
- 怀疑范围：昨日提交 `5745028`（v0.4.2，10-19 22:56）及其同日的 `1c73c3e`（0.4.1 稳定性回退，10-19 11:26）
- 结论一句话：**"已断开" 是一次误判（core died 的假阳性）—— 不是内核真死，而是 10s 存活租约刷新被卡住，心跳文件超过 15s 判陈旧，UI 判定 core-dead 走 rebuild-tun → disconnect → 状态机落到 DISCONNECTED，用户直接看到"已断开"。**

---

## 1. 现象链（真机 hilog，app domain 0x5256）

```
09:47:46.158  [reconnect] net change gen=8 cellular -> wifi
09:47:46.659  vpn onCreate (ext pid 13717)
09:47:47.125  core start result: true
09:47:47.339  connected to node 🇭🇰 香港Z01
09:47:47.380  UiGuardian: guardian engaged
   （traffic diag ×3：09:47:49.332 / 09:47:51.424 / 09:47:53.648 —— UI 进程一直活着在轮询）
09:48:23.696  core died (authority: heartbeat stale/absent); escalating to health self-check
09:48:23.776  [health] report overall=broken pass=2 fail=4 skip=4 firstFail=tun
09:48:23.778  [health] repair steps(max=2)=rebuild-tun > restart-core
09:48:23.868  runtime artifacts cleared: mihomo_config.yaml,vpn_start_params.json
09:48:23.876  disconnected            <=== 用户看到的"已断开"
09:48:23.921  UiGuardian: guardian released
09:48:28.067  vpn onCreate (ext pid 15004)   —— 4s 后自动重连
09:48:55.918  core died (heartbeat stale/absent)     —— 第二轮，形态完全一致
09:48:56.957  disconnected
09:49:00.340  vpn onCreate (ext pid 16319)
09:49:04.276  core start result: true
   （此后 UI 再无任何日志：卡在 CONNECTING，直到 10:01 仍未恢复）
```

**关键点：extension 从未崩溃、也没有被系统杀。**
- 进程存活：UI pid 24593、ext pid 16319；
- 无 LowMemoryKill / lmkd / kill 记录（全量 hilog 检索）；
- ext 13717 / 15004 是被 App 自己 `stopVpnExtensionAbility` 正常拆掉的；
- 事后 `vpn_heartbeat.txt` 内容与 mtime 仍在按 ~10s 刷新（10:01:05.601），`vpn_status.json` = `phase=running, coreAlive=true`；
- Clash API 正常：`/version` → mihomo 1.10.0、`/proxies/PROXY` → `now=♻️ 自动选择`、`/connections` → 有连接。

**=> 内核一直是活的。"core died" 是假阳性。**

## 2. 断开是怎么发生的（代码路径）

| 环节 | 位置 |
|---|---|
| UI 监控每 3s 读心跳 | `ConnectionOrchestrator.ets:3550-3572` → `isCoreAliveByHeartbeatAsync()` |
| 判陈旧阈值 15s | `ConnectionOrchestrator.ets:137-171`（`HEARTBEAT_STALE_MS = 15000`） |
| 判死后升级健康自检 | `handleCoreLossAsync()` `:1201-1250` |
| 自检失败 → 修复动作 | `:1100-1172`（`repair steps(max=2)=rebuild-tun > restart-core`） |
| 修复动作 = 断开+重连 | `repairReconnect()` `:1174-1195` → `disconnect()` `:3030-3058` |
| 状态落到 DISCONNECTED | `disconnectExclusive()` 里打 `'disconnected'`（`:3057`）→ **UI 卡片显示"已断开"** |

也就是说：**任何一次"心跳陈旧/缺失"都会直接走"拆隧道"这条路，没有二次确认、没有宽限期、也没有"内核忙"这个中间态。**

## 3. 心跳租约为什么会被卡住（关键设计缺陷）

租约的**唯一**刷新点在 Extension 侧：

```ts
// VpnExtensionAbility.ets:790-812
this.coreMonitorTimer = setInterval(() => {
  if (this.connection === null || this.recoveryRunning || this.rebuilding || !this.networkAvailable) return;
  coreBridge.isCoreAlive().then((alive) => {
    ...
    this.touchLivenessLease(Date.now());   // ← 只有这里会刷新租约
  })
}, 10000);                                  // ← 10s
```

而这个 `isCoreAlive()` 最终会**同步阻塞 ArkTS 的 JS 线程**：

```
ConnectionOrchestrator/CoreBridge.ets:127  async isCoreAlive() { return nativeModule.isCoreAlive(); }
ssrvpn_core_napi.cpp:354  static napi_value IsCoreAlive(...) {
      const bool alive = loadCore() && g_running.load() && g_alive != nullptr && g_alive() == 1;   // ← 同步进 Go
}
bridge/bridge.go:401      func IsRunning() bool { coreMu.Lock(); defer coreMu.Unlock(); return running; }  // ← 抢 coreMu
```

**三重放大效应：**

1. **租约周期 10s，判定阈值 15s —— 只有 5s 余量，漏掉一次刷新就判死。**
2. `g_alive()` 会去抢 Go 侧 `coreMu`；`coreMu` 在 `Start()` / `Stop()` 整个过程里都被持有（含 `executor.Shutdown()`）。**内核忙 / 正在起停时，ArkTS 的 JS 线程会被卡在这次 NAPI 调用里，连 `setInterval` 回调都跑不了 → 租约彻底停更。**
3. 续租任务和"判死"任务在**两个不同进程**里靠一个文件耦合，UI 没有任何办法区分"内核死了"和"内核正忙"。

## 4. 昨天为什么让它更容易发生 —— 两处改动叠加

### 4.1 `1c73c3e`（10-19 11:26）DoHResolver 重写：**"短 TTL 一律不 pin"**

- 实测机场入口域名 TTL 只有 **51~60s**（`/dns/query` 真机实测：`v.b.p.i.y.e.y.8.d.hk01-ae5...` → TTL 54/53/52/51/59/60）。
- `DoHResolver.resolveMany()` 对短 TTL 域名直接拒收（`DoHResolver.ets:242-296`）→ 日志实证：
  ```
  DoH pinned 0/102 proxy servers
  unpinned servers: v.b.p.i.y.e.y.8.d.hk01-ae5.entry..., z.b.k.6.y.e.m.8.d.hk02-ae5.entry..., ...
  ```
- **生成到设备上的 `mihomo_config.yaml` 里根本没有 `hosts:` 段**（`grep hosts` = 0 命中，1233 行配置）。
- 后果：**100% 的节点入口域名只能由内核自己在运行期解析**，而且每 ~55s（TTL 到期）全部重来一遍。

### 4.2 `5745028`（10-19 22:56，HEAD）`proxy-server-nameserver` 明文 UDP → **DoT**

```diff
-    lines.push('    - 223.5.5.5');
-    lines.push('    - 119.29.29.29');
+    lines.push('    - tls://223.5.5.5:853');
+    lines.push('    - tls://1.12.12.12:853');
```

设备侧现网配置已确认生效：

```yaml
  proxy-server-nameserver:
    - tls://223.5.5.5:853
    - tls://1.12.12.12:853
  fallback:
    - tls://1.1.1.1:853        # ← 国内不可达
```

同一次改动里的注释自己承认了旧前提已不成立（"0.4.0 起 DoHResolver 改成短 TTL 一律不 pin → 内核运行期必须自己解析"），**但只改了 DoT，没有把 pin 修回来**。

### 4.3 两者叠加 → 内核被压满

- 107 个节点的入口域名，内核每分钟要自己解析一遍，每次要走 **DoT 的 TLS 握手**；
- `♻️ 自动选择` 是 **type: smart、107 个成员**、`url: http://www.gstatic.com/generate_204` 的健康检查组，外加 `AUTO`(url-test, 300s)、`自动选择`(url-test, 86400s)、`故障转移`(fallback, 7200s)；
- core.log 实证这些健康检查正在超时：
  ```
  01:49:09.742Z  🇸🇬 新加坡Z01 | IEPL | x2 failed to get the second response from
                 http://www.gstatic.com/generate_204: context deadline exceeded
  01:54:18.345Z  新加坡02aws failed to get the second response ... context deadline exceeded
  ```
  （并伴随 "HTTP 不建议做健康检查地址" 的告警）
- 附带问题：`fallback: tls://1.1.1.1:853` 在国内不可达，而默认 `fallback-filter: geoip:true` 会因为入口域名解析到 **CN 段 IP（36.141.40.13）** 而优先采用 fallback 结果 → 每次解析白白多等一个不可达端点。

**=> 内核周期性变忙 → ArkTS JS 线程卡在 `isCoreAlive()` → 10s 租约漏刷 → 15s 判陈旧 → rebuild-tun → "已断开" → 4s 后自动重连 → 内核又忙 → 循环。周期 27~36s 与健康检查/TTL 周期的量级吻合。**

## 5. 修复建议（按优先级）

**P0 — 别让"内核忙"被当成"内核死"**

1. **续租与内核探针解耦**：Extension 里加一个独立的 10s 租约定时器（只判断 `connection !== null && !stopped`），不要把续租挂在 `coreBridge.isCoreAlive()` 的 `.then()` 上。
2. **让 `IsCoreAlive` 不阻塞 ArkTS JS 线程**：C++ 侧改成读一个由 Go 侧原子更新的 flag（`g_alive` 走无锁原子），不要在 JS 线程上同步抢 `coreMu`。
3. **UI 侧加二次确认**：心跳陈旧必须**连续 N 次**（建议 3 次 × 3s）且 `vpn_status.json` 的 `phase/coreAlive` 也对不上，才判 core-dead。
4. **`repairReconnect()` 不要把状态落成 `DISCONNECTED`**：修复过程中保持 `RECOVERING`，否则 UI 一定会闪"已断开"。

**P0 — 修回 pin，核心不要自己解析**

5. `proxy-server-nameserver` **改回明文 UDP/53**（`223.5.5.5` / `119.29.29.29`）。这个字段只用于解析**代理服务器域名**，防投毒应该由 UI 侧 DoH 预解析 + `hosts:` 承担，而不是把 DoT 压到拨号关键路径上。
6. 或者修 DoH pin 策略：机场**入口域名** TTL 只有 ~55s，"短 TTL 不 pin" 对它们是错的 —— 按 TTL 当 lifetime pin 住、每次连接刷新，就能让 `hosts:` 重新非空，内核运行期零解析，DoT 也就无害了。
7. `fallback: tls://1.1.1.1:853` 在国内不可达：要么删掉，要么显式写 `fallback-filter: { geoip: cn }` 并确认 fallback 端点可达。
8. 降低 `♻️ 自动选择` 的健康检查开销（成员数或检查间隔），核心被压满是整个问题的放大器。

**P1 — 心跳文件本身加固**

9. Extension 写心跳用的是 `READ_WRITE|CREATE|TRUNC` + `writeSync`，**存在 0 字节窗口**；UI 侧 `readCappedAsync` 读到 `size<=0` 会得到 `text=''` → `heartbeatAgeFromText('')` = **-1** → 判"无心跳"→ 假死。改成"临时文件 + rename"原子替换，或把"读空/读失败"当成**未知**（沿用上次值）而不是**死亡**。

## 6. 本次取证实物

| 证据 | 来源 |
|---|---|
| 111054 行全量 hilog | `C:\Worker\tunlog\hilog_all.txt` |
| 设备侧现网配置 | `/data/app/el2/100/base/com.tunbox.client/haps/entry/cache/mihomo_config.yaml`（含 `proxy-server-nameserver`/`fallback`/`nameserver-policy`） |
| 心跳/状态文件 | 同目录 `vpn_heartbeat.txt`（mtime 10:01:05）/ `vpn_status.json`（`phase=running, coreAlive=true`）/ `vpn_start_ok.txt`（09:49:04.275） |
| Clash API | `hdc fport tcp:19090 tcp:9090` + `Authorization: Bearer <secret>`：`/version`、`/proxies`、`/proxies/♻️ 自动选择`（type=Smart, now="Smart - Select", 107 成员）、`/connections`、`/dns/query`（TTL 实测） |
| 内核日志 | 设备侧 `core.log`（mihomo，含 health-check 超时记录） |
| 昨日改动 | `git diff 6cc11e0 HEAD`：`ClashConfigGenerator.ets`(+85)、`YamlMerger.ets`(+171)、`DoHResolver.ets`(+162/-27)、`ConnectionOrchestrator.ets`、`PrivateFileStore.ets`、`RuntimeFilePolicy.ets`、`BackgroundTaskWatch.ets`、`UiGuardian.ets` |
| 另一次会话（用户指的那次） | `C:\Users\Administrator\.dsh\sessions\--C-Worker--\74a9a4ec-45e3-4a6a-b2d7-c132c95197ae`（FlClash 保活机制逆向 + re-arm 整改的**作者会话**，10-18 19:42 → 10-20 09:52；TunBox 代码落地窗口 10-19 11:46:10–11:48:14）。注：原先记的 `241eb1eb` 是该会话派生的子代理（`ohos-spec`，只做官方平台语义调研、零代码改动），已更正） |

---

## 7. 官方文档核对（harmonyos-developer-knowledge MCP，2026-10-20）

### 7.1 用到的平台能力都是官方支持的 ✅

| 项 | 官方依据 |
|---|---|
| `on('continuousTaskCancel')` 监听长时任务被取消 | 《长时任务(ArkTS)》API 15+ 官方示例明确给出；回调带 `info.id` / `info.reason` |
| 取消后重新申请长时任务 | 同上：「用户再次点击音乐播放时，需重新申请长时任务」—— 重新申请是官方范式 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 《权限列表》：权限级别 **normal**，system_grant，**无需 AGC 审批** |
| dataTransfer 进度心跳（实况窗） | 《长时任务》：「进度长时间（超过10分钟）未更新，数据传输的长时任务会被取消」「更新进度的通知类型必须为实况窗」；`MODE_DATA_TRANSFER` ↔ `SUBMODE_LIVE_VIEW_NOTIFICATION` 配对。TunBox 5 分钟一推 → 合规 |
| 长时任务保护全应用进程不被挂起 | 《长时任务》约束与限制：「一个UIAbility申请长时任务后，整个应用下的所有进程均不会被挂起」 |
| `onMemoryLevel` / MEMORY_LEVEL_CRITICAL | 《AbilityStage》《bpta-retrieve-process-memory-info》 |
| 卸载主线程阻塞 | 《CPU密集型任务开发指导》「CPU密集型任务…不适合在UI主线程中执行」+ TaskPool(≤3min)/Worker 官方方案 |
| 进程被系统清理不回调 onDestroy | 《应用退出》：系统因资源回收/内存紧张/电量优化等强制清理时**不触发 onDestroy** |

### 7.2 需要修正的两处 ⚠️

**(1)「1 秒无条件重挂」直接命中官方《Background Tasks Kit 接入规范》两条违规条目**

违规处罚标准把这两条列为**违规行为**：

> · 用户主动停止（通过删除长时任务通知、删除AVSession通知等方式）并取消长时任务后，**立即再次申请长时任务**。
> · 在系统检测到应用不合理使用长时任务，并取消/暂停长时任务后，**不得立即再次申请长时任务**。

处罚：严重影响 → 立刻在违规场景禁止使用长时任务；轻微影响 → 7 个自然日内整改，否则禁止使用。

从 FlClash 逆向来的「取消后 1 秒无条件重挂」正是这两条的教科书式命中。官方 API 提供 `ContinuousTaskCancelInfo.reason` 正是为了让应用区分这两种情形 —— TunBox 已经把 reason 存进 `BackgroundTaskWatch.lastCancelReason`，但**没拿它做判定**。

合规改法：按 reason 分流 —— 用户主动删通知 / 系统判定不合理使用 → 不自动重挂（回到需要显式用户操作，或复用原抑制态）；其余（进程被杀后重启等）→ 允许重挂。

**(2) 长时任务类型选错：应当用 `taskKeeping`（计算任务），不是 `dataTransfer`（数据传输）**

- 官方场景表：`DATA_TRANSFER` =「非托管形式的上传、下载，如在浏览器后台上传或下载数据」；`TASK_KEEPING` =「计算任务。场景举例：**如杀毒软件**」。
- 官方 `BackgroundTaskMode`：`MODE_TASK_KEEPING|9|计算任务。**仅对PC/2in1设备开放，或者非PC/2in1设备但申请了ACL权限为 ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM 的应用开放。**`
- 官方《接入规范 · 受限开发权限申请原则》1：「应用使用计算任务类型长时任务，可申请 ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM 权限。」
- 官方《受限权限》：该权限「从API 11 等级为 system_core；从 API 12 变更为 system_basic，**向普通应用开放**；从 API 26.0.0 开始支持在全设备上申请」。
- **TunBox 设备是手机（非 PC/2in1）→ 走通 `taskKeeping` 需要 `KEEP_BACKGROUND_RUNNING_SYSTEM`；当前只声明了 `KEEP_BACKGROUND_RUNNING`（normal）→ 需要补申请受限权限。**
- 主类型/子类型对照表：`MODE_TASK_KEEPING` ↔ `SUBMODE_NORMAL_NOTIFICATION`（普通通知）→ 顺带摆脱 dataTransfer 的「必须实况窗 + 10 分钟内必须更新进度」约束。
- 运行时约束：「**若运行长时任务的进程后台负载持续高于所申请类型的典型负载，系统会对应用进行管控，即应用退至后台会被挂起或终止**」—— dataTransfer 的典型负载是"上传/下载"，而核心在后台跑 107 节点健康检查，**负载形态与类型严重不匹配** → 这本身就是"被挂起/被终止"的风险源，也就是"租约停更 → 误判 core died → 断开"的上游放大器。
- 接入规范「不得在超出长时任务类型规定的场景使用，保证应用后台执行的业务与申请的任务类型一致」。TunBox 自己的注释也承认：「dataTransfer 的规定场景是'非托管形式的上传、下载'；本用途（隧道保活）按'持续数据传输'口径使用，原定用途需在 AGC 应用介绍中提前声明」。

### 7.3 官方还有一条昨天没接的通道

`on('continuousTaskSuspend')`（API 20+）：长时任务被系统**暂停**（而非取消）时触发。TunBox 只监听了 `continuousTaskCancel`，**没监听 suspend** —— 任务被暂停时不会触发 cancel 事件，但应用已失去"不被挂起"的资格（挂起后定时器全停 → 租约停更）。这条必须补。

### 7.4 VPN 侧官方约束（影响重连风暴的修复）

- 《连接VPN》：「当调用 startVpnExtensionAbility 接口的应用进程退出时」「当VPN服务进程销毁时」系统会主动停止 VPN → **UI 进程必须活着**，这正是连续任务的作用，官方支持。
- 「目前系统仅支持启动一个VPN连接服务，当VPN已经启动时应用新调用启动接口会收到系统拒绝错误」→ 重连风暴里 4s 后再 start，必须能优雅处理"上一个还没完全停"的拒绝。

### 7.5 上一轮建议的 P0/P1 在官方文档里的落点

| 建议 | 官方依据 |
|---|---|
| 租约续期与内核探针解耦 | 《Background Tasks Kit简介》「应用进程挂起后，无法使用软件资源（如公共事件、**定时器**等）」→ 定时器本身不可靠，租约不能只挂在一次 native 调用上 |
| `IsCoreAlive` 不阻塞 ArkTS 主线程 | 《CPU密集型任务开发指导》「不适合在UI主线程中执行」；TaskPool / Worker 官方方案 |
| UI 侧连续 N 次才判死 | 平台无直接对应条目，但《长时任务》整体思路（系统会做业务真实性一致性校验）支持"先确认再拆" |
| 心跳文件原子替换 + 读空视为"未知" | fileIo 的 rename/moveFile 属官方 CoreFileKit API |
| `onMemoryLevel` 降级 | 官方 AbilityStage 回调，已实现 |

### 7.6 结论

1. **昨天改动用到的平台能力都是官方支持的**（`continuousTaskCancel` 监听、取消后重新申请、实况窗进度心跳、`KEEP_BACKGROUND_RUNNING` normal 权限）。
2. **但「1 秒无条件重挂」是官方明文列举的违规行为；「用 dataTransfer 承载隧道保活」是官方场景表外用法** → 这两处必须改。
3. **真机日志证明这次整改没有触及本次自动断开的根因**：09:47:47.380 连续任务挂上后，直到 09:48:23.921 始终健康，**全程没有出现 `continuous task canceled externally`**，重挂代码根本没被触发过。自动断开发生在「连续任务健康 + 内核健康」的前提下 → 根因仍在租约/协议层的假阳性（见 §2 / §3）。
4. 官方文档反而给了一条**能直击症状**的新路径：换成 `taskKeeping` + `KEEP_BACKGROUND_RUNNING_SYSTEM`，让"隧道保活"用计算任务类型合规承载，顺带消除"典型负载不匹配 → 被挂起/被终止"这条放大链。
