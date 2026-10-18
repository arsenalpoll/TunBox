/**
 * HomePage —— TunBox 主页（严格对齐《TunBox-UI重构笔记》§3.1 首页）
 * 布局：TopNavBar(TunBox + rightSlot 备份/主题) → 天体轨域启动按钮(CelestialPowerOrb 320/280/200，
 *      2026-10-17 用户按 stitch 设计稿重构，原 StatusRing 三层同心环下架；按钮内含当前节点名)
 *      → 代理模式三段按钮(规则/全局/直连，启动按钮下方) → 实时速率与流量卡(RateChart，含公网 IP) → 错误条
 * 2026-10-17：规则模式卡片下架，三项迁入 SettingsPage（用户 batch-2）。
 * 后端：复用 ConnectionOrchestrator / SubscriptionService / SettingsService / LatencyController 全量逻辑（未改动）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { NexusSizes } from '../theme/NexusTokens';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { CelestialPowerOrb } from '../components/CelestialPowerOrb';
import { RateChart } from '../components/RateChart';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { ConnectionEntry } from '../commons/services/ClashApiService';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo, AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { DoHResolver } from '../commons/services/DoHResolver';
import { LatencyController } from '../commons/services/LatencyController';
import { FormStateSync } from '../commons/services/FormStateSync';
import { UiGuardian } from '../commons/services/UiGuardian';
import { DiagnosticsSheet } from '../widgets/DiagnosticsSheet';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeSortSnapshot } from '../commons/services/NodeSortPersistence';
import { BackupRestoreService, RestoreOutcome } from '../commons/services/BackupRestoreService';
import { BackupCrypto } from '../commons/services/BackupCrypto';

const TAG = 'HomePage';
/** 连接卡展开时预览的活跃连接条数（全部连接走「连接管理」） */
const CONN_PREVIEW_MAX = 5;
/** 连接卡预览轮询周期（与 ConnectionsPage 一致） */
const CONN_PREVIEW_POLL_MS = 2000;

/** 配置备份与恢复弹窗（Nexus §9）：导出/导入订阅+自定义规则 JSON */
@CustomDialog
struct BackupDialog {
  controller?: CustomDialogController;
  @State toastMsg: string = '';
  onExport: () => void = () => {};
  onImport: () => void = () => {};
  getToast: () => string = (): string => '';

  aboutToAppear(): void {
    this.toastMsg = '';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_doc'))
          .width(20).height(20)
          .fillColor(TunBoxColors.primary)
        Text('配置备份与恢复').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
        Image($r('app.media.ic_close'))
          .width(16).height(16)
          .fillColor(TunBoxColors.textMuted)
          .padding(6)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }.width('100%')
      Text('备份范围包括当前全部已导入的订阅、节点以及自定义规则配置。')
        .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
      Column({ space: 4 }) {
        Text('📤 导出当前配置备份').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text('生成包含所有订阅和规则的 .json 备份文件，便于多设备同步或留存。')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
        Button('导出备份文件 (.json)')
          .width('100%').borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(12.5)
          .onClick(() => this.onExport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(TunBoxColors.background)
      .borderWidth(1).borderColor(TunBoxColors.cardBorder)
      Column({ space: 4 }) {
        Text('📥 导入恢复配置').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text('上传备份的 .json 配置文件，一键恢复所有订阅及自定义规则。')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
        Button('选择备份文件并恢复')
          .width('100%').borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceCard).fontColor(TunBoxColors.textPrimary).fontSize(12.5)
          .borderWidth(1.5).borderColor(TunBoxColors.cardBorder)
          .onClick(() => this.onImport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(TunBoxColors.background)
      .borderWidth(1).borderColor(TunBoxColors.cardBorder)
      if (this.getToast().length > 0) {
        Text(this.getToast())
          .fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(9999).backgroundColor(TunBoxColors.success)
      }
    }
    .padding(20)
    .borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（行卡片/输入框/按钮）样式保持不动。
  }
}

/**
 * 备份密码输入弹窗（P0-4 收尾）：导出/导入加密备份时收集密码。
 * mode: 'export'（确认导出，可选留空=明文）| 'import'（必填密码解密，失败可重试）
 * 结果通过 onSubmit(password) 回传，取消通过 onCancel() 回传。
 */
@CustomDialog
struct BackupPasswordDialog {
  controller?: CustomDialogController;
  @State mode: string = 'export';
  @State attemptHint: string = '';
  @State password: string = '';
  onSubmit: (password: string) => void = (_password: string) => {};
  onCancel: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_lock')).width(18).height(18).fillColor(TunBoxColors.primary)
        Text(this.mode === 'export' ? '设置备份密码' : '输入备份密码')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
      }.width('100%')
      if (this.mode === 'export') {
        Text('使用 AES-256-GCM 加密备份。留空则导出明文；密码至少 4 个字符，遗忘后无法恢复。')
          .fontSize(11.5).fontColor(TunBoxColors.textMuted).width('100%')
      } else {
        Text(this.attemptHint.length > 0 ? this.attemptHint : '此备份已加密，请输入导出时设置的密码。')
          .fontSize(11.5).fontColor(TunBoxColors.textMuted).width('100%')
      }
      TextInput({ placeholder: this.mode === 'export' ? '密码（留空=明文备份）' : '备份密码', text: this.password })
        .type(InputType.Password)
        .width('100%').height(42).borderRadius(8)
        .fontSize(13)
        .onChange((value: string) => {
          this.password = value;
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1).height(38).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceCard).fontColor(TunBoxColors.textMuted).fontSize(13)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onCancel();
          })
        Button(this.mode === 'export' ? '确认导出' : '解密恢复')
          .layoutWeight(1).height(38).borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
          .onClick(() => {
            if (this.mode === 'import' && this.password.length < 4) {
              this.attemptHint = '密码至少 4 个字符，请重新输入。';
              return;
            }
            const pw = this.password;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onSubmit(pw);
          })
      }.width('100%')
    }
    .padding(20)
    .borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（行卡片/输入框/按钮）样式保持不动。
  }
}

