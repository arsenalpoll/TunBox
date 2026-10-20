# 状态源分叉 · 残留审计报告（2026-10-20）

> 审计范围：`entry/src/main/ets/` 全部 + `scripts/` 闸门脚本
> 取证时间：2026-10-20 15:55（**仓库正被多人并行编辑，行号会漂；动手前请用闸门重跑一次对账**）
> 闸门：`scripts/verify-no-divergence.mjs`（14 条断言，当前 **3 绿 / 11 红**）
> 性质：只读审计，**未修改任何 `.ets`**；本报告只列残留，不代改。

---

## 0. 结论摘要

架构改写（单一 IR / 单一生成入口 / 单一测速路径 / 单一结论源）之后，**结构性的分叉基本清掉了，
但「规则级」的分叉还在**：新真源建好了，旧实现没删干净，于是同一个判定现在有两套规则在跑。

- **11 条断言判红**，共 **68 处违例**，集中在 4 个主题：失败分类/文案/阈值（ND01/04/05/06/13/14）、
  结论读写路径（ND07/08）、端口与 hosts 口径（ND09/11）、生成前处理（ND12）。
- **已确认收敛的**（不要重复排期）：生成层「能否写进内核」单一判定、选中节点单一决策点、
  端口不再写回共享状态、代理组/规则集单一拼装、DoH `refreshStale` 唯一调用点、两份 YAML 差异白名单。
- **11 项在途**（lead 交办中的 4 项 + 7 项相关联在途）不计入 bug，见 §4。

---

## 1. 方法与口径

### 1.1 什么算「分叉」

**一条判定规则只能有一个实现。**

允许：写入路径与渲染路径各有一份代码（两种不同用途）。
不允许：同一个**判定**（哪些失败算结论 / 什么算陈旧 / 地址怎么派生 / 节点能不能进代理表 /
结论落在哪个分片 / 测速核连哪个端口）出现两套**各自独立**的规则。

### 1.2 怎么查的

1. 逐文件正则扫描（去注释后），按「规则」而不是按「文件」归类；
2. 每条规则写成一条**可计数**的断言（命中即红）；
3. 每条断言配**负对照**：把当前违例修掉必须转绿，再注入一处同类分叉必须转红
   （`node scripts/verify-no-divergence.mjs --self-test`，14/14 通过，见 §3）。

### 1.3 白名单（豁免即「这里不是分叉」，逐条有理由）

| 豁免 | 理由 |
| --- | --- |
| `scripts/**` 全体 | 闸门脚本自身必须写出被禁字面量才能扫描；闸门不是运行时路径，抄错不影响用户。**代价**：闸门脚本里藏一份真源本闸门发现不了。 |
| 注释 / 文档 | 扫描前统一去注释（本仓库注释里大量出现「这里以前调过 XXX」的调用形态，直接 grep 会把注释算成实现）。 |
| `entry/src/ohosTest/**` | 不在本次扫描范围（测试代码不参与运行时判定）。 |
| ND06：`ConnectionOrchestrator.ets` | `checkEgressReachable()` 的出口连通性自检，与「节点测速地址」不是同一件事；仍建议改引用 `LatencyTestUrl.DEFAULT_URL`。 |
| ND06：`RawSubscriptionStore.ets` | mihomo raw provider 的 `health-check` url，是给内核 provider 用的，与 App 自己的测速地址是不同事实。 |
| ND06：`LatencyEngine.ets` | **在途**（latency-core 正在把 LatencyEngine 接到 LatencyProbe），接线完成后删除本豁免。 |
| ND01：`LatencyState.ets` 的 `dns_unresolved` | **在途**（settings-ui 正在给 `stateText` 加这一行），且只允许出现在这一个文件，不得再扩散。 |
| ND10：`proxyYamlLine` 内部调用 `dropReasonFor` | 生成层已收敛（`proxyYamlLine` 不再自己判一遍），断言反向守住它，别退化。 |

### 1.4 已知盲区（闸门查不出来，需要人盯）

- **正/反两张判定表**：ND13 只能发现「正表与反表并存」，发现不了「反表少登记了一类」。
  本次人工核对：`LatencyProbeKind` 共 12 个分类，`isVerdictKind` 显式管 5 个、
  `isNonVerdictKind` 显式管 5 个，`unknown` / `cancelled` 两类**两边都没登记**，
  目前靠「没提到就算不是结论」兜底（与设计意图一致，但一旦新增分类忘了登记就是静默走偏）。
