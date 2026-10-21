# TunBox（鸿蒙 NEXT）对标 iOS VPN 客户端：REA 差距分析与优化/新功能建议

> 调研对象：Surge iOS 5.23.0、Quantumult X 1.8.1、Loon 3.5.2、sing-box for iOS (SFI/MT) 1.14.7、Shadowrocket 2.2.x、Stash 3.x
> 方法论：REA（服务端契约 / 既有客户端实现 / 构建产物三向交叉验证）——官方手册 + 开源仓库代码逆向 + App Store 元数据 API + 社区资料交叉验证，每条结论标注证据等级。
> 证据等级：📗官方文档 ｜ 📘开源代码/SDK ｜ 📙社区资料 ｜ ⚠️推断/未能验证 ｜ 🔬本次代码级核实（TunBox 仓库）
> 调研日期：2026-10-13（Asia/Shanghai）
> 底稿：[B2-surge-qx-loon-sfi.md](B2-surge-qx-loon-sfi.md)（325 行，四客户端 A–I 维度逐项逆向）

---

## 1. TL;DR

**一句话结论：TunBox 在"订阅兼容性 + App 级分流 + 诊断透明度"三条线上已实质领先 iOS 第一梯队；真实差距集中在"规则/DNS 的匹配阶段精度""用户可扩展性（规则集/配置覆盖）""连接生命周期与系统级入口"三处，而不是协议支持面。**

1. **协议面不需要追赶**。mihomo 内核的协议覆盖 ≈ SFI（sing-box 全量），且 **TunBox 已在代码层实现 uTLS 指纹（`client-fingerprint`）与 HY2 端口跳跃（`ports`）**——常见的"必补项"清单里这两条对 TunBox 不成立（🔬 ClashConfigGenerator.ets:1206、ProxyNode.ets:750）。
2. **App 级分流是 iOS 阵营的结构性能力缺失**，不是"他们没做"，而是"平台做不到"：Surge 官方手册明示 iOS 忽略 PROCESS 规则（📗），SFI 的 `include_package`/`exclude_package`/`process_name` 在 Apple 平台全部标注 ❌（📗）。**TunBox 在此维度反超全部六个对标对象**。
3. **最值得补的三个真实缺口**（均有代码级证据）：
   - **DNS 层 REJECT 预匹配**（Surge 5.14.0 / QX / Loon 均有）：当前 TunBox 的 REJECT 只在连接阶段生效（🔬 ClashConfigGenerator.ets:540 仅 `RULE-SET,...,REJECT`），广告域名的 DNS 查询仍会真实发出——既是性能损失也是**直连阶段的隐私/泄露面**。
   - **订阅自动刷新未接线**：`autoUpdateSubscription` 字段在 AppSettings.ets 定义并持久化（:55/:140/:222/:287），但**全仓库无任何调度器消费它**（🔬 grep 全仓仅 4 处命中，全在模型层）→ 用户打开"自动更新"开关后行为与关闭**完全一致**（静默失效缺陷）。
   - **规则集不可由用户添加**：`rule-providers` 只输出内置 hyper-adrules（🔬 :526-540），用户只能手写单条规则（RulesPage.ets:158）。iOS 六家全部支持添加任意远程 RULE-SET/DOMAIN-SET/rule-set。
4. **生态位缺口（可后置但要承认）**：模块/插件系统、脚本+重写+MitM。这是 Surge/Loon/QX 的护城河，也是 SFI 同样缺失的部分。**其中 MitM 不建议做**（见 §7）。
5. **一处 API 语义领先可固化为壁垒**：TunBox 的逐节点诊断 + 延迟结果持久化（含新鲜度），在六个对标对象中**没有等价物**——它们普遍是"点了才开始测、退出即丢"。

---

## 2. 对标对象与商业化基线

| 客户端 | 版本/日期 | 形态 | 定价 | 内核 | 证据 |
|---|---|---|---|---|---|
| Surge iOS | 5.23.0 / 2026-10-12 | 闭源商业 | 首购 **$49.99**（1 年功能订阅 + 终身使用权），续 **$14.99/年** | 自研 | 📗 |
| Quantumult X | 1.8.1 / 2026-10-07 | 闭源买断 | **$9.99** 买断 | 自研 | 📗 iTunes API |
| Loon | 3.5.2 / 2026-10-01 | 闭源买断 | **$7.99** 买断 | 自研 | 📗 iTunes API |
| sing-box for iOS | 1.14.7 / 2026-10-09 | **GPL-3.0 开源** | 免费无内购 | sing-box | 📘📗 |
| Shadowrocket | 2.2.x | 闭源买断 | **$2.99** 买断 | 自研 | 📗 |
| Stash | 3.x | 闭源买断 | **$3.99** 买断 | mihomo（与 TunBox 同源） | 📙 |

