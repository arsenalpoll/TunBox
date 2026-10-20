/**
 * Clash / Mihomo 配置生成器
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/clash_config_generator.dart
 *
 * 关键约束（与 upstream 行为一致）：
 * - IPv4-only：DNS 不解析 AAAA，ipv6: false
 * - external-controller 仅绑定 127.0.0.1，secret 由调用方注入
 * - TUN 通过 VpnExtensionAbility 的 fd 注入，配置仅声明 tun.enable
 * - 国内直连规则 + 强制代理站点规则
 */
import { ProxyNode, ProxyNodeType } from '../models/ProxyNode';
import { ProxyGroup } from '../models/ProxyGroup';
import { AppSettings, AutoSelectModes, CustomRuleSet } from '../models/AppSettings';
import { YamlMerger } from './YamlMerger';
import { AppLogger } from '../utils/AppLogger';
import {
  RawProviderEntry, RawProviderPlan, RawProviderStats, RawSubscriptionStore,
  RAW_PROVIDER_HEALTH_CHECK_ENABLED, RAW_PROVIDER_HEALTH_CHECK_INTERVAL,
  RAW_PROVIDER_HEALTH_CHECK_URL, RAW_PROVIDER_PATH_MODE
} from './RawSubscriptionStore';

const TAG = 'ClashConfigGenerator';

/** 节点无法写入内核配置的原因（判定顺序与 proxyYamlLine 完全一致） */
export enum ProxyDropReason {
  NONE = 'none',
  /** 协议不在白名单（ss/ssr/vless/vmess/trojan/hysteria2/中继协议之外） */
  UNSUPPORTED_PROTOCOL = 'unsupportedProtocol',
  /** 字段含换行/NUL/超长：写进 YAML 会破坏配置结构 */
  UNSAFE_TEXT = 'unsafeText',
  /** 缺 name/server 或协议级必需字段（如 vless 的 uuid、ss 的 cipher） */
  MISSING_FIELD = 'missingField',
  /** 缺的正是凭据字段（password/uuid）—— 典型为加密层未回填 */
  MISSING_CREDENTIAL = 'missingCredential',
  /** 端口 <=0 或 >65535 */
  INVALID_PORT = 'invalidPort'
}

/**
 * 「列表有、内核无」的显式账本：生成配置时被 proxyYamlLine 判定为不可写入的
 * 节点数与原因分类。调用方（服务层/UI）据此提示用户，禁止静默丢成空行。
 */
export class ProxyDropStats {
  total: number = 0;
  kept: number = 0;
  unsupportedProtocol: number = 0;
  unsafeText: number = 0;
  /** 缺必需字段（含缺凭据） */
  missingFields: number = 0;
  invalidPort: number = 0;
  /** missingFields 中因 password/uuid 为空导致的数量（凭据未回填信号） */
  missingCredential: number = 0;
  /** 被丢弃节点名示例（最多 3 个，便于定位） */
  samples: string = '';

  dropped(): number {
    return this.unsupportedProtocol + this.unsafeText + this.missingFields + this.invalidPort;
  }

  hasDrop(): boolean {
    return this.dropped() > 0;
  }

  /** 原因分类明细（始终列出四项，0 也显示，避免「看起来没丢」的误判） */
  reasons(): string {
    let text = `协议不支持 ${this.unsupportedProtocol}，文本不安全 ${this.unsafeText}`
      + `，缺必需字段 ${this.missingFields}`;
    if (this.missingCredential > 0) {
      text += `（其中凭据缺失 ${this.missingCredential}）`;
    }
    text += `，端口非法 ${this.invalidPort}`;
    if (this.samples.length > 0) {
      text += `；示例：${this.samples}`;
    }
    return text;
  }

  summary(): string {
    return `列表 ${this.total} 个节点，可写入内核 ${this.kept} 个，丢弃 ${this.dropped()} 个（${this.reasons()}）`;
  }
}

/**
 * rule-providers 块条目（**纯缩进层级**判定，见 ClashConfigGenerator.parseProviderBlocks）。
 *
 * 用**显式 class** 而不是 interface：ArkTS 禁止未标注类型的对象字面量
 * （arkts-no-untyped-obj-literals），跨文件构造这些结构必须用有类型的类；
 * interface 只在类型标注层面可用，无法 new 出来。
 */
export class ProviderBlockEntry {
  /** provider 名（键行冒号前的文本去引号、去首尾空白） */
  name: string = '';
  /** 归一后的键行：两空格缩进 + 原键行内容 */
  keyLine: string = '';
  /** 归一后的字段行：四空格缩进 + 原字段行内容 */
  fieldLines: string[] = [];
}

/** parseProviderBlocks 的返回值：解析出的 provider 块 + 结构异常的前置字段行 */
export class ProviderBlockParseResult {
  /** 按出现顺序的 provider 块 */
  blocks: ProviderBlockEntry[] = [];
  /** 出现在任何键行之前的字段行（结构异常，调用方需处理） */
  orphanLines: string[] = [];
}

/** YAML 顶层段（一个顶层键 + 其下所有更深缩进的行） */
export class YamlTopLevelBlock {
  /** 顶层键名（去引号）；空串 = 首个键行之前的前导内容（注释等） */
  key: string = '';
  /** 该段的全部原始行（含键行本身） */
  lines: string[] = [];
}

export class ClashConfigGenerator {
  /**
   * 内核 smart 组（自动选择）的固定组名。
   * 集成层要用它在 PROXY 里选中该组（connect 时不再把 PROXY 钉到具体节点）。
   */
  static readonly SMART_GROUP_NAME: string = '♻️ 自动选择';

  /**
   * smart 组的 `exclude-filter`：排除机场塞进 proxies 列表里的「信息条」伪节点。
   *
   * 真机实证（2026-09-20）：某机场把 `剩余流量：965.99 GB`、`套餐到期：长期有效`
   * 当成节点写进 proxies，它们与真实节点 `🇯🇵日本•移联01` 的
   * server/port/uuid/servername/reality-opts **完全一致**，是纯重复噪音。
   * 若不过滤，内核会拿它们参与 LightGBM 评分并可能选成出口 ——
   * 真机 `/connections` 的 chains[0] 确实出现过 `套餐到期：长期有效`。
   *
   * 内核侧 `GroupBase` 对**显式 proxies 列表同样应用** exclude-filter
   * （`groupbase.go:196`，在合并 provider 之后统一过滤），因此这里无需改可见节点列表：
   * 用户在「全部」里仍能看到并手动选这些条目，只是自动选点不会再用它们。
   *
   * 刻意保守：只匹配明确的信息条措辞，避免误伤真实节点名（真实节点名通常是
   * 「国家+编号」形式）。误伤的代价也必须可控 —— 它只影响自动选点的候选池，
   * 不影响手动选择。
   */
  static readonly SMART_INFO_NODE_FILTER: string =
    '(剩余流量|剩余|套餐到期|到期时间|到期|流量重置|距离下次|重置|官网|客服|订阅地址|更新订阅|Expire|Traffic|Reset|Website)';

  /** 最近一次生成的丢弃账本（UI/诊断可读取，即使调用方忽略返回值也不丢信息） */
  static lastDropStats: ProxyDropStats = new ProxyDropStats();
  /** 最近一次生成的「订阅/覆盖层规则跳过」计数（策略目标或 provider 未声明的行） */
  static lastSkippedUserRules: number = 0;
  /** 最近一次生成的「双轨 provider」账本（开关关闭时 enabled=false 且 emitted=0） */
  static lastProviderStats: RawProviderStats = new RawProviderStats();
  /** 丢弃告警回调：UI 侧注册后，连接/测速生成配置时的丢弃会以提示形式触达用户 */
  private static dropReporter: ((text: string) => void) | null = null;

  static setDropReporter(reporter: ((text: string) => void) | null): void {
    ClashConfigGenerator.dropReporter = reporter;
  }

  /** 记录并上报丢弃：日志必定写，UI 回调存在时同步提示 */
  static notifyDroppedNodes(stats: ProxyDropStats, stage: string): void {
    const text = `${stage}丢弃 ${stats.dropped()} / ${stats.total} 个节点：${stats.reasons()}`;
    AppLogger.warn(TAG, text);
    if (ClashConfigGenerator.dropReporter !== null) {
      ClashConfigGenerator.dropReporter(text);
    }
  }

