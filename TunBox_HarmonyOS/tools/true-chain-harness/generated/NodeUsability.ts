// [harness] generated from entry/src/main/ets/commons/subscription/NodeUsability.ets — 仅 import 目标被重写
/**
 * 节点可用性判定与原因分类（Node Usability）
 *
 * ## 为什么要它
 *
 * 订阅导入层有两类**完全不同**的「节点不可用」，过去被混成一句话「失败」，
 * 导致用户完全不知道该找谁：
 *
 * | 类别 | 含义 | 谁的问题 | 用户该做什么 |
 * |---|---|---|---|
 * | **定义不完整** | 解析层丢了参数（缺 uuid / 缺 REALITY 公钥 / 缺 password…） | **我们**（解析层 bug） | 换订阅源 / 报 bug；节点绝不能进内核代理表 |
 * | **域名无法解析** | 定义完全正确，但服务器域名在公网 DNS 上查不到 | **机场/线路** | 找机场换入口域名或换订阅 |
 *
 * 真机 2026-10-20 的 mitce 34 节点事件正是第二类：
 * `de152710bb8b70d108ec13c7.mitce-nocontact.com` 在阿里/腾讯/Cloudflare/Google
 * 四个解析器上全部 NXDOMAIN，而节点参数（uuid/flow/client-fingerprint/
 * reality-opts.public-key/short-id/tls/servername）**全部正确**。
 * 这种节点进内核代理表只会批量制造 mihomo 503（"An error occurred in the delay test"），
 * 让人误以为是"TunBox 解析坏了"。
 *
 * ## 本文件的口径
 *
 * - `definition` 轴：**定义层**是否完整（由参数表 + 必填校验给出）。
 * - `dns` 轴：**运行层**域名是否解析得到（由上层做 DNS 预检后回填）。
 * - 两轴**独立**：`definition=ok` 且 `dns=nxdomain` 的节点是「定义完整但线路死了」，
 *   它与「定义不完整」必须给出**不同的文案**，不能混成"失败"。
 * - 定义不完整的节点**绝不进内核代理表、不进测速集合**（半条节点 = 批量 503），
 *   但**必须在 UI 可见并带原因**（见 docs/sub-parse.md 第 4 节）。
 *
 * ## ArkTS 纪律
 *
 * 不用 enum（Node 侧 type-stripping 测试台不吃），一律 `export class` + `static readonly`；
 * 不 import 任何 kit（纯逻辑，可在 Node 侧直接跑）。
 */
import { ProtocolParamTableRegistry } from './ProtocolParamTable.ts';

/** 不可用原因分类 */
export class UnusableCategory {
  /** 可用 */
  static readonly OK: string = 'ok';
  /** 定义不完整：缺必填参数（参数问题 —— 我们的问题） */
  static readonly INCOMPLETE: string = 'incomplete';
  /** 域名无法解析：定义完整但域名查不到（机场/线路问题 —— 不是我们的问题） */
  static readonly DNS: string = 'dns';
}

/** DNS 解析状态 */
export class DnsState {
  /** 未探测 */
  static readonly UNKNOWN: string = 'unknown';
  /** 解析成功 */
  static readonly RESOLVED: string = 'resolved';
  /** 权威 NXDOMAIN：域名不存在（机场下线/线路废弃） */
  static readonly NXDOMAIN: string = 'nxdomain';
  /** 解析不到但不是权威 NXDOMAIN（DoH 不可用/超时/被污染） */
  static readonly UNRESOLVED: string = 'unresolved';
}

/** 单个节点的可用性结论 */
export class NodeAvailability {
  /** 原因分类（UnusableCategory） */
  category: string = UnusableCategory.OK;
  /** DNS 状态（DnsState） */
  dns: string = DnsState.UNKNOWN;
  /** 缺失的必填键（规范键名） */
  missing: string[] = [];
  /** 节点地址（域名），供上层做 DNS 预检 */
  server: string = '';
  /** 协议 */
  protocol: string = '';
  /** 一句话原因（中文，UI 直接展示） */
  reason: string = '';
  /** 补充说明（中文，UI 直接展示） */
  detail: string = '';

  /**
   * 定义是否完整 —— **唯一**决定"能不能进内核代理表 / 测速集合"的维度。
   *
   * 只有 INCOMPLETE（缺必填参数）才是 false：那种节点进内核只会批量制造 503。
   * DNS 类结论不影响入表（节点定义是对的，只是这次域名没解析出来）。
   */
  defined(): boolean {
    return this.category !== UnusableCategory.INCOMPLETE;
  }

