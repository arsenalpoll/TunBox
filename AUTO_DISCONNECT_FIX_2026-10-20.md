# TunBox 自动断开代理 — 根因定位与全量修复（2026-10-20）

配套诊断文档：[`AUTO_DISCONNECT_DIAG_2026-10-20.md`](./AUTO_DISCONNECT_DIAG_2026-10-20.md)

---

## 0. 一句话结论

**自动断开不是「后台保活整改」造成的，也不是 DNS 侧的 DoH pin 策略造成的。**
真正的原因是**跨进程存活租约协议的一处设计缺陷 + 一处同步原生调用**：

> 扩展进程用同一个 10 秒定时器同时做两件事 —— ① 刷新存活租约（心跳文件）、
> ② 探测内核是否活着。而该定时器回调的**第一个动作**就是同步调用
> `coreBridge.isCoreAlive()`，这个原生调用会一路进入 Go 侧 `coreMu.Lock()`
> （`Start()` / `Stop()` 全程持有该锁，内含 `hub.ApplyConfig` 与
> `executor.Shutdown`，可达秒级）。于是**扩展进程的 ArkTS 线程被阻塞，
> 整条定时器链停摆 → 心跳租约停更 → UI 侧 15 秒陈旧窗口判死 →
> 拆隧道重连**。真机上表现为 27~36 秒一轮的"自己把自己断掉"。

与之叠加的第二个缺陷是**信号维度混淆**：扩展侧把"内核不活"编码成"删掉心跳文件"，
于是**一次探针误判**与**扩展进程真的死了**在 UI 侧是同一个信号，无法区分。

---

## 1. 根因链（两条并行，都已验证）

### 链路 A：租约刷新被原生调用阻塞（主因）

| 环节 | 位置 | 现象 |
|---|---|---|
| ① 单定时器双职责 | `VpnExtensionAbility.ets` `startCoreMonitor()` | 10s 回调里先探针、后刷租约 |
| ② 探针同步进 Go | `ssrvpn_core_napi.cpp` `IsCoreAlive()` → `bridge.go` `IsRunning()` | `coreMu.Lock()` 与 `Start()`/`Stop()` 竞争 |
| ③ ArkTS 线程阻塞 | 扩展进程 | 定时器回调排队，心跳停更 |
| ④ UI 判死 | `ConnectionOrchestrator.ets` 监控循环（3s） | 心跳年龄 > 15s ⇒ 判"core died" |
| ⑤ 自愈动作 | `handleCoreLoss()` → `runHealthSelfCheckAndRepair()` → `REBUILD_TUN` → `repairReconnect()` | `disconnect()` + 600ms + `connect()` |
| ⑥ 循环 | 重连又触发内核启动 → 再次持有 `coreMu` → 回到 ② | 27~36s 一轮 |

**关键证据链**：

- `bridge.go:401-405` `IsRunning()` 直接 `coreMu.Lock()`；
  `bridge.go:287-375` `Start()` 与 `bridge.go:377-399` `Stop()` **全程持锁**，
  锁内分别含 `hub.ApplyConfig` 与 `executor.Shutdown()`。
- 真机日志 `core died (authority: heartbeat stale/absent)` 与同毫秒的
  `HiLog: write socket failed, 1 line(s) dropped!` 紧邻出现
  （10-19 14:08:46.127）。
- 故障窗口内 **VPN 扩展进程一条日志都没有**（13:58 → 14:08:48）——
  符合"线程被阻塞住、什么都写不出来"的形态，而不是"进程被杀"。

### 链路 B：信号维度混淆（放大器）

`VpnExtensionAbility.writeStatus()` 旧实现：

```ts
if (coreAlive && this.connection !== null) {
  this.touchLivenessLease(st.ts);
} else {
  try { fs.unlinkSync(this.heartbeatDir + '/' + HEARTBEAT_FILE); } catch (e) { }
}
```

于是：

- 扩展侧**一次**探针误判 ⇒ 删心跳 ⇒ UI 只看到"心跳缺失" ⇒ 立即拆隧道重连；
- 扩展进程真的死了 ⇒ 同样是"心跳缺失" ⇒ 同样拆隧道重连。

两种完全不同的故障被压成同一个信号，UI 无法做区分判断。

