/**
 * 数据模型：应用设置
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/app_settings.dart
 * 字段与 upstream 保持一致；鸿蒙端持久化由 SettingsService（@ohos.data.preferences）承担。
 */
import { NodeSortModes } from '../services/NodeSortPersistence';
import { AppRoutingCustomApp, AppRoutingPolicy } from '../services/AppRoutingPolicy';

/** 自动选点模式（第二阶段新增，语义同 NodeSortModes 风格） */
export class AutoSelectModes {
  /** 手动：使用用户在上一次连接/偏好中固定的节点（默认） */
  static readonly MANUAL: string = 'manual';
  /** 自动：按 SmartSelector 评分自动选点，失败达阈值时自动切换 */
  static readonly AUTO: string = 'auto';

  /** 归一化任意输入为合法模式，未知/缺省值一律回退 MANUAL */
  static normalize(mode: string | undefined): string {
    if (mode === AutoSelectModes.AUTO) {
      return AutoSelectModes.AUTO;
    }
    return AutoSelectModes.MANUAL;
  }
}

/** 整数夹取：缺失/非法（非有限数）取默认值，越界夹到 [min,max] */
function clampInt(v: number, def: number, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    return def;
  }
  const i = Math.floor(v);
  if (i < min) {
    return min;
  }
  if (i > max) {
    return max;
  }
  return i;
}