- **语义相同但写法不同**的重复规则（如「同一段逻辑抄成两遍但改了变量名」）本闸门抓不到，需 code review 兜。

---

## 2. 残留分叉清单（11 条判红）

> 每条格式：**位置(file:line)** ｜ 现在有几份真源 ｜ 应收敛到哪 ｜ 风险（用户可见症状）｜ 代价

### F1（ND01）失败分类字面量：**3 份**

- **位置**
  - 新真源：`commons/latency/LatencyProbe.ets:186-221`（`LatencyProbeKind`，12 个分类）
  - 副本 ①：`commons/services/ClashApiService.ets:74,76,78,82,84,89,101`（`LatencyFailKind`，7 个字面量）
  - 副本 ②：`commons/services/LatencyState.ets:346,347,348,349,350`（`isNonVerdictKind` 判定表）
    与 `:403,414,417,436`（`stateText` / `isNotEffective` 的 4 处散判）
- **应收敛到**：`LatencyProbeKind`（`LatencyProbe.ets:186`）。副本 ①②改为引用常量，不留字面量。
- **风险**：新增或改名一类失败时漏改一处 → 同一个失败在两处显示不同话术；
  更糟的是 `LatencyState.ets:436` 的 `isNotEffective` **只认 `switch_failed`**，
  换一种失败名就判成「生效」→ 自动切换不触发、用户以为节点是好的。
- **代价**：小（两处常量表改成引用 + 删 11 个字面量）。注意 `LatencyState.ets:386` 附近
  的 `dns_unresolved` 行**在途**，不要在这一轮动它。

### F2（ND04）theme 层两份一模一样的文案包装

- **位置**：`theme/TunBoxTokens.ets:338,340` 与 `theme/UiTokens.ets:141,143`
  —— 两个文件各写一份「`stateText(...)` + `·旧` 后缀」的包装。
- **应收敛到**：一份共享包装（或直接调用 `LatencyStore.describe`）。
- **风险**：改话术只改一处 → 另一个主题下仍显示旧话术（同一页面两个区域话术不一致）。
- **代价**：极小（删一份，留一份）。

### F3（ND05）陈旧阈值：**2 份**

- **位置**：`commons/latency/LatencyStore.ets:353`（`STALE_MS = 10 * 60 * 1000`，新真源，
  使用点 `:517`）与 `commons/services/LatencyState.ets:190`（同值常量，使用点 `:366`）。
- **应收敛到**：`LatencyStore.STALE_MS`。
- **风险**：改一处 → 同一份结论一处标「·旧」、一处当新鲜，用户看到的灰显口径分裂。
- **代价**：极小。

### F4（ND06）测速地址规则常量：**2 份（+2 处合理豁免）**

- **位置**：`commons/models/AppSettings.ets:86,179,186,187,211,348,358`
  —— 字段默认值、`DEFAULT_TEST_URL` 常量、`upgradeLegacyTestUrl()` 的迁移规则（`:348,358`）
  与调用点（`:211`）。
- **应收敛到**：`commons/latency/LatencyTestUrl.ets`（`DEFAULT_URL`/`ALT_URL`/`effective()`，零依赖纯模块）。
  `AppSettings` 侧应只保留**字段**，不再自带默认值与迁移规则。
- **风险**：设置页占位符（`pages/SettingsPage.ets:278,289,393` 用的是**新**常量）与
  加载期实际改写用户配置的行为（**旧** `upgradeLegacyTestUrl`）口径不同 →
  用户填的 `http://` 地址在一处被升级成 `https://`、在另一处被原样保留；
  「当前生效地址」和「设置页显示的地址」对不上。
- **代价**：中（要动 `AppSettings.toJson/fromJson` 的字段语义 + 迁移一次）。
- **在途豁免**：`LatencyEngine.ets`（latency-core 正在接）、`ConnectionOrchestrator.ets:1726`
  （出口自检，不同用途）、`RawSubscriptionStore.ets:55`（provider health-check，不同用途）。

### F5（ND13）节点结论判定表：**正反两张并存**

- **位置**：正表 `commons/latency/LatencyProbe.ets:346-364`（`isVerdictKind`）；
  反表 `commons/services/LatencyState.ets:345-351`（`isNonVerdictKind`，5 个字面量）。
- **应收敛到**：只留正表 `LatencyProbe.isVerdictKind`（`LatencyStore.ets:381-382` 已是转发，✅）。
  反表的 5 个调用点改调正表取反即可。