### 链路 C：UI 侧把"读不到"等同于"已死"

`ConnectionOrchestrator` 旧实现 `isCoreAliveByHeartbeatAsync()`：

```ts
const age = await this.readHeartbeatAgeAsync();
return age >= 0 && age < HEARTBEAT_STALE_MS;   // age < 0（读不到）→ false → 判死
```

一次文件读失败 / 一次空读 ⇒ 直接判死。而心跳的写入方用的是
`READ_WRITE|CREATE|TRUNC` + `writeSync`，**TRUNC 与 write 之间存在 0 字节窗口**，
读方恰好命中这个窗口就会读到空内容 → `heartbeatAgeFromText('')` 返回 -1 → 判死。

---

## 2. 本次修复清单

### 2.1 `entry/src/main/cpp/ssrvpn_core_napi.cpp` — 探针不再进 Go

```diff
- const bool alive = loadCore() && g_running.load() && g_alive != nullptr && g_alive() == 1;
+ const bool alive = loadCore() && g_running.load();
```

`g_running` 是 `StartCore`/`StopCore` 在 C++ 侧维护的原子量，与 Go 侧 `running`
标志在稳态下等价（Go 侧 `running` 同样不会在内核意外死亡时自动复位 —— 两者都只
反映"启动成功且尚未停止"），但读取是纳秒级且**绝不与任何写者互斥**。

> **为什么不能改 Go 侧**：`bridge.go` 编译进 `libgojni.so`（mihomo v1.10.0 交叉编译，
> 49 MB），本机**没有 Go 工具链也没有 mihomo 源码树**，无法重建。
> 因此修复必须落在 hvigor 会重编的 C++ 层。Go 侧更彻底的做法（`running` 用
> `atomic.Bool` 镜像）留待有工具链时再做。

### 2.2 `VpnExtensionAbility.ets` — 租约与探针彻底解耦

| 改动 | 位置 | 理由 |
|---|---|---|
| 新增独立租约定时器（5s），回调内**不做任何原生调用 / stat / JSON 解析** | `startLeaseTimer()` | 租约连续性不再依赖任何可能阻塞的链路 |
| 租约定时器**不被** `stopCoreMonitor()` 停掉 | `stopCoreMonitor()` | 重建 TUN / 重启内核期间隧道仍存在（Kill Switch 生效），心跳必须继续 |
| `writeStatus()` **不再删除心跳文件**，也不再刷新租约 | `writeStatus()` | 心跳语义收敛为"扩展进程还活着"；内核维度改走 `vpn_status.json` 的 `coreAlive` |
| 内核探针改为**连续 2 次为假才动手** | `startCoreMonitor()` | 单次采样可能是探针与内核状态切换的瞬态错位 |
| 探针异常（原生调用失败）只告警、不升级 | `startCoreMonitor()` | 异常不是"内核已死"的证据 |
| 心跳改为**原子替换**（写 `.tmp` 再 `rename` 覆盖） | `touchLivenessLease()` | 读者要么看到旧内容、要么看到新内容，**永远读不到半个文件** |
| 临时文件纳入清理清单 | `clearStartError()` / `cleanupResourcesInternal()` / `RuntimeFilePolicy.TUNNEL_STATE_FILES` | 不留残留 |

### 2.3 `ConnectionOrchestrator.ets` — 判死改连续多票制

| 改动 | 理由 |
|---|---|
| 新增 `LivenessVerdict` 三态：`ALIVE` / `STALE` / `UNKNOWN` | 把"心跳过期"（强证据）与"心跳读不到"（弱证据）分开 |
| `probeLivenessAsync()` 取代 `isCoreAliveByHeartbeatAsync()` | 旧实现把两者压成同一个 false |
| 判死票数：`STALE` 一次顶满 3 票；`UNKNOWN` 只记 1 票，需连续 3 票 | 一次读失败不再等于"内核已死" |
| 观测到 `ALIVE` 即清零 | 心跳恢复后立刻回到健康态 |
| 修复期重连期间保持 `RECOVERING`（不再发布 `DISCONNECTED`） | 修复过程中的"断开"只是重建隧道的一步，不该让用户以为掉线 |

### 2.4 长时任务合规整改（保活侧）

> 本节由保活整改子任务产出，见下方"落地状态"。

