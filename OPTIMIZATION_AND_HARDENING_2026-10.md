# 2026-10 优化与加固（去广告默认关闭 / 启动提速 / DNS 防泄露 / 后台自愈）

> 本次会话的四项改动。每项都配了 `scripts/verify-vpn-architecture.mjs` 里的源码级不变量，
> 共新增 42 项断言（190 → 232），防止后续改动悄悄把结论推翻。

---

## 一、去广告规则默认关闭

**问题**：全局模式下打开华文应用商店会加载失败。去广告规则命中即 REJECT，而应用商店的
首页/详情页聚合接口常与广告域名共用同一 CDN 或同一证书，REJECT 会连带打断正常业务请求。

**改动**（`commons/models/AppSettings.ets`、`pages/RulesPage.ets`）：

| 位置 | 改动 |
|---|---|
| `AppSettingsJson.hyperAdRulesEnabled` | 默认 `true` → `false` |
| `AppSettings.hyperAdRulesEnabled` | 默认 `true` → `false` |
| `AppSettings.fromJson()` 兜底 | `... : true` → `... : false` |
| `RulesPage` `@State` 初值 | `true` → `false`，并改写说明文案 |

**老用户不受影响**：`fromJson` 只在字段**缺失**时取默认值。老用户显式存过的 `true`/`false`
原样恢复。

**附带收益**：`ConnectionOrchestrator.connect()` 现在把去广告开关计入 `ruleProviderReady`，
关闭时连后台的 MRS 规则集下载都省掉 —— 既不占启动后的带宽，也不产生无意义的 GitHub 访问。

---

## 二、连接路径提速

按收益排序，均为低风险改动。

### 1. DoH pin 结果跨进程落盘（最大单项）

`DoHResolver` 的缓存原本只是进程内 `Map`，应用每次被回收/冷启动都要重走一遍 DoH
（并发 16、预算 6s），而这段时间隧道还没建，用户全程没网 —— 这就是"每次连接都要多等几秒"。

- 新增 `SettingsService.loadDohPins()` / `saveDohPins()`（Preferences key `doh_pins_json`，
  格式 `Record<domain, "ip|ts">`，扁平字符串规避 ArkTS 严格模式的嵌套 JSON 反序列化）。
- 新鲜期 12h / 可用上限 7d。超出新鲜期仍采用（宁可 pin 旧 IP 也不回落明文 DNS），
  但登记进 `staleQueue`，连接前用 `refreshStale()` 在后台刷新（2s 节流落盘）。
- `resolveMany()` 新增第 3 参 `priorityDomains`：把**本次要连的节点**排在最前解析，
  预算再紧也先 pin 住它 —— 连不上当前节点的代价远高于漏 pin 几个备用节点。

**结果**：第二次起的连接这一步直接归零。

### 2. `dropReasonFor` 从三遍降到一遍

`ClashConfigGenerator.generate()` 里 `dropReasonFor` 被跑三遍（`countDroppedNodes` +
有效节点过滤 + `proxyYamlLine` 内部）。它是本文件最贵的纯 CPU 判定：每个节点分配一个
22 元素数组并对 22 个字段各跑 3 次 `.includes()`。现在整批算一次放进 `Map`，统计与过滤共用。

> 注意：不能缓存 `proxyYamlLine()` 的**结果**，因为 `ensureUniqueProxyNames()` 在两遍之间
> 会改 `n.name`。缓存判定（`dropReasonFor`）是安全的。

### 3. `sanitizeControlChars` 零分配快速路径

出口处对整份 150~250KB 配置调用，原实现是逐字符 `out += ...`，即十几万次单字符字符串拼接
（ArkTS 主线程上最贵的写法之一）。现在先做一遍**零分配**的 `charCodeAt` 扫描判断是否需要改写，
干净输入（绝大多数情况）直接原样返回。

### 4. 不再无条件白等 400ms

`stopVpnExtensionAbility` 之后固定等 400ms 等旧扩展进程退出。冷启动首连根本没有旧隧道，
这 400ms 纯属白付。改为仅在确有旧隧道（进程内状态或心跳租约）时才等。

> 实现坑：判据必须用**进入 connect() 之前捕获的状态**。此刻 `this.state` 已/即将被赋成
> `CONNECTING`，编译器会把它窄化成常量，直接比较会报
> `10505001: types have no overlap`。

### 5. `Model.bin` 的 9.3MB 同步读写挪出关键路径

