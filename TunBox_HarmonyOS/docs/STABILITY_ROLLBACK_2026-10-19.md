# 0.4.1 稳定性回退与加固（2026-10-19）

> 触发：0.4.0 上线后部分用户反馈「启动 VPN 后取不到公网 IP」，0.3.3 及之前全部正常。
> 用户裁定：**稳定性优先**，启动可以慢一点，但至少要回到 0.3.3 的速度；
> 启动链路可以直接回退到 0.3.3 语义，稳定后再谈优化；**不允许任何用户场景再出现
> 启动代理不可用**。
>
> 根因复盘见 `C:\Worker\_tunbox_diff\02_PUBLIC_IP_ROOTCAUSE.md`，
> 差异目录见 `01_DIFF_CATALOG.md`，产物核验见 `03_ARTIFACT_VERIFY.md`。

---

## 一、根因（一句话）

**公网 IP 的代码、内核、触发点两版本完全一致；变的是「查的那一刻网络在干什么」。**

0.4.0 新增的「冷启 DoH 预热」用 16 个 worker 并发发 HTTPS（预算 6s），与启动期那次
公网 IP 查询（ip-api 明文 HTTP，连接超时 5s）必然重叠；同时连接链路提速 0.3–1.5s，
让「连接后那次成功的查询」与「启动期那次超时的查询」也重叠。而 `refreshPublicIp()`
**没有请求代次保护**，晚到的失败结果把已显示的正确 IP 覆盖成红字，且不自愈。

0.3.3 没有预热 + 连接更慢 → 两个窗口都不存在 → 「全部正常」。

---

## 二、本次改动清单

### 2.1 启动 / 连接链路回退到 0.3.3 语义

| # | 位置 | 改动 | 理由 |
|---|---|---|---|
| 1 | `ConnectionOrchestrator.ets` `READINESS_MAX_DELAY_MS` | 150 → **300**（回到 0.3.3） | 连接成功判定整体提前，会放大「已连接」与「选点生效」之间的窗口 |
| 2 | `ConnectionOrchestrator.ets` `connect()` | `selectNode` 从「CONNECTED 之后 fire-and-forget」改回 **CONNECTED 之前 `await`**（0.3.3 语义） | YAML 开了 `store-selections: true`，内核冷启动恢复的是**上次选点**；窗口期内新连接走旧节点 → 「连上了但代理不生效 / 公网 IP 查不到」 |
| 3 | 同上 | 新增**读回校验** `GET /proxies/PROXY` 的 `now`；若落到 `DIRECT/REJECT/空` 则**再钉一次**（定向自愈） | 唯一意味着「隧道没有出口」的现场，值得补救；失败也只记 error，不抛错 |
| 4 | 同上 | 钉选失败**只 warn 不抛错** | 与 0.3.3 一致。若抛错，被 `generate()` 过滤掉的非法节点会让 PUT 必然 400 → 用户从「能连但慢」变成「完全连不上」，属于**新增失败面** |
| 5 | `ConnectionOrchestrator.ets` DoH 预算 | `dohBudgetMs` 条件收紧（1500ms）→ **固定 6000ms** | 收紧会让备用节点域名几乎必然解析不到，切节点/故障切换时可能拿到污染 IP |
| 6 | `HomePage.ets` `bootstrap()` | **删除冷启 DoH 预热**（整段移除，`DoHResolver` 不再被 HomePage import） | 它就是与公网 IP 查询抢网络、并把失败结果制造出来的直接原因 |
| 7 | `ClashApiService.ets` `selectNode()` | 返回值改为「**PROXY 组**钉选成功」为准（旧为 `okProxy \|\| okGlobal`），失败重试一次 | 旧语义下规则模式里 PROXY 没钉上也会返回 true，调用方误以为选点生效 |
| 8 | `ClashApiService.ets` | 新增 `groupSelection(group)` | 供连接路径读回校验 |