### 2.5 通知栏：两张卡的来由与取舍（2026-10-20 用户反馈后定稿）

**现象**：真机通知栏出现两行 —— 应用自有卡「TunBox · 节点 ↓0 B/s ↑0 B/s」（**少了运行时间**）
+ 系统卡「TunBox 正在运行计算任务，删除通知后任务将停止」。

**根因（两条，互相独立）**：

1. **多出来的系统卡** = 长时任务类型从 `dataTransfer` 换成 `taskKeeping`（§2.4 的合规整改）
   后，系统按官方规则为长时任务生成了一张**强制卡**。
2. **少了运行时间** = 应用自有卡把时长放在了 `additionalText`（副标题位），
   **折叠态的通知卡片不渲染副标题** → 用户只看得到速率。改造前（实况窗卡片）时长
   与速率是**同一行正文**，所以"看起来像丢了"。

**平台硬约束（SDK d.ts + 官方文档逐字核实，非推测）**：

| 约束 | 原文/依据 | 后果 |
|---|---|---|
| 申请长时任务必然生成系统卡 | 官方《长时任务开发指南》：「应用在申请长时任务成功后，系统会在通知栏显示长时任务通知弹窗」；`BackgroundTaskSubmode` 全部取值都带通知，**无静默子类型** | 系统卡**去不掉**，也没有隐藏 API |
| 非数据传输任务不得改通知内容 | 《Background Tasks Kit 接入规范》：「不得修改长时任务通知内容。数据传输任务除外」 | 不能把速率/时长写进系统卡 |
| 合并接口只作用于两个长时任务 | SDK `ContinuousTaskRequest.combinedTaskNotification` 注释：「两个长时任务……且 `combinedTaskNotification` 都为 true 才会合并」「包含数据传输的长时任务不能合并」 | **合并不了**系统卡与应用自有卡（后者不是长时任务通知） |
| 类型与负载必须匹配 | 官方《长时任务》约束：「若运行长时任务的进程后台负载持续高于所申请类型的典型负载，系统会对应用进行管控，即应用退至后台会被挂起或终止」 | 回退 `dataTransfer` = 把"内核后台计算负载 vs 传输型典型负载"的不匹配放回去 → 正是自动断开的上游放大器 |

**四种方案的取舍（用户已拍板：选方案 A）**：

| 方案 | 通知栏 | 保活/合规 | 结论 |
|---|---|---|---|
| **A. 保持 taskKeeping + 应用卡补全信息** | 两张卡，应用卡正文恢复「速率 · 运行时长」 | 合规、保活稳 | ✅ **已落地并真机验证** |
| B. 只在退到后台时申请长时任务 | 前台一张卡 / 后台两张 | 合规（官方建议按需申请） | 未做：保活凭证从"连接即挂"变成"进后台才挂"，多一个生命周期依赖点 |
| C. 接管系统卡内容（自己写进任务通知 id） | 视觉一张卡 | ❌ 违反接入规范 → 被判定不合理使用会取消/暂停长时任务 → 掉线，甚至禁用长时任务 | 否决 |
| D. 回退 `dataTransfer` | 视觉一张卡（实况窗） | ❌ 类型/负载不匹配 → 系统挂起或终止 → 掉线（今天在修的病） | 否决 |

**落地代码**：`TaskProgressUpdater.updateLive()` 的"无长时任务通知 id"回落分支 →
可见正文改为 `速率 · 运行时长`（与改造前实况窗同一行口径），节点名进 `title`。

**踩坑（值得记）**：`notificationManager.publish` 的 `additionalText` 在**折叠态不显示**，
任何"必须让用户看到"的字段都不能放那里，要放 `text`。

---

## 3. 被否决的方案（重要，避免后人重犯）

### 3.1 ❌ 「DNS 侧回退明文 UDP / 清掉 fallback / 显式写 fallback-filter」

初版 brief 认为 `proxy-server-nameserver` 应当从加密 DoT 回退到明文 UDP，
理由是"入口域名 `hosts:` 为空 → 内核运行期每 ~55s 重解析 102 个域名并全部超时"。
**这个方向的每一个改动都被仓库自己的架构门禁否决**：

