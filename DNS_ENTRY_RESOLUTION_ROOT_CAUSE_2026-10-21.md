# 入口域名解析：根因定案与三家客户端对照（2026-10-21）

> 症状：手机上测速全部超时，同一订阅在桌面 FlClash 正常。
> 结论：**不是订阅的问题，是「全局单值 DNS 字段 × 多订阅合并」的结构冲突。**
> 本篇同时记录：三个主流客户端的实现、为什么它们不会复发、TunBox 还剩下的复发路径、以及唯一能终结这一类的收口方案。

---

## 1. 根因：mihomo 的解析器选择是「全局单值 + 两套 policy 互不相通」

内核源码（`MetaCubeX/mihomo`，与 FlClash fork `chen08209/Clash.Meta` 在这些位置一致）：

| 语义 | 代码位置 |
|---|---|
| `proxy-server-nameserver` 解析入口 | `config/config.go:1450` |
| `proxy-server-nameserver-policy` 解析入口 | `config/config.go:1455` |
| 有 policy 但 `proxy-server-nameserver` 为空 → **直接拒载** | `config/config.go:1458` |
| 专用解析器只吃 `ProxyServerPolicy`，**不继承主解析器的 `policy`** | `dns/resolver.go:612-620` |
| 多个上游 → `batchExchange`：**并发、取最先成功的应答** | `dns/resolver.go:227` |
| anytls 未给 `sni` 时用 `server` 兜底当 SNI | `adapter/outbound/anytls.go:167-169` |

推出两条硬规则：

```
R1  proxy-server-nameserver 非空  →  所有代理服务器域名走专用解析器
                                    它只查 proxy-server-nameserver-policy
                                    nameserver-policy 被整体旁路
R2  proxy-server-nameserver 为空  →  退回主解析器
                                    nameserver-policy 生效
```

而这类机场的入口域名，公共 DNS 给的是**诱饵 IP**，真实 IP 只在订阅私有 DoH 里：

| 订阅 | 私有上游位置 | 公共 DNS 给的诱饵 |
|---|---|---|
| 筋斗云（anytls） | `dns.proxy-server-nameserver` → `ns1.pubdns.co/dns-hyy/<uuid>` | `172.64.153.74`（Cloudflare，18104 端口不通） |
| pronetwork 面板（本次） | `dns.nameserver-policy: +.jushuitan.com` → `bvd-api.dohcore.com:2096/dns-query/<uuid>` | `60.205.172.133`（阿里云 WAF，`yundunwaf4.com`，4430 可握手但不服务 anytls/hy2/tuic） |

`best.jushuitan.com` 公共解析链实测（`doh.pub` JSON）：

```
CNAME  yundunwaf4.com           TTL 600
A      60.205.172.133           TTL 300      ← 诱饵
```

同域私有 DoH 实测返回值（内核 debug 日志）：

```
9jp.jushuitan.com  → 95.85.94.57
15sg.jushuitan.com → 64.120.92.197 / 64.120.95.49 / 64.120.95.50
18jp.jushuitan.com → 160.16.134.241 / 153.121.33.174 / 153.121.36.207
31se.jushuitan.com → 185.186.78.65
```

**同一个根因的三种表现（不是三个 bug）：**

1. 全局 `proxy-server-nameserver` 被写成明文公共 DNS → R1 生效，只给 `nameserver-policy` 的订阅全灭。**← 本次**
2. 全局字段为空但订阅 `nameserver-policy` 被丢弃 → 退回公共 DNS → 诱饵 IP。**← 2026-10-20 已修**
3. `hosts:` pin 用公共 DoH 解析结果覆盖了 policy → `hosts` 是永久覆盖，私有 DoH 再也问不到。**← 本次同源路径**

---

## 2. 真机取证（`com.tunbox.client`，192.168.3.146）

运行配置：`/data/app/el2/100/base/com.tunbox.client/haps/entry/cache/mihomo_test_config.yaml`（108060 B，228 节点，多机场混排）

生成的 DNS 段（节选，逐字）：

```yaml
  proxy-server-nameserver:
    - "223.5.5.5"
    - "119.29.29.29"
    - "114.114.114.114"        # ← 明文 UDP，被打开成全局开关
  nameserver-policy:
    "+.jushuitan.com":
      - "https://bvd-api.dohcore.com:2096/dns-query/48cc6fb2-...#skip-cert-verify=true"
      - "https://bvd-api.cloudflare-lab.com:2096/dns-query/48cc6fb2-...#skip-cert-verify=true"   # ← 被 R1 旁路
```

`core.log` 对应证据：

```
[DNS] resolve 4tw.jushuitan.com A from udp://119.29.29.29:53
[DNS] cache hit best.jushuitan.com --> [60.205.172.133] A, expire at 2162-11-27 17:31:57
Health Checked ... alive: false, delay: 65535 ms
```