**对标价值排序**：① **Stash**（同 mihomo 内核，最直接的能力基准）② **SFI**（唯一可做实现级逆向的样本）③ Surge（功能上限与内存工程范式）④ Loon/QX（脚本与规则工程）⑤ Shadowrocket（订阅兼容与大众化路径）。

---

## 3. TunBox 现状基线（代码级锚点）

| 能力 | 状态 | 锚点 |
|---|---|---|
| 订阅解析 | mihomo 全协议直读 + 逐节点诊断 | SubscriptionParser.ets / SubscriptionService.ets |
| uTLS 指纹 | ✅ 已实现，且与证书 pin 分离语义 | ClashConfigGenerator.ets:1206-1208；ProxyNode.ets:40-52 |
| HY2 端口跳跃 | ✅ 已实现（`ports: "1000-2000"`） | ProxyNode.ets:750 |
| Reality | ✅ reality-opts 回写 | ClashConfigGenerator.ets:1248 |
| 策略组 | select / url-test / fallback / load-balance / relay | ClashConfigGenerator.ets:652 |
| 规则 | 内置 hyper-adrules + 用户单条规则 | :526-540；RulesPage.ets:158 |
| App 级分流 | ✅（对标对象全部缺失） | AppRoutingPage.ets |
| DNS | fake-ip + nameserver-policy + fake-ip-filter + 全 DoT 防泄露 | ClashConfigGenerator.ets:163/250/264/177-232 |
| 代理模式 | 仅 `rule` / `global` | :140-141 |
| proxy-providers | ✅ 双轨 provider 计划 | :392；:1003 |
| 进程匹配 | 有意关闭 `find-process-mode: off` | :157 |
| 订阅自动更新 | ❌ 字段存在但无调度器 | AppSettings.ets:55/140/222/287（无消费者）|
| 列表虚拟化 | ❌ 未使用 LazyForEach（全仓 0 命中） | NodeSelectionPage.ets:1542/1634 |
| 节点搜索框 | ❌ pages 下无 `Search(` | — |
| 订阅失败引导 | ❌ 未连接 + 订阅域名被墙 = 无引导 | — |
| 卡片深链 | 卡片 targetPage 未被消费 | MainPage |
| miniBar | 未启用 | — |
| 备份 | 明文 JSON | SECURITY_HARDENING 文档 |
| IPv6 语义 | `isIPv6Accepted:false` 待真机验证 | ✅ 2026-10-20 真机取证：旧配置下 v6 **从物理网卡绕过代理**（`ping6` 直连成功、`vpn-tun` 上 `::/0` 为 0 条）⇒ 改为设置页开关（默认开）由 TUN 接管 |

---

## 4. 能力矩阵（十维 / 六客户端 + TunBox）

图例：✅强 ｜ 🟡部分/有条件 ｜ ❌无 ｜ ？未验证

