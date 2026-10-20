# 冷启动「假超时」根因与修复（2026-10-20）

> 用户报障原话：**「为什么总有一些节点，我刚打开软件还没测速，就显示超时，测完发现这个节点还是正常的，并没有超时。」**

## 一、现象（真机复现）

设备 `192.168.10.6:39933`，debug 签名安装后冷启动（**未测速**），进入「订阅」tab：

| 节点 | 修复前 | 修复后 |
|---|---|---|
| 剩余流量 | 🔴 超时 | `--` |
| United States 01 | 🔴 超时 | `--` |
| 其余节点 | `--` | `--` |

同一批节点在**点完测速**后全部正常出延迟（例：Nexpanel 7 个节点 46ms / 56ms / 80ms / 104ms / 106ms / 315ms / 716ms）——
即「测速能过、冷启动却显示超时」，说明**显示的结论不是本次测速产生的**。

## 二、根因（两个独立缺陷，叠加成同一个症状）

### 根因 1：写入侧 —— 自动切换的**记账**污染了**测速结论**

`ConnectionOrchestrator.updateNodeStats(name, ok)` 在「一次连接失败」时写：

```ts
rec.failCount = rec.failCount + 1;
rec.lastOk = false;
rec.latency = LATENCY_FAILED;   // ← 根因写入点：把 -1 写进了**测速延迟字段**
```

这个 `-1` 落在**持久化快照** `AppSettings.nodeSortSnapshot` 里，于是：

1. 节点真实的测速延迟被抹掉；
2. 节点偶发失败 / 自动切换一次，下次冷启动该节点就**必显「超时」**——而节点其实是好的。

「连接失败记账」与「测速结论」被塞进了同一个字段，是这个 bug 的本质。

### 根因 2：读取侧 —— 恢复快照时**丢分类 + 伪造时间戳**

`HomePage` / `NodeSelectionPage` 冷启动恢复写的是：

```ts
LatencyController.set(rec.name, rec.latency);   // 只传一个数字
```

`set()` 的语义是「**刚刚测出来的**」：用 `Date.now()` 打时间戳、失败一律归为 TIMEOUT。于是：

1. **失败分类（failKind）被丢掉** → 非判定失败（`core_not_ready` 通道故障、`queue_timeout` 根本没拨号、
   `port_reachable_only` 仅端口可达）全被压成同一种红色「超时」；
2. **时间戳被打成 now** → 上一轮的旧结论被伪装成本次刚测出来的，顶着一颗新鲜的红「超时」；
3. 违反仓库既有约定 `NodeLatencyRecord.isNonVerdict`（非判定结果绝不能当成节点失败）。

## 三、修复

### 3.1 写入侧：记账与测速结论彻底分开

`ConnectionOrchestrator.updateNodeStats`：

- 失败分支**不再**写 `rec.latency = LATENCY_FAILED`，只记 `failCount` / `lastOk`；
- 成功分支只清理**旧版记账残留**（`latency < 0 && failKind === ''`）→ 置 `LATENCY_UNTESTED`；
- `candidateFromRecord` 改为**派生**评分用的有效延迟，口径与旧实现等价：

```ts
let effective = rec.latency;
if (rec.failCount > 0 && !rec.lastOk) effective = LATENCY_FAILED;
else if (rec.lastOk && rec.latency < 0) effective = LATENCY_UNTESTED;
return NodeCandidate.fromStats(name, effective, rec.failCount, rec.lastOk, 0, 0);
```

→ **选点评分口径不变**（失败记账照样降权），但快照里的测速结论不再被污染。

### 3.2 读取侧：新增 `LatencyController.restore(name, latency, failKind, atMs)`

| 快照记录 | 恢复结果 | UI |
|---|---|---|
| `latency >= 1` | MEASURED，`atMs = snap.testedAt` | `123ms`，超过 10 分钟 → `123ms·旧`（灰） |
| `latency === -1` 且 failKind 为**非判定**或空串 | **UNTESTED** | `--` |
| `latency === -1` 且 failKind = `timeout` | TIMEOUT（保留分类与真实时间戳） | `超时`；过期 → `超时·旧`（灰） |
| `latency === -1` 且 failKind = `switch_failed` | FAILED（保留分类） | `未生效`（橙） |
| `latency === -2` | UNTESTED | `--` |