`expire at 2162` = 已落 `hosts:` 永久覆盖（第 3 种表现同时在生效，两条路一起坏）。

---

## 3. 单变量实验（同版内核 v1.19.32，Windows，跑真机那份配置）

只改一处，其余逐字不变：

| # | 改动 | jushuitan 节点 | 全节点 | 解析路径（debug 日志） |
|---|---|---|---|---|
| 1 | 原样 | **0/36** | 41/92 | `udp://114.114.114.114:53` |
| 2 | `proxy-server-nameserver` 置空 | — | 63/92 | 私有 DoH |
| 3 | 保留全局字段 + 补 `proxy-server-nameserver-policy` 镜像 | **22/36** | — | `https://bvd-api.dohcore.com:2096/...` |

桌面 FlClash 同订阅：**22/36**。数字完全对上 → 确认这是唯一差异，不是机场侧问题。

剩下 14 个是机场侧本身坏：`tw3/tw4/3tw`（HTTP404）、`香港01`、`日本18/19/9`、`韩国7`、`瑞典31`。

另记一条 UA 分流（同一 URL，不同 UA 拿到不同模板）：

```
clash-verge/v2.4.2                 → 36 节点
mihomo/v1.19.32                    → 36 节点（多 2 个字段）
ClashforWindows/0.19.23            →  4 节点
Clash Meta for Android/2.11.6.Meta →  0 节点（proxies: { }）
TunBox/1.0                         → 400 Unsupported client
```

TunBox `UA_CHAIN` 首位是 `clash-verge/v2.4.2`，当前无碍；但动这条链要避开 CMFA 那个 UA。

---

## 4. 三个主流客户端怎么做的

### 4.1 Clash Verge Rev（Rust + React）

- **不合并多订阅**：只取 `profiles.current` 一份，再叠它自己的 Merge / Script（`src-tauri/src/enhance/mod.rs:168-186`）。
- **订阅的 provider DNS 字段优先级最高**：

```rust
// src-tauri/src/config/dns.rs:19-23
const PROVIDER_DNS_FIELDS: [&str; 3] = [
    "proxy-server-nameserver",
    "proxy-server-nameserver-policy",
    "nameserver-policy",
];
```

`dns_override_source()`（`dns.rs:25-55`）把这三个字段的**非空**内容算成 sha256 摘要；只要订阅提供了其中任意一个，App 的 DNS 覆写就**自动关闭**并弹 `NoticeStatus::DnsOverrideAutoDisabled`（`dns.rs:143-146`），除非用户针对该份摘要显式确认过才允许覆盖。

它的单测里就写着 `https://doh.dohcore.com:2096/dns-query/#skip-cert-verify=true`（`dns.rs:170`）——同一个机场面板，同一个坑，Verge 靠「订阅优先 + 不合并」绕开。

### 4.2 Clash Meta for Android（Kotlin）

- **不合并多订阅**：单一 profile（`StatusClient.currentProfile()`）。
- **结构上碰不到这个字段**：`ConfigurationOverride` 全字段 `nullable`（`null` = 不动订阅值），而它的 `Dns` 子模型（`core/src/main/java/com/github/kr328/clash/core/model/ConfigurationOverride.kt:84-140`）只有：

```
enable / prefer-h3 / listen / ipv6 / use-hosts / enhanced-mode /
nameserver / fallback / default-nameserver / fake-ip-filter /
fake-ip-filter-mode / fallback-filter / nameserver-policy / geoip / ...
```

**没有 `proxy-server-nameserver`，也没有 `proxy-server-nameserver-policy`。** 订阅值原样透传，App 无从破坏。

### 4.3 FlClash（Dart + 自建 core）

- **不合并多订阅**：单一 `currentProfileId`。
- **订阅 DNS 原样透传**：

```dart
// lib/common/task.dart:283-299
final isEnableDns = rawDns['enable'] == true;
if (!isEnableDns) {                                  // 只有订阅没开 DNS 才注入 baseline
  rawDns = mergeDnsOverride(rawDns, baselineDns.overrideJson(baselineDnsOverrideKeys));
}
rawDns = mergeDnsOverride(rawDns, overrides.dns.overrideJson(overrides.dnsOverrideKeys, ...));
rawConfig['dns'] = rawDns;
```

`dnsOverrideKeys` 默认空集 ⇒ 一行都不改。它的 DNS 覆写 UI 只是"用户显式勾选才覆盖具体字段"。

### 4.4 对照表

