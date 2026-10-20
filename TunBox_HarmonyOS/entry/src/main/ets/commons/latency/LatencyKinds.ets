/**
 * 测速**分类表**与**探测结果类型**（零 import 的纯模块）。
 *
 * 为什么单独成文件（而不是留在 `LatencyProbe.ets` 里）：
 *
 *  1. **判定语义只有一份**：失败分类常量、**唯一判定表** `isNonVerdictKind`
 *     （哪些分类不算「节点结论」）、派生视图 `isVerdictKind`、陈旧判定 `isStale`
 *     都在这里。测速内核（`LatencyProbe.ets`）、测速引擎（`LatencyEngine.ets`）、
 *     结论落盘仓（`LatencyStore.ets`）与 UI 策略层（`LatencyState.ets`）都从这里取
 *     ⇒ 引擎不再自带一套失败映射（旧的 `mapFailure` 已删），恢复路径也不再自带
 *     一份反表（旧的 `LatencyPolicy.isNonVerdictKind` 待转调）。
 *  2. **扁平暂存闸门能跑**：Node 行为闸门把 `commons/services/*.ets` **扁平暂存**
 *     成沙箱再 import，任何 `../latency/*` 的**值**依赖都会因「那一层目录不存在」
 *     让整个闸门 ERR_MODULE_NOT_FOUND 崩掉 ⇒ services 侧能值依赖的必须是
 *     **零 import** 的模块（与 `LatencyDnsVerdict.ets` 同理）。本文件不 import
 *     任何东西 ⇒ 闸门只需多暂存它一个文件。
 *
 * 外部 import 路径保持稳定：`LatencyProbe.ets` 再导出本文件的两个类，
 * 既有调用方（`ClashApiService.ets` 等）不需要改路径。
 */

/**
 * 失败分类（单一表）。
 *
 * 判定类（**写进**结论、参与排序与组级聚合）= 判定表取反后剩下的：
 *  - 实测出延迟（''）
 *  - timeout（节点真超时）
 *  - network_unreachable（节点走不通，有 dial 证据）
 *  - switch_failed（节点不在内核表里 —— 配置类结论，渲染为「未生效」而非红色失败）
 *  - dns_unresolved（域名已下线 —— 该换机场/换订阅，不是换线路）
 *
 * 非判定类（**绝不**写进结论，沿用上一次有效结论）= 判定表本体：
 *  - core_not_ready（通道/凭证坏了 —— 这是「我们」的问题，不是节点的问题）
 *  - unknown（认不出来 —— 宁可什么都不写，也不冤枉节点）
 *  - queue_timeout / untested / cancelled / unsupported / port_reachable_only
 */
export class LatencyProbeKind {
  /** 无失败（测出了延迟） */
  static readonly NONE: string = '';
  /** 节点真超时（内核 504 / 我们自己的超时） */
  static readonly TIMEOUT: string = 'timeout';
  /** 节点不在内核代理表里（内核 404）→ 配置类结论「未生效」 */
  static readonly SWITCH_FAILED: string = 'switch_failed';
  /** 测速通道/凭证层面坏了（401/403/传输层异常）→ **非判定** */
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  /** 节点走不通（内核 503，体内有 dial 类错误） */
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  /**
   * 域名无法解析（**我们自己的 DNS 预检**判定，优先于内核的 503）。
   *
   * 2026-10-20 真机实测（多解析器：阿里/Cloudflare/Google/腾讯）：那批全败节点的
   * 服务器域名四个解析器**全部 NXDOMAIN**；仓库 2026-10-19 真机取证同结论。
   * ⇒ 失败发生在**域名解析**这一步，既不是拨号失败也不是超时。
   *
   * ⚠ mihomo 的 503 body 是**通用句**（"An error occurred in the delay test"），
   * **看不到 DNS 原因** ⇒ 必须靠我们自己的 DoH 预解析先判定
   * （日志里当天明确是 `DoH pinned 0/135` / `test-core proxy hosts: 0/135`）。
   */
  static readonly DNS_UNRESOLVED: string = 'dns_unresolved';
  /** 认不出来的失败 → **非判定**（宁可什么都不写，也不冤枉节点） */
  static readonly UNKNOWN: string = 'unknown';
  /** 排队超时（根本没拨号）→ **非判定** */
  static readonly QUEUE_TIMEOUT: string = 'queue_timeout';
  /** 整批硬截止，本次没测出来 → **非判定** */
  static readonly UNTESTED: string = 'untested';
  /** 客户端主动取消 → **非判定** */
  static readonly CANCELLED: string = 'cancelled';
  /** 协议无法离线探测 → **非判定** */
  static readonly UNSUPPORTED: string = 'unsupported';
  /** 只证明端口可达（直连降级）→ **非判定** */
  static readonly PORT_ONLY: string = 'port_reachable_only';

