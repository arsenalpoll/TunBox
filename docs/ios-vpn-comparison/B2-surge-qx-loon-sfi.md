# Surge / Quantumult X / Loon / sing-box for iOS (SFI) 功能级 REA 底稿

> 调研目的：为鸿蒙 NEXT 上的 mihomo 内核 VPN 客户端 TunBox 做差距分析（B2 底稿）。
> TunBox 现状基线：订阅解析（对齐 mihomo 全协议、逐节点诊断）、DNS 全加密 DoT 防泄露、五态延迟引擎+结果持久化、App 级分流、桌面卡片、mihomo-smart 智能选点内核。
> 调研日期：2026-10-13（Asia/Shanghai）。
> 方法：官方手册（manual.nssurge.com / nsloon.app / sing-box.sagernet.org）、开源仓库代码逆向（github.com/SagerNet/sing-box-for-apple @ commit `56681841de346fb2185dc6eceba415f6b41bb2b2`，本地浅克隆 grep）、iTunes Search/Lookup API（App Store 元数据）、社区资料交叉验证。
> 证据等级：📗官方文档 ｜ 📘开源代码 ｜ 📙社区文章 ｜ ⚠️推断/未能验证。

---

## 0. 目录

1. [Surge iOS](#1-surge-ios)
2. [Quantumult X](#2-quantumult-x)
3. [Loon](#3-loon)
4. [sing-box for iOS (SFI)](#4-sing-box-for-ios-sfi)
5. [四客户端功能矩阵（含 TunBox 粗判列）](#5-四客户端功能矩阵)

---

## 1. Surge iOS

### 基本信息（📗 [iTunes Lookup API](https://itunes.apple.com/lookup?id=1442620678) / [App Store](https://apps.apple.com/us/app/surge-5/id1442620678)）

- 当前版本 5.23.0（2026-10-12 发布），min iOS **17.0**，bundle `com.nssurge.inc.surge-ios`，开发者 Surge Networks Inc.。
- 购买 Surge iOS 授权可免费在 tvOS 使用（5.7.0 起，tvOS profile 经 CloudKit 下发，5.12.0 重构）。
- App Store 定位："advanced network toolbox"，四大工作流：Takeover（代理服务+虚拟网卡 VIF 双接管）→ Processing（重写/改包）→ Forwarding（规则+策略组）→ Intercept（MITM/抓包）。

### A. 订阅/配置导入与托管（📗 [Surge iOS Release Notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-ios.md)）

- 配置 = 纯文本 profile；导入：URL / 文件 / 剪贴板 / iCloud Drive / Dropbox（4.0.0 起支持 Dropbox 同步）。
- iCloud Drive 同步：3.5.0 起检测 iCloud 变更并提示；5.11.1 **iCloud 后台自动同步文件数上限 200**（防内存超限）。
- 远程托管 profile（Managed Profile，服务商 URL 只读下发）；`#!include` 分离文件（Detached Profile，4.12.0）；`#!REQUIREMENT` 条件编译指令（5.11.0）+ `#!IOS-ONLY`/`#!MACOS-ONLY`/`#!TVOS-ONLY` 平台标注（5.14.3）。
- **模块（Module）系统**：模块 = 覆写 profile 的片段，可远程订阅自动更新；`surge:///install-module?url=…` 一键装（5.10.0）；官方模块动态更新 + 分类字段 + 多参数表（文本替换注入，5.9.0）；模块可修改 managed profile；生效顺序可调/可撤销（5.10.0）。
- External Resources 统一管理页（规则集/模块/脚本）：ETag 增量更新（5.14.0）；**大小限制：外部资源 ≤10MB（5.8.0，domain-set 除外）、策略组/脚本类外部资源 ≤2MB（5.11.0）**——iOS NE 内存约束的显式工程体现。
- 机场接入：不解析 Clash YAML；走 external policy group（`policy-path=URL`，服务商提供 Surge 格式/base64 节点列表/vmess URI），见 📗 [KB: Using Proxies from a Third-Party Provider](https://kb.nssurge.com/surge-knowledge-base/guidelines/proxy-provider.md)。全 profile 也可作为 policy-path（4.13.0）。支持 `include-all-proxies` / `include-other-group` / `policy-regex-filter`（4.12.0）。
- URL 托管配置可手动更新（5.23.0）。

### B. 协议覆盖（📗 App Store description + [manual: Proxy Protocols 目录](https://manual.nssurge.com/)）

- 出站协议全集：HTTP/HTTPS、SOCKS5、SOCKS5-TLS、HTTP/2 CONNECT、**Shadowsocks**（2022-blake3-aes-128/256-gcm 于 5.14.0）、**Snell**（自家，v3 UDP relay）、**VMess**（AEAD，4.11.0；ws 传输）、**Trojan**（ws 4.12.0；UDP relay 4.11.0）、**Hysteria 2**（5.8.0；**端口跳跃 5.13.0**）、**TUIC**（**端口跳跃 5.13.0**）、**AnyTLS**、**MASQUE**、**Trust Tunnel**（自家）、**SSH**（4.14.0，等价 `ssh -D`；RSA/ECDSA/ED25519/DSA；仅 curve25519-sha256 kex + aes128-gcm，OpenSSH ≥7.3）、**WireGuard**（4.11.0 作为客户端 outbound 策略；多 peer/preshared-key/IPv6 endpoint/underlying-proxy 4.12.0；AF41 DSCP/ECN 透传 5.8.0）、**Tailscale**、External Proxy Program、**Surge Ponte**（自家 P2P 组网策略）。全部支持 UDP relay（视协议）。
- **不支持 VLESS**（官方手册协议列表中无此协议）、不支持 SSR。
- 协议嗅探：80/443 首包提取 SNI 供规则匹配（`extended-matching` 同时匹配 SNI + HTTP Host/:authority）（5.8.0）；自动 QUIC 阻断促回退 HTTPS/TCP（5.8.0）；`block-quic` 全局开关（5.14.6）；gQUIC SNI 提取（5.14.6）。

### C. 路由规则（📗 manual Rules 目录 + release notes）

- 规则类型面：DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / **DOMAIN-WILDCARD**（`?`/`*`，5.11.0）/ **HOSTNAME-TYPE**（IPv4/IPv6/DOMAIN/SIMPLE，5.11.2）/ URL-REGEX / IP-CIDR(+v6) / **IP-ASN**（4.14.0）/ GEOIP / **PROTOCOL**（TCP/UDP/DOH/STUN…）/ SRC-IP / SRC-PORT / DEST-PORT / IN-PORT / **SUBNET**（SSID/BSSID/路由器 IP 通配，4.7.0）/ CELLULAR-CARRIER（MCC-MNC）/ CELLULAR-RADIO / 逻辑规则 AND,OR,NOT / SCRIPT / RULE-SET / DOMAIN-SET / **Inline Ruleset**（5.7.0，同名 inline 规则集跨主配置+模块合并，5.23.0）/ FINAL（`dns-failed` 参数）。
- **RULE-SET/DOMAIN-SET 5.8.1 全量重写（索引化）**：更新资源时预索引——约 10 万条 DOMAIN-SUFFIX 规则集单次匹配从 ~100ms → 个位数 ms；1 万条 IP-CIDR 从 ~0.1ms → 0.0002ms（≈500×）；IP-CIDR 规则集性能等同内置 GEOIP；`no-resolve`/`extended-matching` 可挂 RULE-SET 级；严格校验（含非法行整体失效，5.11.0）。10 万条+规则集索引算法再优化 10×（5.11.0）。
- 规则使用计数（5.11.2）；请求列表"添加规则"可入既有规则集（5.12.0）；**DNS 阶段预匹配 REJECT/REJECT-DROP/REJECT-NO-DROP**（5.14.0，见 D 节）。
- **PROCESS-NAME：Mac only，Surge iOS 直接忽略进程规则**（📗 [manual: Process Rules](https://manual.nssurge.com/rules/process.html)："Process rules are available on Surge Mac only; Surge iOS ignores these rules"）——iOS VIF 拿不到对端 App 进程信息。**TunBox 的 App 级分流在此维度反超 Surge iOS**。

### D. DNS（📗 [manual: Advanced DNS Topics](https://manual.nssurge.com/dns/advanced.html)）

- VIF 激活时内置 **Fake-IP DNS 响应器**：iOS 监听 `198.18.0.4`（mac `198.18.0.2`，IPv6 `fd00:6152::2`；`198.18.0.2–198.18.0.9` 都算 Surge DNS），fake 池 `198.18.0.0/15`（IPv4 `198.18.1.1–198.19.255.254`），**fake IP⇄域名持久映射**，连接到达时反解回域名做规则匹配；fake 答案 TTL **5s（iOS）/30s（macOS）**；非 A/AAAA 查询（TXT/MX）转发上游；按查询地址族返回（IPv4 查询不给 AAAA fake IP）。
- `hijack-dns = 8.8.8.8:53, *:53`（[General] 参数）劫持硬编码 DNS 流量（仅解析为合法 DNS 报文的包被劫持）；`always-real-ip = *.srv.nintendo.net,…`（通配 Host List）豁免 fake-IP（NAT 类型检测/游戏主机/嵌套 VPN 场景）；`allow-dns-svcb`（默认 false，拒绝 type65 防 fake-IP 被绕过）；响应 `use-application-dns.net` NXDOMAIN 关 Firefox DoH。
- **DNS 层 REJECT 预匹配**：标 `pre-matching` 的域名 REJECT 规则由 DNS 响应器直接执行——无记录(REJECT)/静默丢弃(REJECT-DROP)/sink 地址 `198.18.0.244`(REJECT-NO-DROP)。
- 加密 DNS：`dns-server`（UDP）+ `encrypted-dns-server` 支持 **DoH/DoH3/DoQ/DoT**（DoH 自 4.0.0；**DoT 于 5.14.5 加入**）；`doh-skip-cert-verification`/`encrypted-dns-skip-cert-verification`；多服务器并发取最快；系统 search domains（5.14.0）；网络切换强制断开 DoH/DoQ 长连接（5.8.0）；DoH 默认走 DIRECT（`doh-follow-outbound-mode` 可改，4.2.1）。
- `[Host]` 本地映射（等价 /etc/hosts）：通配/别名/每域名指定 DNS 服务器；5.14.3 支持 DOMAIN-SET/RULE-SET 组织；**DNS Script** 可完全自定义应答（scripting/dns.html）；GeoIP 库自动/手动更新（4.5.0）。

### E. TUN / NetworkExtension（📗 release notes + manual）

- iOS 全部流量经 NetworkExtension VPN；**Enhanced Mode = VIF 虚拟网卡**；另提供 Wi-Fi/热点 HTTP+SOCKS5 代理服务，**Personal Hotspot Proxy Access**（4.12.0）允许热点内设备直接用代理端口。
- **Always On**（3.7.0）：设备重启后自动拉起 VPN；5.11.3 允许 widget/Shortcuts 在 Always On 开启时关闭、以及 VPN profile 未选中/被其他 VPN 占用时通过 widget 启动。⚠️ 未能验证 Surge iOS 是否暴露系统级 NE On-Demand 规则 UI（官方仅提 Always On 术语）。
- auto-suspend（5.11.0）：检测到当前网络由 Surge Mac 网关管理时自动暂停（可关）；Wi-Fi Assist / **Hybrid Network**（4.12.0，Wi-Fi 差时同时建蜂窝连接；解锁后才生效，5.8.0）；IPv6 VIF（4.9.0，`ipv6-vif=always` 5.11.0 + 非 IPv6 网络立即失败不重试）；`include-apns`/`include-cellular-services`/`udp-policy-not-supported-behaviour`（5.8.0）；No Default Route 模式多次优化（5.11.3/5.12.0）；**[IP Rewrite]**（5.23.0：按目的地址处理 VIF 入包，reflect/reject/drop，供本机回环）。
- 性能：5.8.0 VIF 优化——**iPhone 15 Pro 单线程 VIF 跑满 2.5Gbps 有线网卡**（代理模式更快）。
- 内存管理（📗 release notes）：**内存告警阈值 45MB（5.11.0 从 40MB 上调）**——直接对应 iOS NE ~50MB 上限；配合外部资源 10MB/2MB 限制、JSC 并发 ≤2、大脚本不驻留内存（5.11.0）、引擎 256KB 日志环形缓存（5.11.0）。

### F. 脚本 / 重写 / MitM / 模块（📗 manual Scripting/HTTP 目录 + release notes）

- 脚本类型：http-request / http-response / rule / dns / event / cron / generic。API：`$httpClient`（默认 timeout 5s，可覆盖）、`$persistentStore`（UI 可管理）、`$notification.post`（action URL；媒体资源/声音/自动消失 5.11.0）、`$utils.ipasn/ipaso/ungzip`、`$request.id` 贯穿请求/响应脚本、`$argument`。JSC 新执行引擎（5.9.0）、并发 ≤2（5.10.0）；HTTP-API 触发脚本；Shortcuts 执行脚本（4.6.0）。
- 重写：URL Rewrite、Header Rewrite（请求+响应、regex，4.13.0）、**Body Rewrite**（5.10.0；**JQ 表达式操作 JSON**，5.14.0）、Map Local/Mock（5.10.0 增强：text/tiny-gif/base64 内联数据、自定义状态码）、URL-REGEX 支持 MitM 连接（3.8.0）。
- MitM：自建 CA 助手、P12/PEM 导出、**HTTP/2 MitM 与 WebSocket MitM**（4.15.0）、中间证书链签名下发（5.8.1）、`<ip-address>`/`<ipv4-address>`/`<ipv6-address>` 关键字、Keystore（4.14.0：TLS 客户端证书、CA、敏感项入钥匙串）。
- HTTP 捕获：5.8.0 重构（开关即断长连接、自动停止条件、自动开 MitM）；HAR 导出（4.13.0）；**L3 原始抓包 .pcap**（4.5.0）；请求检查器大文件/JSON 高亮（5.14.6）。
- 模块系统详见 A 节（与脚本/重写/MitM 组合成"模块包"生态）。

### G. 系统集成（📗 release notes + [manual: URL Scheme](https://manual.nssurge.com/tools/url-scheme.html)）

- Widget：主屏 widget；**iOS 17 交互式 widget（5.7.0）**；**iOS 18 控制中心控件（5.13.0）**；HTTP capture 控制中心控件（5.14.0）；Information Panel（4.9.3）。
- Shortcuts/Siri：开关 VPN（4.6.0 起；iOS 17 独立 start/stop action，5.7.0）、执行脚本、切换出站模式、widget 在 always-on 下可关（5.11.3）。
- **URL Scheme**（iOS）：`surge:///start|stop|toggle`、`surge:///install-config?url=`、`surge:///install-module?url=`、`surge:///email-license`、`surge:///enterprise-license`（team-license 别名）；`autoclose=true`；x-callback-url（start/stop/toggle，v3.4+）。
- 远程/跨设备：Remote Controller 管理 Mac/tvOS（4.6.0，可远程改规则/更新资源）、Web Dashboard 2.0（5.7.0）、HTTP API（4.4.0；TLS 4.7.0；5.23.0 增外部资源管理端点）、Cloud Notification、Safari 扩展添加规则（App Store desc）、Ponte 设备诊断页（5.13.0）。
- 授权 6 设备共享（4.10.0）。

### H. 商业化（📗 [KB: Feature Update Subscription](https://kb.nssurge.com/surge-knowledge-base/license/ios-fus.md) + iTunes API）

- App Store **免费下载 + 内购**（美区 iTunes API price=0.00）。
- **Feature Update Subscription 模型：首购 $49.99 = 一年新功能订阅 + 终身使用权；续费 $14.99/年**；订阅过期后已解锁功能终身可用（含已解锁功能的 bug 修复与基础系统兼容更新）。（社区常说的"Surge $49.99"即此首购价，并非纯买断）

### I. 已知痛点

- iOS NE ~50MB 内存天花板：官方多处工程妥协（45MB 告警阈值、外部资源 10MB/2MB 限制、JSC 并发限制、iCloud 同步 200 文件上限）。📗
- iOS 无进程规则（系统限制）；不支持 VLESS/SSR；协议面主推自家 Snell/Ponte。📗
- 订阅兼容性：不直接解析 Clash YAML/sing-box JSON 订阅，机场需提供 Surge 格式或经转换。📗
- 价格门槛高（首购 $49.99）；配置语法为闭源自定义格式，学习曲线陡。📙/⚠️

---

## 4. sing-box for iOS (SFI)

### 基本信息（📘 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) + [SagerNet/sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple) @ `56681841de346fb2185dc6eceba415f6b41bb2b2`；📗 iTunes API）

- 仓库结构：主仓库 sing-box（Go 内核）顶层 `clients/` 为 git 子模块 → `clients/apple` → **sing-box-for-apple**（Swift 壳）。两仓库均 **GPL-3.0+**（📘 LICENSE）。
- sing-box-for-apple 目录：`SFI`(iOS app) / `SFM`(macOS) / `SFT`(tvOS) / `Library`(共享核心) / `ApplicationLibrary`(共享 SwiftUI 视图) / `MacLibrary` / `Extension`(iOS PacketTunnel) / `TVExtension` / `SystemExtension`(mac) / `HelperService`+`Jailbreak`+`JailbreakDaemon`(提权/越狱变体) / `IntentsExtension`(App Intents) / `WidgetExtension`(ControlWidget) / `ShareExtension` / `ActionExtension` / `FileProviderExtension`。
- App Store：**"sing-box MT"**，id `6785326793`，bundle `io.nekohasekai.sfamt`（与仓库 iCloud 容器 `iCloud.io.nekohasekai.sfamt` 一致），v1.14.7（2026-10-09），min iOS 15.0，98MB，**免费、无内购**，开发者挂牌 Metamerism LLC（旧 "sing-box" SagerNet 主体的上架关系 ⚠️未能验证）。描述："The universal proxy platform."

### A. 配置/订阅管理（📘代码）

- Profile 三类：`local` / `remote`（URL 订阅）/ `icloud`（`LibboxProfileTypeiCloud`；文件落在 iCloud Drive/sing-box/，`Library/Shared/FilePath.swift:42`；`ApplicationLibrary/Service/ProfileServer.swift:122`）。`ProfileType+Presentation.swift` 明确 iCloud 与 Local/Remote 语义分离。
- 导入：URL / 二维码（`ApplicationLibrary/Views/Scanner/QRScanner*.swift`）/ 文件（自定义文档类型 **`.bpf`**，UTType `$(BASE_PACKAGE_IDENTIFIER).profile`，SFI/Info.plist）/ ShareExtension / ActionExtension。
- **订阅后台自动更新**：BGTaskScheduler `$(BASE_PACKAGE_IDENTIFIER).update_profiles`，UIBackgroundModes `fetch`+`processing`（SFI/Info.plist:7-11,89-93）。
- FileProviderExtension：Files.app 文件域 + 连接状态变化时 `signalEnumerator(for: .workingSet)`（`Library/Network/ExtensionProfile.swift:99-112`）。
- 配置 = sing-box JSON，内置代码编辑器（Runestone 编辑器 + Ghostty 终端组件，SFI/RunestoneTextView.swift / GhosttyConfigEditorWrapperView.swift）。**无 Clash YAML/机场订阅转换 UI**（⚠️内核对 provider 支持有限，常见依赖外部订阅转换服务）。

### B. 协议覆盖

- = sing-box 内核全量（随 1.14.x）：Shadowsocks（含 2022-blake3）、VMess、**VLESS（XTLS Vision / Reality）**、Trojan、**Hysteria / Hysteria2**（端口跳跃）、**TUIC v5**、**WireGuard**（endpoint 出站）、ShadowTLS v1-3、**AnyTLS**、Mieru、SSH、Naive、Tor 等；uTLS 指纹、Reality、ECH。全部 UDP。📗 sing-box.sagernet.org 文档。**协议面四客户端最全**（与 mihomo 重合度最高）。

### C. 路由规则

- sing-box `route.rules`：domain/domain_suffix/domain_keyword/domain_regex、ip_cidr/ip_is_private、port/port_range、protocol(DNS/STUN…)、**rule-set（1.8+：.srs 二进制本地/远程 + inline，source/srs 两格式）**、geosite/geoip（数据库文件）、clash_mode、process_name/process_path（**桌面平台有效；iOS VIF 无进程信息 → 无效**）、wifi_ssid/wifi_bssid、network、inbound/outbound、logical rules（and/or）。📗 sing-box docs（docs/configuration/route）。
- 无 GUI 规则编辑器——规则全在 JSON 手写（与 Surge/QX/Loon 不同）。

### D. DNS（📘 docs/configuration/dns）

- sing-box `dns` 模块：servers 支持 `udp/tcp/tls(DoT)/https(DoH)/quic(DoQ)/h3`；per-server `detour`（DNS 查询走指定出站）/ `address_resolver`（bootstrap）/ `domain_resolver`；**DNS 路由规则**（按 domain/rule-set 等把不同域名指到不同 server）；**fake-ip**（inet4_range/inet6_range）；缓存与 TTL 策略；1.12+ 新版 servers[].type 结构。
- 防泄露机制 = fake-ip + DNS 规则分流 + per-server detour + 规则中 `server` 指定，配置门槛高于 Surge（Surge 为隐式默认防泄露）。

### E. TUN / NetworkExtension（📘 实现级逆向，重点）

- **`Extension/PacketTunnelProvider.swift` 仅 3 行**：`import Library; class PacketTunnelProvider: ExtensionProvider {}`（TVExtension/SystemExtension 同构）。全部逻辑在 **`Library/Network/ExtensionProvider.swift`**（`open class ExtensionProvider: NEPacketTunnelProvider`）。
- startTunnel 流程（ExtensionProvider.swift:133-261）：解析 startOptions（app 经 `startVPNTunnel(options:)` providerConfiguration 传 `configContent` 等）→ **持久化 start options 快照到文件**（供 on-demand 由系统自动拉起时无 app 交互重启，`resolveStartOptions`/`loadPersistedStartOptions`）→ `LibboxSetup`（basePath/workingPath/tempPath、**logMaxLines=3000**、platformMetadata=includeAllNetworks/excludeLocalNetworks/enforceRoutes/excludeAPNs(iOS16.4+)/excludeCellularServices/excludeDeviceCommunication(iOS17.4+)）→ `oomKillerEnabled=true`（**iOS 恒开**；macOS 可配 oomMemoryLimitMB/oomKillerKillConnections）→ `LibboxPromoteOOMDraft()` → 创建 `LibboxCommandServer`（状态/连接/日志 RPC）→ `startOrReloadService(configContent)`（**配置以字符串从 app 传入**）。
- **内存策略（iOS ~50MB NE 上限的解法）**：`Library/Database/SharedPreferences.swift:61` `oom_memory_limit_mb` **默认 50**；`ExtensionProvider.swift:200-201` `options.oomMemoryLimit = oomMemoryLimitMB * 1024 * 1024`（macOS 路径）；iOS 侧 `options.oomKillerEnabled = true`（:204）恒开——**libbox OOMKiller 在逼近内存上限时断开连接自救**（而不是被系统杀死整个扩展）；`OOMReportListView.swift`（ApplicationLibrary/Views/Tools）提供内存上限选择器与 OOM 报告列表；断开连接后 `schedulePromoteOOMDraft()` 延迟 2s 提升草稿状态（ExtensionProfile.swift:79-97）。⚠️ iOS 未显式传 oomMemoryLimit，实际靠 libbox 默认值 + OOMKiller 兜底；主仓库无 `GOMEMLIMIT` 字面量（经 libbox Options 间接设置）。
- 屏幕状态联动：`ScreenStateObserver`（iOS）——设备睡眠 `commandServer.pause()`、唤醒 `wake()`（省电，ExtensionProvider.swift:365-375）。
- **热重载**：app 经 `NETunnelProviderSession.sendProviderMessage` → PTP `handleAppMessage` → `reloadService()`（reasserting 状态，不断开 VPN 换配置）。
- **Always-on / 按需连接**：`SharedPreferences.alwaysOn`（`always_on`，SharedPreferences.swift:113）与 `onDemandEnabled` 双开关；启动时 `manager.isOnDemandEnabled = alwaysOn || onDemandEnabled`（ExtensionProfile.swift:191-196）；**alwaysOn → 默认规则**（单条 `NEOnDemandRuleConnect` interfaceType=.any，probeURL `http://captive.apple.com`，ExtensionProfile.swift:120-125）；onDemandEnabled → 用户自定义规则（`Library/Network/OnDemandRule.swift`：action connect/disconnect/evaluateConnection/ignore × interfaceType any/wifi/cellular × ssidMatch/dnsSearchDomainMatch/dnsServerAddressMatch/probeURL + `NEEvaluateConnectionRule`（matchDomains/connectIfNeeded/neverConnect/useDNSServers/probeURL））。
- **on-demand 与手动停止的互斥处理**：停止 VPN 时若 on-demand 开启 → 写 `wasOnDemandEnabled=true` 标记进 providerConfiguration 并临时关闭 isOnDemandEnabled（否则系统立刻自动重连），再次启动时恢复（ExtensionProfile.swift:283-300；WidgetExtension/WidgetTunnelControl.swift:71-82 同逻辑）。
- 网络能力开关（SharedPreferences + applyProtocolConfiguration，ExtensionProfile.swift:152-166）：includeAllNetworks（含锁屏设备通信）/ excludeLocalNetworks / enforceRoutes / excludeAPNs / excludeCellularServices / excludeDeviceCommunication(iOS 17.4+) / systemProxyEnabled / excludeDefaultRoute / autoRouteUseSubRangesByDefault。
- iOS 18：启停时 `ControlCenter.shared.reloadControls(ofKind:)` 刷新控制中心控件（ExtensionProvider.swift:256-260,346-350）。

### F. 脚本 / 重写 / MitM / 模块

- **无**。sing-box 无 JS 脚本、无 URL/HTTP 重写、无 MitM 体系、无模块系统（内核专注代理/路由）。仅 clash-api（Clash 兼容外部控制 + Dashboard 的 ClashModeCard 切 mode）与 v2ray-api 统计。📗/📘

### G. 系统集成（📘代码）

- **ControlWidget（iOS 17+）**：`WidgetExtension/ServiceToggleControl.swift` —— `ControlWidgetToggle("sing-box")` + `ToggleServiceControlIntent: SetValueIntent`，可放**控制中心/锁屏/Action Button**；`WidgetTunnelControl.setStarted` 直接操作 `NETunnelProviderManager.connection.startVPNTunnel()/stopVPNTunnel()` 并处理 wasOnDemandEnabled 恢复。**无主屏 WidgetKit widget**（WidgetExtension 无 TimelineProvider，grep 证实）。
- **App Intents**（`IntentsExtension/Intents.swift`）：StartServiceIntent（**可指定 profile 启动**，参数化 ProfileProvider 列表）/ RestartServiceIntent / StopServiceIntent / ToggleServiceIntent / GetServiceStatus / GetCurrentProfile / UpdateProfileIntent（remote profile 更新）+ `ServiceShortcuts: AppShortcutsProvider`（Siri 短语 "Start/Stop/Restart/Toggle sing-box"、"Update sing-box profile"）。
- **URL Scheme**：`sing-box` scheme（SFI/Info.plist CFBundleURLSchemes），`SFI/MainView.swift:441` `.onOpenURL(perform: openURL)`；ShareExtension 深链 `sing-box://taildrop`；NSApplicationServices `sing-box:profile`/`sing-box:report-transfer`。⚠️ 未发现 `install-config` 类公开 action（action 清单未文档化）。
- 无通知中心快捷操作、无 Watch app；tvOS 走 SFT。

### H. 商业化

- **免费 + GPL-3.0 开源**（内核与 iOS 壳均 GPL-3.0+）；无内购/无广告。App Store "sing-box MT" 免费。📗/📘

### I. 已知痛点

- 配置门槛四客户端最高：纯 JSON、无 GUI 节点/规则编辑器；社区普遍依赖外部订阅转换服务生成 sing-box 配置。📙/⚠️
- 无脚本/重写/MitM/模块生态——从 Surge/QX/Loon 迁移高级玩家的最大缺口。📘（设计取舍）
- Go runtime + 全功能内核在 NE 内存上限下靠 **OOMKiller 断连接自救**；高负载可能丢连接（📘机制 + ⚠️推断）。
- 无主屏 widget（仅控制中心 ControlWidget）；URL scheme 行动集薄。📘
- remote profile 只吃 sing-box JSON；BGTask 自动更新受系统调度影响。📘

---

## 2. Quantumult X

### 基本信息（📗 [iTunes Lookup API](https://itunes.apple.com/lookup?id=1443988620)）

- 当前版本 1.8.1（2026-10-07），min iOS 15.0，89MB，美区评分 3.8★，**闭源**（唯一官方"文档"= [crossutility/Quantumult-X](https://github.com/crossutility/Quantumult-X) 仓库的 sample.conf + 样例脚本）。
- **定价：美区 $9.99 一次性买断**（任务简报中的 $7.99 为过时/区域价，实测 iTunes API price=9.99）。无订阅、无内购。

### A. 订阅/配置导入与托管（📘 [sample.conf](https://github.com/crossutility/Quantumult-X/blob/master/sample.conf) v1.5.5 build 914）

- 配置 = 单一 .conf 文本，分区结构 `[general] [dns] [policy] [server_local] [server_remote] [filter_local] [filter_remote] [rewrite_local] [rewrite_remote] [task_local] [http_backend] [mitm]`。
- **三类远程资源各自订阅**：`[server_remote]`（节点，参数 tag / update-interval 默认 86400s、负数禁用 / as-policy=static 可把节点列表直接转成静态策略组 / require-devices=设备 ID 白名单 / enabled）、`[filter_remote]`（规则，force-policy 覆盖远程策略、inserted-resource）、`[rewrite_remote]`（重写片段）。
- **订阅格式转换 = resource-parser（JS）**：`[general] resource_parser_url` 全局指定解析器（生态常用 Sub-Store 的 loon/qx 解析器），单条订阅 `opt-parser=true` 启用；解析器作者可用 **$parser 参数化 UI 协议**（hashSchema/hashToUI/uiToHash，1.5.6 build 918+）为订阅 URL `#` 参数生成图形化编辑页（📘 [parser-helper-protocol.md](https://github.com/crossutility/Quantumult-X/blob/master/parser-helper-protocol.md)）。
- iCloud：脚本可存 "On My iPhone - Quantumult X - Scripts" 或 "iCloud Drive - Quantumult X - Scripts"（📘 sample.conf:298；仓库含 sample-icloud-storage.js / backend-icloud-to-http.js）。**完整配置 iCloud 同步、远程托管配置（Managed Profile）官方仓库文档为空文件（remote-managed-configuration.md 0KB）⚠️未能验证**。

### B. 协议覆盖（📘 sample.conf [server_local]；**关键修正：早年 [issue #212](https://github.com/crossutility/Quantumult-X/issues/212) 「不支持 SS2022/Hysteria2/VLESS Reality」已过时**）

- **Shadowsocks**：2022-blake3-aes-128/256-gcm ✅、aes/chacha20 系列、obfs=http/tls/over-tls/ws/wss、**SSR 参数**（ssr-protocol=auth_chain_b、obfs=tls1.2_ticket_fastauth）、udp-relay、**udp-over-tcp（sp.v1/sp.v2，兼容 Xray/sing-box 服务端）**、per-node server_check_url。
- **VMess**（aead、tcp/ws/wss/over-tls/http）、**VLESS**（含 `vless-flow=xtls-rprx-vision`）、Trojan（over-tls/wss）、**AnyTLS**、HTTP、SOCKS5。
- **全部 TLS 系协议支持 Reality**（`reality-base64-pubkey` + `reality-hex-shortid`；启用时用 iOS26 Safari TLS 指纹——X25519MLKEM768 后 ClientHello>1500B 会导致 TFO 失败，官方注明 Reality 不应开 fast-open）+ iOS18 Safari 指纹、tls-alpn（hex）、tls-cert-sha256/tls-pubkey-sha256 证书钉扎、tls-no-session-ticket/reuse。
- **不支持：Hysteria2、TUIC、WireGuard、SSH、Snell**（sample.conf 无对应条目，📙/📘）。per-node fast-open。

### C. 路由规则（📘 sample.conf [filter_local]）

- 规则类型：host / host-suffix / host-keyword / host-wildcard / user-agent / ip-cidr / ip6-cidr / geoip / ip-asn / final；**接口绑定参数**：force-cellular / multi-interface / multi-interface-balance / via-interface=pdp_ip0（蜂窝/Wi-Fi 双路控制）。
- 无 RULE-SET 聚合格式——远程规则集 = 逐行 filter 文件（[filter_remote]）；无 PROCESS 规则（iOS 系统限制，同 Surge）；SSID 维度在 [general] 层处理（ssid_suspended_list / running_mode_trigger / enhanced_compatibility_ssid_list）。
- **DNS 层 REJECT**：`host, example.com, reject` → DNS 应答 127.0.0.1（📘 sample.conf:61）。

### D. DNS（📘 sample.conf [dns]）

- `server`（UDP，支持 IPv6 地址与自定义端口）+ **doh-server + doq-server（DoQ，默认 853）+ prefer-doh3**（DoH3 失败回落 HTTP/2）；**不支持 DoT** ⚠️。多服务器并发取最快；配置了 DoH/DoQ 后普通 server 被忽略（除非域名绑定）；iOS<13 限 1 个 DoH、iOS<15 限 2 个。
- **per-domain DNS 绑定**：`/example.com/8.8.4.4`、通配 `/*.example2.com/223.5.5.5`、per-domain DoH/DoQ（`/*.example3.com/https://…`）、`address=` 静态 IP、`alias=` CNAME；DNS 服务器可挂 `excluded_ssids=`/`included_ssids=` 按 SSID 条件生效。
- `no-system`（禁系统 DNS）、`no-ipv6`（AAAA 直接失败）、`circumvent-ipv4/6-answer`（过滤上游脏结果，支持 ? * 通配）、`dns_exclusion_list`（排除 placeholder-IP **198.18.0.0/15** fake-ip 式映射 → 真解析）、`dns_reject_domain_behavior`（loopback / nxdomain / no-error-no-answer / none，TTL 10s）。
- LAN 网关模式下 DNS handler = **198.19.0.3**（📘 lan-gateway.md）。

### E. TUN / NetworkExtension（📘 README + sample.conf + lan-gateway.md）

- 双通道接管：TUN（"Quantumult X Tunnel"）+ HTTP 代理；**MitM/rewrite 对 TUN 流量生效**（README）。**改配置不触发重连**（README）。
- UDP 控制：`udp_whitelist`（目的端口白名单，外发 ICMP port unreachable）/ `udp_drop_list`（静默丢，支持 STUN/QUIC 协议名）/ `fallback_udp_policy`（节点不支持 UDP relay 时落到指定 fallback 节点或 reject）/ `excluded_routes`（CIDR 绕过 TUN）/ `icmp_auto_reply`。
- **LAN Gateway 模式**（1.0.17+，📘 lan-gateway.md）：iPhone 手动 `sysctl net.inet.ip.forwarding=1` 后可作局域网网关（其他设备网关指向它、DNS 指 198.19.0.3），MitM/rewrite 对 LAN 设备同样生效——四客户端独有。
- SSID 联动：`ssid_suspended_list`（指定 SSID 挂起 VPN）、`running_mode_trigger`（按 SSID 切 all_proxy/all_direct/filter 模式）。⚠️Always-On/On-Demand 未见官方文档化。

### F. 脚本 / 重写 / MitM / 模块（📘 sample.conf [rewrite_local]/[task_local]/[http_backend]/[mitm]）

- 重写动作：reject / reject-200 / reject-img / reject-dict / reject-array（带 0~5s 动态延迟防重试风暴）/ 302 / 307 / request-header / request-body / response-header / response-body 正则替换 / **jsonjq-response-body、jsonjq-request-body（JSON JQ 表达式）** / echo-response（本地文件应答）/ script-*（JS）/ **url-and-header 双条件匹配**。
- `[task_local]`：cron（5/6 字段）+ **event-network**（网络变化触发）+ **event-interaction**（用户点击 UIAction 触发）；`$task.fetch()`（默认 10s）；脚本 URL `#` 后自定义参数（`$environment.sourcePath` 读取）。
- **`[http_backend]` 独有**：本机 HTTP 服务器（`http://127.0.0.1:9999/...`）+ JS 处理（$request/$done 回响应）——把脚本变成本地 API。
- 脚本 API：$request/$response（含 sessionIndex 关联请求响应）、$notify、**$prefs**（持久存储）、$configuration API、iCloud 存储 API；默认 HTTP 超时 10s。
- `[mitm]`：passphrase/p12、skip_validating_cert、skip_src_ip/skip_dst_ip、hostname（按 TLS SNI + 目的地址，通配）。
- **无模块系统**（重写/任务/MitM 直接写主配置，或经 URL scheme 整段导入 remote 片段）。

### G. 系统集成（📘 [url-scheme.md](https://github.com/crossutility/Quantumult-X/blob/master/url-scheme.md)）

- URL Scheme：`quantumult-x:///update-configuration?remote-resource=`（JSON **全量替换**三类远程资源）、`quantumult-x:///add-resource?remote-resource=`（**增量**添加）、`quantumult-x:///ui?module=gallery&type=task|icon&action=add`（导入任务/图标集）。
- Universal Link：`https://quantumult.app/x/open-app/...`（1.0.30+，同 action）。
- **无 start/stop 开关类 scheme** ⚠️；快捷指令可开关 VPN（📙 [V2EX 社区自动化方案](https://global.v2ex.co/t/962783#reply30)）；主屏 widget ⚠️未能验证（官方未宣传）。

### H. 商业化

- **$9.99 美区一次性买断**（📗 iTunes API），无订阅/内购/广告。

### I. 已知痛点

- 协议面停在"经典全家桶"：无 Hysteria2/TUIC/WireGuard/SSH（sample.conf 📘；issue #212 社区长期诉求，其中 SS2022/VLESS-Reality 后已补上，HY2/TUIC 仍无）。
- 无模块系统；配置无官方文档站，只有 sample.conf 注释 + repo 样例，上手门槛高。📙
- 订阅兼容依赖用户自配/自写 resource-parser JS。📙
- 个人开发者 + 低价买断 → 更新节奏慢（1.5.5→1.8.1 跨多年）。📙

---

## 3. Loon

### 基本信息（📗 iTunes Lookup + [LoonManual](https://github.com/Loon0x00/LoonManual)/guide.md）

- id1373567447，v3.5.2（2026-10-01），min iOS 15.0，68MB，Loon Lab Limited，**闭源**。
- 定价：**美区 $7.99 一次性买断**（📗 iTunes API；国区 ¥30 📙第三方 FAQ 站 [nsloon.uk](https://nsloon.uk/faq.html)——非官方站点）。无订阅/内购。

### A. 订阅/配置导入与托管（📗 LoonManual）

- 导入：URL / 文件 / 扫码（📗 guide.md + 📙 nsloon.uk FAQ）；订阅节点、订阅规则、插件、图标集、geoip 数据库、解析器**六类远程资源**均可订阅（📘 scheme.md import 参数面）。
- `resource-parser`（[General]）支持接 Sub-Store 解析器做订阅转换（📗 general.md）。
- iCloud 同步配置（📙 nsloon.uk FAQ"开启 iCloud 备份，配置自动同步"；官方 Manual 无专门章节 ⚠️）。
- **筛选节点（NodeFilter，GUI）**：NodeSelect / NameKeyword / NameRegex 分组（📗 nodefilter.md）。

### B. 协议覆盖（📗 [nsloon.app/docs/Node](https://nsloon.app/docs/Node/) ≙ LoonManual node.md）

- Shadowsocks（2022-blake3-aes-128/256-gcm、simple-obfs、**ShadowTLS v2/3**、udp-over-tcp）、ShadowsocksR、HTTP/S、SOCKS5（+over-tls、ShadowTLS）、VMess（tcp/ws/http；Reality）、**VLESS（xtls-rprx-vision；Reality）**、Trojan（ws；Reality）、**WireGuard**（interface+peers 数组、reserved、keepalive 45s、mtu 1280）、**Hysteria2**（salamander obfs、**端口跳跃 server-ports + hop-interval**、download-bandwidth）、**AnyTLS**（Reality；idle-session-timeout/max-stream-count）。
- **Custom 节点（独有）**：`script-path=http.js` 用 JavaScript 自实现协议握手——任意私有协议扩展点（📗 node.md）。
- 通用参数：**server-dns（每节点独立 DNS，含 DoH/DoQ/DoH3，3.5.2+）**、ip-mode、fast-open、udp、block-quic、skip-cert-verify、sni、**tls-profile（chrome/safari-ios18…TLS 指纹模拟）**、tls-cert-sha256/tls-pubkey-sha256。
- **无 TUIC**、无 Snell、无 SSH（官方协议列表无，📗）。

### C. 路由规则（📗 LoonManual rule 系列）

- 类型：DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD、URL-REGEX、USER-AGENT（通配）、IP-CIDR / IP-CIDR6 / GEOIP / IP-ASN（no-resolve）、**SRC-PORT / DEST-PORT（支持区间 80-443 与 >=、<= 无穷区间）**、**PROTOCOL（HTTP/HTTPS/TCP/QUIC/STUN/UDP）**、**逻辑规则 AND/OR/NOT（3.1.7+）**、FINAL、订阅规则集。
- **匹配引擎**（📗 rule.md/sub_rule.md）：3.0.3 起域名类规则整体优先于 IP 类（目标为域名时先匹配域名规则，未命中才本地 DNS 后匹配 IP 类——避免无谓 DNS）；本地 > 插件 > 订阅；**百万级规则承载 + LRU 结果缓存**，实测 10 万+ DOMAIN/IP-CIDR 查询 <5ms、IP-CIDR6 <20ms（build 669, iPhone 15 Pro）。
- REJECT 家族：REJECT（200 空体）/ REJECT-IMG（1px GIF）/ REJECT-DICT / REJECT-ARRY / **REJECT-DROP（防重试风暴）**（📗 policy.md）。

### D. DNS（📗 LoonManual dns.md / general.md / hostmap.md）

- 四种上游：`dns-server`（UDP，system 关键字）、`doh-server`、`doq-server`（quic://，默认端口 **784**）、`doh3-server`（h3://）。**同时配置加密与普通 DNS 时只走加密**；并发查询取最快；加密失败**回落普通 DNS**（App 内可关）。
- 缓存：LRU 100 条（iOS15+ 200 条），TTL 过期即重查；磁盘缓存 3.1.5 起移除。
- **[Host] 映射**（hostmap.md）：域名→域名 / 域名→IP / 域名→指定 DNS（`server:8.8.4.4`、`server:system`、`server:https://DoH-url`）/ **SSID 条件 DNS**（`ssid:XXX = server:...`）。
- `real-ip`（≈Surge always-real-ip，FakeIP 豁免，防关网后缓存假 IP 失效）、`bypass-tun`、`disable-stun`（防 WebRTC 泄露）、`disable-udp-ports`、`geoip-url`。FakeIP 机制存在但池/参数未文档化 ⚠️。

### E. TUN / NetworkExtension（📗 general.md + scheme.md）

- TUN + HTTP Proxy 双模式（scheme 可切 `proxymode=tun|mix`）；`bypass-tun`（TUN 路径豁免）与 `skip-proxy`（HTTP 代理路径豁免）分离配置。
- `allow-wifi-access`（LAN 共享 HTTP 8899 / SOCKS5 8898）、`interface-mode`（Auto/Cellular/Performance/Balance 双网接口策略）、`ssid-trigger`（按 SSID 切 DIRECT/PROXY/RULE 全局模式）、`switch-node-after-failure-times`（节点连续失败 N 次自动切换，默认 3）。
- ⚠️Always-On / On-Demand 未见官方文档化（依赖 iOS 系统 VPN 设置）。

### F. 脚本 / 重写 / MitM / 插件（📗 LoonManual script.md / script_api.md / rewrite.md / plugin.md）

- 脚本类型：http-request / http-response（requires-body、binary-body-mode Uint8Array、`$done({url,headers,node})` 可改写请求并**指定策略组/节点**（build 534+）、可直接返回伪 response 自动补 content-length/content-encoding）、cron（5/6 字段）、network-changed、generic（手动触发，`$environment.params.node/nodeInfo`）。
- API：$loon、$script、**$config.getConfig() / getConfig(policyName,selectName)（脚本改策略组选择）/ getSubPolicies / getSelectedPolicy / setRunningModel**（脚本级配置控制，深于 Surge）、$persistentStore、$notification.post（attach 支持 openUrl/mediaUrl）、**$httpClient**（7 种方法；params 支持 `node:"HK"` 让请求走指定节点、body-base64、binary-mode、auto-redirect、auto-cookie；默认超时 5s）。
- 复写：URL 302/307、header-add/header-del/header-replace、reject 家族；**复写在规则匹配之前执行**。
- **插件（Plugin）≈ Surge 模块**：规则+复写+脚本+MITM+General 的子配置包；`#!name/desc/author/homepage/icon` + **`#!input`（用户输入参数）/ `#!select`（下拉参数）** → 脚本内 `$persistentStore.read(appName)` 读取；插件规则策略仅限 DIRECT / REJECT* / PROXY（装配时用户指定的策略组）。
- MitM：CA 生成→安装→系统信任三步（📙 nsloon.uk FAQ）。

### G. 系统集成（📘 [scheme.md](https://github.com/Loon0x00/LoonManual/blob/main/docs/cn/scheme.md)）

- URL Scheme **四客户端最全**：`loon://on | off | editconfig | flowmodel=direct|filter|proxy | proxymode=tun|mix | import?sub=|nodelist=|rules=|plugin=|iconset=|geoip=|parser= | update?sub=all`。
- Universal Link：`https://www.nsloon.com/openloon/...`（同 action 全集）。
- 通知跳转：脚本 $notification attach 可带 `loon://switch` 类深链（📘 script_api.md）。
- 主屏 widget ⚠️未能验证（官方 Manual/官网无 widget 文档章节）。

### H. 商业化

- $7.99（美区）一次性买断，无订阅/内购。TestFlight 免费需邀请码（📙 nsloon.uk，第三方）。

### I. 已知痛点

- 无 TUIC/Snell/SSH；HY2 端口跳跃等新特性要求 3.5.x。📗
- 官方文档分散（nsloon.app 与 GitHub LoonManual 双站）、插件生态弱于 Surge 模块生态。📙
- DNS/缓存策略多次重写（3.1.5 删磁盘缓存）→ 大规则集+多插件下的内存权衡仍在迭代。📗
- Always-On/On-Demand 无文档化支持。⚠️

---

## 5. 四客户端功能矩阵

图例：✅=支持/强 ｜ 🟡=部分/有条件 ｜ ❌=无 ｜ ？=未能验证。TunBox 粗判基于任务简报基线（鸿蒙 NEXT + mihomo 内核）。

| 维度 | Surge iOS 5.23 | Quantumult X 1.8.1 | Loon 3.5.2 | SFI 1.14.x | TunBox 粗判 |
|---|---|---|---|---|---|
| **A 订阅导入** | URL/文件/iCloud/Dropbox；不解析 Clash YAML，走 policy-path/模块 | URL+resource-parser JS 转换；三类远程资源订阅 | URL/文件/扫码+六类远程订阅+Sub-Store 解析器 | URL/二维码/.bpf 文件/ShareExt；仅 sing-box JSON，依赖外部转换 | ✅ 强项：mihomo 全协议直读+逐节点诊断，订阅兼容面最广 |
| **A2 托管/模块订阅** | 模块系统（参数化+远程自动更新）+ External Resources 管理（10MB/2MB 限额） | 无模块；rewrite/filter/server 三类 remote 片段 | 插件系统（input/select 参数） | 无（remote profile 仅整文件） | ❌ 最大缺口之一：无模块/插件生态位 |
| **B 协议广度** | SS(2022)/VMess/Trojan/HY2/TUIC/Snell/SSH/WG/AnyTLS/MASQUE/Ponte；**无 VLESS** | SS(2022+SSR)/VMess/VLESS/Trojan/AnyTLS/HTTP/SOCKS5；**无 HY2/TUIC/WG** | SS(2022)/VMess/VLESS/Trojan/HY2/WG/AnyTLS + JS Custom 节点；无 TUIC | **最全**：sing-box 全量（+Mieru/Naive/Tor/ECH…） | ≈SFI（mihomo 内核全协议），并列第一梯队 |
| **B2 协议细节** | Reality❌(无VLESS)；HY2/TUIC 端口跳跃✅；uot✅ | Reality✅(全 TLS 系)；uot sp.v1/v2✅；HY2 跳跃❌ | Reality✅；HY2 跳跃✅；uot✅；ShadowTLS v2/3✅ | 全量✅ | 随 mihomo：Reality/uot/HY2 跳跃齐 |
| **C 规则引擎** | 30+ 类型+RULE-SET 索引化（10 万条 ms 级）+逻辑规则+DNS 预匹配 | host/ip/ua/geoip/asn+接口绑定参数；无聚合规则集格式 | 全类型+逻辑规则+PROTOCOL+端口区间；域名优先匹配+LRU；10 万条 <5ms | route.rules+rule-set(.srs 二进制)+geosite/geoip | mihomo 规则面≈SFI；**App 级分流为四家 iOS 皆无的独有项** |
| **D DNS** | Fake-IP(198.18.0.0/15)+DoH/DoH3/DoQ/DoT+hijack+Host 映射+DNS Script | DoH/DoQ/DoH3（**无 DoT**）+per-domain 绑定+SSID 条件 DNS | UDP/DoH/DoQ/DoH3+回落+Host 映射+SSID 条件 DNS+每节点 server-dns | DoH/DoT/DoQ/H3+DNS 路由规则+fake-ip+per-server detour | ✅ 强项：DoT 全加密防泄露；缺 DoQ/DoH3 与 DNS 分流规则 GUI |
| **E TUN/NE 内存** | 45MB 告警阈值+资源 10MB/2MB 限额+VIF 2.5Gbps 优化 | 未文档化（改配置不重连） | 未文档化 | **开源实现**：OOMKiller 恒开+oom_memory_limit_mb 默认 50+睡眠 pause | 鸿蒙无 NE 50MB 硬限 → 结构性优势；可借鉴 OOMKiller 自救思路 |
| **E2 常驻/按需** | Always On（3.7.0+） | ？（未文档化） | ？（未文档化） | alwaysOn+OnDemand 规则完整（NEOnDemandRule/evaluateConnection）+wasOnDemandEnabled 互斥处理 | 待对标：需系统级常驻策略 |
| **F 脚本/重写/MitM** | **最强**：7 类脚本+JQ Body Rewrite+HTTP/2/WSS MitM+模块 | 6 类重写+jsonjq+http_backend 本地 API+event 任务 | 脚本 API 深（$config 控制）+插件参数化+复写先于规则 | **全无** | ❌ 最大缺口：无脚本/重写/MitM 体系 |
| **G 系统集成** | Widget/控制中心/快捷指令/URL Scheme 全 + Web Dashboard/HTTP API | URL scheme 仅资源导入（无开关）+快捷指令（社区） | **URL Scheme 最全**（开关+六类导入+模式切换） | ControlWidget(控制中心/锁屏/Action Button)+App Intents(带参数启动)+sing-box scheme | 有桌面卡片；建议补：控制中心类常驻入口+URL Scheme 导入 |
| **H 商业化** | $49.99 首购(1 年功能更新+终身用)+$14.99/年续 | $9.99 买断 | $7.99 买断 | 免费+GPL-3.0 | - |
| **I 核心痛点** | 内存天花板/无 VLESS/订阅格式封闭/贵 | 协议停更/无模块/文档缺失 | 无 TUIC/文档分散/生态弱 | 纯 JSON 门槛/无高级功能生态/OOM 断连 | 对标结论见下 |

### 给 TunBox 的差距要点（B2 结论）

1. **领先项**：订阅兼容（mihomo 全协议直读 vs 四家各自封闭格式）、App 级分流（iOS 四家全部做不到进程/App 级分流——Surge 官方明示 iOS 忽略 PROCESS 规则）、无 NE 内存硬限。
2. **必补项（按四家共性反推）**：DNS 层 REJECT 预匹配（Surge 5.14.0/QX/Loon 均有）、端口跳跃（HY2/TUIC）、TLS 指纹模拟（tls-profile）、Reality 全协议覆盖、按 SSID/网络条件的规则与 DNS 条件、节点失败自动切换阈值。
3. **生态位缺口（单点超越但可后置）**：模块/插件系统（Surge 模块 / Loon 插件的参数化订阅包）、脚本+重写+MitM 体系（Surge/QX/Loon 共有，SFI 也没有）、控制中心/锁屏常驻开关、`://import?` 类一键导入 URL Scheme。
