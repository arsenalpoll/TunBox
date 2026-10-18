/**
 * TunBox UI 设计令牌 —— 严格对齐《TunBox-UI重构笔记》§1《设计系统与主题规范》
 * （文档来源：EdgeEver 笔记 TunBox-UI重构，2026-10-17）
 *
 * 文档 §1.1 给出的是浅色原值，逐字落在这里；深色按用户 2026-10-17 提供的
 * 《深色主题配色方案》逐值落地：底 #0A0E1A→#0F131D 渐变 / 卡 #141C2E / 微光描边
 * rgba(255,255,255,0.08) / 凹槽 #0C1220 / 高亮蓝 #3B82F6（浅亮态 #60A5FA）/
 * 荧光绿 #10B981 / 文字 #F8FAFC·#94A3B8·#64748B / Dock rgba(17,24,39,0.85)。
 * 浅色背景同为渐变：#F4F6FB → #EBF1FD。
 *
 * 全部以静态 getter 暴露，调用点写法与文档示例一致（TunBoxColors.primary / surfaceCard …），
 * 深浅切换在渲染时即时解析（页面持有 @StorageLink('theme_revision') 即重渲染）。
 */
import { ThemeService } from './ThemeService';
import { LatencyRecord, LatencyPolicy, LatencyState } from '../commons/services/LatencyState';

/**
 * 页面级动效参数（2026-10-17 用户规格：水平滑动 + 淡入淡出，时长 220–300ms，
 * 位移取屏宽 4%–8%；新页沿水平方向轻进入，旧页同步退出）。页签切换与路由推入式子页共用同一套。
 */
export class TunBoxMotion {
  /** 转场时长（ms） */
  static readonly ms: number = 260;
  /** 转场位移：百分比字符串用于路由页（相对页宽），vp 数值用于页签（本机 800vp 宽 → 48vp ≈ 6%） */
  static readonly slidePercent: string = '6%';
  static readonly slideVp: number = 48;
  /** 转场曲线 */
  static readonly curve: Curve = Curve.Friction;
}

export class TunBoxColors {
  // ── 品牌与强调色（文档原值；深浅共用同一强调色，深色仅次级色阶提亮）──
  static get primary(): ResourceColor {
    // 深色为高亮蓝 #3B82F6（用户深色规范），浅色保持鸿蒙官方品牌蓝 #0A59F7
    return ThemeService.isDark() ? '#3B82F6' : '#0A59F7';
  }

  static get primaryHover(): ResourceColor {
    return ThemeService.isDark() ? '#60A5FA' : '#0047D4';
  }