  /**
   * 是否可用（可进代理表/测速集合）。
   *
   * = 定义完整即可用。**DNS 结论不参与判定** —— 域名查不到是运行层的结论，
   * 不能反过来把定义正确的节点踢出代理表（那会让"机场域名下线"变成
   * "TunBox 把节点删了"）。它只影响 UI 上的原因文案。
   */
  usable(): boolean {
    return this.defined();
  }
}

/** 节点可用性判定 */
export class NodeUsability {
  /**
   * 定义层判定：按参数表检查必填键。
   *
   * @param protocol 规范协议名（vless/vmess/trojan/ss/ssr/hysteria2/tuic/anytls/snell/http/socks）
   * @param params 规范键 → 值（两条导入路径产出的都是同一套规范键）
   * @param server 节点地址（域名或 IP），写入结论供上层做 DNS 预检
   */
  static assess(protocol: string, params: Map<string, string>, server: string): NodeAvailability {
    const out = new NodeAvailability();
    out.protocol = protocol;
    out.server = server;
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      // 未知协议：不在表里就没有必填口径，按"可用"处理（由上游按 unsupported 分类）。
      // ⚠ 绝不能因为"表里没有"就判不可用 —— 那会把所有新协议批量干掉。
      out.category = UnusableCategory.OK;
      out.reason = '';
      return out;
    }
    const missing: string[] = [];
    for (const spec of table.specs) {
      if (!spec.required) {
        continue;
      }
      const v = params.get(spec.key);
      if (v === undefined || v.length === 0) {
        missing.push(spec.key);
      }
    }
    // 条件必填（如 vless 的 security=reality ⇒ reality-public-key）
    for (const spec of table.specs) {
      if (spec.required || spec.requiredWhen.length === 0) {
        continue;
      }
      if (!ProtocolParamTableRegistry.isRequired(protocol, spec.key, params)) {
        continue;
      }
      const v = params.get(spec.key);
      if (v === undefined || v.length === 0) {
        missing.push(spec.key);
      }
    }
    if (missing.length > 0) {
      out.category = UnusableCategory.INCOMPLETE;
      out.missing = missing;
      out.reason = NodeUsability.incompleteReason(protocol, missing);
      out.detail = '定义不完整：解析层没能取到必填参数（我们的问题，需换订阅源或反馈）。'
        + '该节点不会进入内核代理表，也不会参与测速。';
    }
    return out;
  }

  /**
   * 回填 DNS 状态并重算文案。
   *
   * 只在**定义完整**的节点上改分类：定义不完整的节点保持 INCOMPLETE
   * （那才是我们的问题，DNS 结论会把真正的原因盖掉）。
   */
  static withDns(availability: NodeAvailability, dnsState: string): NodeAvailability {
    if (availability.category !== UnusableCategory.OK) {
      return availability;
    }
    availability.dns = dnsState;
    if (dnsState === DnsState.NXDOMAIN) {
      availability.category = UnusableCategory.DNS;
      availability.reason = NodeUsability.dnsReason(availability.server);
      availability.detail = '节点定义完全正确，但服务器域名在公网 DNS 上已查不到'
        + '（机场侧入口域名下线或线路废弃，不是 TunBox 的问题）。'
        + '请找机场确认入口域名或更换订阅。';
    } else if (dnsState === DnsState.UNRESOLVED) {
      availability.category = UnusableCategory.DNS;
      availability.reason = NodeUsability.dnsReason(availability.server);
      availability.detail = '节点定义完全正确，但本次探测没能解析到服务器域名'
        + '（可能是 DNS 出口受限或临时抖动，不一定是机场的问题）。';
    }
    return availability;
  }

  /** 「定义不完整」文案 */
  static incompleteReason(protocol: string, missing: string[]): string {
    return `定义不完整：${protocol} 缺少必填参数 ${missing.join('、')}`;
  }

  /** 「域名无法解析」文案 */
  static dnsReason(server: string): string {
    const host = server.length > 0 ? server : '(空)';
    return `域名无法解析：${host} 在公网 DNS 上查不到`;
  }

  /** 汇总文案（给 UI 的"这批节点"提示用） */
  static summary(availability: NodeAvailability): string {
    if (availability.category === UnusableCategory.INCOMPLETE) {
      return `${availability.reason}（共缺 ${availability.missing.length} 项）`;
    }
    if (availability.category === UnusableCategory.DNS) {
      return availability.reason;
    }
    return '';
  }
}