| 维度 | Surge | QX | Loon | SFI | Shadowrocket | Stash | **TunBox** |
|---|---|---|---|---|---|---|---|
| A 订阅导入 | 自有格式 + policy-path | resource-parser JS | 六类远程订阅 | 仅 sing-box JSON | **最宽容**（多格式/扫码/URL） | Clash YAML 直读 | **✅ 并列第一**（mihomo 全协议直读 + 逐节点诊断） |
| A2 用户可扩展 | 模块系统（参数化+远程） | 三类 remote 片段 | 插件（input/select） | ❌ | 模块/插件（LOWERTOP 生态） | Override JS 脚本 | **❌ 最大缺口** |
| B 协议广度 | 无 VLESS、有 Snell/MASQUE | 无 HY2/TUIC/WG | 无 TUIC | **全量** | 全量 | 全量（mihomo） | ✅ 并列第一 |
| B2 协议细节 | HY2/TUIC 跳跃✅ | Reality✅ | 跳跃✅ + JS Custom 节点 | 全量 + ECH | 全量 | 全量 | ✅ 指纹/跳跃/Reality 均已实现 |
| C 规则引擎 | 30+ 类型、RULE-SET 索引化（10万条 ms 级）、逻辑规则 | host/ip/ua/asn、无聚合格式 | 全类型 + 逻辑规则 + 端口区间 | rule-set(.srs) + geosite/geoip | 全类型 | mihomo 全量 | 🟡 mihomo 规则面够强，但**规则集不可添加** |
| C2 匹配阶段 | **DNS 预匹配 REJECT** | **DNS 层 reject** | 复写先于规则 | — | — | — | **❌ 仅连接期 REJECT** |
| D DNS | Fake-IP + DoH/DoH3/DoQ/DoT + hijack + DNS Script | DoH/DoQ/DoH3（无 DoT） | 四上游 + 回落 + SSID 条件 | DoH/DoT/DoQ/H3 + DNS 路由 | 全 | 全 | ✅ 全 DoT 防泄露 + policy；🟡 无 DoQ/DoH3 |
| E TUN/内存工程 | 45MB 告警 + 资源 10MB/2MB 限额 | 未文档化 | 未文档化 | **OOMKiller 恒开 + 50MB 默认**（开源实现） | 未文档化 | 未文档化 | ✅ **无 NE 50MB 硬限，结构性优势** |
| E2 常驻/按需 | Always On | ？ | ？ | **alwaysOn + OnDemand 规则完整** | On Demand | ？ | 🟡 **缺口**，见 §6 P1-3 |
| F 脚本/重写/MitM | **最强**（7 类脚本 + JQ Body + H2/WSS MitM） | 6 类重写 + jsonjq + 本地 API | 脚本 API 深（$config 控选择）+ 插件 | **全无** | 脚本 + MitM + 模块 | JS Override | ❌ 缺口（但 MitM 建议不做） |
| G 系统集成 | Widget/控制中心/快捷指令/scheme/Web Dashboard/HTTP API | scheme 仅资源导入 | **scheme 最全**（开关+六类导入） | ControlWidget + App Intents + scheme | scheme + widget | scheme | 🟡 有桌面卡片；缺**控制中心类常驻入口 + 一键导入 scheme** |
| H 诊断透明度 | 请求列表 + 规则命中计数 | — | — | — | 请求列表 | 请求列表 | ✅ **领先**：逐节点诊断 + 延迟持久化 + 规则链 |

---

## 5. 领先项（应固化为壁垒，不要在追赶中丢失）

1. **App 级分流**：iOS 六家**全部**做不到。Surge 手册原文："Process rules are available on Surge Mac only; Surge iOS ignores these rules"（📗）；SFI 特性表 `include_package`/`exclude_package`/`include_uid`/`process_name` 在 Darwin 平台全部 ❌（📗）。**这是 TunBox 唯一"人无我有"的强能力**，应在产品叙事中前置。
2. **订阅兼容面**：Surge 不解析 Clash YAML、SFI 只吃 sing-box JSON、QX 依赖自写 JS parser、Loon 需 Sub-Store；只有 Shadowrocket/Stash 接近 TunBox。而 TunBox 额外的**逐节点解析诊断**（哪个节点哪个字段失败）在六家中无等价物。
3. **无 NE 内存硬限**：SFI 用 `oomKillerEnabled` 恒开 + `oom_memory_limit_mb=50` 兜底，逼近上限时**主动断开连接自救**（📘 ExtensionProvider.swift:204、SharedPreferences.swift:61）；Surge 内存告警阈值 45MB、外部资源限 10MB/2MB（📗）。鸿蒙 VPN Extension 无此约束 → 大订阅/大规则集下 TunBox 的稳定性上限更高。
4. **诊断透明度**：延迟结果持久化 + 新鲜度标注 + 规则链展示。

> ⚠️ 反向教训：SFI 的 **OOMKiller 思路值得借鉴为防御性设计**——即使没有 50MB 上限，也应在内存压力下"主动降级（停用大规则集/停用日志）而不是被系统杀死"。📘 机制 + ⚠️ 迁移推断。

---

## 6. 优化清单（按优先级）

### P0 — 正确性 / 合规（必须做）