@Component
export struct HomePage {
  @State isConnected: boolean = false;
  @State isConnecting: boolean = false;
  /** 乐观反馈（2026-10-17 用户反馈「点启动 1 秒多按钮才动」）：点击瞬间点亮「正在连接」，
   *  覆盖订阅 hydrate 等待（冷启最多 ~1.5s）与 connect 进入 CONNECTING 前的空窗；
   *  编排器状态翻转后由真实 isConnecting 接管，流程结束（含失败/无节点）即清除 */
  @State pendingStart: boolean = false;
  @State errorMessage: string = '';
  @State publicIp: string = '';
  @State publicIpRefreshing: boolean = false;
  @State publicIpError: string = '';
  @State currentNodeName: string = '';
  @State showDiagnostics: boolean = false;
  @State diagData: AppDiagnostics | null = null;
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  @State upTotal: number = 0;
  @State downTotal: number = 0;
  @State connectionDuration: number = 0;
  @State proxyMode: string = 'rule';
  @State private connCardOpen: boolean = false;
  /** 连接卡预览：活跃连接前 5 条（按流量降序，全部连接走「连接管理」） */
  @State private connPreview: ConnectionEntry[] = [];
  @State private connPreviewReachable: boolean = true;
  private connPreviewTimer: number = -1;
  private connPreviewBusy: boolean = false;
@State ratePoints: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  @State backupToast: string = '';
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('public_ip_revision') @Watch('onPublicIpRevision') publicIpRevision: number = 0;
  @StorageLink('vpn_request_seq') @Watch('onVpnRequest') vpnRequestSeq: number = 0;
  private pageReady: boolean = false;
  /** 宿主（MainPage）「重新展示」通知桥：替代 @Entry 页面的 onPageShow（见 TabLifecycleBridge） */
  shownBridge?: TabLifecycleBridge;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly connectionListener: () => void = (): void => {
    this.applyOrchestratorState();
  };
  private listenerBound: boolean = false;
  private connectionTimer: number = -1;
  private backupDialog: CustomDialogController = new CustomDialogController({
    builder: BackupDialog({
      getToast: (): string => this.backupToast,
      onExport: (): void => {
        this.exportBackup();
      },
      onImport: (): void => {
        this.importBackup();
      }
    }),
    autoCancel: true
  });
  private exportPassword: string = '';
  private exportPending: boolean = false;
  private exportPasswordAsked: boolean = false;
  private importPendingText: string = '';
  private importAttempt: number = 0;
  @State private importDialogMode: string = 'import';
  @State private importHint: string = '';
  private backupPasswordDialog: CustomDialogController = new CustomDialogController({
    builder: BackupPasswordDialog({
      mode: this.importDialogMode,
      attemptHint: this.importHint,
      onSubmit: (password: string): void => {
        if (this.exportPending) {
          this.exportPending = false;
          this.exportPassword = password;
          this.exportBackup();
        } else if (this.importPendingText.length > 0) {
          this.decryptImportedBackup(this.importPendingText, password);
        }
      },
      onCancel: (): void => {
        this.exportPending = false;
        this.exportPassword = '';
        this.importPendingText = '';
      }
    }),
    autoCancel: true
  });

  /** 对导入文本尝试解密：成功→继续导入；失败→重开密码弹窗（最多 3 次） */
  private decryptImportedBackup(text: string, password: string): void {
    const dec = BackupCrypto.decrypt(text, password);
    if (dec.ok) {
      this.importPendingText = '';
      this.importAttempt = 0;
      this.finishImport(dec.text);
      return;
    }
    promptAction.showToast({ message: dec.message });
    this.importAttempt += 1;
    if (this.importAttempt >= 3) {
      this.importAttempt = 0;
      this.importPendingText = '';
      return;
    }
    this.openImportPasswordDialog(text, `密码错误，还可尝试 ${2 - this.importAttempt} 次。`);
  }