/** 自定义远程规则集条目（P1-2，对标 iOS 六家 RULE-SET/rule-provider 能力） */
export class CustomRuleSet {
  /** 规则集键（YAML provider 名），[a-z0-9_-]，生成器加 rs- 前缀防与内置冲突 */
  name: string = '';
  /** 远程 URL（https） */
  url: string = '';
  /** mihomo behavior: domain / ipcidr / classical */
  behavior: string = 'domain';
  /** 文件格式: yaml / text / mrs */
  format: string = 'yaml';
  /** 命中后策略: DIRECT / PROXY / REJECT */
  policy: string = 'REJECT';
  /** 自动更新间隔秒（最小 3600） */
  interval: number = 86400;
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class AppSettingsJson {
  themeMode: number = 0;
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  includedApps: string[] = [];
  /** 缺失值必须保持 undefined，不能让默认 all 遮蔽旧数据迁移。 */
  appRoutingMode: string | undefined = undefined;
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  forceProxySites: string[] = [];
  forceDirectSites: string[] = [];
  /**
   * 强制拦截网站（P0-3 DNS 层 REJECT 预匹配）：生成 `nameserver-policy` 的
   * `rcode://refused` 条目 + 路由层 DOMAIN-SUFFIX,site,REJECT，广告/追踪域名
   * 在 DNS 层就被拒绝（不建立连接、不发出明文 QNAME），比仅路由层 REJECT
   * 少一次完整连接尝试。旧配置缺失时为空数组（行为不变）。
   */
  forceBlockSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default' 订阅默认顺序 / 'auto' 按最近测速结果 / 'manual' 用户手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照（JSON: NodeSortSnapshot），无测速数据为空串 */
  nodeSortSnapshot: string = '';
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）；旧配置缺失时为空串。 */
  proxyGroupSelections: string = '';
  // ── 第二阶段新增（旧版本配置缺这些字段时由 fromJson 取默认值） ──
  /** 网络类型变化时是否自动重连 */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用连续失败自动切换节点 */
  failoverEnabled: boolean = true;
  /** 触发切换的连续失败阈值（1..10） */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数（0..3600） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，用户固定） / 'auto'（按评分自动选点） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复 */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数（0..3） */
  healthRepairMaxSteps: number = 2;
  rulesEnabled: boolean = true;
  /**
   * HyperADRules 去广告规则集开关。**默认关闭**，由用户在「规则」页自行打开。
   *
   * 关闭原因（2026 起）：全局模式下部分国内应用商店（华文应用商店等）会因去广告
   * 规则命中而加载失败 —— 商店首页/详情页聚合接口常与广告域名共用同一 CDN 或
   * 同一证书，去广告 REJECT 会连带打断正常业务请求。
   */
  hyperAdRulesEnabled: boolean = false;
  customRules: string[] = [];
  /**
   * 用户自定义远程规则集（P1-2）：生成 rule-providers + RULE-SET 规则。
   * 上限 20 条、单条 URL 512 字符（对标 Surge External Resources 的限额思路）。
   * 旧配置缺失时为空数组（行为不变）。
   */
  customRuleSets: CustomRuleSet[] = [];
  /**
   * YAML 覆盖层（P2，对标 Stash JS Override 的无脚本形态）：用户 YAML 原文追加在
   * 生成配置尾部，重复键后者覆盖前者。生成器侧 validateYamlOverride 白名单拦截
   * rules/proxies/proxy-groups/external-controller/secret/tun 六键。上限 8KB。
   * 旧配置缺失时为空串（行为不变）。
   */
  yamlOverride: string = '';
  /**
   * 「双轨」原始订阅 provider（实验开关，默认关闭）：
   * true = 除解析链外，另把每个订阅的**原文**落盘并在生成的 Mihomo 配置里以
   * `proxy-providers: {type: file}` 交给内核自己解析；false = 行为与现状完全一致。
   * 旧版本配置缺此字段时取默认 false。
   */
  useRawProviderConfig: boolean = false;
  /** 内核 smart 组 policy-priority（见 AppSettings.smartPolicyPriority）；旧配置缺失时为空串。 */
  smartPolicyPriority: string = '';
  /**
   * 域名嗅探（sniffer）：从 TLS ClientHello / HTTP Host / QUIC 握手里还原真实目标域名。
   * fake-ip 模式下 DNS 应答是 198.18.x.x，若不嗅探，DOMAIN 规则只能靠内核反查 fake-ip
   * 映射命中，TLS SNI 与 DNS 不一致的场景（CDN / 直连 IP 访问）会分错流。默认开启，
   * 与 Clash Verge / FlClash 等主流客户端一致。旧版本配置缺字段时取默认 true。
   */
  sniffingEnabled: boolean = true;
  /** 内核日志级别（log-level）：debug/info/warning/error/silent；默认 warning（现状）。 */
  coreLogLevel: string = 'warning';
  /**
   * 订阅配额提醒（流量不足/即将到期发系统通知）。默认开启。
   * 阈值常量见 SubscriptionQuotaService：流量剩 <10% 或 3 天内到期。
   */
  quotaNotifyEnabled: boolean = true;
  /**
   * geo 资产下载源偏好（geoip.metadb / Model.bin / 去广告 MRS）：
   * auto=实测可达性默认序 / jsdelivr=CDN 优先 / ghproxy=加速前缀优先 / github=官方直链优先。
   * 偏好源排在候选表最前，失败仍按余下顺序回退；非法值回落 auto。
   */
  assetSource: string = 'auto';
  /** 配额提醒"当天已提醒"标记（JSON）；由 SubscriptionQuotaService 读写。 */
  quotaAlertMarks: string = '';
}

export class AppSettings {
  /** 跟随系统 / 暗色 / 亮色 */
  themeMode: number = 0; // 0=system, 1=dark, 2=light
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  /** 两份名单独立保留，只有 appRoutingMode 选中的一份参与运行。 */
  includedApps: string[] = [];
  appRoutingMode: string = 'all';
  /** 旧版双名单冲突/非法数据必须由 UI 保存确认，普通设置保存不得清除。 */
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  forceProxySites: string[] = [];
  /** 强制直连网站（始终 DIRECT, 不走代理） */
  forceDirectSites: string[] = [];
  /** 强制拦截网站（DNS 层 REJECT 预匹配，详见 AppSettingsJson.forceBlockSites 注释） */
  forceBlockSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  /** 代理模式：rule = 规则 / global = 全局（对应 upstream settings.proxyMode） */
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default'=订阅默认顺序, 'auto'=按最近测速结果, 'manual'=手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照序列化（NodeSortSnapshot JSON），无则空串。随设置一起落盘，
   *  使测速排序结果在退出页面/重启应用后仍然保持，直到用户重新测速才覆盖。 */
  nodeSortSnapshot: string = '';