| 门禁断言 | 要求 | 初版方案 |
|---|---|---|
| `gen.dns.fallback` | `fallback:` **必须存在** | 删掉 |
| `gen.dns.no.explicit-fallback-filter` | **禁止**显式 `fallback-filter:` | 显式写 geoip/geoip-code CN |
| `dns.fallback-is-dot-853` | `fallback:` 块必须含 `tls://1.1.1.1:853` | 删掉 |
| `c12.dot-aliyun` / `c12.dot-dnspod` | `proxy-server-nameserver` 必须用加密 DoT `tls://223.5.5.5:853` / `tls://1.12.12.12:853` | 改成裸 IP 明文 UDP |
| `c12.no-bare-aliyun` / `c12.no-bare-dnspod` | 块内**不得**有裸 IP 明文条目 | 裸 IP 明文 |

`scripts/verify-vpn-architecture.mjs` 里写明了理由（逐字）：

> // 坑 40：fallback 非空会让内核在 config.Parse 阶段加载 MMDB（默认
> // fallback-filter.geoip=true），geoip.metadb 未就绪时启动被联网下载挂死。
> // 因此 fallback 必须被 useGeoip 包住（与 GEOIP 规则同开关）。

**结论：DNS 侧保持 HEAD（`5745028`）的既定策略。**

### 3.2 ❌ 「DoHResolver 短 TTL 不 pin 是昨日回归，应改回 pin」

**这是误判。** 仓库的契约写在 `scripts/verify-doh-cache-runtime.mjs` 文件头（逐字）：

> 契约（2026-10-18 修正）：pin 的寿命由 **DoH 应答里的 DNS TTL** 决定，而不是固定 3h/6h。
>   · 只有 TTL ≥ 10min 的"稳定记录"才允许 pin（写进 YAML hosts:）；
>   · 短 TTL（机场入口域名普遍 60~300s）= 会轮换 = 一律不 pin，交给内核按 TTL 现解析；
>   · pin 寿命 = min(TTL, 60min)，过一半进 stale 队列，到期丢弃；
>   · 持久化三段式 ip|resolvedAt|lifetimeMs，旧版两段式加载即弃（脏 pin 必须洗掉）。
> 真机依据：飞鸟云 34 个 hysteria2 节点整屏「超时」= 旧 pin 钉在已轮换的 IP 上；
> 同一份 YAML 用同一内核在 PC 复现，删掉 pin 立刻 155~250ms。

即 **`hosts:` 对轮换入口域名为空、`DoH pinned 0/102` 是正确行为**，
它修的是"pin 钉在已轮换 IP 上导致 34 个节点整屏超时"这个更严重的事故。
门禁 `rotating server must NOT be pinned into hosts` 会直接拦下任何违背。

### 3.3 ❌ 「10-19 的后台保活整改是自动断开的根因」

**证伪。** 两条独立证据：

1. 会话溯源：整改代码来自 `session-74a9a4ec-45e3-4a6a-b2d7-c132c95197ae`
   （10-19 11:46:10–11:48:14 落地），**从未在设备上跑过** ——
   设备上 10-19 装的是 0.4.0/0.4.1，全 81 个会话搜 `guardian re-armed` /
   `re-arm in 1s` 在设备日志里**零命中**。
2. 真机日志：故障窗口（09:47:47.380 `guardian engaged` → 09:48:23.921
   `guardian released`）内**没有** `continuous task canceled externally`，
   即 re-arm 代码路径**从未被触发**。

> 注：`AUTO_DISCONNECT_DIAG_2026-10-20.md` 第 166 行原先把整改作者记成
> `241eb1eb`（那是该会话派生的调研子代理 `ohos-spec`，零代码改动），
> 已更正为 `74a9a4ec-45e3-4a6a-b2d7-c132c95197ae`。

保活整改本身**独立存在合规风险**（1 秒无条件重挂命中官方接入规范两条违规条目），
必须修 —— 但它**不是**本次自动断开的根因。

---

## 4. 官方依据