`seedSmartModelFromRawfile()` 是 rawfile → cacheDir 的同步读+写，在**扩展拉起之前**、主线程上做，
而 manual（默认模式）根本不会用到 smart 组。现在只在 auto 模式下播种；
manual 下模型就绪交给后台下载保证，用户切到 auto 时即刻可用。

### 6. 其他

- `reservePorts()` 与 DoH 预解析**并行**（互不依赖，串行等于白等两段）。
- 去广告规则集的**关闭时探测**也已省掉（`isRuleProviderReady()` 的 statSync）。
- 拉起 epoch 轮询 250ms → 30ms（扩展把 `writeLaunchEpoch` 当 onCreate 第一条语句，
  原步长等于每次成功连接白付的上限）。

---

## 三、DNS 防泄露

**核心发现**（对着 `mihomo-build/` 里 vendored 的内核源码逐条核实，不是凭记忆）：

> `nameserver: 223.5.5.5 / 119.29.29.29` 是**明文 UDP/53**，且 `respect-rules` 未开。
> 于是用户访问的**每一个域名**都以明文 QNAME 走物理网卡发出去 —— 连 `fallback` 已经用
> 加密 DoT 答过的境外域名也一样，因为 `nameserver` 与 `fallback` 是**竞速**关系，明文包早已发出。

### 改动（`ClashConfigGenerator.ets` 的 `dns:` 段）

> ⚠️ **本节第一版写错了，5.8.0 上线后已修正。** 下面是修正后的最终形态，
> 理由见文末「5.8.0 线上回归」。**勿按第一版思路回改。**

```yaml
dns:
  nameserver:                                # 改：明文 UDP → 境内加密 DoT
    - tls://223.5.5.5:853                    # AliDNS  DoT
    - tls://1.12.12.12:853                   # DNSPod  DoT
  direct-nameserver:                         # 新增：DIRECT 域名同款境内 DoT
    - tls://223.5.5.5:853
    - tls://1.12.12.12:853
  direct-nameserver-follow-policy: false     # 新增
  fallback:                                  # 改：境外加密 DoT（仅非 CN 应答才采用）
    - tls://1.1.1.1:853
  nameserver-policy:                         # 新增：国内后缀显式钉境内 DoT
    "+.cn": [tls://223.5.5.5:853#DIRECT]
    # .com.cn / .net.cn / .org.cn / .gov.cn 同理
```

**核心原则：只加密，不改路由。** DNS 仍然**直连**（不走代理链），只是不再用明文 UDP。
这条是关键 —— 见下方回归分析。

**为什么这样是安全的（均已对 vendored 内核源码 + 真实网络核实）**：

- 不会死锁：所有上游都是**裸 IP**，不需要 `default-nameserver` 引导
  （用域名正是"解析 DoH 域名 → DoH 请求 → 又需要域名"的死锁，见坑 40）。
- 不会代理服务器域名成环：`proxy-server-nameserver` 以 `respectRules=false` 解析
  且永不套 fake-ip（`config/config.go:1485`）—— 防 fake-ip 拨假地址的关键，不可删。
- 不会直连分支成环：`direct-nameserver` 同样以 `respectRules=false` 解析（`:1496`），
  并由 `adapter/outbound/direct.go:53` 用于直连域名。
- 证书按 IP 校验可通过（Go 的 `tls.Config{ServerName: ip}` 需要 IP SAN，实测已有）：
  AliDNS 含 `IP SAN=223.5.5.5`，DNSPod 含 `IP SAN=1.12.12.12`，Cloudflare 含 `IP SAN=1.1.1.1`。
- `nameserver-policy` **刻意只用纯后缀、不用 `geosite:`** —— `geosite:` 会在
  `config.Parse` 阶段触发 `RC.NewGEOSITE` 同步下载，与坑 40 是同一个 90s 启动阻塞。

**保留的明文点（刻意取舍，不是不合格）**：

- `default-nameserver`：内核**要求**必须是裸 IP，只用于引导，业务解析不经过它。
- `proxy-server-nameserver`：刻意的明文**回环阻断器**。这些域名已在 UI 进程被 DoH
  预解析并写进 YAML `hosts:`，运行期几乎不会被真的问到；若改成 DoT，一旦端点抖动
  所有节点域名同时不可解析 = 全面断线，代价远大于理论泄露。

### 5.8.0 线上回归：全局模式下华为应用商店加载失败

**这是本项目自己的回归，由我引入，已修。**

第一版把 primary 设成**海外**解析器并打开了 `respect-rules: true`。两条叠加导致：