  // ── 第二阶段新增设置 ────────────────────────────────────────────────
  /** 网络类型变化（含 none→有网恢复）时，若用户意图为已连接则自动退避重连。默认 true */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用「连续失败→自动切换节点」。默认 true */
  failoverEnabled: boolean = true;
  /** 触发自动切换的连续失败阈值，范围 1..10，默认 3 */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数，范围 0..3600，默认 60（冷却期内禁止再次切换，防切换风暴） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，维持用户固定节点）/ 'auto'（按 SmartSelector 评分自动选点并允许切换） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复。默认 true */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数，范围 0..3，默认 2 */
  healthRepairMaxSteps: number = 2;
  /** 是否启用规则功能；关闭后不生成广告规则和自定义规则。 */
  rulesEnabled: boolean = true;
  /**
   * HyperADRules 去广告规则集开关，默认 **false**（由用户在「规则」页自行打开）。
   *
   * 曾默认开启，但全局代理下会导致国内应用商店（华文应用商店等）加载失败 ——
   * 商店聚合接口与广告域名共用 CDN/证书，去广告 REJECT 会误伤正常业务请求。
   * 改为默认关闭，需要去广告的用户手动开启即可。
   * 已显式保存过 true/false 的老用户不受影响（fromJson 只在字段缺失时取默认值）。
   */
  hyperAdRulesEnabled: boolean = false;
  customRules: string[] = [];
  /** 用户自定义远程规则集（P1-2；见 AppSettingsJson.customRuleSets 注释） */
  customRuleSets: CustomRuleSet[] = [];
  /** YAML 覆盖层（P2）：追加在生成配置尾部的用户 YAML 片段（上限 8KB，白名单在生成器） */
  yamlOverride: string = '';
  /** 双轨原始订阅 provider 开关（默认关闭；见 AppSettings.useRawProviderConfig） */
  useRawProviderConfig: boolean = false;
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）。 */
  proxyGroupSelections: string = '';
  /**
   * 内核 smart 组的 `policy-priority`：按**节点名**给权重因子，格式 `模式:因子;模式:因子`。
   *
   * 这是 lux5am/mihomo-smart 独有的 fork 能力（mainline mihomo 没有 smart 组，更没有这个键）。
   * 语义见 `adapter/outboundgroup/smart.go`：因子**大于** LightGBM 评分的排序优先级 ——
   * 只要两个节点的因子不同，就按因子降序排，分数再高也翻不过来（`smart.go:580`）。
   * 模式支持子串匹配（默认）或正则；**首个命中的规则生效**；因子必须为正数，非法规则内核
   * 只告警并跳过，不会导致启动失败，所以坏配置是安全的。
   *
   * 默认空串 = 不生成该键，排序完全交给 LightGBM（与之前行为一致）。
   */
  smartPolicyPriority: string = '';
  /** 域名嗅探开关（默认 true；见 AppSettingsJson.sniffingEnabled 注释） */
  sniffingEnabled: boolean = true;
  /** 内核日志级别：debug/info/warning/error/silent（默认 warning = 现状行为） */
  coreLogLevel: string = 'warning';
  /** 订阅配额提醒开关（默认 true；阈值见 SubscriptionQuotaService） */
  quotaNotifyEnabled: boolean = true;
  /** geo 资产下载源偏好：auto/jsdelivr/ghproxy/github（非法回落 auto） */
  assetSource: string = 'auto';
  /**
   * 配额提醒"当天已提醒"标记（JSON：dedupeKey → dayKey）。
   * 由 SubscriptionQuotaService 读写；UI 不展示。旧标记 30 天后自动清理。
   */
  quotaAlertMarks: string = '';