> **启动耗时影响**：以上改动合起来约 **+0.3~1.5s**（readiness 退避上限 +150ms、
> DoH 预算最多 +4.5s 但仅首次冷缓存且只影响备用域名、selectNode 往返 100–500ms）。
> 与 0.3.3 持平；不再有 0.4.0 的「1 秒多按钮才动」问题（`pendingStart` 乐观反馈保留）。

### 2.2 公网 IP 链路加固

| # | 位置 | 改动 |
|---|---|---|
| 9 | `PublicIpService.ets` | **重写**：主端点 ip-api（**解析 `status` 字段**，`fail` 归类为 `REJECTED`）→ **仅网络类失败**重试一次 → **备用端点 `https://api64.ipify.org`** 兜底 → 全失败才返回空 |
| 10 | 同上 | 每次查询记一行**不含 IP 明文**的日志：`ip query: trigger=… endpoint=… outcome=… elapsed=…ms [detail]` |
| 11 | 同上 | `query(trigger)` 增加 trigger 参数；`createHttp()` 移入 `try`，`destroy()` 在 `finally` |
| 12 | `HomePage.ets` `refreshPublicIp(trigger, clearBefore)` | **请求代次** `ipQuerySeq`：过期结果直接丢弃，绝不覆盖新结果 |
| 13 | 同上 | 失败**保留上一次成功的 IP**（只有从未成功过才显示错误文案）；`try/finally` 保证刷新标志复位 |
| 14 | 同上 | 新增 `invalidatePublicIpQueries()`；连接成功、断开、模式切换、连接状态翻转时作废在飞查询 |
| 15 | 同上 | 所有调用点都带 trigger：`home-bootstrap` / `node-switched` / `after-connect` / `after-connect-shortcut` / `after-disconnect` / `after-mode-change` / `user-retry` |
| 16 | 同上 | 已连接但两端点都失败 → 文案改「未取到出口 IP，点击重试或更换节点」（可行动，而不是「获取失败」） |

### 2.3 DNS 防投毒：pin 策略与内核解析必须同源

| # | 位置 | 改动 |
|---|---|---|
| 17 | `ClashConfigGenerator.ets` `proxy-server-nameserver` | 明文 `223.5.5.5 / 119.29.29.29` → **加密 DoT** `tls://223.5.5.5:853` + `tls://1.12.12.12:853` |
| 18 | `DoHResolver.ets` 文件头 | 补「与 proxy-server-nameserver 强耦合」说明：短 TTL 不 pin ⇒ 内核必须用加密上游解析代理域名 |
| 19 | `DoHResolver.ets` `hasUsablePin` | 保留但标注**已无调用方**，禁止再接回连接主路径（除非同时保证备用域名预算） |

> 为什么必须一起改：0.4.0 起「短 TTL 记录一律不 pin」（修的是「pin 钉死已轮换 IP」
> 导致的整屏超时，那部分**保留**），机场入口域名 TTL 实测 60/120s ⇒ 永远拿不到 pin
> ⇒ 内核每次都要自己解析它们。若仍用明文 UDP/53，国内网络会被投毒
> （实测 `www.google.com` 明文 `185.45.5.35` / DoH `142.251.155.119`），
> 拨代理服务器打到假 IP ⇒ 全节点超时 ⇒ 「连上了但没有出口」。

### 2.4 `direct` 模式不再跨重启持久化

| # | 位置 | 改动 |
|---|---|---|
| 20 | `AppSettings.ets` `fromJson` | `proxyMode` 只接受 `global`，其余回落 `rule`（**`direct` 不再从磁盘恢复**） |
| 21 | `HomePage.ets` `applyProxyMode` | `mode === 'direct'` 时**不写盘**；toast 文案标注「仅本次运行」；切换后立即重查 IP |