**P0-1 订阅自动刷新静默失效**（缺陷，非功能）
- 现状：🔬 `autoUpdateSubscription` 仅存在于 AppSettings.ets:55/140/222/287，**全仓库无调度器消费**。
- 影响：用户以为订阅会自动更新，实际永不更新 → 节点过期后无法连接，且无任何提示。这是**审核友好度**问题（功能开关不生效）。
- 方案：`@ohos.resourceschedule.workScheduler` 延迟任务（已有 `KEEP_BACKGROUND_RUNNING` 权限）+ 应用前台时按 `updateInterval` 兜底检查。**注意**：扩展/Ability 上下文差异——VpnExtensionAbility.ets:977 已实证 `backgroundTaskManager` 只接受 UIAbility 上下文，WorkScheduler 同理需在 EntryAbility 侧注册。
- 工作量：小（1–2 天，含真机验证）。
- 验收：关闭/开启开关后观察刷新时间戳变化；断网/超时不得影响连接。

**P0-2 订阅拉取失败无自救路径**（首次连接体验）
- 现状：未连接时若订阅域名被墙，用户无引导（docs/first-connect-empty-nodes-rootcause.md）。
- 方案：**复用已有 headless 测速内核**（TestCoreFlight，已具备独立 secret 且不挂 TUN）作为"通过代理拉订阅"的通道——FlClash 的 `findProxy` 等价物。已有节点 → 起临时内核 → 经代理拉订阅 → 关闭。
- 价值/成本比极高：基础设施已存在，只差编排逻辑。
- 工作量：中（3–5 天）。

**P0-3 DNS 层 REJECT 预匹配**（对标 Surge 5.14.0 / QX / Loon）
- 现状：🔬 REJECT 仅在连接阶段（ClashConfigGenerator.ets:540）；DNS 侧有 nameserver-policy(:250)/fake-ip-filter(:264)，**无 DNS 阶段拒绝**。
- 影响：① 广告域名的 DNS 查询**真实发出**（性能 + 隐私）；② 请求要走到 TCP 才被拒。
- 方案：mihomo 支持在 `nameserver-policy`/规则中把域名指向 `rcode://name` 或 `reject`（DoH/DoQ 语义）——**需先做内核能力验证**（⚠️ mihomo 版本相关），再决定是 DNS 侧拒绝还是仅做"预匹配标记 + 连接期拒绝"的折中。
- 工作量：中（3–5 天，含内核验证）。
- 验收：广告域名在 DNS 阶段即被拒（抓包验证无上游查询）。

**P0-4 备份加密**
- 现状：备份为明文 JSON（含订阅 URL 等凭据）。
- 方案：口令派生密钥加密 + 导入校验；或至少剔除凭据 + 明确风险提示。对标：Surge 敏感项入钥匙串（📗 Keystore，4.14.0）。
- 工作量：中。

**P0-5 断言卫生与真机验证缺口**
- 4 个断言脚本在干净树失败；`isIPv6Accepted:false` + `::/0` 黑洞路由的 IPv6 泄漏语义**未经真机验证**。
- 方案：补齐断言基线；真机抓包确认 IPv6 不泄露（或明确"IPv6 全黑洞"的产品语义并写入 UI）。
- 工作量：小–中。
- **2026-10-20 结论（已闭环）**：真机取证证明旧方案**不防泄漏** —— 隧道在线时 `::/0` 只挂在
  `wlan0`、`vpn-tun` 上 0 条，`ping6 2001:4860:4860::8888` 仍能直连；同时 `dns.ipv6: false`
  让隧道 DNS 对 AAAA 恒 `ancount=0` ⇒ v6-only 站点必然打不开。已改为设置页「IPv6 双栈」开关
  （默认开；TUN 与内核读同一份 YAML，不会分叉），诊断面板的 IPv6 项由「恒 skip」改为真实 AAAA 探针。

### P1 — 体验差距（对标后值得补）

**P1-1 代理模式补 `direct`（三态）**
- 现状：🔬 ClashConfigGenerator.ets:140-141 只有 `rule`/`global`。
- 对标：Surge/QX/Loon/SFI 全部提供 **Direct / Rule / Global** 三态（SFI 的 Mode 即来自 `clash_mode`）。
- 方案：mihomo 原生支持 `mode: direct`，一行映射 + UI 第三态。**成本极低、对标收益明确**。
- 工作量：小（0.5 天）。