  toJson(): AppSettingsJson {
    const j = new AppSettingsJson();
    j.themeMode = this.themeMode;
    j.autoConnectOnBoot = this.autoConnectOnBoot;
    j.bypassDomesticApps = this.bypassDomesticApps;
    j.excludedApps = this.excludedApps;
    j.includedApps = this.includedApps;
    j.appRoutingMode = this.appRoutingMode;
    j.appRoutingNeedsReview = this.appRoutingNeedsReview;
    j.appRoutingCustomApps = this.appRoutingCustomApps;
    j.forceProxySites = this.forceProxySites;
    j.forceDirectSites = this.forceDirectSites;
    j.forceBlockSites = this.forceBlockSites;
    j.preferredNodeId = this.preferredNodeId;
    j.preferredNodeSubscriptionId = this.preferredNodeSubscriptionId;
    j.autoUpdateSubscription = this.autoUpdateSubscription;
    j.selectedSubscriptionId = this.selectedSubscriptionId;
    j.testLatencyUrl = this.testLatencyUrl;
    j.proxyMode = this.proxyMode;
    j.nodeSortMode = this.nodeSortMode;
    j.nodeSortSnapshot = this.nodeSortSnapshot;
    j.proxyGroupSelections = this.proxyGroupSelections;
    j.autoReconnectOnNetworkChange = this.autoReconnectOnNetworkChange;
    j.failoverEnabled = this.failoverEnabled;
    j.failoverFailureThreshold = this.failoverFailureThreshold;
    j.failoverCooldownSec = this.failoverCooldownSec;
    j.autoSelectMode = this.autoSelectMode;
    j.healthCheckEnabled = this.healthCheckEnabled;
    j.healthRepairMaxSteps = this.healthRepairMaxSteps;
    j.rulesEnabled = this.rulesEnabled;
    j.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    j.customRules = this.customRules;
    j.customRuleSets = this.customRuleSets;
    j.yamlOverride = this.yamlOverride;
    j.useRawProviderConfig = this.useRawProviderConfig;
    j.smartPolicyPriority = this.smartPolicyPriority;
    j.sniffingEnabled = this.sniffingEnabled;
    j.coreLogLevel = this.coreLogLevel;
    j.quotaNotifyEnabled = this.quotaNotifyEnabled;
    j.assetSource = this.assetSource;
    j.quotaAlertMarks = this.quotaAlertMarks;
    return j;
  }