- **风险**：将来新增一类失败只登记到一张表 → live 路径与冷启动恢复路径结论相反
  （一边写进快照、一边恢复时当成「非结论」丢掉）→ 节点明明测出失败，重启后变成「未测」。
- **代价**：小（删表 + 改 5 处调用）。

### F6（ND14）陈旧判定表：**2 份**

- **位置**：新 `commons/latency/LatencyStore.ets:517`（内联判定）；
  旧 `commons/services/LatencyState.ets:359-367`（`isStaleConclusion`）。
- **应收敛到**：`LatencyStore`（把 `isStaleConclusion` 也提到 store 上作为唯一出口）。
- **风险**：与 F3 叠加 → 「·旧」灰显在两条路径上口径不同。
- **代价**：极小。

### F7（ND07）测速快照的写者：**记账路径仍在写整单**

- **位置**
  - 新分片写入口：`commons/services/SettingsService.ets:214`（`nodeSortSnapshotWrite`，只写测速结论分片）
    与 `:236`（`saveNodeSortStats`，只写记账分片）——✅ 设计正确。
  - **残留**：`commons/services/ConnectionOrchestrator.ets:1482`（读整单合并视图）、
    `:1514`（`settings.nodeSortSnapshot = snap.toJsonText()` —— **第二写者**）、
    `:1596`（自动切换评分读整单字段）；且 `:1515` 走的是 `SettingsService.save(settings)` **整单保存**，
    没有走 `saveNodeSortStats()`。
  - 整单保存的副作用：`SettingsService.ets:183` 的 `routeSnapshotWrite(normalized.nodeSortSnapshot)`
    会把**合并视图**再写回分片（`:403-416` 按 `testedAt` 决定是否整片覆盖）。
- **应收敛到**：编排器记账只调 `SettingsService.saveNodeSortStats()`；
  `routeSnapshotWrite` 只允许测速批次这条线调。
- **风险**（审计 F2 的机制残留）：`load()` 在 `SettingsService.ets:152` 把合并视图塞回
  `settings.nodeSortSnapshot` → 调用方改任意字段后 `save()` → `routeSnapshotWrite` 用**合并视图**
  整片覆盖测速结论分片 → **测速刚写进去的新结论被盖回旧值**（表现：刚测完的延迟突然退回旧值/「未测」）。
- **代价**：中（编排器 3 处改成分片 API；`routeSnapshotWrite` 需要把「谁来写」从
  「比 testedAt」改成「显式分派」）。

### F8（ND08）测速结论的 live 真源：**pages 仍直接读旧门面**

- **位置**：32 处 —— `pages/HomePage.ets:552,560`；
  `pages/NodeSelectionPage.ets:285,350,399,695,1042,1122,1220,1221,1372,1391,1392,1395,1408,1409,1412,1456,1471,1481,1486,1490,1499,2119,2125,2128`；
  `pages/SubscriptionPage.ets:427,445,565,632,637,648`。
  新真源 `LatencyStore`（`commons/latency/LatencyStore.ets`）与
  回灌桥 `commons/services/LatencyStoreBridge.ets:70`（`LatencyController.restore(...)`）已存在，
  但**页面读的还是旧 Map**。
- **应收敛到**：`LatencyStore`（`LatencyStore.describe` / `applyProbeResult` / `restoreAll`）。
  `LatencyController` 降级为纯适配层，最终删除（LP 批次）。
- **风险**：节点页读旧 Map、首页读新 store → **同一节点两处显示不同延迟**；
  `LatencyStoreBridge.ets:70` 把新 store 的结论回灌旧 Map，反向也成立 →
  冷启动恢复时旧 Map 可能盖掉更新的结论。
- **代价**：大（3 个页面共 32 处读点要换 API）。**与在途的 latency-core 接线强相关**，
  建议等 latency-core 把 `LatencyEngine` 接到 `LatencyProbe` 之后再做，避免两拨人同时改同一批页面。

### F9（ND09）测速核 controller 端点：**端口与密钥配对错**

- **位置**：`commons/services/ConnectionOrchestrator.ets:2192`
  `api.setEndpoint(this.apiPort, this.testCoreSecret)` —— 在 `refreshLatencyEndpoint()`
  （`:2181`）里，**真实隧道端点下发失败**时的兜底分支。
  测速核自己的端口是 `this.testCoreApiPort`（`:2518` 由 `testPorts.apiPort` 赋值，
  正常路径在 `:2519` 正确使用）。