  static generate(selectedNode: ProxyNode, allNodes: ProxyNode[], settings: AppSettings,
    mixedPort: number, apiPort: number, dnsPort: number, apiSecret: string, useGeoip: boolean = true,
    ipv6Enabled: boolean = false, proxyHosts: Record<string, string> = {},
    tunEnabled: boolean = true, proxyGroups: ProxyGroup[] = [],
    ruleProviderReady: boolean = true, useSmart: boolean = false,
    subscriptionRules: string[] = [], subscriptionRuleProviders: string = ''): string {
    const lines: string[] = [];

    lines.push('mixed-port: ' + mixedPort);
    lines.push('external-controller: 127.0.0.1:' + apiPort);
    lines.push('secret: "' + apiSecret + '"');
    // 代理模式（upstream settings.proxyMode）：rule=规则 / global=全局 / direct=直连
    lines.push('mode: ' + (settings.proxyMode === 'global' ? 'global' : (settings.proxyMode === 'direct' ? 'direct' : 'rule')));
    // 内核日志级别可调（诊断排查时临时调到 debug/info；默认 warning 减少稳态 I/O）。
    // 白名单外的值一律回落 warning，防止脏设置写出非法 YAML。
    const level = (settings.coreLogLevel ?? '').trim().toLowerCase();
    lines.push('log-level: ' + (level === 'debug' || level === 'info' || level === 'error'
      || level === 'silent' ? level : 'warning'));
    // 项目规格统一为 IPv4-only：同时关闭 mihomo 全局 IPv6 与 DNS AAAA，
    // 配合 VpnExtensionAbility 的 IPv4-only TUN，消除 IPv6 绕过及泄漏通道。
    lines.push('ipv6: false');
    lines.push('disable-ipv6: true');
    lines.push('unified-delay: true');
    lines.push('tcp-concurrent: true');
    // 长连接与会话复用参数：降低频繁握手、弱网切换后的僵尸连接和后台功耗。
    lines.push('keep-alive-idle: 30');
    lines.push('keep-alive-interval: 15');
    lines.push('udp-timeout: 300');
    // 【C22】该字段是 string（mihomo process.FindProcessMode）。裸写 off 在
    // YAML 1.1 语境下会被解析成 bool（内核用的是 YAML 1.2 解析器，裸 off 目前
    // 是 !!str，实测能过；加引号是为了消除语义歧义，与真实内核实测结论一致：
    // `find-process-mode: off` 与 `find-process-mode: "off"` 内核都接受）。
    lines.push('find-process-mode: "off"');
    lines.push('');
    lines.push('dns:');
    lines.push('  enable: true');
    lines.push(`  listen: 127.0.0.1:${dnsPort}`);
    lines.push('  ipv6: false');
    lines.push('  enhanced-mode: fake-ip');
    lines.push('  cache-algorithm: arc');
    lines.push('  fake-ip-range: 198.18.0.1/16');
    // DNS 上游必须用裸 IP(不走引导解析): 用域名会引发解析死锁 ——
    // 解析 DoH 域名 → DoH 请求 → 又需要域名 → 回环超时(真机 core.log 实证)。
    // 这里只承担"引导"职责(给需要按域名寻址的上游解析地址)，不承担业务解析。
    lines.push('  default-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    // ── 防泄露核心：业务解析全部走**加密**上游，且**不**强制走代理链 ──
    //
    // 【为什么业务解析必须加密】
    // 改前 nameserver 是 223.5.5.5/119.29.29.29 的明文 UDP/53。内核
    // config.Parse 时 respect-rules=false → dns_dialer 裸 dial，于是用户访问的
    // **每一个域名**都以明文 QNAME 走物理网卡发出去，连 fallback 已用加密 DoT
    // 答过的境外域名也一样（nameserver 与 fallback 竞速，明文包早已发出）。
    //
    // 【为什么 primary 必须是国内解析器，且绝不能开 respect-rules】
    // 这两条是 5.8.0 反馈「全局模式下华为应用商店加载失败」的根因，写死勿动：
    //  1) 国内 CDN 的调度依赖**境内解析器返回的境内边缘节点**。若把海外解析器
    //     设为 primary，appmarket.huawei.com / *.hicloud.com 这类**非 .cn 后缀**
    //     的国内服务会被解析到境外边缘，应用商店自然加载不出来。
    //  2) respect-rules: true 让 DNS 查询遵从分流规则；全局模式下所有流量走
    //     GLOBAL 代理，于是连国内域名的 DNS 都被推到境外节点上问 —— 又慢又 geo 错。
    // 正确做法是**只加密、不改路由**：DNS 仍然直连，只是不再用明文 UDP。
    //
    // 实测可达性与证书（2026-10 国内网络，本机逐个握手验签）：
    //   tls://223.5.5.5:853   AliDNS  DoT  证书含 IP SAN=223.5.5.5  ✅ 直连可达
    //   tls://1.12.12.12:853  DNSPod  DoT  证书含 IP SAN=1.12.12.12 ✅ 直连可达
    //   https://1.1.1.1:443   Cloudflare DoH ❌ TCP 超时（国内不可直连）
    //   https://8.8.8.8:443   Google    DoH ❌ TCP 超时（国内不可直连）
    // 所以 primary 一律用国内 DoT；境外解析器只作 fallback，且必须走 853（853 实测可达）。
    lines.push('  nameserver:');
    lines.push('    - tls://223.5.5.5:853');
    lines.push('    - tls://1.12.12.12:853');
    // DIRECT 命中的域名专用上游：内核按 respectRules=false 单独构造 DirectResolver，
    // 永远直连、永远不进 fake-ip，因此不存在"直连分支也走代理"的回环。
    lines.push('  direct-nameserver:');
    lines.push('    - tls://223.5.5.5:853');
    lines.push('    - tls://1.12.12.12:853');
    // direct-nameserver 不再套用下面的 nameserver-policy，避免策略把直连域名
    // 又拽回代理侧解析。
    lines.push('  direct-nameserver-follow-policy: false');
    // ── fallback 与 geoip.metadb 强绑定（坑 40）──
    // mihomo 的 `fallback` 一旦非空、且没有显式 `fallback-filter` 时，会套用默认
    // `fallback-filter: {geoip: true, geoip-code: CN}`，于是在 config.Parse 阶段就
    // 同步调用 RC.NewGEOIP → geodata.InitGeoIP() 去加载 MMDB。全新安装时
    // geoip.metadb 不存在，内核会**在启动路径里**联网下载（github.com，国内直连
    // 不可达），结果是启动静默阻塞到超时后直接
    // `load GeoIP dns fallback filter error, can't download MMDB` → 配置解析失败、
    // 内核永远起不来（真机 core.log 停在 "Can't find MMDB, start download"）。
    // 注意这条路与 GEOIP 规则无关：即使已经按 useGeoip 去掉了 GEOIP 规则，
    // 只要 fallback 还在，MMDB 依然会被加载 —— 所以 fallback 必须同受 useGeoip 约束。
    // 降级语义：未就绪就整块不声明（内核走 nameserver 单路解析），后台补齐
    // geoip.metadb 后下次连接自动恢复完整分流。
    //
    // fallback 只在「nameserver 的应答被判定为非 CN」时才采用（默认
    // fallback-filter: geoip/cn），所以境外域名仍能拿到境外解析，不会被国内解析器
    // 污染成假地址；国内域名走 primary，拿到的仍是境内边缘。
    // 端点只留 1.1.1.1:853 一个，**刻意不加冗余**：2026-10 国内网络实测，
    // 境外加密解析器里只有 Cloudflare 的 853 可直连（证书含 IP SAN=1.1.1.1）；
    // 8.8.8.8 / 8.8.4.4 / 9.9.9.9 / 149.112.112.112 / 208.67.222.222 /
    // 64.6.64.6 / 185.228.168.9 的 853 全部 TCP 超时，Cloudflare/Google 的
    // 443(DoH) 同样超时。写多个不可达条目不是"冗余保险"，而是让**每个境外域名
    // 解析都要多付一次连接超时**，反而拖慢首次打开。宁可单点但可达。
    if (useGeoip) {
      lines.push('  fallback:');
      lines.push('    - tls://1.1.1.1:853');
    }
    // fallback 与 nameserver 竞速（命中国内即返回，避免 fallback 拖慢国内解析）。
    lines.push('  strategy: prefer_ipv4');
    lines.push('  disable-cache: false');
    // 代理服务器域名的专用解析: 不走 fake-ip(否则内核拿 198.18.x.x 假地址拨号
    // 代理服务器, 全部 i/o timeout —— 真机 core.log 实证), 用真实 DNS 直出。
    // 内核以 respectRules=false 解析本项，且永不套 fake-ip，所以这是防
    // 「解析代理域名 → 又需要代理解析代理域名」回环的关键，**不可删**。
    //
    // ## 2026-10-19 稳定性：明文 UDP/53 → 加密 DoT（**必须与 pin 策略同源**）
    //
    // 旧注释的前提是「这些域名在 UI 进程已被 DoH 预解析并写进 YAML hosts:，
    // 运行期几乎不会被真的问到」，因此用明文 UDP 换取「DoT 抖动时仍可解析」的鲁棒性。
    // 但 0.4.0 起 DoHResolver 改成「短 TTL 记录一律不 pin」（机场入口域名 TTL 实测
    // 60~120s，见该文件头真机取证），于是这个前提**不再成立**：
    // 绝大多数节点域名不会被写进 hosts:，内核运行期**必须自己解析它们**，
    // 而明文 UDP/53 在国内网络会被投毒（实测：www.google.com 明文返回
    // 185.45.5.35，DoH 返回 142.251.155.119）→ 拨代理服务器打到假 IP →
    // 全部节点超时 → 「连上了但没有出口 / 公网 IP 查不到」。
    //
    // 所以这里改为与 `nameserver` 相同的**加密 DoT**（223.5.5.5 / 1.12.12.12，
    // 均实测直连可达且证书含 IP SAN）。两个端点互为冗余，单点抖动仍可解析；
    // 且 DoT 走 853/TCP，不经 UDP/53，不受投毒影响。
    // ⚠ 与 DoHResolver 的 pin 策略是**同一件事的两面**：如果将来恢复「短 TTL 也 pin」，
    //    这里才可以考虑退回明文（但没必要——加密只多几毫秒握手，且有缓存）。
    lines.push('  proxy-server-nameserver:');
    lines.push('    - tls://223.5.5.5:853');
    lines.push('    - tls://1.12.12.12:853');
    // ── 国内域名显式钉到国内加密 DoT ──
    // direct-nameserver 已覆盖 DIRECT 分支，这里再加一层是为了让意图可审计、
    // 且不依赖内核对 direct-nameserver 的适用面判断。
    // 刻意只用**纯后缀**，不用 `geosite:` —— geosite/geodata 会在 config.Parse
    // 阶段触发同步下载，正是坑 40 那个 90s 启动阻塞的同类。
    lines.push('  nameserver-policy:');
    lines.push('    "+.cn":');
    lines.push('      - tls://223.5.5.5:853#DIRECT');
    lines.push('    "+.com.cn":');
    lines.push('      - tls://223.5.5.5:853#DIRECT');
    lines.push('    "+.net.cn":');
    lines.push('      - tls://223.5.5.5:853#DIRECT');
    lines.push('    "+.org.cn":');
    lines.push('      - tls://223.5.5.5:853#DIRECT');
    lines.push('    "+.gov.cn":');
    lines.push('      - tls://223.5.5.5:853#DIRECT');
    // ── P0-3 DNS 层 REJECT 预匹配 ──
    // 强制拦截网站在 nameserver-policy 里直接拒绝（rcode://refused）：DNS 查询
    // 在解析层就拿到 NXDOMAIN/REFUSED，不建立 TCP 连接、不发出明文 QNAME、
    // 不进入 fake-ip —— 比仅路由层 REJECT 少一次完整连接尝试（省电省流量）。
    // mihomo nameserver-policy 值支持 rcode:// 协议（与 upstream 同位置解析）。
    const blockSites = ClashConfigGenerator.normalizeDomains(settings.forceBlockSites);
    for (const site of blockSites) {
      lines.push(`    "+.${site}": rcode://refused`);
    }
    // fake-ip 过滤：局域网/系统/直连目标不返回假 IP，避免误伤本地发现与测速。
    // STUN / NTP / 反向解析 / 门户探活这一类必须给真实地址：给假地址会让它们
    // 退化成一次无意义的明文 nameserver 查询，同时破坏连通性探测。
    lines.push('  fake-ip-filter:');
    lines.push('    - "*.lan"');
    lines.push('    - "*.local"');
    lines.push('    - "localhost"');
    lines.push('    - "*.localhost"');
    lines.push('    - "+.home.arpa"');
    lines.push('    - "*.msftconnecttest.com"');
    lines.push('    - "*.msftncsi.com"');
    lines.push('    - "+.captive.apple.com"');
    lines.push('    - "localhost.ptlogin2.qq.com"');
    lines.push('    - "+.market.xiaomi.com"');
    lines.push('    - "+.srv.nintendo.net"');
    lines.push('    - "stun.*.*"');
    lines.push('    - "+.stun.*.*"');
    lines.push('    - "stun.l.google.com"');
    lines.push('    - "+.pool.ntp.org"');
    lines.push('    - "time.*"');
    lines.push('    - "+.time.*"');
    lines.push('    - "+.arpa"');
    lines.push('    - "+.in-addr.arpa"');
    lines.push('    - "+.ip6.arpa"');
    lines.push('');
    // ── 域名嗅探（对齐 Clash Verge / FlClash 默认开启的 sniffer）──────────────
    // fake-ip 模式下内核拿到的目标地址是 198.18.x.x，DOMAIN 类规则依赖 DNS 映射反查；
    // TLS ClientHello SNI 与 DNS 记录不一致（CDN、直连 IP、QUIC）时必须靠嗅探还原
    // 真实域名才能正确命中 DOMAIN/GEOIP 规则。键位以本仓库内核源码 config.go 的
    // RawSniffer 为准：顶层 sniffer 键，sniff 为「协议名 → 配置」map（键必须是大写
    // 规范名 HTTP/TLS/QUIC，见 parseSniffer 的大小写匹配逻辑），空值 {} = 继承全局
    // override-destination；parse-pure-ip 让纯 IP 直连流量同样被嗅探。
    if (settings.sniffingEnabled !== false) {
      lines.push('sniffer:');
      lines.push('  enable: true');
      lines.push('  override-destination: true');
      lines.push('  parse-pure-ip: true');
      lines.push('  force-dns-mapping: true');
      lines.push('  sniff:');
      lines.push('    HTTP: {}');
      lines.push('    TLS: {}');
      lines.push('    QUIC: {}');
      lines.push('');
    }
    lines.push('profile:');
    // 连接复用：存储已选策略，减少重连后的重复握手与选点抖动。
    // 【C22】键名是 store-selected（mihomo RawConfig.Profile.StoreSelected），
    // 旧写法 store-selections 是**错键** → 内核不认 → 「记住选择」静默失效。
    lines.push('  store-selected: true');
    lines.push('  store-fake-ip: true');
    lines.push('');
    lines.push('tun:');
    // headless 测速模式: tun.enable=false, 内核只开 mixed/API 端口, 不建隧道不碰 VPN 权限
    lines.push('  enable: ' + (tunEnabled ? 'true' : 'false'));
    lines.push('  stack: gvisor');  // fd 注入 + 沙箱无 iptables, 只有 gvisor 可用
    // DNS 覆写(TUN 层): 所有目标端口 53 的 DNS 请求一律劫持进内核解析。
    lines.push('  dns-hijack:');
    lines.push('    - any:53');
    lines.push('  auto-route: false');   // 路由由 VpnExtensionAbility 安装（默认路由 = 系统级 Kill Switch）
    lines.push('  auto-detect-interface: false');
    // 说明：strict-route 依赖 nftables/iptables，OHOS gvisor+fd 注入沙箱不可用，
    // 故不启用；Kill Switch 由 Extension 的 IPv4-only 默认路由 + 内核存活监控保证。
    lines.push('  mtu: 1400');          // 缺省值；Extension 按物理承载改写并下发 VpnConfig.mtu
    lines.push('');
    // ── hosts: 代理服务器域名的防投毒固定解析(UI 进程 DoH 预解析结果) ──
    // 内核拨号代理服务器时直接命中这些真实 IP, 不再走运行期(可能被污染的)DNS。
    const normalizedHosts = new Map<string, string>();
    for (const rawHost of Object.keys(proxyHosts)) {
      const host = ClashConfigGenerator.normalizeDomain(rawHost);
      const address = proxyHosts[rawHost].trim();
      if (host.length === 0 || !ClashConfigGenerator.isValidIpAddress(address)) {
        continue;
      }
      normalizedHosts.set(host, address.toLowerCase());
    }
    if (normalizedHosts.size > 0) {
      lines.push('hosts:');
      for (const h of Array.from(normalizedHosts.keys()).sort()) {
        lines.push(`  "${ClashConfigGenerator.escapeYaml(h)}": "${ClashConfigGenerator.escapeYaml(normalizedHosts.get(h) ?? '')}"`);
      }
      lines.push('');
    }
    lines.push('proxies:');
    // 只从白名单结构化字段生成合法配置，任何协议均不透传 rawYaml。
    // 同时把不可写入的节点按原因计数（漏洞 A：此前 validNodes 过滤是静默的，
    // 列表显示 N 个而内核只有 0 个，界面无任何提示）。
    //
    // 性能：dropReasonFor 会为每个节点分配一个 22 元素数组并跑 22 次 isSafeText，
    // 是本文件里最贵的纯 CPU 判定。原先一次 generate() 里它被跑三遍
    // （countDroppedNodes + 过滤 + proxyYamlLine 内部），这里**只算一遍**
    // 并把结果同时供统计与过滤使用。
    const dropReasons: Map<ProxyNode, string> = new Map<ProxyNode, string>();
    for (const n of allNodes) {
      dropReasons.set(n, ClashConfigGenerator.dropReasonFor(n));
    }
    const dropStats = ClashConfigGenerator.countDroppedNodes(allNodes, dropReasons);
    ClashConfigGenerator.lastDropStats = dropStats;
    const validNodes: ProxyNode[] = [];
    for (const n of allNodes) {
      if (dropReasons.get(n) === ProxyDropReason.NONE) {
        validNodes.push(n);
      }
    }
    if (dropStats.hasDrop()) {
      // 存活数少于列表节点数：日志 + UI 回调（不阻止连接，但绝不静默）
      ClashConfigGenerator.notifyDroppedNodes(dropStats, '生成配置');
    }
    if (validNodes.length === 0) {
      // 零有效节点时生成空 proxies + 空组会让内核解析失败，直接抛出可读错误。
      // 错误文案必须带丢弃数量与原因，否则用户只看到「没有可用的节点配置」而无从下手。
      throw new Error(`没有可用的节点配置：${dropStats.summary()}。`
        + (dropStats.missingCredential > 0
          ? '其中多个节点缺少 password/uuid：本机加密存储未能回填凭据，请到「订阅」页刷新订阅后重连。'
          : '请到「订阅」页刷新订阅后重连。'));
    }
    // 全局代理名唯一化 —— **必须在写 proxies 之前**完成，因为：
    //   proxies[i].name、proxy-groups 的 proxies 成员、PROXY 组的内容全部按名字引用，
    //   只改其中一处会造成悬空引用（组里引用了一个不存在的名字）。
    // 一起改完，后续所有引用自然指向新名字。
    ClashConfigGenerator.ensureUniqueProxyNames(validNodes);
    // 用户在 UI 里选中的那个节点必须跟着改名，否则 PROXY 组首个成员会引用旧名字
    // （validNodes.includes 是对象身份比较，所以改名前取到的引用仍然有效）。
    for (const n of validNodes) {
      lines.push(ClashConfigGenerator.proxyYamlLine(n));
    }
    // ── 双轨（settings.useRawProviderConfig，默认关闭）────────────────────
    // 开关关闭：计划为空、不追加任何一行 → 输出与现状（HEAD）完全一致。
    // 开关开启：每个已落盘的订阅原文作为 `type: file` provider 交给内核自行解析，
    // 与 Mihomo/Clash Verge 对齐；文件缺失的 provider 绝不写入（避免 use: 悬空引用）。
    const providerPlan: RawProviderPlan = ClashConfigGenerator.planRawProviders(settings, allNodes);
    ClashConfigGenerator.lastProviderStats = providerPlan.stats;
    if (providerPlan.entries.length > 0) {
      lines.push('');
      lines.push('proxy-providers:');
      for (const entry of providerPlan.entries) {
        lines.push(`  "${ClashConfigGenerator.escapeYaml(entry.providerName)}":`);
        lines.push('    type: file');
        // path 语义见 RawSubscriptionStore 顶部注释：默认相对内核 HomeDir(=cacheDir)
        lines.push(`    path: "${ClashConfigGenerator.escapeYaml(entry.providerPath)}"`);
        if (RAW_PROVIDER_HEALTH_CHECK_ENABLED) {
          lines.push('    health-check:');
          lines.push('      enable: true');
          lines.push(`      url: "${RAW_PROVIDER_HEALTH_CHECK_URL}"`);
          lines.push(`      interval: ${RAW_PROVIDER_HEALTH_CHECK_INTERVAL}`);
        }
      }
    }
    const groupSelected: ProxyNode = validNodes.includes(selectedNode) ? selectedNode : validNodes[0];
    // ── YAML 覆盖层自定义 proxy-groups 聚合 ──────────────────────────────
    // 覆盖层里用户手写的 proxy-groups（如「落地选择」）此前被 validateYamlOverride
    // 连同整个覆盖层一起丢弃，订阅里引用它们的规则全部被 isValidUserRuleLine 判
    // 「目标组未声明」而跳过（真机 517 条规则只落下 34 条的根因）。这里把覆盖层组
    // 与订阅组合并后统一交给 planProxyGroups：名字冲突时覆盖层组优先（覆盖订阅组），
    // 订阅组的 health-check url/interval 等测速语义保真不受影响。
    const overrideGroupNames = new Set<string>();
    let overrideGroups: ProxyGroup[] = [];
    for (const og of overrideGroups) {
      overrideGroupNames.add(og.name);
    }
    const mergedGroups: ProxyGroup[] = [];
    for (const g of proxyGroups) {
      if (!overrideGroupNames.has(g.name)) {
        mergedGroups.push(g);
      }
    }
    for (const og of overrideGroups) {
      mergedGroups.push(og);
    }
    const emittedGroups = ClashConfigGenerator.planProxyGroups(mergedGroups, validNodes);
    const selections = ClashConfigGenerator.parseProxyGroupSelections(settings.proxyGroupSelections);
    // ── ♻️ 自动选择（内核 smart 组 / LightGBM）──────────────────────────────
    // 仅在「自动选择模式 + Model.bin 已就绪」时声明（见 isSmartModelReady）。
    // 必须满足三个前提，否则整块不写：
    //   1) useSmart：应用侧确认 Model.bin 已落盘。内核 GetModel() 在缺文件时会
    //      **同步联网下载**（github 直连不可达 → 实测阻塞 90s，然后软失败降级）。
    //      与坑 24/40 同源的启动期阻塞，必须在应用侧拦住。
    //   2) validNodes.length >= 2：只有一个节点时 smart 无意义，且会平白多一层跳转。
    //   3) 名称不与任何节点/PROXY 冲突（组名与节点名同名会造成引用二义性）。
    const SMART_GROUP_NAME = ClashConfigGenerator.SMART_GROUP_NAME;
    const emitSmart = useSmart && validNodes.length >= 2
      && !ClashConfigGenerator.usesName(validNodes, emittedGroups, SMART_GROUP_NAME);
    lines.push('');
    lines.push('proxy-groups:');
    lines.push('  - name: "PROXY"');
    lines.push('    type: select');
    lines.push('    proxies:');
    if (emitSmart) {
      // 自动模式下 PROXY 默认指向 smart 组：内核按每条连接的目标特征（ASN/GeoIP/
      // 端口/域名类型）在组内动态选点，而不是整条隧道钉死在一个节点上。
      const smartFirst = settings.autoSelectMode === AutoSelectModes.AUTO;
      lines.push(`      - "${smartFirst ? SMART_GROUP_NAME : ClashConfigGenerator.escapeYaml(groupSelected.name)}"`);
      if (!smartFirst) {
        lines.push(`      - "${SMART_GROUP_NAME}"`);
      }
    } else {
      lines.push(`      - "${ClashConfigGenerator.escapeYaml(groupSelected.name)}"`);
    }
    for (const group of emittedGroups) {
      lines.push(`      - "${ClashConfigGenerator.escapeYaml(group.name)}"`);
    }
    for (const n of validNodes) {
      if (n.id !== groupSelected.id) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(n.name)}"`);
      }
    }
    // 代理组通过 use: 引用原始订阅 provider：解析链节点 + provider 节点同时可用，
    // 任一路径失效都不会让「组内为空」导致内核启动失败（双轨过渡的核心保障）。
    if (providerPlan.entries.length > 0) {
      lines.push('    use:');
      for (const entry of providerPlan.entries) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(entry.providerName)}"`);
      }
    }
    for (const group of emittedGroups) {
      const members = group.members.slice();
      const selected = selections.get(ClashConfigGenerator.proxyGroupKey(group));
      if (selected !== undefined && members.includes(selected)) {
        members.splice(members.indexOf(selected), 1);
        members.unshift(selected);
      }
      lines.push(`  - name: "${ClashConfigGenerator.escapeYaml(group.name)}"`);
      lines.push(`    type: ${group.groupType}`);
      // 组测速参数保真：订阅声明的 url/interval/tolerance/expected-status 优先，
      // 未声明（或非法）回退内核默认口径（gstatic / 300s），行为与旧版一致。
      // select 组无测速语义；relay 链式中继不支持测速键，两者均不发射。
      if (group.groupType === 'url-test' || group.groupType === 'fallback'
        || group.groupType === 'load-balance') {
        lines.push(`    url: "${ClashConfigGenerator.safeGroupUrl(group.url)}"`);
        lines.push(`    interval: ${ClashConfigGenerator.clampGroupInterval(group.intervalSec)}`);
        if ((group.groupType === 'url-test' || group.groupType === 'load-balance')
          && group.toleranceMs > 0) {
          lines.push(`    tolerance: ${Math.min(Math.floor(group.toleranceMs), 60000)}`);
        }
        if (group.expectedStatus.length > 0
          && /^[0-9]{3}([ ]*,[ ]*[0-9]{3})*$/.test(group.expectedStatus.trim())) {
          lines.push(`    expected-status: "${ClashConfigGenerator.escapeYaml(group.expectedStatus.trim())}"`);
        }
        if (group.groupType === 'load-balance') {
          lines.push('    strategy: consistent-hashing');
        }
      }
      lines.push('    proxies:');
      for (const member of members) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(member)}"`);
      }
    }
    if (emitSmart) {
      // 内核 smart 组：LightGBM 综合评分（延迟 / 建连时间 / 成功率 / 历史吞吐 /
      // 丢包 / ASN / GeoIP / 端口 / 域名类型），按连接粒度选点。
      //   uselightgbm: true → 用学习模型；collectdata 仅在你愿意上传样本时才开，
      //     默认 false（本地隐私优先，且不影响本地推理）。
      //   prefer-asn 必须为 false：开启后 smart.go 会同步调 geodata.InitASN() 拉
      //     ASN.mmdb，实测 **90s 阻塞**（同 MMDB 坑），而设备上并没有 ASN.mmdb。
      //   url 用用户配置的测速地址，而不是内核默认的 gstatic —— 否则「测速设置」
      //     对自动选点不生效，两处延迟口径不一致（真机发现的遗漏）。
      lines.push(`  - name: "${SMART_GROUP_NAME}"`);
      lines.push('    type: smart');
      lines.push('    uselightgbm: true');
      lines.push('    collectdata: false');
      lines.push('    prefer-asn: false');
      const smartUrl: string = (settings.testLatencyUrl ?? '').trim();
      if (smartUrl.length > 0) {
        lines.push(`    url: "${ClashConfigGenerator.escapeYaml(smartUrl)}"`);
      }
      // 机场常把「剩余流量/套餐到期」这类**信息条**塞进 proxies 列表，它们和真实节点
      // 共用同一个 server/uuid（真机实证：4 条信息条与 🇯🇵日本•移联01 端点完全相同），
      // 纯属重复噪音。不排除的话内核会把它们当真节点参与评分，甚至选成出口 ——
      // 真机 /connections 里就出现过 chains[0] = "套餐到期：长期有效"。
      // 交给内核自己的 exclude-filter 过滤（GroupBase 对显式 proxies 同样生效），
      // 不改可见节点列表，用户仍可在「全部」里看到并手动选它们。
      lines.push(`    exclude-filter: "${ClashConfigGenerator.SMART_INFO_NODE_FILTER}"`);
      // fork 独有：policy-priority 是**高于** LightGBM 评分的排序键（因子不同则按因子
      // 降序，分数再高也翻不过来）。默认不写该键 = 完全交给模型评分。
      const priority: string = (settings.smartPolicyPriority ?? '').trim();
      if (priority.length > 0) {
        lines.push(`    policy-priority: "${ClashConfigGenerator.escapeYaml(priority)}"`);
      }
      lines.push('    proxies:');
      for (const n of validNodes) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(n.name)}"`);
      }
    }
    // ── YAML 覆盖层的 rules/rule-providers 预解析 ─────────────────────────
    // 【2026-10-20 认知纠正】mihomo 用 go.yaml.in/yaml/v3，**uniqueKeys 默认开启**：
    // 同一层级的重复键是 **TypeError → 整份配置拒载**（全有全无），
    // **不是**「后者覆盖前者」（旧注释写的正是后者，是错的，也是 R2/R4/R5 的认知根源）。
    // 所以这里把覆盖层的 rules/rule-providers 段**提取**出来，按键合并进上方已生成的
    // 同段（见下方规则发射）；其余顶层键走 C17 的「允许覆盖 + 结构化合并」
    // （同名则删掉生成器那一整段，绝不再出现两个同名顶层键）。
    let overrideBody = '';
    let overrideRuleLines: string[] = [];
    let overrideProviderLines: string[] = [];
    const override = (settings.yamlOverride ?? '').trim();
    if (override.length > 0 && ClashConfigGenerator.validateYamlOverride(override)) {
      try {
        const orules = YamlMerger.extractSection(override, 'rules').trim();
        if (orules.length > 0) {
          for (const line of orules.split('\n')) {
            const t = line.trim();
            if (t.length === 0 || t.startsWith('#') || !t.startsWith('- ')) {
              continue;
            }
            overrideRuleLines.push(t.substring(2).trim());
          }
        }
        const oprovs = YamlMerger.extractSection(override, 'rule-providers').trim();
        if (oprovs.length > 0) {
          for (const line of oprovs.split('\n')) {
            const t = line.trim();
            if (t.length === 0 || t.startsWith('#')) {
              continue;
            }
            overrideProviderLines.push(line);
          }
        }
        // 覆盖层自定义 proxy-groups（如「落地选择」）同样预解析为组对象，
        // 与订阅组合并后统一交给 planProxyGroups（见下方组聚合）。
        const ogroups = YamlMerger.extractSection(override, 'proxy-groups').trim();
        if (ogroups.length > 0) {
          overrideGroups = ClashConfigGenerator.parseOverrideProxyGroups(ogroups);
        }
      } catch (e) {
        // 覆盖层 rules/rule-providers/proxy-groups 解析失败按「未携带」处理，原文仍追加（旧语义）
        overrideGroups = [];
      }
      overrideBody = (overrideRuleLines.length > 0 || overrideProviderLines.length > 0
        || overrideGroups.length > 0)
        ? YamlMerger.removeSection(YamlMerger.removeSection(
          YamlMerger.removeSection(override, 'rules'), 'rule-providers'), 'proxy-groups').trim()
        : override;
    }
    // ── rule-providers 声明段（单一合并段）────────────────────────────
    // 真机实证 2026-10-16：多个 rule-providers: 顶层键（hyper/自定义/订阅/覆盖层各发
    // 一个头）会让 yaml.v3 报重复键拒载；订阅 provider 块原样回写在缩进不规范时
    // 报「did not find expected key」。所以这里统一收集、按键去重、逐条重缩进，
    // 最后只发一个 rule-providers: 头。
    //
    // 【2026-10-20 C16/C19/C20】三处修复合并落地：
    // ① 块边界改为「纯缩进层级」判定（parseProviderBlocks）—— 旧实现用
    //    /^([A-Za-z0-9_-]+):\s*$/ 认键行，点号名（my.provider:）不被认成键行
    //    → 键行消失、字段行变成 rule-providers 的兄弟键 → 内核报
    //    cannot unmarshal !!null/!!str into map[string]interface {}（R1），
    //    且引用它的 RULE-SET 规则被静默丢弃（比拒载更隐蔽）。
    // ② 去重改为**整块丢弃**（绝不只丢键行）—— 只丢键行会让字段行落进上一条
    //    provider 的 mapping → mapping key "type" already defined（R4）；
    //    字段键名与上一条不同时**不报错、静默并错 provider**（R4'''，更隐蔽）。
    // ③ 两个集合严格分离：
    //    declaredProviderNames = 引用校验账本（RULE-SET 引用必须落在已声明 provider 上）
    //    emittedProviderKeys    = 输出去重判定（已实际输出的块名）
    //    旧实现两者合一且**预置**了自产的 rs-*/hyper-adrules → 自己刚生成的块
    //    被自己判成重复块丢掉（R4'：键行被丢、字段行成孤儿）。
    const providerCandidates: ProviderBlockEntry[] = [];
    // ① hyper-adrules（自产）：优先级最高（与旧实现「预置账本」的语义一致 ——
    //    订阅里同名 provider 被丢弃，不会两个 provider 抢同一个名字）。
    //    声明与下方 RULE-SET 引用同受「本地 path 文件就绪」闸门约束：
    //    ruleProviderReady=false 时不声明、不引用，避免内核启动期联网下载阻塞。
    if (settings.rulesEnabled && settings.hyperAdRulesEnabled && ruleProviderReady) {
      const hyperBlock = new ProviderBlockEntry();
      hyperBlock.name = 'hyper-adrules';
      hyperBlock.keyLine = '  hyper-adrules:';
      hyperBlock.fieldLines = [
        '    type: http',
        '    behavior: domain',
        '    format: mrs',
        '    interval: 86400',
        '    path: ./ruleset/hyper_adrules_ads.mrs',
        '    url: "https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs"',
      ];
      providerCandidates.push(hyperBlock);
    }
    // ② 用户自定义远程规则集（rs-*）：同样优先于订阅/覆盖层的同名块
    if (settings.rulesEnabled && settings.customRuleSets.length > 0) {
      for (const ruleSet of settings.customRuleSets) {
        const block = new ProviderBlockEntry();
        block.name = `rs-${ruleSet.name}`;
        block.keyLine = `  rs-${ruleSet.name}:`;
        block.fieldLines = [
          '    type: http',
          `    behavior: ${ruleSet.behavior}`,
          `    format: ${ruleSet.format}`,
          `    interval: ${ruleSet.interval}`,
          `    path: ./ruleset/custom_rs_${ClashConfigGenerator.sanitizeFileKey(ruleSet.name)}`,
          `    url: "${ClashConfigGenerator.escapeYaml(ruleSet.url)}"`,
        ];
        providerCandidates.push(block);
      }
    }
    // ③ 订阅带来的 provider 块
    if (settings.rulesEnabled && subscriptionRuleProviders.length > 0) {
      const parsed = ClashConfigGenerator.parseProviderBlocks(subscriptionRuleProviders.split('\n'));
      if (parsed.orphanLines.length > 0) {
        AppLogger.warn(TAG, `subscription rule-providers: ${parsed.orphanLines.length} orphan line(s) `
          + 'before any provider key (dropped)');
      }
      for (const block of parsed.blocks) {
        providerCandidates.push(block);
      }
    }
    // ④ 覆盖层 provider 块
    if (overrideProviderLines.length > 0) {
      const parsed = ClashConfigGenerator.parseProviderBlocks(overrideProviderLines);
      if (parsed.orphanLines.length > 0) {
        AppLogger.warn(TAG, `override rule-providers: ${parsed.orphanLines.length} orphan line(s) `
          + 'before any provider key (dropped)');
      }
      for (const block of parsed.blocks) {
        providerCandidates.push(block);
      }
    }
    // 整块去重（先到先得）：命中重复名 → **整块丢弃**（键行 + 全部字段行一起丢）
    const emittedProviderKeys = new Set<string>();
    const declaredProviderNames = new Set<string>();
    const finalProviderLines: string[] = [];
    for (const block of providerCandidates) {
      if (emittedProviderKeys.has(block.name)) {
        AppLogger.warn(TAG, `duplicate rule-provider "${block.name}" dropped (whole block)`);
        continue;
      }
      emittedProviderKeys.add(block.name);
      declaredProviderNames.add(block.name);
      finalProviderLines.push(block.keyLine);
      for (const field of block.fieldLines) {
        finalProviderLines.push(field);
      }
    }
    if (finalProviderLines.length > 0) {
      lines.push('');
      lines.push('rule-providers:');
      for (const pl of finalProviderLines) {
        lines.push(pl);
      }
    }
    lines.push('');
    lines.push('rules:');
    if (settings.rulesEnabled && settings.hyperAdRulesEnabled && ruleProviderReady) {
      lines.push('  - RULE-SET,hyper-adrules,REJECT');
    }
    // 用户自定义远程规则集（P1-2）：与 hyper-adrules 同策略——provider 声明放 rule-providers
    // 段，规则引用放在自定义单条规则之前（RULE-SET 精确度高于逐条扫描，mihomo 按序匹配）。
    if (settings.rulesEnabled) {
      for (const ruleSet of settings.customRuleSets) {
        lines.push(`  - RULE-SET,rs-${ruleSet.name},${ruleSet.policy}`);
      }
      for (const customRule of ClashConfigGenerator.normalizeCustomRules(settings.customRules)) {
        lines.push(`  - ${customRule}`);
      }
      // ── 订阅自带 rules（导入订阅时落账）──────────────────────────────
      // 策略目标必须是**实际写进 proxy-groups 段的组**或内置策略；RULE-SET 必须引用
      // 已声明的 provider。不合法的行跳过并计数（静态账本 lastSkippedUserRules），
      // 绝不整份拒载。
      //
      // ⚠ 2026-10-19 真机报障修复：这里原先遍历的是 mergedGroups（**过滤前**），
      // 而 proxy-groups 段实际由 emittedGroups（planProxyGroups 过滤后）写出。
      // 二者不等价 —— planProxyGroups 会丢弃「类型不支持 / 与节点同名 / 空成员 /
      // 循环引用无法落地」的组。于是订阅里被丢弃的组仍被当作合法目标，引用它的规则
      // 照常写入，内核 config.Parse 直接报
      //   parse config:rules[0] [DOMAIN-SUFFIX,local, 本地直连] error: proxy not found
      // 整份配置拒载 → 启动代理失败（用户报障原文）。必须用 emittedGroups。
      const groupTargets = new Set<string>(['DIRECT', 'PROXY', 'REJECT', 'REJECT-DROP',
        'PASS', 'GLOBAL', 'COMPATIBLE']);
      for (const g of emittedGroups) {
        groupTargets.add(g.name);
      }
      // ♻️ 自动选择组只在 emitSmart 为真时才真正声明（见上方 proxy-groups 段），
      // 未声明就不能算合法目标，否则同理会写出指向不存在组的规则。
      if (emitSmart) {
        groupTargets.add(ClashConfigGenerator.SMART_GROUP_NAME);
      }
      let skippedUserRules = 0;
      // GEOIP 规则依赖 geoip.metadb（坑 40 同源）：metadb 缺失/损坏时内核会在
      // config.Parse 阶段同步联网下载 MMDB（国内不可达）→ 启动卡死超时。
      // 内置 GEOIP 已按 useGeoip 降级；订阅/覆盖层自带的 GEOIP 规则必须同闸门，
      // 否则一条订阅规则就能把启动重新拖死。metadb 后台补齐后下次连接恢复。
      for (const rawRule of subscriptionRules) {
        // 【C21】入口自己剥离行首 '- '（不依赖调用方）：rules 段的每一项必须是
        // **纯字符串**，写成 '- - RULE' 会变成嵌套 seq → 内核报
        // cannot unmarshal !!seq into string 整份拒载（R6）。
        const ruleLine = ClashConfigGenerator.stripRuleListPrefix(rawRule);
        if (ruleLine.length === 0) {
          skippedUserRules = skippedUserRules + 1;
          continue;
        }
        if (!useGeoip && ruleLine.toUpperCase().startsWith('GEOIP,')) {
          skippedUserRules = skippedUserRules + 1;
          continue;
        }
        if (ClashConfigGenerator.isValidUserRuleLine(ruleLine, declaredProviderNames, groupTargets)) {
          const normalized = ClashConfigGenerator.normalizeRuleLine(ruleLine);
          if (normalized.length === 0) {
            skippedUserRules = skippedUserRules + 1;
            continue;
          }
          lines.push(`  - ${normalized}`);
        } else {
          skippedUserRules = skippedUserRules + 1;
        }
      }
      // ── YAML 覆盖层的 rules（同段合并，与订阅规则共存而不是整段替换）──
      for (const rawRule of overrideRuleLines) {
        const ruleLine = ClashConfigGenerator.stripRuleListPrefix(rawRule);
        if (ruleLine.length === 0) {
          skippedUserRules = skippedUserRules + 1;
          continue;
        }
        if (!useGeoip && ruleLine.toUpperCase().startsWith('GEOIP,')) {
          skippedUserRules = skippedUserRules + 1;
          continue;
        }
        if (ClashConfigGenerator.isValidUserRuleLine(ruleLine, declaredProviderNames, groupTargets)) {
          const normalized = ClashConfigGenerator.normalizeRuleLine(ruleLine);
          if (normalized.length === 0) {
            skippedUserRules = skippedUserRules + 1;
            continue;
          }
          lines.push(`  - ${normalized}`);
        } else {
          skippedUserRules = skippedUserRules + 1;
        }
      }
      ClashConfigGenerator.lastSkippedUserRules = skippedUserRules;
      if (skippedUserRules > 0) {
        AppLogger.warn(TAG, `skipped ${skippedUserRules} user rule line(s) `
          + '(policy target or rule provider not declared)');
      }
    }
    // 强制站点规则统一做域名规范化、格式验证和去重，避免规则/YAML 注入。
    const directSites = ClashConfigGenerator.normalizeDomains(settings.forceDirectSites);
    const proxySites = ClashConfigGenerator.normalizeDomains(settings.forceProxySites);
    for (const site of directSites) {
      lines.push(`  - DOMAIN-SUFFIX,${site},DIRECT`);
    }
    for (const site of proxySites) {
      // DIRECT 优先，避免同一域名生成互相冲突的规则。
      if (!directSites.includes(site)) {
        lines.push(`  - DOMAIN-SUFFIX,${site},PROXY`);
      }
    }
    // P0-3 路由层兜底：SNI 嗅探/纯 IP 直连等不经过 DNS 解析的路径仍可能到达
    // 被拦截域名（fake-ip 被绕过时），这里再拦一次。与 DNS 层条目同源
    // （settings.forceBlockSites），DIRECT 域名优先级更高（不生成冲突规则）。
    for (const site of blockSites) {
      if (!directSites.includes(site)) {
        lines.push(`  - DOMAIN-SUFFIX,${site},REJECT`);
      }
    }
    // 国内直连：GEOIP 需要 geoip.metadb（内核 home 目录）; 缺失时降级跳过,
    // 否则 config.Parse 阶段就会联网下载 MMDB, 国内网络不可达直接导致启动失败。
    // DOMAIN-SUFFIX,cn 直连不受影响, MMDB 由编排器后台补齐后下次连接生效。
    if (useGeoip) {
      lines.push('  - GEOIP,CN,DIRECT');
    }
    lines.push('  - DOMAIN-SUFFIX,cn,DIRECT');
    // 兜底规则: 上面的国内规则已放行国内流量, 剩余(YouTube/Google 等国外站点)
    // 必须走代理。此前 bypassDomesticApps=true 会生成 MATCH,DIRECT, 导致
    // 国外流量也直连、无法访问被墙站点(真机 core.log: youtube:443 using DIRECT)。
    // bypassDomesticApps 的语义收敛为"国内直连分流是否启用"(见上方 GEOIP/cn 规则),
    // 不再影响兜底 —— 兜底永远是 PROXY, 否则 VPN 没有意义。
    lines.push('  - MATCH,PROXY');
    // ── YAML 覆盖层合并（C17 + C18）──────────────────────────────────
    // 【2026-10-20 认知纠正】mihomo 用 go.yaml.in/yaml/v3（uniqueKeys **默认开启**）：
    // 同一层级的重复键 = TypeError = **整份配置拒载**（全有全无，一个节点坏整个
    // VPN 起不来），**不是**「后者覆盖前者」。旧实现把覆盖层原文整段追加在配置
    // 尾部 → 与生成器自己的 dns:/mode:/profile:/mixed-port:/log-level:/ipv6:/
    // sniffer:/hosts: 等顶层键重复 → mapping key "dns" already defined（R2）。
    //
    // 新实现（产品口径：**允许覆盖 + 结构化合并**，用户能力不丢）：
    //   ① 覆盖层顶层键与生成器顶层键同名 → **删掉生成器那一整段**，改用覆盖层版本；
    //   ② 覆盖层自身的重复顶层键去重（保留首个）——否则照样整份拒载；
    //   ③ 未知顶层键 → **保留**并 AppLogger.warn 记录键名（绝不静默删除）；
    //   ④ 合并后再做布尔值归一（C18，路径感知，只改已知 bool 字段）。
    // rules / rule-providers / proxy-groups 三段已在前面按「提取合并」路径处理，
    // 不再出现在覆盖层正文里（提取失败时才会原样保留，此时同样走「同名删生成段」）。
    if (overrideBody.length > 0) {
      const overrideBlocks = ClashConfigGenerator.splitTopLevelBlocks(overrideBody.split('\n'));
      const overrideKeys = new Set<string>();
      const mergedOverrideLines: string[] = [];
      let droppedOverrideDup = 0;
      for (const block of overrideBlocks) {
        if (block.key.length === 0) {
          // 首个键行之前的前导内容（注释/空行）：原样保留
          for (const l of block.lines) {
            mergedOverrideLines.push(l);
          }
          continue;
        }
        if (overrideKeys.has(block.key)) {
          // 覆盖层自身重复顶层键 → 保留首个，其余整段丢弃（否则整份拒载）
          droppedOverrideDup = droppedOverrideDup + 1;
          continue;
        }
        if (!ClashConfigGenerator.blockHasContent(block)) {
          // 空段（只有键行 + 注释/空行）→ 整段跳过：
          // 既不删生成器的同名段（否则生成器内容被抹掉），也不原样追加
          // （否则多出一个空的同名顶层键 → 重复键 → 整份拒载）。
          AppLogger.warn(TAG, `yaml override: empty top-level key "${block.key}" ignored`);
          continue;
        }
        overrideKeys.add(block.key);
        for (const l of block.lines) {
          mergedOverrideLines.push(l);
        }
        if (!ClashConfigGenerator.KNOWN_TOP_LEVEL_KEYS.has(block.key)) {
          AppLogger.warn(TAG, `yaml override: unknown top-level key "${block.key}" kept as-is`);
        }
      }
      if (droppedOverrideDup > 0) {
        AppLogger.warn(TAG, `yaml override: ${droppedOverrideDup} duplicate top-level key(s) dropped (first wins)`);
      }
      // ① 生成器同名顶层段整段删除 → 改用覆盖层版本
      const keptLines = ClashConfigGenerator.stripTopLevelBlocks(lines, overrideKeys);
      lines.length = 0;
      for (const l of keptLines) {
        lines.push(l);
      }
      // ④ 布尔归一（路径感知；只改白名单里的已知 bool 字段）
      const normalizedOverride = ClashConfigGenerator.normalizeOverrideBooleans(mergedOverrideLines);
      lines.push('');
      lines.push('# ---- user override (P2) ----');
      for (const l of normalizedOverride) {
        lines.push(l);
      }
    }
    // 最终出口净化：无论上游哪条路径漏进控制字符（rawTemplate/逐字 ws 值/持久化脏数据），
    // 落盘配置必然 YAML-printable，内核不会因 "control characters are not allowed" 拒载。
    return ClashConfigGenerator.sanitizeControlChars(lines.join('\n') + '\n');
  }

  /**
   * YAML 覆盖层白名单（P2）：拦截危险顶层键。proxies 键由生成器程序化生成
   * （用户覆盖会绕过 UI 校验与去重），external-controller/secret/tun 三个键
   * 控制内核管理面，同样拦截。返回 true = 允许处理。
   * rules/rule-providers/proxy-groups 三键不再整段拦截：由 generate() 提取后
   * 按键合并进生成的同段（覆盖层 proxy-groups 聚合 + rules 同段合并），
   * 其余顶层键（dns 等）走 C17 的「允许覆盖 + 结构化合并」。
   *
   * 【C17】被拒时**必须报出具体键名**：旧实现整段丢弃且**完全静默**，
   * 用户只看到「覆盖层没生效」却没有任何线索。现在返回值语义不变（false =
   * 整段不生效），但会 AppLogger.warn 出具体被拒的键名。
   */
  static validateYamlOverride(text: string): boolean {
    if (text.length > 8 * 1024) {
      AppLogger.warn(TAG, 'yaml override rejected: exceeds 8KB limit (whole override ignored)');
      return false;
    }
    const blocked = /^(proxies|external-controller|secret|tun)\s*:/;
    const rejected: string[] = [];
    for (const line of text.split('\n')) {
      const m = line.trim().match(blocked);
      if (m !== null) {
        rejected.push(m[1]);
      }
    }
    if (rejected.length > 0) {
      AppLogger.warn(TAG, `yaml override rejected: blocked top-level key(s) `
        + `${rejected.join(', ')} — the whole override is ignored`);
      return false;
    }
    return true;
  }

  /**
   * 剥掉规则行的列表项前缀（'- ' / '- - ' 反复剥）。
   * rules 段的每一项在 mihomo RawConfig 里是**纯字符串**（Rule []string），
   * 写成 '- - RULE' 会变成嵌套 seq → cannot unmarshal !!seq into string 整份拒载（R6）。
   */
  private static stripRuleListPrefix(raw: string): string {
    let text = raw.trim();
    while (text.startsWith('- ') || text === '-') {
      text = text.startsWith('- ') ? text.substring(2).trim() : '';
    }
    return text;
  }

  /**
   * 规范化用户规则行的逗号空白：`DOMAIN-SUFFIX,local, 本地直连` → `DOMAIN-SUFFIX,local,本地直连`。
   *
   * 2026-10-19：isValidUserRuleLine 校验时对每个逗号段做了 trim，但写盘用的是原始行。
   * 校验通过、写盘却带空白，会让内核侧「策略目标精确匹配」的语义与校验不一致
   * （用户报障原文里规则正是 `DOMAIN-SUFFIX,local, 本地直连`，逗号后带空格）。
   * 这里把两侧统一到同一个规范形态，消除歧义。
   */
  static normalizeRuleLine(rule: string): string {
    const text = rule.trim();
    // 【C21】以 '- ' 开头的是**列表项**而不是规则内容：写进 rules: 段会变成嵌套
    // seq（cannot unmarshal !!seq into string）→ 整份拒载。这里直接拒绝（返回空串），
    // 调用方据此跳过该行。
    if (text.startsWith('- ') || text === '-') {
      return '';
    }
    return text.split(',').map((v: string) => v.trim()).join(',');
  }

  /**
   * 单条用户规则行（订阅自带 rules / 覆盖层 rules）是否可安全写入 rules 段：
   * - 策略目标（最后一个逗号字段，容忍 no-resolve 参数）必须是**实际写进 proxy-groups
   *   段的组**或内置策略（见 generate() 里 groupTargets 的构建，务必传 emittedGroups）；
   * - RULE-SET 引用的 provider 必须已声明（声明段与引用同受校验）。
   * 不合法的行由调用方跳过并计数 —— 内核 config.Parse 对「引用未声明的 provider /
   * 不存在的组」会直接拒载整份配置，所以这里必须在生成侧兜底。
   */
  private static isValidUserRuleLine(rule: string, providerNames: Set<string>,
    groupTargets: Set<string>): boolean {
    const text = rule.trim();
    if (text.length === 0 || text.length > 1024 || text.includes('\n') || text.includes('\r')) {
      return false;
    }
    const parts: string[] = [];
    for (const p of text.split(',')) {
      const t = p.trim();
      if (t.length > 0) {
        parts.push(t);
      }
    }
    if (parts.length < 2) {
      return false;
    }
    let policy = parts[parts.length - 1];
    if (policy.toUpperCase() === 'NO-RESOLVE' && parts.length >= 3) {
      policy = parts[parts.length - 2];
    }
    if (!groupTargets.has(policy)) {
      return false;
    }
    const type = parts[0].toUpperCase();
    if (type === 'RULE-SET') {
      return parts.length >= 3 && providerNames.has(parts[1]);
    }
    return true;
  }

  /**
   * rule-providers 块解析（**纯缩进层级**判定，C16）。
   *
   * 为什么必须「只看缩进层级、不看键名长什么样」：旧实现用
   * `/^([A-Za-z0-9_-]+):\s*$/` 认键行，点号名（`my.provider:`）、中文名、
   * 带引号的名**都不被认成键行** → 键行消失、它的字段行变成 `rule-providers:`
   * 的**兄弟键** → mihomo（RuleProvider map[string]map[string]any）报
   * `cannot unmarshal !!null/!!str into map[string]interface {}` 整份拒载（R1），
   * 且引用它的 RULE-SET 规则被**静默丢弃**（比拒载更隐蔽：规则不生效、无报错）。
   * 同一套判定此前在**三处各写一份正则**（本文件解析/去重 + SubscriptionService
   * 的引用账本），三处不一致 → 隐患。本方法是**唯一权威实现**，其余调用方复用。
   *
   * 判定规则：
   * - 预处理：去掉 `\r`、tab 换 2 空格、去行尾空白；空行与 `#` 注释行丢弃；
   * - indent = 行首空格数；
   * - indent >= 4 → 字段行；indent === 2 → 键行；
   * - indent <= 1 → 仅当冒号后为空值（`key:` 后面没有内容，忽略尾部注释）时
   *   才是键行，否则算字段行；
   * - 键行冒号前的文本去引号 = provider 名；名为空 → 视为字段行（结构异常）；
   * - 字段行归属于它前面**最近**的键行；任何键行之前的字段行进 orphanLines。
   */
  static parseProviderBlocks(lines: string[]): ProviderBlockParseResult {
    const result = new ProviderBlockParseResult();
    // 当前块栈（正常只有 1 层：块内不再嵌套块）
    const stack: ProviderBlockEntry[] = [];
    for (const raw of lines) {
      const line = raw.replace(/\r/g, '').replace(/\t/g, '  ');
      const body = line.trim();
      if (body.length === 0 || body.startsWith('#')) {
        continue;
      }
      const indent = ClashConfigGenerator.leadingSpaces(line);
      let isKeyLine = false;
      if (indent >= 4) {
        isKeyLine = false;
      } else if (indent === 2) {
        isKeyLine = true;
      } else {
        isKeyLine = ClashConfigGenerator.isEmptyValueKeyLine(body);
      }
      if (isKeyLine) {
        const name = ClashConfigGenerator.providerNameOf(body);
        if (name.length > 0) {
          const entry = new ProviderBlockEntry();
          entry.name = name;
          entry.keyLine = '  ' + body;
          result.blocks.push(entry);
          stack.push(entry);
          continue;
        }
      }
      // 字段行：归属于前面最近的键行；没有键行 → 结构异常（orphan）
      if (stack.length === 0) {
        result.orphanLines.push('    ' + body);
      } else {
        stack[stack.length - 1].fieldLines.push('    ' + body);
      }
    }
    return result;
  }

  /** 只要 provider 块名（引用账本 / 去重判定的轻量入口）。 */
  static providerBlockKeyNames(lines: string[]): string[] {
    const parsed = ClashConfigGenerator.parseProviderBlocks(lines);
    const out: string[] = [];
    for (const block of parsed.blocks) {
      out.push(block.name);
    }
    return out;
  }

  /**
   * 把 provider 声明块重缩进为规范 2/4 空格（provider 键行 2 空格、字段行 4 空格）。
   *
   * 实现改为调用 parseProviderBlocks（**纯缩进层级**判定），
   * 保留本方法名以免破坏既有调用方。语义不变：把 provider 块重缩进为 2/4 空格。
   * 真实订阅的 rule-providers 缩进不规范（tab、缩进深度不一）时原样回写，会让
   * yaml.v3 报「did not find expected key」整份拒载（真机实证 2026-10-16）。
   */
  static normalizeProviderBlock(rawLines: string[]): string[] {
    const parsed = ClashConfigGenerator.parseProviderBlocks(rawLines);
    const out: string[] = [];
    for (const block of parsed.blocks) {
      out.push(block.keyLine);
      for (const field of block.fieldLines) {
        out.push(field);
      }
    }
    return out;
  }

  /** 行首空格数（tab 已在调用前归一为 2 空格）。 */
  private static leadingSpaces(line: string): number {
    let count = 0;
    while (count < line.length && line.charAt(count) === ' ') {
      count = count + 1;
    }
    return count;
  }

  /**
   * 按**第一个引号外的冒号**切分 key/value；没有冒号时返回 ['', '']。
   * 引号感知是必需的：provider 名可以是 `"my.provider":`。
   */
  static splitKeyValue(text: string): string[] {
    let quote = '';
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        continue;
      }
      if (ch === ':') {
        return [text.substring(0, i), text.substring(i + 1)];
      }
    }
    return ['', ''];
  }

  /** 剥掉标量外层成对引号（provider 名 / 顶层键名都可能是带引号的）。 */
  private static unquoteKey(text: string): string {
    let value = text.trim();
    if (value.length >= 2
      && ((value.startsWith('"') && value.endsWith('"'))
        || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  /** 去掉值的尾部注释（`' #'` 之后才算注释，避免砍掉值里的 '#'）。 */
  private static stripYamlComment(value: string): string {
    const text = value.trim();
    if (text.startsWith('#')) {
      return '';
    }
    const idx = text.indexOf(' #');
    if (idx >= 0) {
      return text.substring(0, idx).trim();
    }
    return text;
  }

  /** 该行是否是「键行」：冒号存在，且冒号后为空值（忽略尾部注释）。 */
  private static isEmptyValueKeyLine(text: string): boolean {
    const parts = ClashConfigGenerator.splitKeyValue(text);
    if (parts[0].trim().length === 0) {
      return false;
    }
    return ClashConfigGenerator.stripYamlComment(parts[1]).length === 0;
  }

  /** 键行的 provider 名（冒号前文本去引号）。 */
  private static providerNameOf(text: string): string {
    const parts = ClashConfigGenerator.splitKeyValue(text);
    return ClashConfigGenerator.unquoteKey(parts[0]);
  }

  /**
   * 「已知顶层键」清单（生成器产出 + mihomo 常见顶层键）。
   * 覆盖层出现**不在此清单**的顶层键 → **保留**并 AppLogger.warn 记录键名
   * （绝不静默删除）；内核大概率不认这个键，提示用户避免"写了没生效"。
   */
  private static readonly KNOWN_TOP_LEVEL_KEYS: Set<string> = new Set<string>([
    'mixed-port', 'port', 'socks-port', 'redir-port', 'tproxy-port', 'mixed-port-range',
    'external-controller', 'external-controller-cors', 'external-controller-tls',
    'external-ui', 'external-ui-name', 'external-ui-url', 'secret',
    'mode', 'log-level', 'ipv6', 'disable-ipv6', 'unified-delay', 'tcp-concurrent',
    'keep-alive-idle', 'keep-alive-interval', 'udp-timeout', 'find-process-mode',
    'allow-lan', 'bind-address', 'disable-keep-alive', 'authentication', 'listeners',
    'interface-name', 'routing-mark', 'global-client-fingerprint', 'geodata-mode',
    'geodata-loader', 'geox-url', 'geosite-matcher', 'experimental', 'iptables',
    'etag-support', 'cfw-latency-url', 'cfw-bypass',
    'dns', 'sniffer', 'profile', 'tun', 'hosts',
    'proxies', 'proxy-providers', 'proxy-groups', 'rule-providers', 'rules', 'sub-rules',
  ]);

  /**
   * 覆盖层布尔字段白名单（C18）：只有这些**路径**上的布尔字面量才会被改写成
   * 裸 true/false。路径 = 缩进栈推导出的「顶层键 → 子键」链（如 dns.enable）。
   *
   * ⚠ **口径以真实内核实测为准**（Mihomo Meta 1.10.0，2026-10-20 逐写法实测，
   *   详见 normalizeOverrideBooleans 的实测表）：
   *   - 裸写 `yes/no/on/off` 内核**接受**（yaml.v3 对 bool 目标有 YAML 1.1 兼容分支）
   *     → 改写它们只是「规范化」，**不是**救火；
   *   - 真正会整份拒载的是**带引号的** `"true"/"false"/"1"/"0"`（!!str into bool）
   *     与**裸写的** `1/0`（!!int into bool）→ 这两类必须改写。
   *
   * 刻意**保守**：只列 RawConfig 里确定是 bool 的字段；未知路径上的值
   * **一律原样保留**（内核对不认识的字段宽容，我们不擅自改写用户原文）。
   */
  private static readonly OVERRIDE_BOOL_PATHS: Set<string> = new Set<string>([
    'allow-lan', 'ipv6', 'unified-delay', 'tcp-concurrent', 'disable-keep-alive',
    'dns.enable', 'dns.ipv6', 'dns.disable-cache', 'dns.direct-nameserver-follow-policy',
    'dns.respect-rules',
    'tun.enable', 'tun.auto-route', 'tun.auto-detect-interface', 'tun.strict-route',
    'sniffer.enable', 'sniffer.override-destination', 'sniffer.parse-pure-ip',
    'sniffer.force-dns-mapping',
    'profile.store-selected', 'profile.store-fake-ip',
  ]);

  /**
   * 按「顶层键」切分 YAML 文本块（C17）。
   *
   * 段落边界：一个 indent 0 的 `key:` 行开始一段，直到下一个 indent 0 的 `key:` 行
   * （或 EOF）为止；段内所有更深缩进的行属于该段；**段内缩进为 0 的注释行不结束
   * 当前段**（仍归当前段）。
   */
  static splitTopLevelBlocks(lines: string[]): YamlTopLevelBlock[] {
    const out: YamlTopLevelBlock[] = [];
    // 当前块栈（顶层块不会嵌套：块内更深缩进的行都归它）
    const stack: YamlTopLevelBlock[] = [];
    for (const raw of lines) {
      const line = raw.replace(/\r$/, '');
      const indent = ClashConfigGenerator.leadingSpaces(line);
      const trimmed = line.trim();
      let key = '';
      if (indent === 0 && trimmed.length > 0 && !trimmed.startsWith('#')
        && !trimmed.startsWith('- ')) {
        const parts = ClashConfigGenerator.splitKeyValue(trimmed);
        if (parts[0].trim().length > 0) {
          key = ClashConfigGenerator.unquoteKey(parts[0]);
        }
      }
      if (key.length > 0) {
        const block = new YamlTopLevelBlock();
        block.key = key;
        block.lines.push(line);
        out.push(block);
        stack.push(block);
        continue;
      }
      if (stack.length === 0) {
        const preamble = new YamlTopLevelBlock();
        preamble.lines.push(line);
        out.push(preamble);
        continue;
      }
      stack[stack.length - 1].lines.push(line);
    }
    return out;
  }

  /**
   * 从一段 YAML 行里**整段删除**指定的顶层键（C17）。
   * 段落边界与 splitTopLevelBlocks 同源；段内缩进为 0 的注释行不结束当前段。
   * 纯函数（不改入参），可直接被 Node 侧回归脚本抽出来跑。
   */
  static stripTopLevelBlocks(lines: string[], keys: Set<string>): string[] {
    if (keys.size === 0) {
      return lines.slice();
    }
    const out: string[] = [];
    let skipping = false;
    for (const raw of lines) {
      const line = raw.replace(/\r$/, '');
      const indent = ClashConfigGenerator.leadingSpaces(line);
      const trimmed = line.trim();
      if (indent === 0 && trimmed.length > 0 && !trimmed.startsWith('#')
        && !trimmed.startsWith('- ')) {
        const parts = ClashConfigGenerator.splitKeyValue(trimmed);
        if (parts[0].trim().length > 0) {
          skipping = keys.has(ClashConfigGenerator.unquoteKey(parts[0]));
        }
      }
      if (!skipping) {
        out.push(raw);
      }
    }
    return out;
  }

  /**
   * 该顶层段是否「有内容」。
   *
   * 用途：覆盖层里出现一个**空段**（例如 `rules:` 下面只有注释）时，
   * 既不能拿它去删掉生成器的同名段（会把生成器的规则整段抹掉 → 配置无规则），
   * 也不能把它原样追加（会多出一个空的同名顶层键 → 重复键 → 整份拒载）。
   * 判定：键行自身有非空值，或段内存在非注释非空的子行 → 有内容。
   */
  private static blockHasContent(block: YamlTopLevelBlock): boolean {
    for (let i = 0; i < block.lines.length; i++) {
      const text = block.lines[i].trim();
      if (text.length === 0 || text.startsWith('#')) {
        continue;
      }
      if (i === 0) {
        const parts = ClashConfigGenerator.splitKeyValue(text);
        if (parts[0].trim().length > 0
          && ClashConfigGenerator.stripYamlComment(parts[1]).length > 0) {
          return true;
        }
        continue;
      }
      return true;
    }
    return false;
  }

  /**
   * 覆盖层布尔值归一（C18）：**路径感知**，只改白名单路径上的布尔字面量。
   *
   * ── 真实内核实测口径（Mihomo Meta 1.10.0，`mihomo.exe -t -d <dir> -f <cfg>`，
   *    2026-10-20 逐个写法实测，不是推测）──────────────────────────────
   *  | 写法                              | 真实内核                          |
   *  |-----------------------------------|-----------------------------------|
   *  | `allow-lan: yes` / `on` / `no`    | **通过**（裸写）                  |
   *  | `allow-lan: "yes"` / `"on"` / `"no"` / `"OFF"` | **通过**（带引号也在兼容表内）|
   *  | `allow-lan: true` / `false`       | 通过（裸写，本就是 bool）         |
   *  | `allow-lan: "true"` / `"True"` / `"TRUE"` / `"false"` / `"1"` / `"0"` | **整份拒载** |
   *  | `allow-lan: 1` / `0`              | **整份拒载**（!!int into bool）   |
   *
   *  原因（yaml.v3 decode 层）：resolve 表只认 true/false → 带引号的字面量是
   *  !!str；但对 **bool 目标**另有一层 YAML 1.1 兼容分支，把
   *  y/Y/yes/Yes/YES/on/On/ON、n/N/no/No/NO/off/Off/OFF 转成 bool。
   *  **该兼容表里没有 true/True/TRUE/false/False/FALSE/1/0** → 带引号的
   *  "true"/"1" 是 !!str 落进 bool 字段 = `cannot unmarshal !!str 'true' into bool`
   *  = 整份拒载（unmarshal errors 是全有全无）。
   *
   * 所以本函数的**真正职责**是：把「会炸的写法」改成内核必吃的裸 true/false ——
   *  ① 带引号的 `"true"/"false"/"True"/"TRUE"/"1"/"0"` → 去引号写成 true/false；
   *  ② 裸写的 `1`/`0`（!!int into bool，同样会炸）→ true/false；
   *  ③ 裸写/带引号的 `yes/no/on/off` → 统一成裸 true/false（**语义相同**，
   *     内核本来也吃，属于规范化而非救火）。
   *  带引号的 `"yes"/"on"/"no"/"off"` 内核能吃，**保持原样不改**（不擅自改写用户原文）。
   *
   * **路径感知**：用缩进栈推导「顶层键 → 子键」路径，只有白名单路径才改写；
   * 未知路径上的值一律**原样保留**（绝不全局文本替换）。
   */
  static normalizeOverrideBooleans(lines: string[]): string[] {
    const out: string[] = [];
    const stackKeys: string[] = [];
    const stackIndents: number[] = [];
    for (const raw of lines) {
      const line = raw.replace(/\r$/, '');
      const trimmed = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        out.push(raw);
        continue;
      }
      const indent = ClashConfigGenerator.leadingSpaces(line);
      while (stackIndents.length > 0 && stackIndents[stackIndents.length - 1] >= indent) {
        stackIndents.pop();
        stackKeys.pop();
      }
      if (trimmed.startsWith('- ') || trimmed === '-') {
        // 序列项：不是键值对，也不改写
        out.push(raw);
        continue;
      }
      const parts = ClashConfigGenerator.splitKeyValue(trimmed);
      const rawKey = parts[0];
      const key = ClashConfigGenerator.unquoteKey(rawKey);
      if (key.length === 0) {
        out.push(raw);
        continue;
      }
      const path = stackKeys.length > 0 ? `${stackKeys.join('.')}.${key}` : key;
      const valueRaw = parts[1];
      const split = ClashConfigGenerator.splitValueAndComment(valueRaw);
      const value = split[0];
      const comment = split[1];
      let rewritten = raw;
      if (ClashConfigGenerator.OVERRIDE_BOOL_PATHS.has(path)) {
        const boolText = ClashConfigGenerator.boolLiteralToCanonical(value);
        if (boolText.length > 0) {
          const prefix = line.substring(0, indent);
          rewritten = `${prefix}${rawKey.trim()}: ${boolText}${comment}`;
        }
      }
      out.push(rewritten);
      if (value.length === 0) {
        // 可能是嵌套块（`dns:`）→ 压栈，后续更深缩进的行挂在它下面
        stackKeys.push(key);
        stackIndents.push(indent);
      }
    }
    return out;
  }

  /**
   * 把一个值文本归一成内核必吃的**裸** true/false；不需要改写时返回空串。
   *
   * 口径见 normalizeOverrideBooleans 的实测表：
   *  - 带引号的 "true"/"false"/"True"/"TRUE"/"1"/"0" → true/false（**会炸的写法**）
   *  - 裸写的 1/0 → true/false（!!int into bool，同样会炸）
   *  - 裸写的 yes/no/on/off（任意大小写）→ true/false（语义相同，规范化）
   *  - 带引号的 "yes"/"on"/"no"/"off" → **保持原样**（内核能吃）
   *  - 其它（true/false 裸写、非布尔值）→ 保持原样
   */
  private static boolLiteralToCanonical(value: string): string {
    const text = value.trim();
    if (text.length === 0) {
      return '';
    }
    const quoted = text.length >= 2
      && ((text.startsWith('"') && text.endsWith('"'))
        || (text.startsWith("'") && text.endsWith("'")));
    if (quoted) {
      const inner = text.substring(1, text.length - 1).trim();
      const lower = inner.toLowerCase();
      if (lower === 'true') {
        return 'true';
      }
      if (lower === 'false') {
        return 'false';
      }
      if (inner === '1') {
        return 'true';
      }
      if (inner === '0') {
        return 'false';
      }
      // "yes"/"on"/"no"/"off" 在 yaml.v3 的 bool 兼容表内 → 内核能吃，原样保留
      return '';
    }
    const lower = text.toLowerCase();
    if (lower === 'yes' || lower === 'on') {
      return 'true';
    }
    if (lower === 'no' || lower === 'off') {
      return 'false';
    }
    if (text === '1') {
      return 'true';
    }
    if (text === '0') {
      return 'false';
    }
    return '';
  }

  /**
   * 拆出「值」与「尾部注释」（引号感知）：只有引号外、且前面是空白的 '#' 才是注释起点；
   * 引号内的 '#' 不算。返回 [值, 注释（含前导空白）]。
   */
  private static splitValueAndComment(valueRaw: string): string[] {
    let quote = '';
    for (let i = 0; i < valueRaw.length; i++) {
      const ch = valueRaw.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        continue;
      }
      if (ch === '#' && (i === 0 || valueRaw.charAt(i - 1) === ' ')) {
        const comment = i > 0 ? valueRaw.substring(i - 1) : valueRaw.substring(i);
        return [valueRaw.substring(0, i).trim(), comment];
      }
    }
    return [valueRaw.trim(), ''];
  }

  /** 与节点页持久化键保持一致：订阅 ID + NUL + 原始组名。 */
  static proxyGroupKey(group: ProxyGroup): string {
    return group.subscriptionId + '\u0000' + group.name;
  }

  /**
   * 解析 YAML 覆盖层的 proxy-groups 段（extractSection 归一化输出）为组对象。
   * 容错行解析：`- name:` 起新组；type/url/interval/tolerance/expected-status
   * 映射到组字段（planProxyGroups 只对 url-test/fallback/load-balance 发射测速键）；
   * proxies: 后的序列项为成员。仅保留名称合法且不重复的组；名称与 'PROXY' 冲突、
   * 名字重复或含不安全文本的组跳过（绝不整份拒载）。流式写法（`- {name: ...}`）、
   * include-all/filter 等动态分组语法不支持，保守跳过；成员为空的组由
   * planProxyGroups 的落地性迭代统一丢弃。
   */
  private static parseOverrideProxyGroups(section: string): ProxyGroup[] {
    const out: ProxyGroup[] = [];
    const seenNames = new Set<string>();
    let current: ProxyGroup | null = null;
    let inProxies = false;
    for (const rawLine of section.split('\n')) {
      const line = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
      const t = line.trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const itemMatch = t.match(/^-\s+name:\s*(.+)$/);
      if (itemMatch !== null) {
        if (current !== null) {
          out.push(current);
          current = null;
        }
        const name = ClashConfigGenerator.unquoteYamlScalar(itemMatch[1]);
        if (name.length === 0 || name === 'PROXY' || seenNames.has(name)
          || !ClashConfigGenerator.isSafeText(name)) {
          continue;
        }
        const group = new ProxyGroup();
        group.subscriptionId = '';
        group.name = name;
        seenNames.add(name);
        current = group;
        inProxies = false;
        continue;
      }
      if (current === null) {
        continue;
      }
      if (t === 'proxies:' || t.startsWith('proxies:')) {
        inProxies = true;
        continue;
      }
      if (t.startsWith('- ') && inProxies) {
        const member = ClashConfigGenerator.unquoteYamlScalar(t.substring(2));
        if (member.length > 0 && ClashConfigGenerator.isSafeText(member)
          && !current.members.includes(member)) {
          current.members.push(member);
        }
        continue;
      }
      // 非 member 序列项（不支持的动态分组键等）跳过
      if (t.startsWith('- ')) {
        continue;
      }
      inProxies = false;
      const ci = t.indexOf(':');
      if (ci <= 0) {
        continue;
      }
      const key = t.substring(0, ci).trim().toLowerCase();
      const value = t.substring(ci + 1).trim();
      if (key === 'type') {
        current.groupType = ClashConfigGenerator.unquoteYamlScalar(value).toLowerCase();
      } else if (key === 'url') {
        current.url = ClashConfigGenerator.unquoteYamlScalar(value);
      } else if (key === 'interval' || key === 'tolerance') {
        const n = Number(value);
        if (Number.isFinite(n) && n > 0) {
          if (key === 'interval') {
            current.intervalSec = Math.floor(n);
          } else {
            current.toleranceMs = Math.floor(n);
          }
        }
      } else if (key === 'expected-status') {
        current.expectedStatus = ClashConfigGenerator.unquoteYamlScalar(value);
      }
    }
    if (current !== null) {
      out.push(current);
    }
    return out;
  }

  /** 剥掉 YAML 标量外层成对引号（覆盖层组名/成员/测速值常带引号落盘）。 */
  private static unquoteYamlScalar(value: string): string {
    let v = value.trim();
    if (v.length >= 2
      && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
      v = v.substring(1, v.length - 1).trim();
    }
    return v;
  }

  /**
   * 组测速 URL 安全化：仅接受 http(s) 明文链接且不含 YAML 破坏字符；
   * 非法/未声明回退内核默认口径 gstatic generate_204。
   *
   * 【C4】兜底值改为 **https**：mihomo 官方点名 `group.url` 应使用 HTTPS
   * （明文地址会被出口劫持，测速结果不可信）。**用户/订阅自己声明的 url
   * 保持原样不动**（个别出口掐 gstatic 的 TLS SNI 是真机实证过的合法用法）。
   */
  static safeGroupUrl(raw: string): string {
    const url = raw.trim();
    if (url.length === 0 || url.length > 2048 || !ClashConfigGenerator.isSafeText(url)
      || !(url.startsWith('http://') || url.startsWith('https://'))) {
      return 'https://www.gstatic.com/generate_204';
    }
    return ClashConfigGenerator.escapeYaml(url);
  }

  /** 组测速间隔夹取：30..86400 秒；未声明（0/负数）回退 300（旧版硬编码值）。 */
  static clampGroupInterval(intervalSec: number): number {
    if (!Number.isFinite(intervalSec) || intervalSec <= 0) {
      return 300;
    }
    return Math.min(Math.max(Math.floor(intervalSec), 30), 86400);
  }

  /** 容错读取代理组选择；旧版本、损坏 JSON 或非字符串值均按空选择处理。 */
  static parseProxyGroupSelections(raw: string): Map<string, string> {
    const out = new Map<string, string>();
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      for (const key of Object.keys(parsed)) {
        const value = parsed[key];
        // 键是节点页稳定键（subscriptionId + '\u0000' + 组名），含 NUL 属预期格式，
        // 仅用于内存查找、从不写入 YAML，故不套用 isSafeText；值会进入配置，必须安全。
        if (typeof value === 'string' && key.length > 0 && key.length <= 64 * 1024
          && ClashConfigGenerator.isSafeText(value)) {
          out.set(key, value);
        }
      }
    } catch (_) {
      // 设置损坏不能阻止连接，回退到订阅声明顺序。
    }
    return out;
  }

  /**
   * 名称是否已被任何节点或订阅组占用。
   * 组名与节点名同名会让 `proxies:` 成员产生「解析为节点还是组」的二义性
   * （与 planProxyGroups 里 reservedNames 的约束同源），因此 smart 组名必须避开。
   */
  static usesName(nodes: ProxyNode[], groups: ProxyGroup[], name: string): boolean {
    for (const n of nodes) {
      if (n.name === name) {
        return true;
      }
    }
    for (const g of groups) {
      if (g.name === name) {
        return true;
      }
    }
    return name === 'PROXY';
  }

  /**
   * 生成可安全写入 Mihomo 的代理组计划。
   * 仅保留支持类型、名称唯一且成员最终可解析的组，并通过迭代消除悬空引用与纯循环组。
   */
  static planProxyGroups(groups: ProxyGroup[], validNodes: ProxyNode[]): ProxyGroup[] {
    // relay（链式中继）成员只能经节点链拨号；mihomo 原生支持该类型，此前被白名单
    // 丢弃导致含 relay 的订阅整组失效。url-test/fallback/load-balance 同为原生类型。
    const supported = new Set<string>(['select', 'url-test', 'fallback', 'load-balance', 'relay']);
    const nodeNames = new Set<string>();
    const originalToDisplay = new Map<string, string[]>();
    for (const node of validNodes) {
      nodeNames.add(node.name);
      const original = node.originalName.length > 0 ? node.originalName : node.name;
      const displays = originalToDisplay.get(original);
      if (displays === undefined) {
        originalToDisplay.set(original, [node.name]);
      } else if (!displays.includes(node.name)) {
        displays.push(node.name);
      }
    }
    // 组名保留字：任何节点显示名/原始名（含 NUL 分隔的订阅键无关）都不能被组占用，
    // 否则成员引用存在「解析为节点还是组」的二义性。
    const reservedNames = new Set<string>();
    for (const node of validNodes) {
      reservedNames.add(node.name);
      reservedNames.add(node.originalName.length > 0 ? node.originalName : node.name);
    }

    const candidates: ProxyGroup[] = [];
    const acceptedNames = new Set<string>();
    for (const source of groups) {
      const type = source.groupType.trim().toLowerCase();
      const name = source.name.trim();
      if (!supported.has(type) || name.length === 0 || name === 'PROXY'
        || !ClashConfigGenerator.isSafeText(name) || reservedNames.has(name)
        || acceptedNames.has(name)) {
        continue;
      }
      const item = new ProxyGroup();
      item.subscriptionId = source.subscriptionId;
      item.name = name;
      item.groupType = type;
      item.members = source.members.slice();
      // 组测速参数语义保真：url/interval/tolerance/expected-status 原样带出，
      // 由 generate() 按类型决定是否发射（select/relay 不发射测速键）。
      item.url = source.url;
      item.intervalSec = source.intervalSec;
      item.toleranceMs = source.toleranceMs;
      item.expectedStatus = source.expectedStatus;
      candidates.push(item);
      acceptedNames.add(name);
    }

    // 落地性迭代：组必须能经成员引用最终到达真实节点才可写入配置。
    // 纯循环组（互相引用但无节点出口）永远不会落地 → 整组丢弃；
    // 带真实出口的循环由直接引用节点的组先落地，再逐轮向外传播保留。
    const groundedNames = new Set<string>();
    const groundedOrder = new Map<string, number>();
    let changed = true;
    while (changed) {
      changed = false;
      for (const group of candidates) {
        if (groundedNames.has(group.name)) {
          continue;
        }
        // relay 组只接受真实节点成员（中继链内嵌套组引用的拨号语义不可控，保守丢弃）
        const isRelay = group.groupType === 'relay';
        for (const rawMember of group.members) {
          const displays = originalToDisplay.get(rawMember);
          const reachesNode = nodeNames.has(rawMember)
            || (displays !== undefined && displays.length > 0);
          const reachesGroundedGroup = !isRelay && groundedNames.has(rawMember)
            && rawMember !== group.name;
          if (reachesNode || reachesGroundedGroup) {
            groundedOrder.set(group.name, groundedOrder.size);
            groundedNames.add(group.name);
            changed = true;
            break;
          }
        }
      }
    }

    const out: ProxyGroup[] = [];
    for (const group of candidates) {
      if (!groundedNames.has(group.name)) {
        continue;
      }
      const isRelay = group.groupType === 'relay';
      const members: string[] = [];
      for (const rawMember of group.members) {
        const displays = originalToDisplay.get(rawMember);
        if (displays !== undefined) {
          for (const display of displays) {
            if (!members.includes(display)) {
              members.push(display);
            }
          }
        } else if (nodeNames.has(rawMember) && !members.includes(rawMember)) {
          members.push(rawMember);
        } else if (!isRelay && groundedNames.has(rawMember) && rawMember !== group.name
          && (groundedOrder.get(rawMember) ?? 0) < (groundedOrder.get(group.name) ?? 0)
          && !members.includes(rawMember)) {
          // 组引用只指向更早落地的组：严格偏序天然消除配置内循环引用，
          // 也绝不引用被丢弃的组（无悬空引用），内核可安全加载。
          members.push(rawMember);
        }
      }
      if (members.length === 0) {
        continue;
      }
      group.members = members;
      out.push(group);
    }
    return out;
  }

  static normalizeCustomRules(values: string[]): string[] {
    const out: string[] = [];
    for (const raw of values) {
      const rule = raw.trim();
      if (rule.length === 0) {
        continue;
      }
      const error = ClashConfigGenerator.validateCustomRuleDetailed(rule);
      if (error.length > 0) {
        continue;
      }
      const parts = rule.split(',').map((v: string) => v.trim());
      const normalized = parts.join(',');
      if (!out.includes(normalized)) {
        out.push(normalized);
      }
    }
    return out.slice(0, 500);
  }

  /**
   * 自定义规则逐行校验（M8）：返回空串 = 合法；否则返回用户可读原因。
   * 与 normalizeCustomRules 共用同一套判定，保证「所见校验 = 实际落盘」。
   *
   * 范围刻意保守（相对 mihomo 全量规则类型）：
   *  - 不开放 GEOSITE / RULE-SET：二者会在 config.Parse 阶段触发 geosite/规则文件
   *    联网下载（与 MMDB 90s 阻塞坑同源），没有文件就绪门控前绝不放进用户输入；
   *  - 不开放 DOMAIN-REGEX：payload 可含逗号，与逗号切分模型冲突；
   *  - 策略白名单：DIRECT / PROXY / REJECT / PASS / REJECT-DROP（mihomo 内建策略）。
   */
  static validateCustomRuleDetailed(rule: string): string {
    const trimmed = rule.trim();
    if (trimmed.length === 0) {
      return '规则为空';
    }
    if (trimmed.length > 512) {
      return '规则超过 512 字符';
    }
    if (trimmed.includes('\n') || trimmed.includes('\r')) {
      return '规则不能包含换行';
    }
    if (trimmed.includes('#')) {
      return '规则不能包含注释符 #';
    }
    const parts = trimmed.split(',').map((v: string) => v.trim());
    if (parts.length !== 3 && parts.length !== 4) {
      return '格式应为 类型,值,策略[,no-resolve]';
    }
    const allowedTypes: string[] = ['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD',
      'IP-CIDR', 'IP-CIDR6', 'GEOIP'];
    const type = parts[0].toUpperCase();
    if (!allowedTypes.includes(type)) {
      return `不支持的规则类型 ${parts[0]}（支持：${allowedTypes.join(' / ')}）`;
    }
    const value = parts[1];
    if (value.length === 0) {
      return '匹配值为空';
    }
    if (type === 'DOMAIN' || type === 'DOMAIN-SUFFIX' || type === 'DOMAIN-KEYWORD') {
      // 域名类值：拒绝空白与规则元字符（逗号已在切分时消费）
      if (/\s/.test(value) || value.includes('"') || value.includes("'")) {
        return '域名值不能包含空白或引号';
      }
      if (type !== 'DOMAIN-KEYWORD' && value.includes('..')) {
        return '域名不能包含连续点号';
      }
    } else if (type === 'IP-CIDR') {
      const m = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/);
      if (m === null) {
        return 'IPv4 CIDR 应为 a.b.c.d/掩码';
      }
      for (let i = 1; i <= 4; i++) {
        if (parseInt(m[i]) > 255) {
          return 'IPv4 地址段超出 0-255';
        }
      }
      if (parseInt(m[5]) > 32) {
        return 'IPv4 掩码超出 0-32';
      }
    } else if (type === 'IP-CIDR6') {
      if (!/^[0-9A-Fa-f:]+\/\d{1,3}$/.test(value)) {
        return 'IPv6 CIDR 应为 地址/前缀长度';
      }
      if (parseInt(value.substring(value.lastIndexOf('/') + 1)) > 128) {
        return 'IPv6 前缀长度超出 0-128';
      }
    } else if (type === 'GEOIP') {
      if (!/^[A-Za-z]{2,8}$/.test(value)) {
        return 'GEOIP 值应为 2-8 位国家/地区代码（如 CN、US）';
      }
    }
    const target = parts[2].toUpperCase();
    const allowedTargets: string[] = ['DIRECT', 'PROXY', 'REJECT', 'PASS', 'REJECT-DROP'];
    if (!allowedTargets.includes(target)) {
      return `策略 ${parts[2]} 不支持（支持：${allowedTargets.join(' / ')}）`;
    }
    if (parts.length === 4) {
      if (parts[3] !== 'no-resolve') {
        return '第四段只支持 no-resolve';
      }
      if (type !== 'IP-CIDR' && type !== 'IP-CIDR6' && type !== 'GEOIP') {
        return 'no-resolve 仅对 IP/GEOIP 规则有效';
      }
    }
    return '';
  }

  /**
   * 规则调试（P1-5）：给定一个域名，模拟配置中域名类规则的命中顺序。
   * 返回命中的规则描述（"TYPE value → TARGET"）或 ''（未命中任何自定义域名规则）。
   * 顺序与 rules 段一致：自定义规则（先于强制直连/代理名单）。
   */
  static debugDomainMatch(domain: string, rules: string[]): string {
    const host = domain.trim().toLowerCase();
    if (host.length === 0) {
      return '';
    }
    for (const raw of rules) {
      const parts = raw.split(',').map((v: string) => v.trim());
      if (parts.length < 3) {
        continue;
      }
      const type = parts[0].toUpperCase();
      const value = parts[1].toLowerCase();
      const target = parts[2].toUpperCase();
      if (type === 'DOMAIN' && host === value) {
        return `DOMAIN,${value} → ${target}`;
      }
      if (type === 'DOMAIN-SUFFIX' && (host === value || host.endsWith('.' + value))) {
        return `DOMAIN-SUFFIX,${value} → ${target}`;
      }
      if (type === 'DOMAIN-KEYWORD' && host.indexOf(value) >= 0) {
        return `DOMAIN-KEYWORD,${value} → ${target}`;
      }
    }
    return '';
  }

  /** 节点 → 内核类型（ss/ssr 用模型枚举，其余用 proxyType 小写） */
  private static proxyTypeOf(n: ProxyNode): string {
    return n.type === ProxyNodeType.SSR ? 'ssr'
      : (n.type === ProxyNodeType.SS ? 'ss' : n.proxyType.toLowerCase());
  }

  /**
   * 「能否写入内核配置」的唯一判定（顺序与旧 proxyYamlLine 的 return '' 分支严格一致）：
   * 协议不支持 → 文本不安全 → 缺 name/server 或协议必需字段 → 端口非法。
   * 生成配置与诊断计数共用此函数，保证「丢弃计数」与「实际写入行」永不漂移。
   */
  static dropReasonFor(n: ProxyNode): ProxyDropReason {
    const proxyType = ClashConfigGenerator.proxyTypeOf(n);
    // direct 出站只有 name/type（mihomo 合法节点），没有 server/port/凭据可校验
    if (proxyType === 'direct') {
      return n.name.length === 0 ? ProxyDropReason.MISSING_FIELD : ProxyDropReason.NONE;
    }
    if (proxyType !== 'ss' && proxyType !== 'ssr' && proxyType !== 'vless'
      && proxyType !== 'vmess' && proxyType !== 'trojan' && proxyType !== 'hysteria2'
      && !YamlMerger.isRelayType(proxyType)) {
      return ProxyDropReason.UNSUPPORTED_PROTOCOL;
    }
    const textValues: string[] = [n.name, n.server, n.password, n.method, n.protocol, n.protocolParam,
      n.obfs, n.obfsParam, n.uuid, n.network, n.servername, n.flow, n.clientFingerprint,
      n.certFingerprint, n.realityPublicKey, n.realityShortId, n.wsPath, n.wsHost,
      n.grpcServiceName, n.hyUp, n.hyDown, n.alpnList];
    for (const value of textValues) {
      if (!ClashConfigGenerator.isSafeText(value)) {
        return ProxyDropReason.UNSAFE_TEXT;
      }
    }
    if (n.name.length === 0 || n.server.length === 0) {
      return ProxyDropReason.MISSING_FIELD;
    }
    if (n.port <= 0 || n.port > 65535) {
      return ProxyDropReason.INVALID_PORT;
    }
    if (proxyType === 'ss' || proxyType === 'ssr') {
      // method 缺失属结构缺字段; password 缺失属凭据缺失(加密层未回填的典型信号)
      if (n.method.length === 0) {
        return ProxyDropReason.MISSING_FIELD;
      }
      if (n.password.length === 0) {
        return ProxyDropReason.MISSING_CREDENTIAL;
      }
    }
    if (proxyType === 'ssr' && (n.protocol.length === 0 || n.obfs.length === 0)) {
      return ProxyDropReason.MISSING_FIELD;
    }
    if ((proxyType === 'vless' || proxyType === 'vmess') && n.uuid.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) {
      // REALITY 字段合法性对齐内核解析规则(mihomo reality.go):
      // public-key = base64url(RawURLEncoding) 解码后必须 32 字节(43 字符);
      // short-id 必须偶数长度 hex 且解码后 ≤8 字节(≤16 字符)。
      // 新版官方内核对解析失败的代理是「跳过该节点」; 捆绑的旧内核是
      // 「整份配置解析失败」→ 一个坏节点曾让内核完全起不来(全部超时)。
      // 这里在生成前拦截: 非法 REALITY 字段的节点按无效丢弃并计数。
      if (n.realityPublicKey.length > 0
        && !/^[A-Za-z0-9_-]{43}$/.test(n.realityPublicKey)) {
        return ProxyDropReason.MISSING_FIELD;
      }
      if (n.realityShortId.length > 0
        && !/^[0-9a-fA-F]{2}([0-9a-fA-F]{2}){0,7}$/.test(n.realityShortId)) {
        return ProxyDropReason.MISSING_FIELD;
      }
    }
    if (proxyType === 'trojan' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (proxyType === 'hysteria2' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    // 中继白名单(isRelayType)对任意合法小写类型放行(订阅升级不丢协议),但 mihomo
    // 对下面这些协议有必填凭据/参数:一个空 password/uuid 的节点会让**整份配置**
    // 解析失败(真机报错 `proxy "N": has unset fields:password`,内核完全起不来)。
    // 因此必须在生成前按内核必填字段丢弃,统一进「无效节点」账本提示。
    //
    // 判定口径必须与**实际写进内核的键**一致,否则会误丢可用节点:
    //  · tuic v4 = uuid + password;tuic v5 = token(只认 token,不认 uuid/password)。
    //    token 走 extraOpts 原样透传(不能回填到 password 槽 —— 那会让内核 v5 收到
    //    一个它不认的 password 键),所以这里要查 extraOpts。
    //  · hysteria v1 的凭据是 auth-str/auth_str(已由 YamlMerger 回填进 password 槽);
    //    它的 `protocol` 是**传输协议**(udp/wechat-video/faketcp,默认 udp)、
    //    `up`/`down` 是带宽(mihomo 自带默认值)——都不是必填凭据,不能拿来判死节点。
    if (proxyType === 'tuic') {
      const hasToken = ClashConfigGenerator.hasExtraKey(n.extraOpts, 'token');
      const hasV4 = n.password.length > 0 && n.uuid.length > 0;
      if (!hasToken && !hasV4) {
        return ProxyDropReason.MISSING_CREDENTIAL;
      }
    }
    if (proxyType === 'hysteria' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (proxyType === 'anytls' && n.password.length === 0) {
      return ProxyDropReason.MISSING_CREDENTIAL;
    }
    if (n.alterId < 0 || !Number.isInteger(n.alterId)) {
      return ProxyDropReason.MISSING_FIELD;
    }
    return ProxyDropReason.NONE;
  }

  /**
   * 统计 nodes 中「列表有、内核无」的节点数与原因分类（漏洞 A 的核心修复）。
   * 判定复用 dropReasonFor，因此与实际写入内核配置的判定完全同源。
   *
   * @param precomputed 调用方已算好的 node→原因映射。generate() 会把整批结果算一次
   *        再传进来（省掉一次全量重算）；缺省时退化为自行计算，对外行为不变。
   */
  static countDroppedNodes(nodes: ProxyNode[], precomputed: Map<ProxyNode, string> | null = null): ProxyDropStats {
    const stats = new ProxyDropStats();
    stats.total = nodes.length;
    const samples: string[] = [];
    for (const n of nodes) {
      const cached = precomputed === null ? undefined : precomputed.get(n);
      const reason = cached !== undefined ? cached : ClashConfigGenerator.dropReasonFor(n);
      if (reason === ProxyDropReason.NONE) {
        stats.kept = stats.kept + 1;
        continue;
      }
      if (reason === ProxyDropReason.UNSUPPORTED_PROTOCOL) {
        stats.unsupportedProtocol = stats.unsupportedProtocol + 1;
      } else if (reason === ProxyDropReason.UNSAFE_TEXT) {
        stats.unsafeText = stats.unsafeText + 1;
      } else if (reason === ProxyDropReason.INVALID_PORT) {
        stats.invalidPort = stats.invalidPort + 1;
      } else {
        stats.missingFields = stats.missingFields + 1;
        if (reason === ProxyDropReason.MISSING_CREDENTIAL) {
          stats.missingCredential = stats.missingCredential + 1;
        }
      }
      if (samples.length < 3) {
        samples.push(n.name.length > 0 ? n.name : '(未命名)');
      }
    }
    stats.samples = samples.join('、');
    return stats;
  }

  /**
   * 「双轨」provider 计划：决定本次配置要不要输出 proxy-providers / use:。
   *
   * 硬约束（缺一不可，任何一条不满足都只是「少一条 provider」，绝不产生悬空引用）：
   * 1) settings.useRawProviderConfig 为 true（开关关闭 → 直接返回空计划，输出与现状一致）；
   * 2) 该订阅的原文已成功落盘且文件此刻仍存在（RawSubscriptionStore.active 已校验）；
   * 3) 该订阅此刻仍有节点在列表里（订阅被删/被隐藏后不再引用其 provider）。
   * 差额（缺失文件 / 无对应节点）全部计入 lastProviderStats，由诊断面板展示。
   */
  static planRawProviders(settings: AppSettings, allNodes: ProxyNode[]): RawProviderPlan {
    const plan = new RawProviderPlan();
    plan.stats.pathMode = RAW_PROVIDER_PATH_MODE;
    if (!settings.useRawProviderConfig) {
      // 默认路径：开关关闭时行为与现状完全一致（不产生任何额外行 / 额外 IO）
      plan.stats.enabled = false;
      return plan;
    }
    plan.stats.enabled = true;
    const liveSubscriptions = new Set<string>();
    for (const n of allNodes) {
      if (n.subscriptionId.length > 0) {
        liveSubscriptions.add(n.subscriptionId);
      }
    }
    const names: string[] = [];
    for (const entry of RawSubscriptionStore.active()) {
      plan.stats.candidates = plan.stats.candidates + 1;
      if (!liveSubscriptions.has(entry.subscriptionId)) {
        plan.stats.orphaned = plan.stats.orphaned + 1;
        continue;
      }
      if (!RawSubscriptionStore.has(entry.subscriptionId)) {
        plan.stats.missingFiles = plan.stats.missingFiles + 1;
        continue;
      }
      plan.entries.push(entry);
      names.push(entry.providerName);
    }
    plan.stats.emitted = plan.entries.length;
    plan.stats.providerNames = names.join(',');
    if (plan.stats.candidates > plan.stats.emitted) {
      AppLogger.warn(TAG, `raw provider plan: ${plan.stats.detail()}`);
    }
    return plan;
  }

  /**
   * extraOpts 里是否存在某个键（用于按「实际写进内核的键」判定凭据齐不齐）。
   *
   * 例：tuic v5 的凭据键是 `token`，它走中继透传留在 extraOpts 里，
   * 结构化槽位 password/uuid 都是空的 —— 判定必须查这里，否则 v5 节点被误丢。
   */
  private static hasExtraKey(extraOpts: string, key: string): boolean {
    if (extraOpts.length === 0) {
      return false;
    }
    for (const pair of YamlMerger.parseExtraOpts(extraOpts)) {
      if (pair[0] === key) {
        return true;
      }
    }
    return false;
  }

  /**
   * 提取 extras 里以 `ws-opts.<sub>` 前缀保全的 WS 高级子键（max-early-data 等），
   * 返回 [subKey, 发射值]：布尔/数字原样、其余引号，供并入 ws-opts 结构。
   */
  private static wsExtraPairs(extraOpts: string): string[][] {
    const out: string[][] = [];
    for (const pair of YamlMerger.parseExtraOpts(extraOpts)) {
      const key = pair[0];
      if (!key.startsWith('ws-opts.')) {
        continue;
      }
      const sub = key.substring('ws-opts.'.length);
      if (!YamlMerger.isSafeExtraKey(sub) || !ClashConfigGenerator.isSafeText(pair[1])) {
        continue;
      }
      const value = pair[1];
      if (value === 'true' || value === 'false' || /^-?[0-9]+(\.[0-9]+)?$/.test(value)
        || value.startsWith('{') || value.startsWith('[')) {
        out.push([sub, ClashConfigGenerator.sanitizeControlChars(value)]);
      } else {
        out.push([sub, `"${ClashConfigGenerator.escapeYaml(value)}"`]);
      }
    }
    return out;
  }

  /**
   * 全局代理名唯一化（**就地**改名，幂等）。
   *
   * 为什么必须有这一层：mihomo 对重名代理是**致命**的 ——
   *   config/config.go:900-907
   *     for idx, mapping := range proxiesConfig { …
   *       return nil, nil, fmt.Errorf("proxy %s is the duplicate name", proxy.Name()) }
   * 只要 `proxies:` 里出现两个同名条目，内核会**拒绝加载整份配置**（不是跳过其一），
   * 用户表现为「连不上」，而 App 侧只看到配置加载失败，极难定位。
   *
   * 为什么单靠 SubscriptionParser.dedupName 不够：那个函数只在**单个订阅内部**去重
   * （它只看本次 parse 累积的 nodes）。而配置是把**所有订阅 + provider** 的节点合并
   * 生成的，两个订阅各有一个「香港 01」时没有任何一层兜底 —— 这正是本函数补的洞。
   *
   * 改名规则与 dedupName 一致（首个保留原名，其后追加 " 2"、" 3"…），
   * 且**幂等**：第二次调用时名字已唯一，不会再追加序号。
   * 注意 originalName 不动，所以 proxy-groups 里按面板原始名写的成员
   * 仍能通过 planProxyGroups 的 originalToDisplay 映射解析到改名后的显示名。
   *
   * 【C24 覆盖范围核实结论 —— 已核实，规格如下】
   * 改名后的节点名必须在**所有引用处**同步，当前已全部覆盖（逐处核实）：
   *   ① `proxies:` 段 —— 改名在写 proxies 之前完成（generate() 里的调用点
   *      早于任何 proxyYamlLine 输出），落盘的就是新名；
   *   ② `proxy-groups` 的 `proxies:` 成员 —— 成员以**原始名**声明，
   *      planProxyGroups 用 originalToDisplay 把原始名映射到**改名后的显示名**
   *      （planProxyGroups 拿到的 validNodes 已是改名后的对象）；
   *   ③ 内建 `PROXY` 组的成员列表 —— 直接写 n.name（改名后的）；
   *   ④ smart（♻️ 自动选择）组的成员列表 —— 直接写 n.name（改名后的）；
   *   ⑤ `use:` 引用 —— 引用的是**订阅 provider 名**（不是节点名），与节点改名无关。
   * 已知残留缺口（不在本函数职责内，且开关默认关闭）：双轨 provider
   * （settings.useRawProviderConfig=true）时，provider 原文里的节点名由**内核自己**
   * 解析，不经过本函数 → 与我们 `proxies:` 段里的同名节点可能撞名
   * （内核报 "proxy X is the duplicate name"）。要根治需在 RawSubscriptionStore
   * 落盘时给 provider 内节点名加前缀（属于方案组 C 的 provider 生命周期改造）。
   *
   * @returns 实际改名的节点数（0 = 本来就没有重名）
   */
  static ensureUniqueProxyNames(nodes: ProxyNode[]): number {
    const used = new Set<string>();
    let renamed = 0;
    for (const n of nodes) {
      const base = n.name.length > 0 ? n.name : 'node';
      let candidate = base;
      let i = 2;
      while (used.has(candidate)) {
        candidate = `${base} ${i++}`;
      }
      if (candidate !== n.name) {
        n.name = candidate;
        renamed = renamed + 1;
      }
      used.add(candidate);
    }
    if (renamed > 0) {
      AppLogger.warn(TAG, `renamed ${renamed} duplicate proxy name(s) `
        + 'to keep the config loadable (mihomo rejects duplicate proxy names)');
    }
    return renamed;
  }

  static proxyYamlLine(n: ProxyNode): string {
    // 判定统一走 dropReasonFor：能写出合法行的节点必定判定为 NONE，
    // 判定非 NONE 的节点返回空行（调用方用 countDroppedNodes 记账并提示）。
    if (ClashConfigGenerator.dropReasonFor(n) !== ProxyDropReason.NONE) {
      return '';
    }
    const proxyType = ClashConfigGenerator.proxyTypeOf(n);
    const q = (value: string): string => `"${ClashConfigGenerator.escapeYaml(value)}"`;
    // ── 逐字模板优先（根治「解析→重生成丢字段」）──
    // 订阅原始 flow-map 已去 name/凭据，原样回写，再注入去重后的 name 与
    // 加密层回填的凭据。传输/选项字段(xhttp-opts、reality-opts、headers、
    // dialer-proxy、null 值…)全部逐字保留，与桌面 Clash 用原始 YAML 等价。
    if (n.rawTemplate.length > 0 && ClashConfigGenerator.isSafeText(n.rawTemplate)) {
      const rawParts: string[] = [`name: ${q(n.name)}`, ClashConfigGenerator.sanitizeControlChars(n.rawTemplate)];
      if (n.uuid.length > 0) {
        rawParts.push(`uuid: ${q(n.uuid)}`);
      }
      if (n.password.length > 0) {
        rawParts.push(`password: ${q(n.password)}`);
      }
      if (n.protocolParam.length > 0) {
        rawParts.push(`protocol-param: ${q(n.protocolParam)}`);
      }
      if (n.obfsParam.length > 0) {
        rawParts.push(`${proxyType === 'hysteria2' ? 'obfs-password' : 'obfs-param'}: ${q(n.obfsParam)}`);
      }
      // 保留结构化路径的 WS 兜底: 面板把 ws 节点写成 network: ws 却省略 ws-opts 时,
      // mihomo 会发无路径/无 Host 的 Upgrade 被 Cloudflare 拒绝, 这里补默认值。
      if ((proxyType === 'vless' || proxyType === 'vmess' || proxyType === 'trojan')
        && n.network === 'ws' && !n.rawTemplate.includes('ws-opts')) {
        const ws: string[] = ['path: "/"'];
        if (n.servername.length > 0) {
          ws.push(`headers: {Host: ${q(n.servername)}}`);
        }
        rawParts.push(`ws-opts: {${ws.join(', ')}}`);
      }
      return `  - {${rawParts.join(', ')}}`;
    }
    // ── 无模板(URI 导入/块式写法)：回退结构化生成 ──
    const fields: string[] = [];
    fields.push(`name: ${q(n.name)}`);
    fields.push(`type: ${proxyType}`);
    if (proxyType !== 'direct') {
      // direct 出站没有 server/port（mihomo 的 DirectOption 不含这两个键）
      fields.push(`server: ${q(n.server)}`);
      fields.push(`port: ${n.port}`);
    }
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'vmess') {
      fields.push(`cipher: ${q(n.method.length > 0 ? n.method : 'auto')}`);
    }
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'trojan'
      || proxyType === 'hysteria2' || (proxyType !== 'vless' && proxyType !== 'vmess'
        && n.password.length > 0)) {
      // 口令类协议: vless/vmess 用 uuid, 其余(含 tuic/hysteria/socks5/http)用 password
      fields.push(`password: ${q(n.password)}`);
      // hysteria v1 的凭据键在 mihomo 里是 auth-str/auth_str（password 是较新内核的
      // 别名）。与 URI 导入路径（ProxyNode.parseHysteria）保持同一口径：password 与
      // auth-str 一起写，缺一个就可能让内核认不出凭据 → 节点连不上。
      if (proxyType === 'hysteria') {
        fields.push(`auth-str: ${q(n.password)}`);
      }
    }
    if (proxyType === 'ssr') {
      fields.push(`protocol: ${q(n.protocol)}`);
      fields.push(`protocol-param: ${q(n.protocolParam)}`);
      fields.push(`obfs: ${q(n.obfs)}`);
      fields.push(`obfs-param: ${q(n.obfsParam)}`);
    }
    if ((proxyType === 'vless' || proxyType === 'vmess' || proxyType === 'tuic')
      && n.uuid.length > 0) {
      fields.push(`uuid: ${q(n.uuid)}`);
    }
    if (proxyType === 'vmess') {
      fields.push(`alterId: ${n.alterId}`);
    }
    if (n.udp) {
      fields.push('udp: true');
    }
    if (n.network.length > 0) {
      fields.push(`network: ${q(n.network)}`);
    }
    if (n.tls) {
      fields.push('tls: true');
    }
    if (n.servername.length > 0) {
      // hysteria2/hysteria/tuic 的 SNI 键名是 sni（不接受 servername 键）
      fields.push(`${YamlMerger.usesSniKey(proxyType) ? 'sni' : 'servername'}: ${q(n.servername)}`);
    }
    if (n.skipCertVerify) {
      fields.push('skip-cert-verify: true');
    }
    if (n.flow.length > 0) {
      fields.push(`flow: ${q(n.flow)}`);
    }
    if (n.clientFingerprint.length > 0) {
      // uTLS 指纹固定发 client-fingerprint（不要再按协议改写键名）
      fields.push(`client-fingerprint: ${q(n.clientFingerprint)}`);
    }
    if (n.certFingerprint.length > 0) {
      // 证书指纹 pinSHA256 → fingerprint，与上面的 uTLS 指纹是两个独立的键
      fields.push(`fingerprint: ${q(n.certFingerprint)}`);
    }
    if (proxyType === 'hysteria2') {
      if (n.obfs.length > 0) {
        fields.push(`obfs: ${q(n.obfs)}`);
      }
      if (n.obfsParam.length > 0) {
        fields.push(`obfs-password: ${q(n.obfsParam)}`);
      }
      if (n.hyUp.length > 0) {
        fields.push(`up: ${q(n.hyUp)}`);
      }
      if (n.hyDown.length > 0) {
        fields.push(`down: ${q(n.hyDown)}`);
      }
    }
    if (n.alpnList.length > 0 && YamlMerger.supportsAlpn(proxyType)) {
      // alpn 不再只输出给 hysteria2: vless/vmess/trojan/tuic 同样需要 ALPN 协商
      const items: string[] = [];
      for (const it of n.alpnList.split(',')) {
        if (it.length > 0) {
          items.push(q(it));
        }
      }
      if (items.length > 0) {
        fields.push(`alpn: [${items.join(', ')}]`);
      }
    }
    if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) {
      const reality: string[] = [];
      if (n.realityPublicKey.length > 0) {
        reality.push(`public-key: ${q(n.realityPublicKey)}`);
      }
      if (n.realityShortId.length > 0) {
        reality.push(`short-id: ${q(n.realityShortId)}`);
      }
      fields.push(`reality-opts: {${reality.join(', ')}}`);
    }
    if (n.wsPath.length > 0 || n.wsHost.length > 0) {
      const ws: string[] = [];
      if (n.wsPath.length > 0) {
        ws.push(`path: ${q(n.wsPath)}`);
      }
      if (n.wsHost.length > 0) {
        ws.push(`headers: {Host: ${q(n.wsHost)}}`);
      }
      // ws-opts 高级子键（max-early-data 等）从 extras 并回 ws-opts 结构
      for (const pair of ClashConfigGenerator.wsExtraPairs(n.extraOpts)) {
        ws.push(`${pair[0]}: ${pair[1]}`);
      }
      fields.push(`ws-opts: {${ws.join(', ')}}`);
    } else if (n.network === 'ws') {
      // 订阅未提供 ws-opts 的 WS 节点（典型：Cloudflare 隧道，servername 是
      // xxx.trycloudflare.com 而 path/Host 留空）。mihomo 缺 ws-opts 时不会发
      // 正确的 WebSocket Upgrade（无路径/无 Host），CF 直接拒绝 → 测速 503/
      // 连上也不通。主流客户端（Clash Verge/v2rayN）对这类节点默认 path="/"、
      // Host 取 SNI，这里对齐同样语义。仅对 network=ws 生效，不影响
      // grpc/hysteria2/plain tcp 节点；订阅已给出 path/host 时走上面的分支原样保留。
      const ws: string[] = [`path: ${q('/')}`];
      if (n.servername.length > 0) {
        ws.push(`headers: {Host: ${q(n.servername)}}`);
      }
      fields.push(`ws-opts: {${ws.join(', ')}}`);
    }
    if (n.grpcServiceName.length > 0) {
      fields.push(`grpc-opts: {grpc-service-name: ${q(n.grpcServiceName)}}`);
    }
    // extraOpts 中继: 结构化槽位未覆盖的键(plugin/plugin-opts、h2-opts、ports、tfo、
    // mptcp、ip-version、smux、packet-encoding 等, 以及 tuic/hysteria/http/socks5 等
    // 中继协议的专用键)原样回写; 与已输出键重名时以结构化字段为准。
    const emitted = new Set<string>();
    for (const f of fields) {
      const ci = f.indexOf(':');
      if (ci > 0) {
        emitted.add(f.substring(0, ci).trim());
      }
    }
    for (const pair of YamlMerger.parseExtraOpts(n.extraOpts)) {
      const key = pair[0];
      const value = pair[1];
      if (emitted.has(key) || key === 'name' || key === 'type' || key === 'server'
        || key === 'port' || !YamlMerger.isSafeExtraKey(key)) {
        continue;
      }
      if (!ClashConfigGenerator.isSafeText(value)) {
        continue;
      }
      if (value.startsWith('{') || value.startsWith('[')
        || value === 'true' || value === 'false' || /^-?[0-9]+(\.[0-9]+)?$/.test(value)) {
        fields.push(`${key}: ${value}`);
      } else {
        fields.push(`${key}: ${q(value)}`);
      }
      emitted.add(key);
    }
    return `  - {${fields.join(', ')}}`;
  }

  /** 规范化域名列表并去重，忽略无法安全表达的条目。 */
  private static normalizeDomains(values: string[]): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const value of values) {
      const domain = ClashConfigGenerator.normalizeDomain(value);
      if (domain.length > 0 && !seen.has(domain)) {
        seen.add(domain);
        out.push(domain);
      }
    }
    return out;
  }

  /** 规范化并验证 hosts/规则使用的域名，拒绝通配符、换行和 YAML/规则元字符。 */
  private static normalizeDomain(value: string): string {
    let domain = value.trim().toLowerCase();
    while (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    if (domain.length === 0 || domain.length > 253 || domain.includes('\n') || domain.includes('\r')
      || domain.includes(',') || domain.includes(':') || domain.includes('#') || domain.includes('[')
      || domain.includes(']') || domain.includes('{') || domain.includes('}') || domain.includes('*')
      || domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) {
      return '';
    }
    const labels = domain.split('.');
    for (const label of labels) {
      if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
        || !/^[a-z0-9-]+$/.test(label)) {
        return '';
      }
    }
    return domain;
  }

  /** hosts 值仅接受规范 IPv4 或无区域标识的 IPv6 字面量。 */
  private static isValidIpAddress(value: string): boolean {
    if (value.length === 0 || value.includes('\n') || value.includes('\r') || value.includes('%')
      || value.includes('#') || value.includes(',') || value.includes(' ') || value.includes('\t')) {
      return false;
    }
    const ipv4 = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (ipv4 !== null) {
      for (let i = 1; i <= 4; i++) {
        const part = parseInt(ipv4[i]);
        if (part < 0 || part > 255) {
          return false;
        }
      }
      return true;
    }
    if (!/^[0-9a-fA-F:]+$/.test(value) || !value.includes(':')) {
      return false;
    }
    const pieces = value.split(':');
    if (pieces.length < 3 || pieces.length > 8) {
      return false;
    }
    let emptyRuns = 0;
    for (let i = 0; i < pieces.length; i++) {
      const piece = pieces[i];
      if (piece.length === 0) {
        if (i > 0 && pieces[i - 1].length === 0) {
          emptyRuns++;
        }
      } else if (piece.length > 4 || !/^[0-9a-fA-F]+$/.test(piece)) {
        return false;
      }
    }
    return emptyRuns <= 1;
  }

  private static isSafeText(value: string): boolean {
    return value.length <= 64 * 1024 && !value.includes('\n') && !value.includes('\r')
      && !value.includes('\u0000');
  }

  static escapeYaml(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '"') {
        out += '\\"';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (code < 0x20 || code === 0x7f) {
        out += '?';
      } else {
        out += ch;
      }
    }
    return out;
  }

  /** 自定义规则集文件名键（P1-2）：名称已限 [a-zA-Z0-9_-]，这里兜底只留白名单字符 */
  static sanitizeFileKey(name: string): string {
    let out = '';
    for (let i = 0; i < name.length; i++) {
      const ch = name.charAt(i);
      const ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
        || (ch >= '0' && ch <= '9') || ch === '_' || ch === '-';
      if (ok) {
        out += ch;
      }
    }
    return out.length > 0 ? out : 'unnamed';
  }

  /**
   * YAML 可打印白名单净化（用户真机修复 2026-09-18）：
   * mihomo 的 yaml.v3 对 C0 控制符（除 \t\n\r）、0x7F-0x84、0x86-0x9F 一律报
   * "control characters are not allowed"，整份配置拒绝启动。订阅节点里
   * （rawTemplate / ws-opts 原样值 / 历史持久化数据）任何路径漏进来的非法字符
   * 在此统一清洗：制表/游离回车→空格，其余不可打印→'?'。
   * generate() 出口与逐字模板出口双重调用，杜绝"单点遗漏→整机无法连接"。
   *
   * 性能：出口处对整份 150~250KB 配置调用，而绝大多数订阅不含任何控制字符。
   * 先做一遍**零分配**的 charCode 扫描判断是否需要改写，命中才进逐字符拼接循环 ——
   * 干净输入（绝大多数情况）直接原样返回，省掉十几万次单字符字符串拼接，
   * 那才是 ArkTS 主线程上真正贵的那部分。
   * 预扫描判据与下方逐字符分支严格等价：0x09 / 0x0D 会被改写，0x0A 保留，
   * 其余小于 0x20 与 0x7F-0x9F 会被改写。
   */
  static sanitizeControlChars(value: string): string {
    let needsRewrite = false;
    for (let i = 0; i < value.length; i++) {
      const probe = value.charCodeAt(i);
      if (probe === 0x09 || probe === 0x0d || (probe < 0x20 && probe !== 0x0a)
        || (probe >= 0x7f && probe <= 0x9f)) {
        needsRewrite = true;
        break;
      }
    }
    if (!needsRewrite) {
      return value;
    }
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code === 0x09 || code === 0x0d) {
        out += ' ';
      } else if (code === 0x0a || (code >= 0x20 && code <= 0x7e) || code >= 0xa0) {
        out += value.charAt(i);
      } else {
        out += '?';
      }
    }
    return out;
  }

  /** 为端口冲突策略提供本实现使用的端口清单（对应 runtime_port_conflict_policy.dart） */
  static requiredPorts(): number[] {
    return [1053, 7890];
  }
}