  /** 弱化胶囊背景（primaryLight） */
  static get primaryLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.20)' : '#EFF4FF';
  }

  static get primaryBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.42)' : '#D0E1FD';
  }

  // ── 语义状态色 ──
  static get success(): ResourceColor {
    // 深色为荧光绿 #10B981（用户深色规范）
    return ThemeService.isDark() ? '#10B981' : '#00BA66';
  }

  static get successLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.15)' : '#E8FAF0';
  }

  /** 智能优选卡专用：浅绿底 / 浅绿描边（文档 §3.2 内核智能优选条目） */
  static get successTint(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.10)' : '#F1FBF5';
  }

  static get successBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.34)' : '#C8F2D7';
  }

  static get warning(): ResourceColor {
    return ThemeService.isDark() ? '#FF9F33' : '#FF8800';
  }

  static get danger(): ResourceColor {
    return ThemeService.isDark() ? '#FF5A5F' : '#FA2A2D';
  }

  static get dangerLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(250, 42, 45, 0.16)' : '#FEECEE';
  }

  // ── 背景与表面 ──
  /** 页面底色的平色回退（渐变终点色）；页面根容器请统一用 bgGradientStart/End 渐变 */
  static get background(): ResourceColor {
    return ThemeService.isDark() ? '#0F131D' : '#F4F6FB';
  }

  /** 系统全局大背景渐变：浅色 #F4F6FB → #EBF1FD；深色 #0A0E1A → #0F131D（用户 2026-10-17 规范） */
  static get bgGradientStart(): ResourceColor {
    return ThemeService.isDark() ? '#0A0E1A' : '#F4F6FB';
  }

  static get bgGradientEnd(): ResourceColor {
    return ThemeService.isDark() ? '#0F131D' : '#EBF1FD';
  }

  /** 卡片表面：浅色=纯白高光卡片（2026-10-17 用户浅色规范「核心卡片容器 #FFFFFF」+ 1px #E5EDF8 内描边）。
   *  2026-10-17 性能修正：不再逐卡挂 blur（30+ 离屏模糊层拖慢切页/滚动），玻璃感靠半透明填充+渐变底；Dock/弹层等背后有滚动内容的组件才保留 blur */
  static get surfaceCard(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(20, 28, 46, 0.78)' : '#FFFFFF';
  }

  /** 次级凹槽底色：浅色对齐用户规范「#F0F4FC 或 #EDF2FA」 */
  static get surfaceSubtle(): ResourceColor {
    return ThemeService.isDark() ? '#232A35' : '#F0F4FC';
  }

  /** 微光内描边：深色 1px rgba(255,255,255,0.08)（用户规范），浅色 #E5EDF8 */
  static get cardBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : '#E5EDF8';
  }

  // ── 排版 ──
  static get textPrimary(): ResourceColor {
    return ThemeService.isDark() ? '#F8FAFC' : '#111827';
  }

  static get textSecondary(): ResourceColor {
    return ThemeService.isDark() ? '#94A3B8' : '#4B5563';
  }

  static get textMuted(): ResourceColor {
    return ThemeService.isDark() ? '#64748B' : '#9CA3AF';
  }

  static get textOnPrimary(): ResourceColor {
    return '#FFFFFF';
  }

  // ── 文档未逐字给出的控件底色（同设计语言派生，供分段器/标签/代码容器复用）──
  /** 分段器轨道（文档 §3.1 智能/全局 #EDF2FA） */
  static get controlTrack(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#EDF2FA';
  }

  /** 三段模式条轨道（文档 §3.3 #E9EFF9） */
  static get controlTrackSoft(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#E9EFF9';
  }

  /** 分段器选中块（文档：纯白） */
  static get controlThumb(): ResourceColor {
    return ThemeService.isDark() ? '#3A4453' : '#FFFFFF';
  }

  /** 协议/类型标签底（文档 §3.2 #EFF3F9 / §3.3 #EEF2F8 / §3.5 #EFF4FD） */
  static get chipBg(): ResourceColor {
    return ThemeService.isDark() ? '#2A323F' : '#EFF3F9';
  }

  /** 弹窗内选项行底（文档 §3.4 #F8FAFD） */
  static get rowFill(): ResourceColor {
    return ThemeService.isDark() ? '#232A35' : '#F8FAFD';
  }

  /** 代码/等宽容器底与描边（文档 §3.6 #F8FAFC / #E2E8F0） */
  static get codeBg(): ResourceColor {
    return ThemeService.isDark() ? '#151A22' : '#F8FAFC';
  }

  static get codeBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : '#E2E8F0';
  }

  static get codeText(): ResourceColor {
    return ThemeService.isDark() ? '#D7DEE8' : '#1E293B';
  }

  /** 速率曲线容器底（文档 §3.1 #F0F4FC） */
  static get chartBox(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#F0F4FC';
  }

  // ── 顶部导航栏 / 底部悬浮毛玻璃栏（文档 §2.1 / §2.2）──
  static get navFill(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(18, 21, 28, 0.90)' : 'rgba(244, 246, 251, 0.90)';
  }

  static get dockFill(): ResourceColor {
    // 2026-10-17 用户要求「底部菜单栏整体实现全透明」：底栏不再有着色层，
    // 只保留 backdropBlur(24) 磨砂模糊 + 细描边/投影维持悬浮轮廓，
    // 背后滚动的内容与渐变底直接透出（深浅主题一致）。
    return Color.Transparent;
  }

  static get dockEdge(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.14)' : 'rgba(255, 255, 255, 0.60)';
  }

  static get dockShadow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.60)' : 'rgba(10, 89, 247, 0.08)';
  }

  static get dockIconInactive(): ResourceColor {
    return ThemeService.isDark() ? '#64748B' : '#9CA3AF';
  }

  /** 底栏点击瞬间光亮（用户 2026-10-17 要求「点哪个位置出现瞬间的光亮」）：亮帧满透明度呈现，靠 280ms 淡出收尾 */
  static get dockGlow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.50)' : 'rgba(10, 89, 247, 0.30)';
  }

  /** 弹窗蒙层（文档 §3.4 rgba(15, 23, 42, 0.35)） */
  static get scrim(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.55)' : 'rgba(15, 23, 42, 0.35)';
  }
}