  private openImportPasswordDialog(text: string, hint: string): void {
    this.importPendingText = text;
    // BackupPasswordDialog 按 exportPending 判定模式；导入前先确保非导出态
    this.exportPending = false;
    this.importHint = hint;
    this.importDialogMode = 'import';
    this.backupPasswordDialog.open();
  }

  /** 导入结果应用：恢复成功则重载设置并提示 */
  private applyImportOutcome(outcome: RestoreOutcome): void {
    if (outcome.ok) {
      SettingsService.load().then((loaded: AppSettings): void => {
        this.settings = loaded;
        const pm: string = this.settings.proxyMode;
    this.proxyMode = (pm === 'global' || pm === 'direct') ? pm : 'rule';
        this.refreshDisplayNode();
      });
      this.backupToast = `✓ 恢复成功！已导入 ${outcome.subCount} 个订阅及自定义规则`;
      promptAction.showToast({ message: this.backupToast });
    } else {
      promptAction.showToast({ message: outcome.message });
    }
  }

  /** finishImport：解密成功后的导入入口（复用 importBackup 的恢复逻辑） */
  private finishImport(text: string): void {
    BackupRestoreService.importJsonText(text).then((outcome: RestoreOutcome): void => {
      this.applyImportOutcome(outcome);
    }).catch((): void => {
      promptAction.showToast({ message: '导入失败，请重试' });
    });
  }