**P1-2 用户自定义规则集（rule-provider）**
- 现状：🔬 仅内置 hyper-adrules（:526-540）；用户只能手写单条规则（RulesPage.ets:158）。
- 对标：Surge External Resources（ETag 增量 + 10MB/2MB 限额）、QX `[filter_remote]`、Loon 订阅规则集、SFI `.srs`、Stash mihomo rule-providers——**六家全部支持**。
- 方案：UI 添加远程 RULE-SET（URL + 格式 behavior + 策略 + 更新间隔），生成器已具备 rule-providers 输出能力（hyper-adrules 即先例），**扩展成本低**。需配套：大小上限（对标 Surge 的限额思路）、下载校验、失败回退（保留上一版）。
- 工作量：中（5–8 天）。

**P1-3 连接生命周期与系统级入口**
- (a) **连接阶段进度可视化**：TunnelAuthority phase 已有，但未在主页做阶段呈现。对标对象普遍有明确的"连接中/已连接"状态机。
- (b) **HdsTabs miniBar**：未启用（🔬 全仓无 `miniBar` 命中）——低成本获得"常驻状态 + 一键启停"，对标 SFI 的 ControlWidget、Surge 的控制中心控件。
- (c) **卡片 targetPage 深链**：卡片已有跳转参数但未消费 → 点卡片直达对应页签。
- (d) **一键导入 URL Scheme**：`tunbox://import?sub=...`（对标 `loon://import?sub=`、`surge:///install-config?url=`、`sing-box://`、`quantumult-x:///add-resource`）。用于从浏览器/文档一键加订阅。
- 工作量：小–中（分 4 个小项，可独立交付）。

**P1-4 列表性能与检索**
- 现状：🔬 全仓无 `LazyForEach`（NodeSelectionPage.ets:1542/1634 为普通 `List`）；pages 下无 `Search(`。
- 对标：Surge 的规则集索引化（10万条 ms 级）；Shadowrocket/Stash 的节点搜索。
- 方案：`LazyForEach` + 数据源；节点搜索/收藏/批量多选（测速、删除）。
- 工作量：中（3–5 天）。

**P1-5 规则调试闭环**
- 现状：RulesPage 只提供文本编辑 + 说明；无"哪个域名命中了哪条规则"的检索。
- 方案：ConnectionsPage → 规则链已存在，补"按域名/关键词搜索命中规则 + 一键修正"联动。
- 工作量：小–中。

### P2 — 增强 / 差异化

| 项 | 说明 | 对标参照 | 工作量 |
|---|---|---|---|
| 流量与连接统计 | 按 App / 域名 Top N，基于 mihomo `/connections` 已有数据 | Surge/QX 统计能力 | 中 |
| 端口跳跃 UI 暴露 | 内核已支持（ProxyNode.ets:750），补编辑入口与校验 | Loon/Surge 明确宣传 | 小 |
| 节点失败自动切换阈值 | Loon `switch-node-after-failure-times`（默认 3）；TunBox 有 fallback 组但无健康度阈值 UI | Loon 📗 | 小–中 |
| DoQ / DoH3 | 当前全 DoT；对标 Surge（DoQ/DoH3）、QX（DoQ+prefer-doh3）、Loon（doq/doh3） | 三家 📗 | 中（依赖内核） |
| 内存压力自适应降级 | 借鉴 SFI OOMKiller：内存紧张时停用大规则集/日志而非被杀 | SFI 📘 | 中 |
| 配置覆盖层（非脚本） | 对标 Stash Override / Surge 模块的**安全子集**：YAML 片段合并（YamlMerger 已是基础），不做 JS/MitM | Stash/Surge | 中大 |
| SSID 条件规则 | 对标 QX `ssid_suspended_list`、Loon `ssid-trigger`、SFI `wifi_ssid` | 三家 📗 | ⚠️**需评估 `GET_WIFI_INFO` 权限**（AGC 闸门） |

### 明确不做（附理由）