  static fromJson(j: AppSettingsJson): AppSettings {
    const s = new AppSettings();
    s.themeMode = j.themeMode === 1 || j.themeMode === 2 ? j.themeMode : 0;
    s.autoConnectOnBoot = typeof j.autoConnectOnBoot === 'boolean' ? j.autoConnectOnBoot : true;
    s.bypassDomesticApps = typeof j.bypassDomesticApps === 'boolean' ? j.bypassDomesticApps : true;
    // 不能 filter 无效项：丢掉仅代理名单会扩大接管，丢掉绕过名单会改变用户边界。
    s.excludedApps = Array.isArray(j.excludedApps) ? AppRoutingPolicy.normalizePackages(j.excludedApps)
      : (j.excludedApps === undefined ? [] : ['[无效名单] ' + String(j.excludedApps)]);
    s.includedApps = Array.isArray(j.includedApps) ? AppRoutingPolicy.normalizePackages(j.includedApps)
      : (j.includedApps === undefined ? [] : ['[无效名单] ' + String(j.includedApps)]);
    const legacyRouting = j.appRoutingMode === undefined;
    s.appRoutingMode = legacyRouting ? AppRoutingPolicy.legacyMode(s.includedApps, s.excludedApps)
      : (typeof j.appRoutingMode === 'string' ? j.appRoutingMode : 'invalid');
    s.appRoutingNeedsReview = j.appRoutingNeedsReview === true ||
      (j.appRoutingNeedsReview !== undefined && typeof j.appRoutingNeedsReview !== 'boolean') ||
      (legacyRouting && s.includedApps.length > 0 && s.excludedApps.length > 0);
    if (AppRoutingPolicy.validationError(s.appRoutingMode, s.includedApps, s.excludedApps, false).length > 0) {
      s.appRoutingNeedsReview = true;
    }
    if (Array.isArray(j.appRoutingCustomApps)) {
      for (const item of j.appRoutingCustomApps) {
        if (item === null || typeof item !== 'object') {
          s.appRoutingNeedsReview = true;
          continue;
        }
        const custom = new AppRoutingCustomApp();
        custom.bundleName = typeof item.bundleName === 'string' ? item.bundleName.trim() : '[无效包名]';
        custom.label = typeof item.label === 'string' ? item.label.trim() : '';
        s.appRoutingCustomApps.push(custom);
      }
    }
    s.forceProxySites = Array.isArray(j.forceProxySites)
      ? j.forceProxySites.filter((v: string) => typeof v === 'string') : [];
    s.forceDirectSites = Array.isArray(j.forceDirectSites)
      ? j.forceDirectSites.filter((v: string) => typeof v === 'string') : [];
    s.forceBlockSites = Array.isArray(j.forceBlockSites)
      ? j.forceBlockSites.filter((v: string) => typeof v === 'string') : [];
    s.preferredNodeId = typeof j.preferredNodeId === 'string' ? j.preferredNodeId : '';
    s.preferredNodeSubscriptionId = typeof j.preferredNodeSubscriptionId === 'string'
      ? j.preferredNodeSubscriptionId : '';
    s.autoUpdateSubscription = typeof j.autoUpdateSubscription === 'boolean' ? j.autoUpdateSubscription : true;
    s.selectedSubscriptionId = typeof j.selectedSubscriptionId === 'string' ? j.selectedSubscriptionId : '';
    s.testLatencyUrl = typeof j.testLatencyUrl === 'string' && j.testLatencyUrl.length > 0
      ? j.testLatencyUrl : 'https://www.gstatic.com/generate_204';
    s.proxyMode = j.proxyMode === 'global' ? 'global' : 'rule';
    s.nodeSortMode = NodeSortModes.normalize(j.nodeSortMode);
    s.nodeSortSnapshot = typeof j.nodeSortSnapshot === 'string' ? j.nodeSortSnapshot : '';
    s.proxyGroupSelections = typeof j.proxyGroupSelections === 'string' ? j.proxyGroupSelections : '';
    // 旧版本配置缺字段 → 取默认值；非法值 → 回落/夹取（加载不炸、保存幂等）
    s.autoReconnectOnNetworkChange = typeof j.autoReconnectOnNetworkChange === 'boolean'
      ? j.autoReconnectOnNetworkChange : true;
    s.failoverEnabled = typeof j.failoverEnabled === 'boolean' ? j.failoverEnabled : true;
    s.failoverFailureThreshold = clampInt(j.failoverFailureThreshold, 3, 1, 10);
    s.failoverCooldownSec = clampInt(j.failoverCooldownSec, 60, 0, 3600);
    s.autoSelectMode = AutoSelectModes.normalize(j.autoSelectMode);
    s.healthCheckEnabled = typeof j.healthCheckEnabled === 'boolean' ? j.healthCheckEnabled : true;
    s.healthRepairMaxSteps = clampInt(j.healthRepairMaxSteps, 2, 0, 3);
    s.rulesEnabled = typeof j.rulesEnabled === 'boolean' ? j.rulesEnabled : true;
    // 去广告规则默认关闭：字段缺失（用户从未设置过）→ false。
    // 老用户显式存过的 true/false 原样恢复，不会被这次改默认值覆盖。
    s.hyperAdRulesEnabled = typeof j.hyperAdRulesEnabled === 'boolean' ? j.hyperAdRulesEnabled : false;
    s.customRules = Array.isArray(j.customRules)
      ? j.customRules.filter((v: string) => typeof v === 'string').slice(0, 500) : [];
    // 自定义规则集（P1-2）：逐条规范化（名称/URL/behavior/format/policy/interval），
    // 上限 20 条；非法项跳过（加载不炸、保存幂等），合法性细则在生成器校验。
    s.customRuleSets = Array.isArray(j.customRuleSets)
      ? AppSettings.normalizeRuleSets(j.customRuleSets) : [];
    // YAML 覆盖层（P2）：缺字段/非字符串回落空串；上限 8KB，合法性（顶层键白名单）
    // 在生成器 validateYamlOverride 判定，不合法的覆盖层不追加（行为与旧版一致）。
    s.yamlOverride = typeof j.yamlOverride === 'string' ? j.yamlOverride.slice(0, 8192) : '';
    // 双轨 provider 开关：缺字段/脏值一律回落 false（默认关闭 = 可一键回退的安全默认）
    s.useRawProviderConfig = typeof j.useRawProviderConfig === 'boolean' ? j.useRawProviderConfig : false;
    // policy-priority：缺字段/非字符串回落空串（=不生成该键，行为与旧版一致）。
    // 长度上限防止脏配置把生成的 YAML 撑爆；合法性（pattern:factor）交给内核判定，
    // 内核遇到非法规则只告警跳过，不会启动失败。
    s.smartPolicyPriority = typeof j.smartPolicyPriority === 'string'
      ? j.smartPolicyPriority.slice(0, 2000) : '';
    // 域名嗅探：缺字段取默认 true（对齐主流客户端）；显式 false 才关闭。
    s.sniffingEnabled = j.sniffingEnabled === false ? false : true;
    // 日志级别：仅接受白名单值，其余回落 warning（现状行为），防止脏值写进 YAML。
    const level = typeof j.coreLogLevel === 'string' ? j.coreLogLevel.trim().toLowerCase() : '';
    s.coreLogLevel = (level === 'debug' || level === 'info' || level === 'warning'
      || level === 'error' || level === 'silent') ? level : 'warning';
    s.quotaNotifyEnabled = j.quotaNotifyEnabled === false ? false : true;
    const source = typeof j.assetSource === 'string' ? j.assetSource.trim().toLowerCase() : '';
    s.assetSource = (source === 'jsdelivr' || source === 'ghproxy' || source === 'github')
      ? source : 'auto';
    s.quotaAlertMarks = typeof j.quotaAlertMarks === 'string'
      ? j.quotaAlertMarks.slice(0, 128 * 1024) : '';
    return s;
  }