1. `respect-rules: true` 让 DNS 查询遵从分流规则；**全局模式下所有流量走 GLOBAL 代理**，
   于是连国内域名的 DNS 都被推到境外节点上问 —— 每个解析多一个代理往返，且 geo 错。
2. 国内 CDN 的调度依赖**境内解析器返回的境内边缘节点**。`appmarket.huawei.com`、
   `*.hicloud.com` 这些是 **`.com` 后缀**，不在我加的 `.cn` 策略覆盖范围内，
   于是被解析到境外边缘，应用商店自然加载不出来。

**实测数据（2026-10 国内网络，逐个 TCP + TLS 握手验签）**：

| 端点 | 结果 |
|---|---|
| `tls://223.5.5.5:853`（AliDNS DoT） | ✅ 可达，证书含 IP SAN=223.5.5.5 |
| `tls://1.12.12.12:853`（DNSPod DoT） | ✅ 可达，证书含 IP SAN=1.12.12.12 |
| `tls://1.1.1.1:853`（Cloudflare DoT） | ✅ 可达，证书含 IP SAN=1.1.1.1 |
| `https://1.1.1.1:443`（Cloudflare DoH） | ❌ TCP 超时 |
| `https://8.8.8.8:443`（Google DoH） | ❌ TCP 超时 |
| `8.8.8.8/8.8.4.4/9.9.9.9/149.112.112.112/208.67.222.222/64.6.64.6/185.228.168.9 :853` | ❌ 全部 TCP 超时 |

第一版写进 `nameserver` 的两个端点（`https://1.1.1.1/dns-query`、`https://8.8.8.8/dns-query`）
**在国内根本不可直连**，只有靠 `respect-rules` 走代理才连得上 —— 这正是把 DNS 推出境的原因。

**教训（已写进架构自检当闸门）**：
「防泄露」和「CDN geo 正确」是两个独立目标，**不要用同一个开关去追**。
正确的做法是**只加密传输层，不动解析路径的出口**。
另外「多写几个备用解析器」不等于冗余保险 —— 不可达条目会让每个境外域名解析
都多付一次连接超时。宁可单点但可达。

### 附带

- `fake-ip-filter` 从 7 条补到 20 条（localhost / STUN / NTP / 反向解析 / 门户探活）。
  给这些域名假 IP 会让它们退化成一次无意义的明文查询，同时破坏连通性探测。
- **`DoHResolver.refreshStale()` 刻意放在隧道建立之前**，不是连接成功之后。
  放到连接后就是"隧道已起、UI 进程却还在对 doh.pub 裸发查询"，等于在刚建好的
  防泄露链路上又开一个明文的洞。
- **`checkDnsResolvable()` 改为问系统解析器**（`connection.getAddressesByName`）。
  原实现是拿 `www.gstatic.com` 去 doh.pub 问一遍：通了只能证明公网 HTTPS 通，
  证明不了内核 DNS；不通则报 `fix-dns`，而那个修复动作本来就是空操作。
  改后隧道在时该查询走 `VpnConfig.dnsAddresses` → 被 TUN 接管 → `any:53` 劫持进内核，
  真正走的就是业务流量所走的那条 DNS 路径。

### 仍未解决（需要真机验证）

`VpnConfig.isIPv6Accepted: false` 究竟是"IPv6 被丢弃"还是"平台不再过问、IPv6 走物理网卡"，
无法从 SDK 头文件确认。若是后者，则本机没有 IPv6 路由，IPv6 会绕过隧道 ——
`VpnExtensionAbility` 里"杜绝 IPv6 泄漏通道"的注释目前**言过其实**。
可靠的 IPv6 开关只能是往 `VpnConfig` 里加一条 `::/0` 黑洞路由。**必须先真机验证再动。**

---

## 四、后台保活与自愈

**核心发现**：应用有能力*察觉*隧道已死（15s 跨进程心跳租约），但没有能力*处理*它 ——
唯一托管监控逻辑的进程一死就彻底没人管了。具体三个洞：

### 1. 用户意图只在连上之后才落盘

原来 `desiredConnected` 在 `state = CONNECTED` 之后才写。而建连过程有 30s 就绪窗口 + 系统授权
弹窗，这期间进程随时可能被回收 —— 一旦被杀，磁盘上仍是 `false`，冷启动无从判断
"用户本来是想连着的"。

**改动**：意图写入点前移到拉起之前（`connect()` 里 `advanceSessionIntent(true,'connecting',…)`），
成功后同代升格为 `connected`（`updateSessionSnapshot`）。**任何时刻被杀，磁盘上的意图都是诚实的。**