| | 多订阅合并？ | provider DNS 归属 | 会不会踩 R1 |
|---|---|---|---|
| Clash Verge Rev | 否 | 订阅有该字段 → App 覆写自动让路 + 通知 | 不会 |
| Clash Meta for Android | 否 | 模型里没有该字段，无法覆写 | 不会 |
| FlClash | 否 | 订阅 dns 原样透传 | 不会 |
| **TunBox** | **是（228 节点混排）** | App 重写整个 dns 段，上游从**所有订阅并集** | **会** |

**三家共享的隐含前提：一份运行配置 = 一份订阅。** TunBox 为了多订阅同时用打破了这个前提，但 DNS 仍按"全局"处理 —— 这就是复发的土壤。

---

## 5. 已改（本次落地）

文件：`TunBox_HarmonyOS/entry/src/main/ets/commons/services/ClashConfigGenerator.ets`

1. **`pushDnsSection`：把入口域名策略镜像进 `proxy-server-nameserver-policy`**
   条件：`subDnsServers.length > 0 && policyOrder.length > 0`（内核要求二者同在，`config.go:1458`）。
   效果：全局字段非空时，专用解析器仍能按后缀走各自私有 DoH，不再被 R1 旁路。

2. **`generate()` 的 `hosts:` pin：被 policy 覆盖的入口域名不再 pin**
   用 `policyMatchesAny(pair[0], [host])` 判断，命中即 `continue`。
   理由：`hosts` 是永久覆盖（真机 `expire at 2162`），会把拨号锁死在公共 DoH 解出的诱饵 IP 上。

---

## 6. 残留复发路径（未堵，需拍板）

`SubscriptionService.subscriptionDnsProxyServers()`（`SubscriptionService.ets:2723`）把**所有启用订阅**的 `proxy-server-nameserver` 并成一个列表交给生成器。

结合 `dns/resolver.go:227` 的 `batchExchange`（并发取首个成功应答）：

```
订阅 A: proxy-server-nameserver = [https://私有 DoH]      (慢，但答案正确)
订阅 B: proxy-server-nameserver = [223.5.5.5]            (快，但答案是诱饵)
合并后: [私有 DoH, 223.5.5.5]  →  223.5.5.5 抢跑  →  A 的节点全灭
```

**所以：会。** 触发条件更苛刻（需两份订阅都提供该字段且互为公私），但根因未除。

---

## 7. 收口方案（唯一能终结这一类）

把 provider DNS 从「全局并集」改成「按订阅、按域名」：

### 7.1 数据契约

`subscriptionDnsProxyServers(): string[]` →

```ts
interface SubDnsUpstreams {
  subId: string;
  suffixes: string[];   // 该订阅节点域名的后缀（从 ProxyNode.server 推导，如 "+.jushuitan.com"）
  servers: string[];    // 该订阅自己的 proxy-server-nameserver（规范化后）
}
subscriptionDnsUpstreams(): SubDnsUpstreams[]
```

### 7.2 生成规则

1. 每个订阅：`suffixes × servers` → 写进 `proxy-server-nameserver-policy`
2. 已有 `nameserver-policy` 的订阅：同样镜像（本次已做的逻辑，改为按订阅取）
3. 全局 `proxy-server-nameserver`：**不再并集**，固定写中性默认（`tls://223.5.5.5:853`），或仅当无任何 policy 时写订阅值
4. 后缀冲突：同一后缀被两个订阅声明 → 先声明者优先 + `AppLogger.warn` 记账（避免静默覆盖）
5. 订阅未给任何上游 → 不写 policy，回落全局默认

### 7.3 边界

- 节点 server 是纯 IP → 不产生后缀（无需解析）
- 同一订阅多级域名（`best.jushuitan.com` / `1hk.jushuitan.com`）→ 收敛到最长公共后缀 `+.jushuitan.com`，条目数上限沿用现有 16 条
- `proxy-server-nameserver-policy` 存在时全局字段**必须非空**（`config.go:1458`），故第 3 步不能省

### 7.4 验证矩阵（改完必须全绿）

| 用例 | 期望 |
|---|---|
| 单订阅 + `nameserver-policy` | 根因日志走私有 DoH，节点数 = 桌面 FlClash |
| 单订阅 + `proxy-server-nameserver` | 同上 |
| 两订阅：一个 policy、一个 proxy-server-nameserver（公私混合） | 两份各自走对的上游，**无抢跑** |
| 两订阅同后缀不同上游 | 有 warn 日志，取先声明者 |
| 订阅无任何 DNS | 回落 DoT，配置可解析 |
| `hosts:` 与 policy 同时命中同域名 | 不产生 hosts 条目 |

判定口径：`core.log` 里不得出现 `resolve <入口域名> ... from udp://`；节点结果应与桌面 FlClash 同一订阅相差 ≤1（个别机场侧坏点除外）。