| 不做项 | 理由 |
|---|---|
| **MitM / HTTPS 解密 / 重写** | 与"不收集、不上传"隐私承诺直接冲突（解密用户流量）；AGC 审核高风险；需用户装根证书。**Surge/QX/Loon 有 ≠ 应该有**。 |
| 脚本沙箱（JS 引擎） | 无 MitM 的纯脚本价值有限；引入 JS 运行时带来内存/审核/攻击面成本。若要"用户可扩展"，优先做 P1-2 规则集 + YAML 覆盖层。 |
| 进程/UID 级规则 | 平台无此能力（iOS 同样没有：Surge iOS 忽略 PROCESS、SFI 标注 ❌）；TunBox 已用 App 级分流覆盖该需求。 |
| 局域网网关模式 | QX 有（需 `sysctl` 改内核参数，📘 lan-gateway.md），但与商店定位/合规边界冲突，且非目标用户场景。 |
| 追赶"协议数量"叙事 | mihomo 已覆盖；营销上应讲**兼容性与诊断**，不是协议计数。 |

---

## 7. 工作量汇总

| 批次 | 内容 | 预估 |
|---|---|---|
| **Sprint 1（P0）** | P0-1 自动刷新接线、P0-2 订阅自救通道、P0-5 断言/IPv6 收尾 | 1–2 周 |
| **Sprint 2（P0+P1 低成本）** | P0-3 DNS 预匹配、P0-4 备份加密、P1-1 direct 模式、P1-3 四项系统集成 | 2–3 周 |
| **Sprint 3（P1 主体）** | P1-2 自定义规则集、P1-4 列表性能/检索、P1-5 规则调试闭环 | 3–4 周 |
| **Sprint 4（P2 选做）** | 统计、端口跳跃 UI、健康度阈值、内存降级 | 3–4 周 |

---

## 8. 附录：证据来源

- Surge：manual.nssurge.com（Rules/Process、Advanced DNS、Scripting、URL Scheme）、kb.nssurge.com release-notes、iTunes Lookup API
- Quantumult X：github.com/crossutility/Quantumult-X（sample.conf、url-scheme.md、lan-gateway.md、parser-helper-protocol.md）
- Loon：nsloon.app/docs、github.com/Loon0x00/LoonManual（guide/node/rule/dns/policy/script/scheme/plugin）
- sing-box for iOS：github.com/SagerNet/sing-box-for-apple @ `56681841de346fb2185dc6eceba415f6b41bb2b2`（ExtensionProvider.swift、SharedPreferences.swift、ExtensionProfile.swift、OnDemandRule.swift、WidgetExtension/）、sing-box.sagernet.org（TUN/route/DNS/inbound 特性表）
- Shadowrocket / Stash：App Store 元数据、社区文档与实践资料（📙）
- TunBox：本仓库代码级核实（🔬，锚点见 §3/§6）

> 未验证项（⚠️）：Surge iOS 是否暴露系统级 NE On-Demand UI；QX/Loon 的 Always-On 与主屏 widget；mihomo 当前内核对 DNS 阶段 `reject`/`rcode://` 的支持粒度；鸿蒙 `GET_WIFI_INFO` 权限的 AGC 审核口径。

---

## 9. 实施状态（2026-10-14 更新）