### 2. 断开回滚没有代次保护（本次新增的隐患，顺手补上）

前移写入点后会引出一个新问题：并发场景下旧连接的失败回滚会抹掉新连接刚写下的 `true`，
后台自愈就再也读不到"用户仍想连着"。新增 `clearSessionIntent(expectedGeneration)`：
代次不匹配就跳过写入，**但隧道拆除本身照常执行**（只保护"写意图"，不保护"拆隧道"）。

> 这套 `sessionGeneration` / `advanceSessionIntent` / `updateSessionSnapshot` 机制本来就是
> 为这件事写的，但此前**零调用点**（死代码）。本次接上，而不是重写一套。

### 3. 没人消费这份意图 / 守护者只会投降

- `EntryAbility.onCreate`（冷启动）与 `onForeground` 新增 `restoreKilledSession()`，
  按"意图还在 ∧ 相位合理 ∧ 隧道确实没了 ∧ 本进程无在途连接"五道闸门判断后自动重建隧道。
- `onBackground` 新增驻留凭证补engage（`UiGuardian.registered` 是进程级静态布尔，
  进程重启后必然为 false，而卡片路径没有页面，原先没人补这一环）。
- **守护者不再一丢了之**：`QuickToggleAbility` 原来在连续 2 次（≈30s）租约缺失后直接
  release + `terminateSelf()`。现在先看用户意图 —— 意图还在说明是"被杀后台"，
  于是走 `VpnQuickStart.run('start')` 自己爬起来重连（与用户手动点「启动代理」完全同款，
  自带单航班与卡片/通知同步，不会出现"自愈连上了但卡片还是断开"），
  退避重试 3 次用尽才交还系统。
- 有明确用户请求（快捷方式/卡片）时**跳过**自愈，否则会和 `VpnQuickStart` 的 toggle
  抢 `connectSeq`，把一次点击变成两次互相打断的建连。

### 4. 扩展进程恢复的 3 分钟悬崖

`VpnExtensionAbility` 在 `want.parameters` 被系统丢弃时，靠 cacheDir 的
`vpn_start_params.json` 回退，但那份文件只接受"≤3 分钟"。而"进程被回收 → OS 重新拉起
扩展"几乎必然超过 3 分钟 → 扩展硬拒绝恢复，隧道再也起不来（用户表现为"连着连着就断了，
之后再也没连上"）。

**改动**：UI 连接前把同一份三元组也写进 Preferences（与扩展进程同沙箱同库），
扩展新增第二级回退。三重校验缺一不可：① 持久化用户意图仍是"想连着"
② `configPath` 与本次解析出的路径逐字相等 ③ 三字段类型完整。
**仍然不猜任何默认值 —— 防泄漏红线不变。**

---

## 验证

```
hvigorw assembleHap (debug)          BUILD SUCCESSFUL
verify-vpn-architecture.mjs          232/232 通过（新增 42 项不变量）
verify-logic-pure.mjs                228/228
verify-mihomo-alignment.mjs          102/102
其余 verify-*                        与改动前基线一致
```

**基线说明**：以下 4 个脚本在**未改动的干净树上同样失败**，属既有问题（Windows CRLF 检出
导致源码断言字面量不匹配，以及 `verify-types.mjs` 用裸 `tsc` 解析不了 SDK 的 `.d.ets`），
与本次改动无关：

`verify-app-routing.mjs`、`verify-concurrent-refresh.mjs`、`verify-site-routing.mjs`、`verify-types.mjs`

**本次改动中踩到的坑**：

- 用编辑工具往源码里写 `\u0000` 这类转义序列时，`\uXXXX` 被当成真实字符写进文件，
  文件直接变成 binary、无法读取。必须避开 `\uXXXX`，改用**不含转义的等价写法**
  （如逐 `charCodeAt` 预扫描）。发现后用 PowerShell 正则把那行清掉才恢复。
- ArkTS 严格模式：`.catch((e) => ...)` 的参数隐式 `any` 会报 `10605008`，必须写
  `(e: Error): void`。
- `this.state` 在同一函数内被赋值后，编译器会窄化类型，后续比较报
  `10505001: types have no overlap`。需要用赋值前捕获的局部变量。
- 架构自检是**按字面量文本**断言的。把 `settings.autoSelectMode === AutoSelectModes.AUTO && smartReady`
  改写成经中间变量的等价形式，会让 `orch.smart.gated-by-auto` 这道闸门失效。
  已恢复字面量形式并在注释里写明原因。