- **应收敛到**：`this.testCoreApiPort`（与 `:2519` 同一口径）。
- **风险**：测速核 secret 配隧道端口 → 探活 401/连不上 → `refreshLatencyEndpoint()` 失败 →
  **整批测速显示「内核未就绪」**（用户看到所有节点同时「未生效/未就绪」）。
- **代价**：极小（一行）。

### F10（ND11）DoH hosts：**3 个调用点，唯一真源声明落空**

- **位置**
  - 声称的唯一来源：`commons/config/RuntimeConfigBuilder.ets:266`（`resolveSharedHosts()`，
    内部 `:283` 调 `DoHResolver.resolveMany`）、`:315`（`refreshStale()`，全仓唯一 ✅）。
  - **残留**：`ConnectionOrchestrator.ets:2447`（测速核 hosts）与 `:3134`（隧道 hosts）
    各自直接调 `DoHResolver.resolveMany(...)`。
- **应收敛到**：`RuntimeConfigBuilder.resolveSharedHosts()`（隧道/测速核共用同一份解析结果）。
- **风险**：隧道与测速核各自解析 → 同一域名钉到不同 IP → **同一节点隧道里能用、测速超时**
  （用户看到「能连上但延迟测不出来」）。
- **代价**：中（编排器两处改成调 builder；但要注意 builder 的 `resolveSharedHosts` 目前在
  生成流程内被 `:324` 调用，编排器侧要先取到同一份结果，可能要把 hosts 提到 profile 里再回填）。
- **说明**：`DoHResolver.refreshStale()` 确实只有 `:315` 一处 ✅（这条已收敛）。

### F11（ND12）凭据回填：**3 个调用点**

- **位置**：`ConnectionOrchestrator.ets` 内 `await this.hydrateNodeCredentials(subs)` 共 **3 处**
  （闸门报 `:2473` 起共 3 个调用点；定义在 `:2416`）。
- **应收敛到**：**1 处** —— 统一在「生成配置之前」回填一次（`RuntimeConfigBuilder` 那条线上）。
- **风险**：三条路径各回填一次、各自 try/catch → 漏掉一条就把「缺凭据」的节点整条写进内核 →
  **节点存在但握手必失败**（用户看到「节点能选、连上就断」）；
  回填顺序不同还会让同一节点在两份 YAML 里凭据不一致（隧道能用、测速核不能用）。
- **代价**：中（要理清 3 条路径是否都必经「生成前」）。

---

## 3. 闸门与负对照

```
node scripts/verify-no-divergence.mjs              # 验收闸门：有残留即红（exit 1）
node scripts/verify-no-divergence.mjs --pending    # 预览：只打印残留清单（exit 0）
node scripts/verify-no-divergence.mjs --self-test  # 负对照自检
```

**负对照结果（2026-10-20 15:55）**：14 条断言全部「修掉即绿 / 注入即红」✅

| 断言 | 规则 | 当前 | 负对照 |
| --- | --- | --- | --- |
| ND01 | 失败分类字面量只在 `LatencyProbe`/`LatencyStore` | ❌ 16 处 | ✅ |
| ND02 | `isVerdictKind`/`isNonVerdictKind` 各只有一份实现 | ✅ | ✅ |
| ND03 | `describe`/`stateText` 各只有一份实现 | ✅ | ✅ |
| ND04 | theme/pages 不得自带文案包装 | ❌ 4 处 | ✅ |
| ND05 | `STALE_MS` 只定义一次 | ❌ 1 处 | ✅ |
| ND06 | 测速地址常量只在一处 | ❌ 7 处 | ✅ |
| ND07 | 快照写者唯一（编排器走 `saveNodeSortStats`） | ❌ 4 处 | ✅ |
| ND08 | pages 不得直接读旧 `LatencyController` | ❌ 32 处 | ✅ |
| ND09 | 测速核端点必须用自己的端口 | ❌ 1 处 | ✅ |
| ND10 | 「能否写进内核」单一判定 | ✅ | ✅ |
| ND11 | DoH hosts 单一来源 | ❌ 2 处 | ✅ |
| ND12 | 凭据回填调用点 = 1 | ❌ 2 处 | ✅ |
| ND13 | 判定清单只能一张表（正反不得并存） | ❌ 1 处 | ✅ |
| ND14 | 陈旧判定只能一张表 | ❌ 1 处 | ✅ |