/** 文档 §1.2 圆角与间距规范 */
export class TunBoxGeometry {
  /** 页面水平外边距 16vp */
  static readonly pagePadding: number = 16;
  /** 卡片曲率 20~24vp（标准卡 22 / 次级卡 20 / 大卡 26） */
  static readonly cardRadius: number = 22;
  static readonly cardRadiusSmall: number = 20;
  static readonly cardRadiusLarge: number = 26;
  /** 胶囊/小组件圆角 100vp（Full Pill） */
  static readonly pillRadius: number = 100;
  /** 控件圆角 14vp（按钮/输入框） */
  static readonly controlRadius: number = 14;
  /** 列表间距 12vp */
  static readonly listGap: number = 12;
  /** 卡片内边距 16~20vp */
  static readonly cardPadding: number = 16;
  static readonly cardPaddingLarge: number = 18;
  /** 顶部导航栏高 56vp */
  static readonly navHeight: number = 56;
  /** 底部悬浮栏：64 高 / 32 圆角 / 下边距 20（文档 §2.2） */
  static readonly dockHeight: number = 64;
  static readonly dockRadius: number = 32;
  static readonly dockBottomMargin: number = 20;
  /** 页面底部为悬浮栏留白（栏高 + 下边距 + 余量） */
  static readonly dockClearance: number = 96;
  /** 首页「天体轨域」启动按钮（CelestialPowerOrb，2026-10-17 设计稿规格）：
   *  最外呼吸光晕 320 / 点阵轨道 280 / 渐变轨环(弧线) 260 / 核心亚克力盘 200 */
  static readonly orbGlow: number = 320;
  static readonly orbTrack: number = 280;
  static readonly orbArcRing: number = 260;
  static readonly orbDisc: number = 200;
}

/**
 * 节点延迟的文案与配色。
 *
 * 颜色角色取自文档（绿=极速 / 橙=偏高 / 红=拦截或错误），阈值与失败语义沿用本仓库
 * 既有产品决策（UiTokens.LatencyStyle）：<300ms 绿 / 300~800ms 橙 / ≥800ms 红；
 * 自动/静默批的失败显示中性「未测」（用户明确诉求），只有用户手测失败标红。
 */
export class TunBoxPing {
  static readonly TIMEOUT_MS: number = 65535;

  static isTimeout(latencyMs: number | null): boolean {
    return latencyMs !== null && (latencyMs <= 0 || latencyMs >= TunBoxPing.TIMEOUT_MS);
  }

  static color(latencyMs: number | null): ResourceColor {
    if (latencyMs === null) {
      return TunBoxColors.textMuted;
    }
    if (TunBoxPing.isTimeout(latencyMs)) {
      return TunBoxColors.danger;
    }
    if (latencyMs < 300) {
      return TunBoxColors.success;
    }
    if (latencyMs < 800) {
      return TunBoxColors.warning;
    }
    return TunBoxColors.danger;
  }

  static text(latencyMs: number | null): string {
    if (latencyMs === null) {
      return '--';
    }
    if (TunBoxPing.isTimeout(latencyMs)) {
      return '超时';
    }
    return `${latencyMs}ms`;
  }

  /** 状态化文案（五态可区分；auto 失败=未测，manual 失败=超时/失败） */
  static recordText(rec: LatencyRecord | null, nowMs: number): string {
    if (rec === null) {
      return '--';
    }
    if (rec.hasValue()) {
      const body = `${rec.delayMs}ms`;
      if (rec.state === LatencyState.OFFLINE) {
        return `≈${body}`;
      }
      return LatencyPolicy.isStale(rec, nowMs) ? `${body}·旧` : body;
    }
    if (rec.isFailure() && rec.source === 'auto') {
      return '未测';
    }
    return LatencyPolicy.stateText(rec.state);
  }

  /** 状态化配色（文档色角色：实测走阈值；过期/未测中性；用户手测失败红） */
  static recordColor(rec: LatencyRecord | null, nowMs: number): ResourceColor {
    if (rec === null) {
      return TunBoxColors.textMuted;
    }
    if (rec.hasValue()) {
      if (LatencyPolicy.isStale(rec, nowMs)) {
        return TunBoxColors.textSecondary;
      }
      return TunBoxPing.color(rec.delayMs);
    }
    if (rec.isFailure() && rec.source === 'auto') {
      return TunBoxColors.textMuted;
    }
    if (rec.state === LatencyState.TIMEOUT || rec.state === LatencyState.FAILED) {
      return TunBoxColors.danger;
    }
    return TunBoxColors.textMuted;
  }
}