  /**
   * 自定义规则集规范化（P1-2）：名称限 [a-zA-Z0-9_-]（≤48 字符）、URL 必须 https 且 ≤512、
   * behavior/format/policy 白名单、interval 夹取 [3600, 604800]；重名保留首条。
   * 无效条目跳过（加载不炸、保存幂等）。上限 20 条（对标 Surge External Resources 限额思路）。
   */
  static normalizeRuleSets(values: CustomRuleSet[]): CustomRuleSet[] {
    const out: CustomRuleSet[] = [];
    for (const raw of values) {
      if (raw === null || typeof raw !== 'object') {
        continue;
      }
      const entry = new CustomRuleSet();
      entry.name = typeof raw.name === 'string' ? raw.name.trim() : '';
      entry.url = typeof raw.url === 'string' ? raw.url.trim() : '';
      const behavior = typeof raw.behavior === 'string' ? raw.behavior.trim().toLowerCase() : '';
      entry.behavior = (behavior === 'domain' || behavior === 'ipcidr' || behavior === 'classical')
        ? behavior : 'domain';
      const format = typeof raw.format === 'string' ? raw.format.trim().toLowerCase() : '';
      entry.format = (format === 'yaml' || format === 'text' || format === 'mrs') ? format : 'yaml';
      const policy = typeof raw.policy === 'string' ? raw.policy.trim().toUpperCase() : '';
      entry.policy = (policy === 'DIRECT' || policy === 'PROXY' || policy === 'REJECT') ? policy : 'REJECT';
      let interval = typeof raw.interval === 'number' && Number.isFinite(raw.interval) ? raw.interval : 86400;
      if (interval < 3600) {
        interval = 3600;
      }
      if (interval > 604800) {
        interval = 604800;
      }
      entry.interval = Math.floor(interval);
      const nameOk = /^[a-zA-Z0-9_-]{1,48}$/.test(entry.name);
      const urlOk = entry.url.startsWith('https://') && entry.url.length <= 512;
      if (!nameOk || !urlOk) {
        continue;
      }
      const key = entry.name.toLowerCase();
      let dup = false;
      for (const existing of out) {
        if (existing.name.toLowerCase() === key) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      out.push(entry);
      if (out.length >= 20) {
        break;
      }
    }
    return out;
  }
}