两个页面改用它恢复：`HomePage`（主页冷启动）、`NodeSelectionPage`（节点选择页）。

**为什么空分类（`''`）也算非判定**：测速路径写进快照的失败**一定**带分类
（见 `NodeSelectionPage.toPersistRecord`：timeout / network_unreachable / port_reachable_only / untested），
唯一会写出「不带分类的失败」的地方就是**旧版自动切换记账** —— 那不是测速结论。
方向上也是保守的：宁可显示 `--`，也不显示假的「超时」。

> ⚠ 注意口径分层（两处判定表必须一致但**不混用**）：
> - `LatencyPolicy.isNonVerdictKind(failKind)` = 5 类通道级失败（**不含**空串）——
>   写快照（`buildAuto`）与恢复都用它，唯一真源；
> - **空串**只在**恢复路径**上被当成非结论（见上）。

### 3.3 渲染层：陈旧结论灰显，不再顶红字

`TunBoxPing`（`TunBoxTokens.ets`）与 `LatencyStyle`（`UiTokens.ets`）：

- `LatencyPolicy.isStaleConclusion(rec, nowMs)`：失败结论且 `atMs <= 0`（年龄未知）或超过 10 分钟 → 陈旧；
- 陈旧失败 → 文案 `超时·旧`，配色改为中性灰（与既有 `123ms·旧` 口径一致：**过期 = 不是当前结论**）；
- 新鲜失败仍是红色 `超时` / 橙色 `未生效`。

### 3.4 快照解析：缺字段按「未测」而不是「失败」

`NodeSortSnapshot.fromJsonText`：`latency` 缺失 / 非法 → `-2`（未测），不再是 `-1`（失败）。
「没有数据」不等于「测出来超时」。

## 四、闸门

新增 `TunBox_HarmonyOS/scripts/verify-latency-restore.mjs`（39 条断言，运行时真跑 + 源码断言）：

- 非判定失败（`core_not_ready` / `queue_timeout` / `port_reachable_only` / 空串）恢复成「未测」；
- 真实失败保留分类与**快照时间戳**（不得被改成 `Date.now()`）；
- 陈旧失败 → `超时·旧` + 灰；新鲜失败 → `超时` + 红；
- 写入侧不再出现 `rec.latency = LATENCY_FAILED`；评分口径仍是 `effective` 派生；
- 两个页面的恢复路径必须走 `LatencyController.restore(...)`。

配套改动：

- `tools/true-chain-harness/prepare.mjs`：harness 补 `LatencyState.ts`（NodeSortPersistence 新增了对它的依赖）；
- `scripts/verify-node-sort-persistence.mjs`：补 `LatencyState.ts` 暂存；非法 latency 期望值 `-1 → -2`。

## 五、真机验收

| 项 | 结果 |
|---|---|
| `node scripts/verify-all.mjs` | PASS=36 / 白名单 2（既有基线）/ 真失败 0 |
| `node scripts/verify-arkts-compile.mjs`（DevEco 真编译 + assembleHap） | 3/3 |
| `node scripts/verify-latency-restore.mjs` | 39/39 |
| debug 签名装机 → 冷启动（未测速） | 剩余流量 / United States 01 由 🔴超时 → `--` |
| 测速 | Nexpanel 7 节点全部出延迟（46~716ms） |
| 连接 | 已连接 Malaysia 01，公网 IP 43.216.28.213（记账路径未破坏选点） |
| 提交前签名 | `switch-signing.ps1 -Mode release` 已切回，`verify-build-profile.mjs` 13 断言通过 |

## 六、遗留（另案，未在本次动）

1. **信息条伪节点**（机场把「剩余流量 / 套餐到期 / 官网」塞进 proxies）：它们**真实测速也必然超时**，
   属于噪音，建议把它们排除出测速集合（`ClashConfigGenerator.SMART_INFO_NODE_FILTER` 已有同类过滤）。
2. **订阅 tab 的测速结果不落盘**：`SubscriptionPage` 全程不写 `nodeSortSnapshot`，
   只有节点选择页与自动切换记账会写。所以「在订阅 tab 测完 → 重启」结果会回到 `--`（既有行为，非本次回归）。
3. `BackgroundLatencyService.scheduleStartup(context, 1200)` 是**死代码**（全仓无调用点）：
   冷启动不会自动跑一批静默测速，因此启动后只有快照里的记录有徽标。