| 结论 | 官方来源 |
|---|---|
| 长时任务类型：`DATA_TRANSFER`=非托管形式的上传/下载；`TASK_KEEPING`=计算任务（如杀毒软件） | 《Background Tasks Kit 接入规范》场景表 |
| `ContinuousTaskCancelReason`：`USER_CANCEL=1`、`SYSTEM_CANCEL=2`、`USER_CANCEL_REMOVE_NOTIFICATION=3`、`SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED=4`、…、`SYSTEM_CANCEL_USE_ILLEGALLY=11` | SDK `@ohos.resourceschedule.backgroundtaskmanager.d.ts`（API 26） |
| `ContinuousTaskSuspendReason`：`SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED=4` 等 | 同上 |
| 一个 UIAbility 申请长时任务后，**整个应用下的所有进程均不会被挂起** | 《Background Tasks Kit 接入规范》 |
| 应用进程挂起后**无法使用定时器等软件资源** | 同上 |
| 非 PC/2in1 设备用 `MODE_TASK_KEEPING` 需 `ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM`（system_basic） | SDK d.ts + AGC 申请 |
| 违规处罚标准：用户主动停止后立即再申请、系统判定不合理使用后立即再申请 | 《Background Tasks Kit 接入规范》 |
| CPU 密集型任务不适合在 UI 主线程执行；应用 taskpool/worker | 《CPU密集型任务开发指导》 |
| VPN：调用方进程退出或服务进程销毁时系统主动停止 VPN；系统仅支持一个 VPN 连接服务 | 《/@ohos.net.vpnExtension》 |

---

## 5. 门禁与构建

```
cd TunBox_HarmonyOS && node scripts/verify-all.mjs
```

已知基线失败（白名单，不阻塞）：

- `verify-subscription-fidelity.mjs` —— 需要真实订阅 fixture，仓库不含该文件；
  脚本按设计在"没跑"时返回失败。
- `verify-types.mjs` —— SDK 自带 `@ohos.annotation.d.ets` 用了 tsc 不认的语法，
  属 SDK 缺陷；**[B] 段（真实源码语法解析）通过**才算通过。

---

## 6. 真机复测清单（发布前必须跑）

1. **基线**：装机后连一次代理，确认 `vpn_heartbeat.txt` 每 **5 秒**刷新一次
   （`hdc shell ls -l .../cache/vpn_heartbeat.txt` 看 mtime，或读内容看时间戳递增）。
2. **核心路径**：保持连接 ≥ 20 分钟，观察日志里**不再出现**
   `core died (authority: heartbeat stale/absent)`。
3. **人为阻塞验证**：连接状态下让内核重启一次（切换节点 / 触发 `recoverCore`），
   确认心跳**没有断档**（这是本次修复的核心断言）。
4. **扩展进程被杀**：从后台杀掉扩展进程，确认 UI 在 ~15~24s 后才判死，
   且日志里先出现 `liveness suspect (absent)` 票数累积，而不是直接 `core died`。
5. **长时任务**：切换到后台 > 10 分钟，确认长时任务**没有被系统取消**
   （日志里不应出现 `continuous task canceled externally`）；
   若出现，确认 reason 分流正确（用户手动取消 ⇒ 不自动重挂）。
6. **回滚路径**：手动断开，确认 `vpn_heartbeat.txt` / `vpn_status.json` /
   `vpn_heartbeat.txt.tmp` 三个文件都被清掉。

---

## 7. 遗留风险与后续项

- **Go 侧 `IsRunning()` 仍在抢 `coreMu`**（`bridge.go:401-405`）。当前靠 C++ 层不再
  调用它来规避；一旦有人在别处再调 `g_alive()`，阻塞会复现。
  彻底修法是给 `running` 加 `atomic.Bool` 镜像，**需要 Go 工具链 + mihomo 源码树**
  重建 `libgojni.so`。
- **`fallback: tls://1.1.1.1:853` 在国内可能不可达**（子任务已核实并反馈）。
  该端点是仓库既定决策（门禁强制），若要改动必须**同时**修改门禁并给出
  可达替代端点的实测证据，不应在热修中静悄悄反转。
- **`DoHResolver.hasUsablePin()` 仍是死代码**（无调用方），不改变可观测行为的前提
  下可接回或删除。
- **租约刷新仍在扩展进程的 ArkTS 线程上**。当前已消除已知的阻塞源（原生调用），
  但若将来出现新的主线程长阻塞，可考虑把租约写入迁到 taskpool worker
  （官方《CPU密集型任务开发指导》推荐路径）。