  /**
   * **唯一判定表**：哪些失败分类**不构成**节点结论。
   *
   * ⚠ 这张表是**唯一**的判定真源（2026-10-20 lead 拍板：正表/反表不得并存 ⇒
   * 删掉旧的正表，只留这张反表；live 路径需要的「是不是结论」由它**派生**）。
   *
   * 非判定 = **这次失败不构成「这个节点通不通」的结论**：
   *  - core_not_ready  测速通道/凭证坏了（是我们的问题，不是节点的问题）
   *  - queue_timeout   根本没拨号（没排上队）
   *  - untested        整批硬截止，本次没测出来
   *  - cancelled       客户端主动取消
   *  - unsupported     协议无法离线探测
   *  - port_reachable_only 只证明端口可达（直连降级）
   *  - unknown         认不出来的失败（宁可什么都不写，也不冤枉节点）
   *
   * ⚠ **空串（''）不在本表里**：'' = 没有失败（实测出了延迟）⇒ 它**是**结论。
   * 「空分类 = 旧版记账残留 ⇒ 恢复时按未测处理」是**恢复路径**的规则，
   * 不是判定表的一部分。
   */
  static isNonVerdictKind(kind: string): boolean {
    return kind === LatencyProbeKind.CORE_NOT_READY
      || kind === LatencyProbeKind.QUEUE_TIMEOUT
      || kind === LatencyProbeKind.UNTESTED
      || kind === LatencyProbeKind.CANCELLED
      || kind === LatencyProbeKind.UNSUPPORTED
      || kind === LatencyProbeKind.PORT_ONLY
      || kind === LatencyProbeKind.UNKNOWN;
  }

  /**
   * 派生视图（**不是第二张表**）：这个分类是不是**节点结论**（可盖章：参与排序、
   * 进组级聚合）。
   *
   * 判定权全部来自 {@link isNonVerdictKind} 这一张表；这里只做两件事：
   *  1. 空串（''）= 实测出了延迟 ⇒ 是结论；
   *  2. 其它一切 ⇒ 取反那张表。
   *
   * ⚠ 内核（LatencyProbe）与引擎（LatencyEngine）都用它决定要不要落记录
   * （引擎不再自带一套 publishable/notPublishable 语义）。
   */
  static isVerdictKind(kind: string): boolean {
    if (kind === LatencyProbeKind.NONE) {
      return true;
    }
    return !LatencyProbeKind.isNonVerdictKind(kind);
  }

  /**
   * 结论的 TTL：超过即视为陈旧（UI 灰显但保留）。
   *
   * ⚠ 这是**唯一**的阈值定义（2026-10-20 lead 拍板：阈值只能一份）。
   */
  static readonly STALE_MS: number = 10 * 60 * 1000;

  /**
   * **唯一**的「陈旧」判定表。
   *
   * 语义：
   *  1. 有时间戳（testedAtMs > 0）：`nowMs - testedAtMs > STALE_MS` ⇒ 陈旧；
   *  2. 年龄未知（testedAtMs <= 0）：
   *     - **失败结论** ⇒ 算陈旧（不知道多久以前的失败，绝不能当成本次刚测出来的
   *       结论顶在列表上 —— 2026-10-20 真机「刚打开软件就显示一颗红『超时』」的防线）；
   *     - 非失败结论（有值但年龄未知）⇒ 不算（无法判断，不标「·旧」）。
   */
  static isStale(testedAtMs: number, nowMs: number, isFailure: boolean): boolean {
    if (testedAtMs <= 0) {
      return isFailure;
    }
    return (nowMs - testedAtMs) > LatencyProbeKind.STALE_MS;
  }

  /**
   * 这个分类是不是**超时档**（UI 归到「超时」而不是「失败」）。
   *
   * ⚠ `queue_timeout`（没排上队）也算超时档：它与真超时同为「没测出延迟」，
   * 但**独立计数**（`LatencyProgress.queueTimeout`）—— UI/持久化据此把
   * 「节点不通」与「没排上队」分开。
   */
  static isTimeoutKind(kind: string): boolean {
    return kind === LatencyProbeKind.TIMEOUT || kind === LatencyProbeKind.QUEUE_TIMEOUT;
  }
}

/** 一次探测的结果 */
export class LatencyProbeResult {
  /** 节点名 */
  nodeName: string = '';
  /** 延迟毫秒；>=1 = 实测；-1 = 失败；-2 = 未测 */
  delayMs: number = -1;
  /** 失败分类（LatencyProbeKind.*；'' = 无失败） */
  failKind: string = LatencyProbeKind.NONE;
  /** HTTP 状态码（0 = 传输层失败/中止） */
  httpCode: number = 0;
  /** 是否构成节点结论（非判定类失败 = false） */
  isVerdict: boolean = false;
  /** 失败细节（含完整响应体） */
  detail: string = '';
  /** **完整**响应体（不截断；日志里才截断） */
  bodyText: string = '';
  /** 本次探测耗时（ms） */
  elapsedMs: number = 0;
}