> 理由：`direct` = 所有流量绕过代理。一旦持久化，用户误触一次后每次启动都直连，
> 表现就是「VPN 连上了但代理不生效、公网 IP 是本地出口」，且用户几乎无法自查。
> 内存里仍保留 `direct`（网络变化触发的自动重连需要它重新生成 YAML），
> 重启后的回落由 `fromJson` 统一兜底。

### 2.5 工程问题（三个坑，全部修复）

| # | 问题 | 修复 |
|---|---|---|
| 22 | **发布包不可复现**：0.4.0 HAP 由脏工作区构建（含 10 个未提交改动 + 未跟踪文件），任何 commit 都构建不出来 | 本次全部改动**提交入库**，并新增 `scripts/verify-build-profile.mjs` 等护栏；发布前用 `git status --porcelain` 必须为空 |
| 23 | **`CelestialOrbLayout.ets` 被 `CelestialPowerOrb.ets:38` import 但未入库** → 干净检出编译不过 | 纳入版本控制 |
| 24 | **`build-profile.json5` 把本机调试证书 + 加密口令串提交进 main**，与文件内注释「保持空」矛盾 | `signingConfigs` 恢复 `[]`、移除 `signingConfig: "default"`；新增护栏脚本拦截（检查 `.ohos\config` / `storePassword` / `keyPassword` 字样） |
| 25 | 仓库根 `TunBox-Windows/_patch_*.py` 7 个临时补丁脚本误入工作区 | 移出仓库（存 `C:\Worker\_tunbox_diff\removed_scripts\`） |
| 26 | `AppSettings.ets:340` 两条语句挤在一行（diff/审查失真） | 拆行 |
| 27 | `scripts/verify-vpn-architecture.mjs` 的 `home.rules-entry` 断言过期（0.4.0 把规则入口从主页迁到设置页）→ 常年红，掩盖真实回归 | 断言改为检查 `SettingsPage` → `pages/RulesPage` |
| 28 | 另有 4 个 verify 脚本在 0.4.0 基线就失败（页面重构后断言过期 + CRLF 假阴性） | 修复到绿色并做负对照（见 §四） |

---

## 三、启动耗时对照

| 环节 | 0.3.3 | 0.4.0 | 本次（0.4.1） |
|---|---|---|---|
| readiness 探针退避上限 | 300ms | 150ms | **300ms** |
| 连接期 DoH 预算 | 6000ms 固定 | 命中 pin 时 1500ms | **6000ms 固定** |
| `selectNode` | `await`（CONNECTED 前） | fire-and-forget（CONNECTED 后） | **`await`（CONNECTED 前）** |
| api secret 读盘 | 串行 | 并行 | **并行（保留，纯收益、无风险）** |
| 订阅 hydrate | 不等待 | connect 前 `await`（修 38s 竞态） | **保留** |
| 冷启 DoH 预热 | 无 | 16 并发 × 6s | **无（已删除）** |
| 乐观反馈 `pendingStart` | 无 | 有 | **保留**（消除「点了没反应」） |
| 分段计时日志 | 无 | 有 | **保留** |

结论：**连接速度回到 0.3.3 水平**；保留的 4 项都是「无副作用或纯观测」的改动。

---

## 四、验证

### 4.1 构建

```
hvigor --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
→ BUILD SUCCESSFUL（0 ERROR；`No signingConfig found` 为预期，说明签名配置已恢复为空）
```

产物字节码校验（`ets/modules.abc`）：
- 含 `ip query: trigger=`、`节点选择失败`→已移除、`after-connect`、`ipQuerySeq`、`tls://1.12.12.12:853`
- 不含 `doh warmup failed`、`dohBudgetMs`（预热与预算收紧均已移除）

### 4.2 脚本

**一条命令跑完全部门禁**：

```bash
cd TunBox_HarmonyOS
node scripts/verify-all.mjs          # 25 PASS / 2 白名单 / 0 真失败 → exit 0
node scripts/verify-all.mjs --strict # 发布前最终闸门（白名单也要求通过）
```