---

## 8. 收口已落地（2026-10-21）

### 8.1 改动清单

| 文件 | 改动 |
|---|---|
| `commons/models/SubDnsUpstream.ets`（新增） | `SubDnsUpstream{subId, servers}`（按订阅承载上游）+ `SubDnsUpstreamPolicy{suffix, servers}`（归一化结果） |
| `commons/services/SubscriptionService.ets` | `subscriptionDnsProxyServers(): string[]` → **`subscriptionDnsUpstreams(): SubDnsUpstream[]`**（按订阅分组，不再扁平并集） |
| `commons/services/ClashConfigGenerator.ets` | 新增 `normalizeDnsUpstreams()` / `entryDomainSuffix()` / `TWO_LABEL_SUFFIXES`；`pushDnsSection` 全局只写中性 DoT，订阅上游一律按后缀写进 `proxy-server-nameserver-policy`；`hosts:` pin 同时跳过被 upstream 策略覆盖的域名 |
| `commons/config/RuntimeConfigBuilder.ets` | 字段 `subscriptionDnsUpstreams: SubDnsUpstream[]` |
| `commons/services/ConnectionOrchestrator.ets` | 装配 `subs.subscriptionDnsUpstreams()` |
| `scripts/verify-config-generation-integrity.mjs` | 场景 14 重写为新契约，新增「A/B 两份订阅互不越界」断言 |
| `scripts/verify-vpn-architecture.mjs` | 形状断言更新；`dns.no-geosite-policy` 改锁 `lines.push(...geosite:)`（原 400 字窗口会被注释误红） |
| `tools/true-chain-harness/prepare.mjs` | 新增 `SubDnsUpstream.ts` 条目与两处 import 映射 |
| `scripts/latency-gen-fingerprint.json` | 指纹 `bc332ba43195a6cf` + 本次原因说明 |

### 8.2 语义（与三家客户端对齐）

```
全局 proxy-server-nameserver      = tls://223.5.5.5:853, tls://1.12.12.12:853   (恒为中性默认)
proxy-server-nameserver-policy:
  "+.jushuitan.com": [该订阅自己的私有 DoH]      ← 来自 A 订阅的 proxy-server-nameserver
  "+.example.net":   [该订阅自己的上游]          ← 来自 B 订阅
nameserver-policy:
  "+.jushuitan.com": [...]                      ← 保留（普通解析也用得上）
  "+.cn" / "+.com.cn" / ...                     ← 内置国内直连 DoT
```

即：**任何订阅的入口域名只用它自己的上游解析**，互不抢答；订阅没给上游的域名回落中性 DoT。
Verge 的「订阅优先」、CMFA 的「结构上碰不到该字段」、FlClash 的「原样透传」，在这套生成规则下等价成立。

### 8.3 后缀推导规则（`entryDomainSuffix`）

- 纯 IPv4 / IPv6 字面量 → 空（不需要解析）
- 两段域名 `example.com` → 精确域名（不产生 `+.com`）
- 三段及以上 `a.example.com` → `+.example.com`
- 双段公共后缀下 `a.b.com.cn` → `+.b.com.cn`
- 每订阅最多 16 个后缀、每后缀最多 4 个上游；同后缀被两订阅声明 → 先声明者优先 + `warn` 日志

### 8.4 验证结果

| 关卡 | 结果 |
|---|---|
| 真实内核单变量（设备原配置，jushuitan 36 节点） | 修复前 **0/36**（明文 UDP → 阿里 WAF 60.205.172.133）→ 补 `proxy-server-nameserver-policy` 后 **22/36**，与桌面 FlClash 一致 |
| `verify-config-generation-integrity.mjs` | 111 ✅ / 0 ❌（含新场景 14 的 16 条断言） |
| `verify-vpn-architecture.mjs` | 272 / 272 PASSED |
| `verify-generator-fingerprint.mjs` | 2 / 2 |
| ArkTS 真编译闸门（hvigor assembleHap） | 3 / 3，无 ArkTS 编译错误 |
| `test-latency-engine.js` | 35/47（12 项为引擎存量基线失败，与本次 DNS 改动无关） |

### 8.5 未做 / 需你拍板

- **明文 UDP 保底**：订阅若自己给明文 UDP 上游，仍按订阅意愿使用（本轮按你要求不动）。
  若要彻底消掉投毒面，可在 `normalizeNameserver` 里把裸 IP 上游降级为 `tls://<ip>:853`，或直接丢弃只信私有 DoH。
- **真机装机验证**：当前在 `main` 分支，签名配置为空（出 unsigned HAP）。
  要在真机复测需先 `switch-signing.ps1 -Mode debug` 再构建装机，或在 `test-debug-sign` 分支合入后构建。