**与既有闸门的关系**：`scripts/verify-config-single-source.mjs` 管「一个生成入口 + 两份 YAML 差异白名单」，
本闸门管**规则级**分叉，两者互补不重叠；`scripts/verify-legacy-purge.mjs`（LP01–LP15，文件尚未落地）
管「旧实现是否删干净」—— 本闸门在旧实现删掉之前就能报「同一规则还有几份实现」，删完自动转绿。

---

## 4. 在途项（**不计入 bug**，勿重复排期）

| # | 内容 | 负责人 | 在本报告中的位置 |
| --- | --- | --- | --- |
| ① | `ClashConfigGenerator` smart 组 url（config-gen） | config-gen | 未列为分叉（`RuntimeConfigBuilder.ets:337-338` 已走 `LatencyTestUrl.effective()`） |
| ② | `LatencyState.stateText` 的 `dns_unresolved` 行（settings-ui） | settings-ui | ND01 的**逐文件豁免**，只允许出现在 `LatencyState.ets` |
| ③ | `LatencyEngine` → `LatencyProbe` 接线（latency-core） | latency-core | ND06 的**逐文件豁免**；F8 与它强相关，建议等它落地再做 |
| ④ | `ProxyNode` 新解析层接线（yaml-sub） | yaml-sub | 未列为分叉 |

关联在途（同一批文件、同一波改动，建议**同一人同一轮**处理，避免互相顶掉）：
`LatencyEngine.ets`（③）、`LatencyState.ets:386`（②）、`ClashConfigGenerator` smart 组（①）。

---

## 5. 已确认收敛（不要重复排期）

| 事实 | 证据 |
| --- | --- |
| 「节点能不能写进内核代理表」只有一份判定 | `ClashConfigGenerator.ets:1973` `dropReasonFor()` 是唯一判定；`:2255` 的 `proxyYamlLine()` 在 `:2258` **调它**、不自己再判一遍；`:428-435` 的 validNodes 过滤也用它 |
| 选中节点只有一个决策点 | `commons/config/RuntimeConfigBuilder.ets:223-225,239`（`resolveSelectedNode`），隧道与测速核共用 `this.lastNodeName`（`:2476`） |
| 端口不再写回共享状态 | `RuntimeConfigBuilder.ets:64-65,121`（注释明确禁止写回 `this.mixedPort/apiPort/dnsPort`）；测速核端口走 `testPorts` → `this.testCoreApiPort`（`ConnectionOrchestrator.ets:2518`） |
| 代理组 / 规则集单一拼装 | `ConnectionOrchestrator.ets:2799-2800`（`profile.proxyGroups` / `subscriptionRules` / `subscriptionRuleProviders` 一次性装配）→ `RuntimeConfigBuilder.ets:333` → 生成器 |
| `DoHResolver.refreshStale()` 全仓唯一 | `RuntimeConfigBuilder.ets:315`（唯一调用点） |
| 两份 YAML 的差异白名单 | 由 `scripts/verify-config-single-source.mjs` B1/B2 守（已绿） |
| 测速结论/记账分片写入口分离 | `SettingsService.ets:214`（结论）与 `:236`（记账）各自只写自己那片 ✅（残留只在编排器侧，见 F7） |

---

## 6. 建议排期（按「代价 ÷ 收益」排序）

**第 1 批（改一行级，当天可完成，立刻见效）**
F9（`ConnectionOrchestrator.ets:2192` 端口）、F3（`LatencyState.ets:190` 常量）、
F2（theme 两份包装删一份）、F6（`isStaleConclusion` 收敛到 store）。

**第 2 批（小改，需要跑一轮真机回归）**
F1（失败分类字面量统一到 `LatencyProbeKind`）、F5（删反表改 5 处调用）、
F10（hosts 收敛到 `resolveSharedHosts`）、F11（凭据回填收敛到 1 处）。

**第 3 批（中等，需要设计对齐）**
F7（快照写者收敛 + `routeSnapshotWrite` 显式分派）、F4（`AppSettings` 去掉自带默认值与迁移规则）。

**第 4 批（大，与在途强耦合，最后做）**
F8（3 个页面 32 处读点切到 `LatencyStore`）—— **等 latency-core 的 ③ 落地后再做**。

**第 5 批（闸门护栏，防回归）**
把本闸门接进 `scripts/verify-all.mjs`；等 F1–F14 全部修完、闸门全绿后，再从总闸里去掉 `--pending` 口径
（现在是「有残留即红」，尚未接入总闸，避免阻塞其他人的在途改动）。