新增：
- `verify-all.mjs`（**一键门禁**：跑完全部 verify 脚本，白名单项显式打印"为什么允许失败"，
  白名单外的任何失败 → exit 1）
- `verify-public-ip-stability.mjs`（公网 IP 链路：代次/保留旧值/备用端点/日志不含 IP，36 条）
- `verify-connect-stability.mjs`（连接链路：readiness 300、selectNode await 顺序、
  PROXY 读回校验、DIRECT/REJECT 自愈、预算 6000、无预热，38 条）
- `verify-build-profile.mjs`（签名配置为空、无凭据字样，13 条）

以上三个新脚本均对**修复前代码**（`git worktree` 出的 HEAD 副本）做过负对照：
A 组 31/36 失败、B+C+D 组 30/38 失败、E 组 10/13 失败 —— 证明断言不是空转。

修复（0.4.0 起常年红）：`verify-app-routing`、`verify-site-routing`、
`verify-sub-node-two-row`、`verify-concurrent-refresh`。
（根因：CRLF 假阴性 + 页面重构后断言过期；已用 18 条负对照逐条验证修复后的断言仍会红。）

### 4.3 可复现性

```
# 在干净检出的 worktree（git worktree add <dir> HEAD）里构建：
hvigor --mode module -p product=default -p module=entry@default -p buildMode=release assembleHap
→ BUILD SUCCESSFUL，且 ets/modules.abc sha256 与工作区构建**逐字节相同**
  （da3dcdb6aeb605f0211cfb4e9361ea73f8a0589ed1aa66870da3090b8a7242a5）
```

> 注意：HAP 的 zip 层 hash 每次不同（内嵌时间戳），但**编译产物 abc 完全一致**，
> 说明"同一 commit → 同一份代码"成立。资源 ID 在增量缓存下会漂移（同一个源码
> 两次增量构建 abc 有 175 字节差异），**清掉 `entry/build` 与 `.hvigor/cache` 后即一致**——
> 这也是为什么发布包必须在干净构建目录里产出。

---

## 五、真机验收清单（发布前必须逐条过）

| # | 场景 | 预期 |
|---|---|---|
| 1 | 冷启 → 立刻点启动 | IP 区先「获取中…」→ 出现出口 IP；**不会先成功后变红** |
| 2 | 冷启 → 等 10s → 点启动 | 同上（两条路径结果一致，证明无竞态） |
| 3 | 连接成功 → 断开 | IP 变成本机宽带出口（或显示「未连接」），不残留代理 IP |
| 4 | 连接成功 → 切节点 | IP 随节点变化，且**新节点立即生效**（不再走旧节点） |
| 5 | 全局模式连接 | 国内应用商店仍能加载（`respect-rules` 未开）、IP 为节点出口 |
| 6 | 点「直连」→ 杀进程重开 | 模式回到「规则」，不会粘在直连 |
| 7 | 弱网（4G / 信号差）连接 | IP 能出来；失败也可点一下恢复 |
| 8 | 多订阅（≥50 节点）冷启 | 启动不再被预热拖慢；IP 正常 |
| 9 | 日志检查 | `ip query: trigger=… outcome=ok`；`PROXY pinned to <node>`；无 `unpinned servers` 大面积刷屏 |

---

## 六、后续（稳定后再谈）

1. **恢复启动优化**：只能在 `selectNode` 的 await 语义不变的前提下做（例如把
   `PUT /proxies` 与 readiness 轮询并行，而不是移到 CONNECTED 之后）。
2. **DoH 预热**：若恢复，必须延后到首屏之后 ≥3s、worker ≤4、只预热当前订阅、
   且与公网 IP 查询串行。
3. **ip-api 限流**：可考虑自建/换端点（ipify 已作兜底），或把结果缓存 60s。
4. **`build-profile.json5`**：建议长期移出 tracked（本地 override），从根上杜绝调试证书入库。