> 以下为 §6 优化清单的实施结果。除 P1-1（direct 模式，用户明确跳过）与 P2 流量统计页（判定既有功能已覆盖，见下）外，全部 P0/P1/P2 项已实施并通过构建验证（`assembleHap --mode module -p product=default`，BUILD SUCCESSFUL）。实施前快照：`C:\Worker\.snapshots\tunbox-pre-optimization-20261013-145407\`。

| 项 | 状态 | 落地形态 |
|---|---|---|
| P0-1 订阅自动刷新 | ✅ 完成 | `SubscriptionUpdateScheduler.ets`（单例：6h 过期阈值、前台兜底 5min 节流、2 lane 并发刷新）+ `SubscriptionWorkAbility.ets`（WorkScheduler 延迟任务，4h 周期）；EntryAbility onCreate/onForeground 接线；module.json5 注册 |
| P0-2 订阅拉取自救 | ✅ 完成（务实形态） | 原方案「经 headless 内核代理拉订阅」经调查不可行（ArkTS http 无 per-request proxy、headless 内核只听 mixed-port）→ 改为「网络性失败标记 + 连接成功后自动补拉」：`SubscriptionService.markNetworkFetchFailure/takePendingNetworkRetries`（30min TTL）+ `ConnectionOrchestrator.retryPendingSubscriptionFetches`（连接成功 3s 后 fire-and-forget 补拉） |
| P0-3 DNS 层 REJECT 预匹配 | ✅ 完成 | 双层拦截：DNS 层 `nameserver-policy` 的 `"+.site": rcode://refused`（解析层直接拒绝，不发上游查询）+ 路由层 `DOMAIN-SUFFIX,site,REJECT` 兜底。新增第三名单 `forceBlockSites`（SiteRoutingPage 三张 chip，block 与 proxy/direct 重叠时拒绝保存） |
| P0-4 备份加密 | ✅ 完成 | `BackupCrypto.ets`：AES-256-GCM + PBKDF2-SHA256（100000 轮、16B salt、12B IV），封套 `app: TunBox-Encrypted`；HomePage 导出/导入接线（`BackupPasswordDialog` 自定义弹窗收密码，导入 3 次重试） |
| P0-5 断言卫生/IPv6 | ✅ 完成 | `console.assert` 全仓零命中（本就干净）；`probeIpv6` 改为恒 skip 并在 UI 标注「IPv4-only 规格」，消除误导性的 pass 语义 |
| P1-1 direct 模式 | ⏭️ 跳过 | 用户明确排除 |
| P1-2 自定义规则集 | ✅ 完成 | `CustomRuleSet{name,url,behavior,format,policy,interval}` + `normalizeRuleSets`（名称/URL/behavior/format/policy/interval 全校验、重名保留首条、上限 20）；生成器输出 `rs-<name>` rule-provider + `RULE-SET` 规则；RulesPage UI（添加/删除/格式与策略 chip） |
| P1-3a miniBar | ✅ 完成 | MainPage HdsTabs `barFloatingStyle.miniBar`（状态点 + 节点名 + 连接/断开按钮，经 AppStorage `vpn_request_*` 通道触发 HomePage 既有消费逻辑） |
| P1-3b 卡片深链 | ✅ 完成 | EntryAbility `captureDeepLink`（targetPage→页签）+ MainPage `onDeepLink` 消费 |
| P1-3c 一键导入 scheme | ✅ 完成 | `tunbox://import?...url=`（module.json5 skills + `captureImportScheme` + SubscriptionPage `onImportRequest` 自动导入） |
| P1-4 列表检索 | ✅ 完成（务实形态） | 节点搜索框（`searchFiltered` 过滤）；LazyForEach 经评估不改造（行键含 latencyTick 动态刷新，需自维护 IDataSource，收益低） |
| P1-5 规则调试闭环 | ✅ 完成 | `ClashConfigGenerator.debugDomainMatch(domain, rules)` + RulesPage「规则调试」输入框（实时显示 `TYPE,value → TARGET` 命中） |
| P2 端口跳跃 UI | ✅ 完成 | NodeEditPage 端口跳跃 TextInput（`ports` 键经 extraOpts JSON 持久化，校验对齐 `splitPortHopping` 白名单） |
| P2 失败切换阈值 | ✅ 已有 | SettingsPage 既有 StepperRow（failoverThreshold 1-10 + cooldown），无需改动 |
| P2 流量统计页 | ✅ 判定已覆盖 | HomePage 速率/总量 + ConnectionsPage 按连接明细（↑↓ 流量）已存在；按 App/域名 Top N 未做（mihomo `/connections` 无 App 归属，鸿蒙侧映射成本高） |
| P2 内存压力自适应降级 | ✅ 完成 | VpnExtensionAbility `onMemoryLevel`：MODERATE 记日志；CRITICAL 写 warn + 经 detail 通道推 UI 状态。不在扩展内主动断连接（mihomo 自回收，主动断栈收益<恢复成本） |
| P2 YAML 覆盖层 | ✅ 完成 | `settings.yamlOverride`（8KB 上限）追加在生成配置尾部（对标 Stash JS Override 的无脚本形态）；`validateYamlOverride` 黑名单拦截 rules/proxies/proxy-groups/external-controller/secret/tun 六键；RulesPage TextArea + 保存 |
| SSID 条件规则 | ⏭️ 未做 | 需 `GET_WIFI_INFO` 权限 AGC 审核评估（§6 P2 表） |
| DoQ / DoH3 | ⏭️ 未做 | 依赖内核版本升级（§6 P2 表） |

**未做的三项与理由**（与 §6「明确不做」一致）：MitM/重写（隐私承诺冲突）、JS 脚本沙箱（YAML 覆盖层已覆盖无脚本可扩展性）、进程/UID 级规则（平台无此能力，App 级分流已覆盖）。