  aboutToAppear(): void {
    // 作为主页页签内容组件（非 @Entry 页）后：页签「重新展示」由宿主经桥通知，
    // 语义等价于原 onPageShow（从子页返回 / 切回页签时刷新）。
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.refreshForShown(); });
    }
  }

  /** 宿主通知的「重新展示」：执行原 onPageShow 的刷新 */
  refreshForShown(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.stopConnectionTimer();
    this.stopConnPreview();
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    if (this.listenerBound) {
      this.orchestrator.removeListener(this.connectionListener);
      this.listenerBound = false;
    }
  }

  private knownNodeNames(): string[] {
    return this.subs.nodes.map((n: ProxyNode): string => n.name);
  }

  /** 连接卡展开期间的 2s 轮询：活跃连接前 5 条（对齐 ConnectionsPage 排序口径） */
  private async refreshConnPreview(): Promise<void> {
    if (this.connPreviewBusy) {
      return;
    }
    this.connPreviewBusy = true;
    try {
      if (!this.isConnected) {
        this.connPreview = [];
        this.connPreviewReachable = true;
        return;
      }
      const list = await this.orchestrator.api.listConnections(this.knownNodeNames());
      if (list === null) {
        this.connPreviewReachable = false;
        return;
      }
      this.connPreviewReachable = true;
      list.sort((a: ConnectionEntry, b: ConnectionEntry): number =>
        (b.download + b.upload) - (a.download + a.upload));
      this.connPreview = list.slice(0, CONN_PREVIEW_MAX);
    } catch (e) {
      AppLogger.warn('HomePage', `conn preview failed: ${AppLogger.errText(e)}`);
    } finally {
      this.connPreviewBusy = false;
    }
  }

  private startConnPreview(): void {
    if (this.connPreviewTimer >= 0) {
      return;
    }
    this.refreshConnPreview();
    this.connPreviewTimer = setInterval((): void => {
      this.refreshConnPreview();
    }, CONN_PREVIEW_POLL_MS);
  }

  private stopConnPreview(): void {
    if (this.connPreviewTimer >= 0) {
      clearInterval(this.connPreviewTimer);
      this.connPreviewTimer = -1;
    }
  }

  private toggleConnCard(): void {
    this.connCardOpen = !this.connCardOpen;
    if (this.connCardOpen) {
      this.startConnPreview();
    } else {
      this.stopConnPreview();
    }
  }

  private formatConnBytes(total: number): string {
    if (total < 1024) {
      return `${Math.round(total)} B`;
    }
    const kb = total / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  private applyOrchestratorState(): void {
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    // App 内手动连接路径的会话守护：连接成功注册 dataTransfer 连续任务（防杀），
    // 断开/失败释放。幂等，状态重复同步不会重复注册/释放。
    if (this.isConnected && !UiGuardian.isRegistered()) {
      UiGuardian.engage(getContext(this) as Context).catch((): void => {});
    } else if (!this.isConnected && UiGuardian.isRegistered()
      && this.orchestrator.state !== ConnState.CONNECTING
      && this.orchestrator.state !== ConnState.DISCONNECTING
      && this.orchestrator.state !== ConnState.RECOVERING) {
      UiGuardian.release(getContext(this) as Context).catch((): void => {});
    }
    this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
      || this.orchestrator.state === ConnState.DISCONNECTING
      || this.orchestrator.state === ConnState.RECOVERING;
    // miniBar（P1-3a）宿主信号：AppStorage 键供 MainPage 的 @StorageLink 消费
    AppStorage.setOrCreate('mini_conn_connected', this.isConnected);
    AppStorage.setOrCreate('mini_conn_connecting', this.isConnecting);
    AppStorage.setOrCreate('mini_conn_node', this.orchestrator.currentNodeName());
    this.errorMessage = this.orchestrator.lastError;
    this.upSpeed = this.orchestrator.traffic.uploadSpeed;
    this.downSpeed = this.orchestrator.traffic.downloadSpeed;
    this.upTotal = this.orchestrator.traffic.uploadBytes;
    this.downTotal = this.orchestrator.traffic.downloadBytes;
    if (!this.isConnected) {
      this.ratePoints = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    if (this.pageReady) {
      this.syncConnectionTimer();
    }
    this.refreshDisplayNode();
  }

  private syncConnectionTimer(): void {
    if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
      this.connectionDuration = 0;
      this.stopConnectionTimer();
      return;
    }
    this.connectionDuration = Math.max(0,
      Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
    if (this.connectionTimer >= 0) {
      return;
    }
    this.connectionTimer = setInterval(() => {
      if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
        this.connectionDuration = 0;
        this.stopConnectionTimer();
        return;
      }
      this.connectionDuration = Math.max(0,
        Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
      // 速率采样：滑动窗口 26 点，量程 1500KB/s
      const speed = this.orchestrator.traffic.uploadSpeed + this.orchestrator.traffic.downloadSpeed;
      const ratio = Math.min(1, Math.max(0, speed / (1500 * 1024)));
      const next = this.ratePoints.slice();
      next.push(ratio);
      if (next.length > NexusSizes.ratePoints) {
        next.splice(0, next.length - NexusSizes.ratePoints);
      }
      this.ratePoints = next;
      this.upSpeed = this.orchestrator.traffic.uploadSpeed;
      this.downSpeed = this.orchestrator.traffic.downloadSpeed;
      this.upTotal = this.orchestrator.traffic.uploadBytes;
      this.downTotal = this.orchestrator.traffic.downloadBytes;
    }, 1000);
  }

  private stopConnectionTimer(): void {
    if (this.connectionTimer >= 0) {
      clearInterval(this.connectionTimer);
      this.connectionTimer = -1;
    }
  }

  private async toggleTheme(): Promise<void> {
    await ThemeService.toggle();
    const mainWindow = AppStorage.get<window.Window>('main_window');
    if (mainWindow !== undefined) {
      await ThemeService.syncSystemBars(mainWindow);
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    const latencySnapshot = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    if (latencySnapshot !== null) {
      for (const rec of latencySnapshot.records) {
        if (rec.latency !== -2) {
          LatencyController.set(rec.name, rec.latency);
        }
      }
      LatencyController.flushNow();
    }
    const pm: string = this.settings.proxyMode;
    this.proxyMode = (pm === 'global' || pm === 'direct') ? pm : 'rule';
    const authority = await this.orchestrator.authorityState();
    const snapshot = await SettingsService.loadSnapshot();
    if (authority.connected) {
      this.orchestrator.state = ConnState.CONNECTED;
      if (this.orchestrator.startedAt <= 0 && snapshot.startedAt > 0) {
        this.orchestrator.startedAt = snapshot.startedAt;
      }
    }
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.addListener(this.connectionListener);
    }
    if (this.publicIp.length === 0) {
      setTimeout((): void => {
        this.refreshPublicIp().catch((): void => {});
      }, 0);
    }
    // 启动速度预热（2026-10-17）：应用打开、尚未连接时（此刻网络干净、TUN 未建），
    // 后台把当前首选节点及其余订阅节点入口域名的 DoH pin 全部解析好。用户点「启动」
    // 时连接路径上的 DoH 预解析直接全量命中缓存（budget 1.5s 通常瞬间归零），
    // 首连冷缓存最坏 6s 的 DoH 等待被挪到「开应用的空闲时间」。失败静默 ——
    // 预热失败只是回到旧行为（连接时现场解析）。
    if (!this.isConnected && !this.isConnecting) {
      const domains: string[] = [];
      const seenD = new Set<string>();
      for (const n of this.subs.nodes) {
        const s = n.server;
        if (s.length === 0 || s.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(s)) {
          continue;
        }
        const d = s.toLowerCase();
        if (!seenD.has(d)) {
          seenD.add(d);
          domains.push(d);
        }
      }
      if (domains.length > 0) {
        const preferred: ProxyNode | null = this.selectedNode();
        const priority: string[] = (preferred !== null && preferred.server.length > 0
          && !preferred.server.includes(':')
          && !/^\d+\.\d+\.\d+\.\d+$/.test(preferred.server)) ? [preferred.server] : [];
        DoHResolver.resolveMany(domains, 6000, priority)
          .catch((e: Object): void => {
            AppLogger.warn('HomePage', `doh warmup failed: ${AppLogger.errText(e)}`);
          });
      }
    }
    this.applyOrchestratorState();
    this.pageReady = true;
    this.syncConnectionTimer();
    this.consumeVpnRequest();
  }

  onPublicIpRevision(): void {
    if (!this.pageReady || this.publicIpRefreshing) {
      return;
    }
    this.publicIp = '';
    this.refreshPublicIp().catch((): void => {});
  }

  onVpnRequest(): void {
    this.consumeVpnRequest();
  }

  private consumeVpnRequest(): void {
    if (!this.pageReady) {
      return;
    }
    const mode = AppStorage.get<string>('vpn_request_mode') ?? '';
    if (mode.length === 0) {
      return;
    }
    AppStorage.setOrCreate('vpn_request_mode', '');
    // 外部请求（卡片/快捷方式）= 显式用户操作：清除"用户主动停止后台任务"的抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (mode === 'start') {
      this.startConnectionIfNeeded();
    } else if (mode === 'toggle') {
      this.toggleConnection();
    }
  }

  /** 连接入口的订阅就绪等待（冷启动 ~1.4s 内点连接时进程级 hydrate 可能未完成，
   *  提前解析节点会误报「暂无可用节点」；init 进程内记忆化，已加载立即返回） */
  private async awaitSubsReady(): Promise<void> {
    try {
      await this.subs.init(getContext(this) as Context);
    } catch (e) {
      AppLogger.warn(TAG, `subs hydration wait failed: ${AppLogger.errText(e)}`);
    }
  }

  private async startConnectionIfNeeded(): Promise<void> {
    // 显式用户操作（快捷方式 start）：清除长时任务抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (this.isConnecting || this.isConnected || this.pendingStart) {
      return;
    }
    // 乐观反馈同 toggleConnection：快捷方式路径同样不出现无响应空窗
    this.pendingStart = true;
    try {
      await this.awaitSubsReady();
      if (this.isConnecting || this.isConnected) {
        return;
      }
      const node = this.selectedNode();
      if (node === null) {
        promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
        return;
      }
      const ok = await this.orchestrator.connect(node, this.subs);
      if (ok) {
        this.refreshPublicIp();
      }
    } finally {
      this.pendingStart = false;
    }
  }

  private selectedNode(): ProxyNode | null {
    const preferred: ProxyNode | null = this.subs.findNode(this.settings.preferredNodeId);
    if (preferred !== null) {
      return preferred;
    }
    if (this.subs.nodes.length > 0) {
      return this.subs.nodes[0];
    }
    return null;
  }

  private refreshDisplayNode(): void {
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO
      && this.orchestrator.ensureSmartModelReady()) {
      this.currentNodeName = ClashConfigGenerator.SMART_GROUP_NAME;
      return;
    }
    const preferred = this.subs.findNode(this.settings.preferredNodeId);
    if (preferred !== null) {
      this.currentNodeName = preferred.name;
      return;
    }
    if (this.subs.nodes.length > 0) {
      this.currentNodeName = this.subs.nodes[0].name;
      return;
    }
    this.currentNodeName = '';
  }

  /** 实时速率数值与单位拆分（文档 §3.1：数值 26 Bold + 单位 13 textSecondary） */
  private realtimeRateParts(): string[] {
    if (!this.isConnected) {
      return ['0.0', 'KB/s'];
    }
    return this.formatSpeedValue(this.upSpeed + this.downSpeed).split(' ');
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    const kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(1)} MB/s`;
  }

  private formatTotalMB(): string {
    const total = this.upTotal + this.downTotal;
    if (total < 1024) {
      return `${Math.round(total)} B`;
    }
    const kb = total / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  private formatDuration(): string {
    const s = Math.max(0, Math.floor(this.connectionDuration));
    const hh = `0${Math.floor(s / 3600)}`.slice(-2);
    const mm = `0${Math.floor((s % 3600) / 60)}`.slice(-2);
    const ss = `0${s % 60}`.slice(-2);
    return this.connectionDuration > 0 ? `${hh}:${mm}:${ss}` : '--:--:--';
  }

  private refreshDiagnostics(): void {
    this.orchestrator.diagnostics().then((d: AppDiagnostics) => {
      this.diagData = d;
    }).catch(() => {
      this.diagData = null;
    });
  }

  private async refreshPublicIp(): Promise<void> {
    this.publicIpRefreshing = true;
    this.publicIpError = '';
    const info: PublicIpInfo = await PublicIpService.query();
    if (info.ip.length > 0) {
      this.publicIp = info.ip;
    } else {
      this.publicIp = '';
      this.publicIpError = '获取公网 IPv4 失败，点击重试';
    }
    this.publicIpRefreshing = false;
  }

  private async toggleConnection(): Promise<void> {
    // 显式用户操作（电源按钮/卡片 toggle）：清除长时任务抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (this.isConnecting || this.pendingStart) {
      return;
    }
    const context = getContext(this) as Context;
    // 乐观反馈：任何 await 之前先点亮「正在连接」—— 冷启订阅 hydrate 等待
    // （最多 ~1.5s）绝不能变成按钮无响应的空窗
    this.pendingStart = true;
    try {
      await this.awaitSubsReady();
      const node = this.selectedNode();
      const nodeName = node === null ? '' : node.name;
      if (this.isConnected) {
        await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
        await this.orchestrator.disconnect();
        await FormStateSync.publish(context,
          node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName));
        this.refreshPublicIp();
        return;
      }
      if (node === null) {
        await FormStateSync.publish(context, FormStateSync.noNode());
        promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
        return;
      }
      await FormStateSync.publish(context, FormStateSync.connecting(node.name));
      const ok = await this.orchestrator.connect(node, this.subs);
      await FormStateSync.publish(context,
        ok ? FormStateSync.connected(node.name) : FormStateSync.failed(node.name));
      if (ok) {
        this.refreshPublicIp();
      }
    } finally {
      this.pendingStart = false;
    }
  }

  private async applyProxyMode(mode: string): Promise<void> {
    if (mode === this.proxyMode) {
      return;
    }
    this.proxyMode = mode;
    this.settings.proxyMode = mode;
    await SettingsService.save(this.settings);
    const label = mode === 'global' ? '全局模式' : (mode === 'direct' ? '直连模式' : '规则模式');
    await this.orchestrator.applyProxyMode(mode);
    promptAction.showToast({
      message: this.orchestrator.state === ConnState.CONNECTED
        ? `已切换${label}` : `已切换${label}，下次连接生效`
    });
  }

  /** Nexus §9 导出：快照 → JSON → 可选密码加密 → 系统文件选择器另存（用户自选导出位置） */
  private async exportBackup(): Promise<void> {
    try {
      // P0-4：先经密码弹窗收集可选密码（留空=明文），确认后再走文件选择器
      if (!this.exportPasswordAsked) {
        this.exportPasswordAsked = true;
        this.exportPending = true;
        this.importDialogMode = 'export';
        this.importHint = '';
        this.exportPassword = '';
        this.backupPasswordDialog.open();
        return;
      }
      this.exportPasswordAsked = false;
      const password = this.exportPassword;
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [BackupRestoreService.defaultFileName()];
      opts.fileSuffixChoices = ['JSON 备份|.json'];
      const uris = await docPicker.save(opts);
      if (uris.length === 0) {
        return;
      }
      let json = BackupRestoreService.exportJsonWithSettings(this.settings);
      if (password.length >= 4) {
        const enc = BackupCrypto.encrypt(json, password);
        if (!enc.ok) {
          promptAction.showToast({ message: enc.message });
          return;
        }
        json = enc.text;
      }
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, json);
      } finally {
        fs.closeSync(f);
      }
      const slash = uris[0].lastIndexOf('/');
      const savedName = slash >= 0 ? uris[0].substring(slash + 1) : '备份文件';
      this.backupToast = '✓ 备份文件已成功导出！';
      promptAction.showToast({ message: `备份已导出：${savedName}` });
      AppLogger.info(TAG, `backup exported: ${uris[0]}`);
    } catch (e) {
      this.backupToast = '';
      promptAction.showToast({ message: '导出备份失败，请重试' });
      AppLogger.error(TAG, `backup export failed: ${AppLogger.errText(e)}`);
    }
  }

  /** Nexus §9 导入：系统文件选择器挑 .json → 校验恢复 */
  private async importBackup(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.json'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let text = '';
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          promptAction.showToast({ message: '文件大小需在 4MB 以内' });
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
      } finally {
        fs.closeSync(file);
      }
      // 加密备份探测与解密：TunBox-Encrypted 信封 → 密码弹窗（decryptImportedBackup 内可重试 3 次）
      if (BackupCrypto.isEncrypted(text)) {
        this.importAttempt = 0;
        this.openImportPasswordDialog(text, '');
        return;
      }
      const outcome = await BackupRestoreService.importJsonText(text);
      this.applyImportOutcome(outcome);
    } catch (e) {
      AppLogger.warn(TAG, `backup import failed: ${AppLogger.errText(e)}`);
      promptAction.showToast({ message: '导入失败，请重试' });
    }
  }

  /** 代理模式三段按钮（选中=品牌蓝底白字；未选中=白卡描边） */
  @Builder
  ProxyModeButton(mode: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.proxyMode === mode ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.proxyMode === mode ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
      .textAlign(TextAlign.Center)
      .height(40)
      .borderRadius(TunBoxGeometry.pillRadius)
      .backgroundColor(this.proxyMode === mode ? TunBoxColors.primary : TunBoxColors.surfaceCard)
      .border({
        width: 1,
        color: this.proxyMode === mode ? Color.Transparent : TunBoxColors.cardBorder
      })
      .layoutWeight(1)
      .onClick(() => this.applyProxyMode(mode))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层背景列（文档骨架：纯色画布，不再用渐变/玻璃底）；
      // expandSafeArea 仅作用于背景，内容仍布局在安全区内（顶栏不被状态栏遮挡）。
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 1. 顶部导航（文档 §2.1，无返回）：rightSlot 承载既有「备份 / 主题切换」入口 ──
        TopNavBar({ title: 'TunBox' }) {
          Row({ space: 8 }) {
            Row() {
              Text('备份')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(TunBoxColors.textPrimary)
            }
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .borderRadius(TunBoxGeometry.pillRadius)
            .backgroundColor(TunBoxColors.chipBg)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .accessibilityText('打开配置备份与恢复')
            .onClick(() => {
              this.backupToast = '';
              this.backupDialog.open();
            })
            Button() {
              SymbolGlyph($r('sys.symbol.sun_max'))
                .fontSize(20)
                .fontColor([TunBoxColors.textMuted])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .accessibilityText('切换浅色或深色主题')
            .onClick(() => this.toggleTheme())
          }
          .alignItems(VerticalAlign.Center)
        }

        Scroll() {
          Column({ space: 16 }) {
            // ── 2. 天体轨域启动按钮（2026-10-17 用户按 stitch 设计稿「方案一」重构；
            //       节点名放回按钮内部，副标题/状态胶囊按用户要求删除）──
            Column() {
              CelestialPowerOrb({
                isConnected: $isConnected,
                isConnecting: this.isConnecting || this.pendingStart,
                nodeName: this.currentNodeName,
                onToggle: (): void => {
                  this.toggleConnection();
                }
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 4 })

            // ── 代理模式三段按钮：规则/全局/直连（2026-10-17 自分流模式卡片迁出，置于启动按钮下方）──
            Row({ space: 10 }) {
              this.ProxyModeButton('rule', '规则')
              this.ProxyModeButton('global', '全局')
              this.ProxyModeButton('direct', '直连')
            }
            .width('100%')

            // ── 3. 实时速率与流量卡片（文档 §3.1 第 4 节）──
            Column({ space: 12 }) {
              Row() {
                Column({ space: 4 }) {
                  Text('实时速率')
                    .fontSize(12)
                    .fontColor(TunBoxColors.textMuted)
                    .width('100%')
                  Row() {
                    Text(this.realtimeRateParts()[0])
                      .fontSize(26)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(TunBoxColors.textPrimary)
                    Text(` ${this.realtimeRateParts()[1]}`)
                      .fontSize(13)
                      .fontColor(TunBoxColors.textSecondary)
                  }.alignItems(VerticalAlign.Bottom)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                // 2026-10-17 用户要求：公网 IP 与启动按钮保持同一中线 —— 左右两侧
                // 各配一个等宽 flex(1) 列（此处是右侧容器，包住「流量消耗」与
                // 「连接时长」），IP 块在中间自适应宽度，Row 主轴自然居中，
                // IP 的几何中心与卡片（=启动按钮）中线对齐。
                if (this.isConnected) {
                  Column({ space: 4 }) {
                    Text('公网 IP')
                      .fontSize(12)
                      .fontColor(TunBoxColors.textMuted)
                    Row({ space: 4 }) {
                      if (this.publicIpRefreshing) {
                        LoadingProgress().width(12).height(12).color(TunBoxColors.primary)
                      }
                      Text(this.publicIpRefreshing ? '获取中…'
                        : (this.publicIp.length > 0 ? this.publicIp : this.publicIpError))
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.publicIpRefreshing ? TunBoxColors.textMuted
                          : (this.publicIp.length > 0 ? TunBoxColors.textPrimary : TunBoxColors.danger))
                        .fontFamily('monospace')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 180 })
                    }.alignItems(VerticalAlign.Center)
                  }
                  // 2026-10-17 用户要求：公网 IP 与启动按钮保持同一中线 —— 左侧
                  // 「实时速率」与右侧「流量消耗+连接时长」两个 flex(1) 等分剩余
                  // 宽度，中间的 IP 块（自适应宽）天然落在卡片（=页面）中线上；
                  // 不再给 IP 列配重，左右列宽变化也不会让中线偏移。
                  .alignItems(HorizontalAlign.Center)
                  .onClick(() => {
                    if (!this.publicIpRefreshing) {
                      this.refreshPublicIp();
                    }
                  })
                }

                Column() {
                  Row({ space: 20 }) {
                    Column({ space: 4 }) {
                      Text('流量消耗')
                        .fontSize(12)
                        .fontColor(TunBoxColors.textMuted)
                      Text(this.formatTotalMB())
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(TunBoxColors.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }.alignItems(HorizontalAlign.End)
                    Column({ space: 4 }) {
                      Text('连接时长')
                        .fontSize(12)
                        .fontColor(TunBoxColors.textMuted)
                      Text(this.formatDuration())
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(TunBoxColors.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }.alignItems(HorizontalAlign.End)
                  }
                }.layoutWeight(1).alignItems(HorizontalAlign.End)
              }.width('100%').alignItems(VerticalAlign.Top)

              // 速率曲线容器（48 高，2026-10-17 用户要求去掉凹槽框，曲线直接坐在卡片上）
              Stack({ alignContent: Alignment.BottomStart }) {
                RateChart({ points: this.ratePoints, isConnected: this.isConnected })
                Text(`↓ ${this.formatSpeedValue(this.upSpeed)}`)
                  .fontSize(11)
                  .fontColor(TunBoxColors.textSecondary)
                  .margin({ left: 10, bottom: 6 })
              }
              .width('100%')
              .height(48)
              .clip(true)

            }
            .width('100%')
            .padding(TunBoxGeometry.cardPaddingLarge)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })


            // ── 连接卡（2026-10-17 自速率卡下移为独立卡：可收起/展开显示连接信息）──
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                Text('连接')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(TunBoxColors.textPrimary)
                Circle({ width: 6, height: 6 })
                  .fill(this.isConnecting ? TunBoxColors.primary
                    : (this.isConnected ? TunBoxColors.success : TunBoxColors.textMuted))
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(14).height(14)
                  .fillColor(TunBoxColors.textMuted)
                  .rotate({ angle: this.connCardOpen ? 90 : 0 })
                  .animation({ duration: 250, curve: Curve.EaseInOut })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.toggleConnCard(); })

              if (this.connCardOpen) {
                Column({ space: 8 }) {
                  // 活跃连接前 5 条（要看全部走下方「连接管理」）
                  if (this.connPreview.length === 0) {
                    Text(this.isConnected
                      ? (this.connPreviewReachable ? '暂无活跃连接' : '内核无响应，稍后自动重试')
                      : '连接后显示活跃连接')
                      .fontSize(12)
                      .fontColor(TunBoxColors.textMuted)
                      .width('100%')
                  } else {
                    ForEach(this.connPreview, (item: ConnectionEntry) => {
                      Row({ space: 8 }) {
                        Text(item.port > 0 ? `${item.host}:${item.port}` : item.host)
                          .fontSize(12)
                          .fontColor(TunBoxColors.textPrimary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(item.outbound.length > 0 ? item.outbound
                          : (item.rule.length > 0 ? item.rule : item.network))
                          .fontSize(10)
                          .fontColor(TunBoxColors.textMuted)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: 130 })
                        Text(this.formatConnBytes(item.download + item.upload))
                          .fontSize(11)
                          .fontColor(TunBoxColors.textSecondary)
                          .fontFamily('monospace')
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    }, (item: ConnectionEntry) => item.id)
                  }
                  Row() {
                    Blank()
                    Row({ space: 2 }) {
                      Text('连接管理')
                        .fontSize(12)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(TunBoxColors.primary)
                      Image($r('app.media.ic_arrow_right'))
                        .width(12).height(12)
                        .fillColor(TunBoxColors.primary)
                    }
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .backgroundColor(TunBoxColors.primaryLight)
                    .onClick(() => {
                      router.pushUrl({ url: 'pages/ConnectionsPage' });
                    })
                  }.width('100%')
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 错误条（既有功能，令牌化）：点击打开诊断面板 ──
            if (this.errorMessage.length > 0) {
              Row({ space: 6 }) {
                Image($r('app.media.ic_warning'))
                  .width(16).height(16)
                  .fillColor(TunBoxColors.danger)
                Text(this.errorMessage)
                  .fontSize(12)
                  .fontColor(TunBoxColors.danger)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .borderRadius(TunBoxGeometry.cardRadius)
              .backgroundColor(TunBoxColors.dangerLight)
              .onClick(() => {
                this.showDiagnostics = true;
                this.refreshDiagnostics();
              })
            }

          }
          .width('100%')
          // 页签页底部为悬浮 Dock 留白（TunBoxGeometry.dockClearance = 96，契约硬性规则）
          .padding({
            left: TunBoxGeometry.pagePadding,
            right: TunBoxGeometry.pagePadding,
            bottom: TunBoxGeometry.dockClearance
          })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      // 诊断面板（既有实现不动，仅蒙层色改令牌）
      if (this.showDiagnostics) {
        Column() {
          Blank()
          DiagnosticsSheet({
            diag: this.diagData,
            onRefresh: () => {
              this.refreshDiagnostics();
            },
            onClose: () => { this.showDiagnostics = false; }
          })
            .height('78%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor(TunBoxColors.scrim)
        .onClick(() => { this.showDiagnostics = false; })
      }
    }
    .width('100%')
    .height('100%')
  }
}