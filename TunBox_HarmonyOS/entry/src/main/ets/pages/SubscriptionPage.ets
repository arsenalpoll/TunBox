/**
 * SubscriptionPage —— 订阅与节点页（严格对齐《TunBox-UI重构笔记》§3.2）
 * 布局：TopNav(单列/双列切换 · 刷新全部 · 添加订阅) → 全局概览卡 → 内核智能优选条目
 *       → 折叠式订阅分组（展开后显示该订阅下的节点并单选；2026-10-17 用户要求去掉全量节点区）
 * 后端：复用 SubscriptionService / SettingsService / LatencyController / BackgroundLatencyService 全量逻辑。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { BusinessError } from '@kit.BasicServicesKit';
import { TunBoxColors, TunBoxGeometry, TunBoxPing } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { SubscriptionService, DIRECT_GROUP_ID } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { ProxyNode } from '../commons/models/ProxyNode';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { AppLogger } from '../commons/utils/AppLogger';
import { LatencyController } from '../commons/services/LatencyController';
import { NodeProtocolPolicy } from '../commons/services/NodeSortPersistence';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshItemOutcome
} from '../commons/services/ConcurrentRefresh';

const TAG = 'SubscriptionPage';

/** “+”导入三选一弹窗（扫描 / URL / 文件），对齐 HTML import-overlay */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @State mode: string = 'main';
  @State urlText: string = '';
  onScan: () => void = () => {};
  onUrl: (url: string) => void = () => {};
  onFile: () => void = () => {};

  aboutToAppear(): void {
    this.mode = 'main';
  }

  @Builder
  OptionBtn(icon: string, title: string, desc: string, bg: ResourceColor, fg: ResourceColor, target: string) {
    Row({ space: 14 }) {
      Text(icon).fontSize(20).fontColor(fg)
        .width(40).height(40).textAlign(TextAlign.Center)
        .borderRadius(10).backgroundColor(bg)
      Column({ space: 1 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text(desc).fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(12)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderWidth(1).borderColor(TunBoxColors.cardBorder)
    .onClick(() => {
      this.mode = target;
    })
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(this.mode === 'main' ? '导入订阅' : (this.mode === 'scan' ? '扫码导入' : (this.mode === 'url' ? '从 URL 链接导入' : '从本地文件导入')))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
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

      if (this.mode === 'main') {
        this.OptionBtn('☷', '扫描', '扫描屏幕或纸质二维码导入订阅',
          TunBoxColors.successLight, TunBoxColors.success, 'scan')
        this.OptionBtn('🔗', 'URL', '输入或粘贴订阅链接一键解析',
          TunBoxColors.primaryLight, TunBoxColors.primary, 'url')
        this.OptionBtn('📄', '文件', '选择本地 .yaml / .json / .conf 配置文件',
          'rgba(245, 158, 11, 0.12)', TunBoxColors.warning, 'file')
      } else if (this.mode === 'scan') {
        Column() {
          Text('[ 摄像头：请在系统扫码页对准二维码 ]')
            .fontSize(12).fontColor(TunBoxColors.success)
            .width('100%').textAlign(TextAlign.Center)
            .padding(30).borderRadius(10)
            .backgroundColor('#0f172a')
            .borderWidth(1).borderColor('rgba(16, 185, 129, 0.50)')
        }.width('100%')
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('开始扫码').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onScan();
            })
        }.width('100%').margin({ top: 2 })
      } else if (this.mode === 'url') {
        Text('输入订阅链接（节点链接可一行一个批量导入）：').fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
        TextArea({ placeholder: 'https://... 或 vless://...（一行一个）', text: this.urlText })
          .onChange((v: string) => { this.urlText = v; })
          .height(88).borderRadius(8).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('确认导入').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onUrl(this.urlText);
            })
        }.width('100%').margin({ top: 2 })
      } else {
        Column({ space: 2 }) {
          Text('选择本地 Clash / V2Ray 配置文件').fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(TunBoxColors.textPrimary).width('100%').textAlign(TextAlign.Center)
          Text('支持 .yaml、.json、.conf 格式').fontSize(11).fontColor(TunBoxColors.textMuted)
            .width('100%').textAlign(TextAlign.Center)
        }.width('100%').padding(16).borderRadius(8)
        .borderWidth(1.5).borderColor(TunBoxColors.cardBorder)
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('选择文件').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onFile();
            })
        }.width('100%').margin({ top: 2 })
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

@CustomDialog
struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('确认删除').fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Text('删除后将无法恢复，确定要删除吗？')
        .fontSize(13).fontColor(TunBoxColors.textMuted).textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.danger).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }.width('100%')
    }
    .padding(24).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（按钮）样式保持不动。
  }
}

/**
 * 长按节点后的单节点删除确认框。
 * 语义与 NodeSelectionPage.NodeDeleteDialog 一致：删除 = 移出节点表并记入隐藏清单，
 * 后续订阅刷新自动过滤，被删节点不会"复活"。
 */
@CustomDialog
struct NodeDeleteConfirmDialog {
  controller?: CustomDialogController;
  getNodeName: () => string = (): string => '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('删除节点').fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Text(`确定删除「${this.getNodeName()}」吗？该节点在订阅刷新后不会再出现。`)
        .fontSize(13).fontColor(TunBoxColors.textMuted).textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.danger).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }.width('100%')
    }
    .padding(24).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（按钮）样式保持不动。
  }
}

@CustomDialog
struct EditSubscriptionDialog {
  controller?: CustomDialogController;
  @State editName: string = '';
  @State editUrl: string = '';
  @State isLocal: boolean = false;
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  getIsLocal: () => boolean = () => false;
  onConfirm: (name: string, url: string) => void = () => {};

  aboutToAppear(): void {
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
    this.isLocal = this.getIsLocal();
  }

  build() {
    Column({ space: 14 }) {
      Text('编辑订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      TextInput({ placeholder: '订阅名称', text: this.editName })
        .onChange((v: string) => { this.editName = v; })
        .height(40).borderRadius(8).fontSize(13)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderWidth(1).borderColor(TunBoxColors.cardBorder)
        .fontColor(TunBoxColors.textPrimary)
      if (!this.isLocal) {
        TextInput({ placeholder: '订阅链接', text: this.editUrl })
          .onChange((v: string) => { this.editUrl = v; })
          .height(40).borderRadius(8).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
      } else {
        Text('本地导入的订阅仅支持改名')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl);
          })
      }.width('100%')
    }
    .padding(20).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（输入框/按钮）样式保持不动。
  }
}

@Component
export struct SubscriptionPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 宿主（MainPage）「重新展示」通知桥：替代 @Entry 页面的 onPageShow（见 TabLifecycleBridge） */
  shownBridge?: TabLifecycleBridge;
  @State subs: Subscription[] = [];
  @State expandedIds: string[] = [];
  @State activeSubId: string = '';
  @State activeNodeId: string = '';
  /** 自动选点模式（manual 手动固定 / auto 内核 smart 优选），与设置页同一份持久化 */
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  /** 节点排布列数（1=单列 2=双列），用户在订阅分组展开区手动切换，选择持久化 */
  @State nodeColumns: number = 1;
  @State latencyTick: number = 0;
  @State isAdding: boolean = false;
  @State isRefreshing: boolean = false;
  @State refreshingIds: string[] = [];
  /** 分组头闪电测速按钮的防重入（对齐 refreshingIds 语义） */
  @State speedTestingIds: string[] = [];
  @State isImporting: boolean = false;
  @State isScanning: boolean = false;
  @State toastMsg: string = '';
  @State toastVisible: boolean = false;
  @State deleteTargetId: string = '';
  /** tunbox://import 导入请求 seq（EntryAbility.captureImportScheme 发布，@Watch 即时消费） */
  @StorageLink('import_request_seq') @Watch('onImportRequest') importRequestSeq: number = 0;
  /** 长按删除单个节点目标（确认框标题展示用） */
  @State deleteNodeTargetName: string = '';
  private deleteNodeTargetId: string = '';
  @State spinTick: number = 0;
  private service: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
  };
  private latencyBound: boolean = false;
  private deleteDialog: CustomDialogController = new CustomDialogController({
    builder: DeleteConfirmDialog({
      onConfirm: () => {
        this.doDelete(this.deleteTargetId);
      }
    })
  });
  /** 长按节点后的单节点删除确认框（复用 SubscriptionService.removeNode） */
  private deleteNodeDialog: CustomDialogController = new CustomDialogController({
    builder: NodeDeleteConfirmDialog({
      getNodeName: (): string => this.deleteNodeTargetName,
      onConfirm: () => {
        this.doDeleteNode();
      }
    }),
    autoCancel: true
  });
  private editTarget: Subscription | null = null;
  private editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubscriptionDialog({
      getInitialName: (): string => this.editTarget !== null ? this.editTarget.name : '',
      getInitialUrl: (): string => this.editTarget !== null ? this.editTarget.url : '',
      getIsLocal: (): boolean => this.editTarget !== null && this.editTarget.url.startsWith('local://'),
      onConfirm: (name: string, url: string) => {
        this.doEdit(name, url);
      }
    }),
    autoCancel: true
  });
  private importDialog: CustomDialogController = new CustomDialogController({    builder: ImportDialog({
      onScan: () => {
        this.importFromQr();
      },
      onUrl: (url: string) => {
        this.importFromUrl(url);
      },
      onFile: () => {
        this.importYamlFile();
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    // 作为 HdsTabs 页签内容组件（非 @Entry 页）后：页签「重新展示」由宿主经桥通知，
    // 语义等价于原 onPageShow（从子页返回 / 首次切入 / 切回页签时刷新）。
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.refreshForShown(); });
    }
    // tunbox://import scheme（P1-3c）：@StorageLink 即时响应外部导入请求
    // （EntryAbility.captureImportScheme 解析 tunbox://import?url=… 后发布）。
    this.importRequestSeq = AppStorage.get<number>('import_request_seq') ?? 0;
  }

  /** 宿主通知的「重新展示」：执行原 onPageShow 的刷新 */
  refreshForShown(): void {
    this.bootstrap();
  }

  /** tunbox://import scheme 消费（P1-3c）：seq 变化即取 url 导入（一次性，取后清空） */
  onImportRequest(): void {
    const pendingUrl = AppStorage.get<string>('import_request_url') ?? '';
    if (pendingUrl.length === 0) {
      return;
    }
    AppStorage.setOrCreate('import_request_url', '');
    this.importFromUrl(pendingUrl).catch((): void => {});
  }

  aboutToDisappear(): void {
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    if (this.latencyBound) {
      LatencyController.removeListener(this.latencyListener);
      this.latencyBound = false;
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    ConnectionOrchestrator.instance().init(ctx);
    await SettingsService.init(ctx);
    await this.service.init(ctx);
    this.settings = await SettingsService.load();
    this.activeSubId = this.settings.preferredNodeSubscriptionId;
    this.activeNodeId = this.settings.preferredNodeId;
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.nodeColumns = await SettingsService.loadNodeColumns();
    this.reload();
    if (!this.latencyBound) {
      this.latencyBound = true;
      LatencyController.addListener(this.latencyListener);
    }
  }

  private expandedInitialized: boolean = false;

  private reload(): void {
    this.subs = this.service.subscriptions.filter((s: Subscription) =>
      s.id !== DIRECT_GROUP_ID || s.nodeCount > 0);
    // 展开状态只在首次进入时给默认值（活动订阅）；此后删/加订阅一律保持
    // 用户当前的展开/收起状态，不重置（此前 expandedIds 空了就自动展开第一个，
    // 表现为"每次删/加订阅都自动展开第一个分组"）。
    if (!this.expandedInitialized) {
      this.expandedInitialized = true;
      if (this.subs.length > 0) {
        const first = this.subs.find((s) => s.id === this.activeSubId) ?? this.subs[0];
        this.expandedIds = [first.id];
      }
    }
    // 同步活动节点展示
    const node = this.service.findNode(this.activeNodeId);
    if (node === null && this.service.nodes.length > 0) {
      this.activeNodeId = this.service.nodes[0].id;
      this.activeSubId = this.service.nodes[0].subscriptionId;
    }
  }

  private showToast(msg: string): void {
    this.toastMsg = msg;
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2400);
  }

  /** 节点排布单列/双列切换（订阅分组始终单行），选择经 SettingsService 持久化 */
  private toggleNodeColumns(): void {
    const next = this.nodeColumns === 2 ? 1 : 2;
    this.nodeColumns = next;
    SettingsService.saveNodeColumns(next);
    this.showToast(next === 2 ? '节点已切换为双列排布' : '节点已切换为单列排布');
  }

  /**
   * 节点卡片（文档 §3.2 节点网格）：两行信息列 —— 名称行（Radio 单选 + 名称）+
   * 协议行（协议标签 + 延迟文本）。单列/双列均由 GridRow 控宽，卡片自身 100% 填充。
   */
  @Builder
  nodeCard(node: ProxyNode) {
    Column({ space: 8 }) {
      // 第一行：单选圆圈 + 节点名称
      Row({ space: 6 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 16, height: 16 })
            .fill(node.id === this.activeNodeId ? TunBoxColors.primary : Color.Transparent)
            .stroke(node.id === this.activeNodeId ? TunBoxColors.primary : TunBoxColors.textMuted)
            .strokeWidth(1.6)
          if (node.id === this.activeNodeId) {
            Circle({ width: 5, height: 5 }).fill(TunBoxColors.textOnPrimary)
          }
        }.width(16).height(16)
        Text(node.name)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 第二行：协议标签 + 延迟
      Row() {
        Text(this.protoOf(node))
          .fontSize(10).fontColor(TunBoxColors.textSecondary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(TunBoxColors.chipBg)
          .borderRadius(4)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(this.nodePingText(node))
          .fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor(this.nodePingColor(node))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor(TunBoxColors.surfaceCard)
    .border({
      width: node.id === this.activeNodeId ? 1.5 : 1,
      color: node.id === this.activeNodeId ? TunBoxColors.primary : TunBoxColors.cardBorder
    })
    .onClick(() => this.selectNode(node))
    // 长按弹出单节点删除确认框（与节点页长按删除同语义）
    .gesture(LongPressGesture().onAction(() => {
      this.deleteNodeTargetId = node.id;
      this.deleteNodeTargetName = node.name;
      this.deleteNodeDialog.open();
    }))
  }

  private isOpen(id: string): boolean {
    return this.expandedIds.includes(id);
  }

  private toggleOpen(id: string): void {
    if (this.isOpen(id)) {
      this.expandedIds = this.expandedIds.filter((x) => x !== id);
    } else {
      this.expandedIds = this.expandedIds.concat([id]);
    }
  }

  private activeSub(): Subscription | null {
    const s = this.subs.find((x) => x.id === this.activeSubId);
    if (s !== undefined) {
      return s;
    }
    return this.subs.length > 0 ? this.subs[0] : null;
  }

  private activeNode(): ProxyNode | null {
    return this.service.findNode(this.activeNodeId);
  }

  private totalNodes(): number {
    let n = 0;
    for (const s of this.subs) {
      n += this.service.nodesOf(s.id).length;
    }
    return n;
  }

  /**
   * 协议展示文本（协议标签）：VLESS·REALITY / VMESS / TROJAN / HYSTERIA2 / SS / SSR / 未知。
   *
   * 复用 NodeProtocolPolicy（与 NodeSelectionPage 同一口径），不再用旧的
   * proxyType.toUpperCase().slice(0, 8)：那是把「VLESS」「HYSTERIA2」硬截成
   * 8 字符的土办法，看不出 REALITY，且未知协议直接显示空串。
   */
  private protoOf(node: ProxyNode): string {
    return NodeProtocolPolicy.fromNode(node).display();
  }

  /** 节点延迟文案（TunBoxPing.recordText：五态语义；第二参为页面既有延迟触发变量） */
  private nodePingText(node: ProxyNode): string {
    return TunBoxPing.recordText(LatencyController.recordFor(node.name), this.latencyTick);
  }

  /** 节点延迟配色（TunBoxPing.recordColor：实测走阈值，过期/未测中性，手测失败红） */
  private nodePingColor(node: ProxyNode): ResourceColor {
    return TunBoxPing.recordColor(LatencyController.recordFor(node.name), this.latencyTick);
  }

  /**
   * 节点按延迟升序（边测边排）：有效延迟小的在前；未测(null)/超时沉底并保持
   * 原相对顺序。ForEach 键含 latencyTick，测速中每批新结果落地（控制器 200ms
   * 合并通知）即重渲染重排，用户实时看到快节点「冒泡」到前面。
   */
  private nodesSortedByLatency(subId: string): ProxyNode[] {
    const arr: ProxyNode[] = this.service.nodesOf(subId).slice();
    const key = (node: ProxyNode): number => {
      const v = LatencyController.latencyFor(node.name);
      return (v === null || v < 0) ? Number.MAX_SAFE_INTEGER : v;
    };
    // 稳定排序：ArkTS sort 对相同 key 保持插入序（ECMAScript 规范）
    arr.sort((a: ProxyNode, b: ProxyNode): number => key(a) - key(b));
    return arr;
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // 真实节点必须退出自动模式（同 NodeSelectionPage 语义）：否则 orchestrator 的
    // pinSmartGroup 会把 PROXY 指向 smart 组，preferredNodeId 被架空，主页环永远显示“自动选择”。
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
      this.autoSelectMode = AutoSelectModes.MANUAL;
      AppLogger.info(TAG, `manual node pick (${node.name}); auto mode disabled`);
    }
    this.activeNodeId = node.id;
    this.activeSubId = node.subscriptionId;
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeSubscriptionId = node.subscriptionId;
    this.settings.selectedSubscriptionId = node.subscriptionId;
    await SettingsService.save(this.settings);
    // 已连接时完整重连让新节点即时生效；未连接时仅保存选择。
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(node, this.service, 'preferredNode=' + node.id);
    if (didRestart) {
      this.showToast(`已选择 ${node.name}，正在自动重连…`);
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    } else {
      this.showToast(`已选择 ${node.name}`);
    }
  }

  /**
   * 启用内核智能选点（mihomo-smart LightGBM）：跨全部订阅自动优选出口，
   * 故障自动切换 + 网络变化自动重连由编排器既有策略承担（默认全开）。
   * 语义同节点页 smart 合成行：重连仍需一个真实节点做拨号目标。
   */
  private async enableAutoSelect(): Promise<void> {
    if (this.autoSelectMode === AutoSelectModes.AUTO) {
      this.showToast('已在使用内核智能选点');
      return;
    }
    const pool: ProxyNode[] = this.service.nodes;
    let target: ProxyNode | null = this.service.findNode(this.settings.preferredNodeId);
    if (target === null && pool.length > 0) {
      target = pool[0];
    }
    if (target === null) {
      this.showToast('没有可用节点');
      return;
    }
    this.settings.autoSelectMode = AutoSelectModes.AUTO;
    await SettingsService.save(this.settings);
    this.autoSelectMode = AutoSelectModes.AUTO;
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(target, this.service, 'autoSelectMode=auto');
    if (didRestart) {
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    }
    this.showToast(didRestart ? '已启用内核智能选点，正在自动重连…' : '已启用内核智能选点，下次连接生效');
  }

  /**
   * 分组头闪电测速（单个订阅 / **单节点分组**）。
   *
   * 单节点分组（`DIRECT_GROUP_ID`）必须与普通订阅同权：手工导入的节点其
   * `subscriptionId` 就是 DIRECT_GROUP_ID，而 `BackgroundLatencyService.testSubscription`
   * 正是按 `node.subscriptionId` 过滤节点集合 —— 因此它走的是**完全相同**的
   * LatencyEngine 路径，没有任何特殊之处。此前这里把 direct 一并拦掉，
   * 配合按钮上同款 `sub.id !== DIRECT_GROUP_ID` 判定，使「单节点」分组头既没有
   * 闪电图标、展开区的提示文字却又写着「点行头闪电图标测速」——用户报障：
   * 单节点无法测速。
   */
  private async speedTestSub(subId: string): Promise<void> {
    if (this.speedTestingIds.includes(subId)) {
      return;
    }
    this.speedTestingIds = this.speedTestingIds.concat([subId]);
    try {
      this.showToast('正在测速…');
      await BackgroundLatencyService.testSubscription(getContext(this) as Context, subId);
      this.showToast('✓ 测速完成');
    } catch (e) {
      this.showToast('测速失败，请重试');
    } finally {
      this.speedTestingIds = this.speedTestingIds.filter((x: string) => x !== subId);
    }
  }

  private isRefreshingSub(id: string): boolean {
    return this.refreshingIds.includes(id);
  }

  private async refreshOne(sub: Subscription): Promise<void> {
    if (sub.id === DIRECT_GROUP_ID || this.isRefreshing || this.isRefreshingSub(sub.id)) {
      return;
    }
    this.spinTick += 1;
    this.refreshingIds = this.refreshingIds.concat([sub.id]);
    try {
      const result = await this.service.refreshSubscription(sub.id);
      this.reload();
      if (result.status === SubscriptionRefreshStatus.OK) {
        this.showToast(`✓ 已刷新「${sub.name}」及节点测速`);
      } else {
        this.showToast(`${sub.name}：${result.userText('刷新失败')}`);
      }
    } finally {
      this.refreshingIds = this.refreshingIds.filter((x) => x !== sub.id);
    }
  }

  private async refreshAll(): Promise<void> {
    if (this.isAdding || this.isRefreshing || this.refreshingIds.length > 0) {
      return;
    }
    const ids: string[] = [];
    for (const s of this.subs) {
      if (s.id !== DIRECT_GROUP_ID) {
        ids.push(s.id);
      }
    }
    if (ids.length === 0) {
      this.showToast('没有可刷新的订阅');
      return;
    }
    this.spinTick += 1;
    this.isRefreshing = true;
    this.refreshingIds = ids.slice();
    try {
      const summary = await this.service.refreshSubscriptionsConcurrently(ids,
        ConcurrentRefresh.DEFAULT_LANES,
        (progress: RefreshBatchProgress, item: RefreshItemOutcome) => {
          this.refreshingIds = this.refreshingIds.filter((x) => x !== item.id);
          this.reload();
        },
        (): boolean => !this.isRefreshing);
      if (summary.failCount === 0) {
        this.showToast(`✓ 已成功刷新全部 ${summary.total} 个订阅及节点！`);
      } else if (summary.okCount > 0) {
        this.showToast(`部分刷新成功（${summary.okCount} 成功 / ${summary.failCount} 失败）`);
      } else {
        this.showToast('刷新失败，请检查网络后重试');
      }
    } finally {
      this.refreshingIds = [];
      this.isRefreshing = false;
      this.reload();
    }
  }

  private subscriptionNameOf(id: string): string {
    const f = this.subs.find((s: Subscription) => s.id === id);
    return f === undefined ? id : f.name;
  }

  /** URL 导入（HTML importFromUrl 等价：按 host 自动命名） */
  private async importFromUrl(rawUrl: string): Promise<void> {
    const raw = rawUrl.trim();
    if (raw.length === 0 || this.isAdding || this.isRefreshing) {
      return;
    }
    // 多行输入（一行一个节点链接）走批量导入；单行保持原行为（节点/订阅二选一）
    const nonEmptyLines = raw.split(/\r?\n/)
      .map((l: string): string => l.trim())
      .filter((l: string): boolean => l.length > 0);
    if (nonEmptyLines.length > 1) {
      await this.importNodeUris(raw);
      return;
    }
    if (SubscriptionService.isNodeUri(raw)) {
      await this.importNodeUris(raw);
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(raw)) {
      promptAction.showToast({ message: '请输入有效的URL地址' });
      return;
    }
    const dupe = this.subs.find((s) => s.url === raw);
    if (dupe !== undefined) {
      promptAction.showToast({ message: '该订阅已存在，无需重复添加' });
      return;
    }
    this.isAdding = true;
    try {
      let host = raw.replace(/^https?:\/\//, '').split('/')[0];
      if (host.length === 0) {
        host = '订阅';
      }
      const sub = await this.service.addSubscription(`🔗 ${host} 节点组`, raw, '', '');
      // 立刻上屏：订阅卡先出现（0 节点 · 刷新中），不等网络刷新完成。
      // 此前 reload 放在 refreshSubscription 之后，慢订阅要等十几秒才有可见反馈。
      this.expandedIds = [sub.id];
      this.activeSubId = sub.id;
      this.reload();
      this.showToast('已添加，正在获取节点…');
      const result = await this.service.refreshSubscription(sub.id);
      if (result.status === SubscriptionRefreshStatus.OK && result.nodeCount > 0) {
        const nodes = this.service.nodesOf(sub.id);
        if (nodes.length > 0) {
          await this.selectNode(nodes[0]);
        }
      }
      this.reload();
      this.showToast(result.status === SubscriptionRefreshStatus.OK
        ? `✓ 订阅成功，获取到 ${result.nodeCount} 个节点` : `已添加，但刷新失败：${result.userText('请稍后重试')}`);
    } catch (e) {
      promptAction.showToast({ message: '添加失败，请检查链接是否有效' });
    }
    this.isAdding = false;
  }

  /** 节点链接导入：一行一个批量（vless/vmess/ss/trojan…），重复与无效逐条隔离 */
  private async importNodeUris(raw: string): Promise<void> {
    this.isAdding = true;
    try {
      const r = await this.service.addDirectNodesText(raw);
      this.reload();
      if (r.added > 0) {
        let msg = r.added === 1
          ? `节点链接已导入，当前共 ${this.service.nodes.length} 个节点`
          : `✓ 已导入 ${r.added} 个节点，当前共 ${this.service.nodes.length} 个`;
        const extra: string[] = [];
        if (r.duplicate > 0) {
          extra.push(`${r.duplicate} 条重复`);
        }
        if (r.invalid > 0) {
          extra.push(`${r.invalid} 条无效`);
        }
        if (extra.length > 0) {
          msg += `（${extra.join('，')}）`;
        }
        this.showToast(msg);
      } else if (r.duplicate > 0 && r.invalid === 0) {
        this.showToast(r.duplicate === 1 ? '该节点已存在，无需重复添加' : `${r.duplicate} 条链接均已存在，无需重复添加`);
      } else {
        this.showToast('导入失败，请检查链接是否有效');
      }
    } catch (e) {
      this.showToast('导入失败，请检查链接是否有效');
    }
    this.isAdding = false;
  }

  private async importFromQr(): Promise<void> {
    if (this.isScanning || this.isAdding || this.isRefreshing || this.isImporting) {
      return;
    }
    this.isScanning = true;
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as Context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      const raw = result.originalValue.trim();
      if (raw.length === 0) {
        this.showToast('二维码内容为空');
        return;
      }
      if (SubscriptionService.isNodeUri(raw)) {
        await this.importNodeUris(raw);
        return;
      }
      const lower = raw.toLowerCase();
      if (!(lower.startsWith('https://') || lower.startsWith('http://'))
        || !SubscriptionFetchPolicy.isValidSubscriptionUrl(raw, true)) {
        this.showToast('二维码不是有效的 HTTP 或 HTTPS 订阅链接');
        return;
      }
      await this.importFromUrl(raw);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        this.showToast('已取消二维码扫描');
      } else if (err.code === 201) {
        this.showToast('相机权限被拒绝，无法扫描二维码');
      } else {
        this.showToast('二维码扫描失败，请重试');
      }
    } finally {
      this.isScanning = false;
    }
  }

  private async importYamlFile(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.yaml', '.yml', '.txt', '.json', '.conf'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          this.showToast('文件大小需在 4MB 以内');
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
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
        const fileName = uri.substring(uri.lastIndexOf('/') + 1);
        const count = await this.service.addLocalYaml(fileName, text);
        if (count > 0) {
          this.showToast(`文件导入成功，解析出 ${count} 个节点`);
          this.reload();
        } else {
          this.showToast('文件未解析出节点（支持 Clash YAML 与 ss/vless/vmess/trojan 链接）');
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `yaml file import failed: ${AppLogger.errText(e)}`);
      this.showToast('导入失败，请重试');
    } finally {
      this.isImporting = false;
    }
  }

  private async doDelete(id: string): Promise<void> {
    if (id === DIRECT_GROUP_ID) {
      this.showToast('单节点分组为常驻分组，不能删除');
      return;
    }
    await this.service.removeSubscription(id);
    this.expandedIds = this.expandedIds.filter((x) => x !== id);
    if (this.activeSubId === id) {
      this.activeSubId = '';
      this.activeNodeId = '';
    }
    this.reload();
    this.showToast('订阅已删除');
  }

  private openEdit(sub: Subscription): void {
    this.editTarget = sub;
    this.editDialog.open();
  }

  /**
   * 长按删除单个节点（语义与 NodeSelectionPage.doDeleteNode 一致）：
   * - 服务端 removeNode 会把节点指纹记入隐藏清单，订阅刷新后该节点不会"复活"；
   * - 删除的是当前选中节点时清空偏好（所有消费方都有 nodes[0] 兜底），并同步
   *   页面态 activeNodeId/activeSubId，避免状态卡仍显示已删节点。
   */
  private async doDeleteNode(): Promise<void> {
    const nodeId = this.deleteNodeTargetId;
    this.deleteNodeTargetId = '';
    if (nodeId.length === 0) {
      return;
    }
    const node = this.service.findNode(nodeId);
    const wasSelected = this.activeNodeId === nodeId;
    const ok = await this.service.removeNode(nodeId);
    if (!ok) {
      this.showToast('删除失败，请重试');
      return;
    }
    if (wasSelected) {
      this.settings.preferredNodeId = '';
      this.settings.preferredNodeSubscriptionId = '';
      await SettingsService.save(this.settings);
      this.activeNodeId = '';
      this.activeSubId = '';
    }
    this.reload();
    this.showToast(node !== null ? `已删除「${node.name}」` : '节点已删除');
  }

  private async doEdit(name: string, url: string): Promise<void> {
    const target = this.editTarget;
    if (target === null) {
      return;
    }
    if (name.trim().length === 0) {
      this.showToast('订阅名称不能为空');
      return;
    }
    const isLocal = target.url.startsWith('local://');
    if (target.id !== DIRECT_GROUP_ID && !isLocal && url.trim().length === 0) {
      this.showToast('订阅链接不能为空');
      return;
    }
    // 本地导入允许改名；http/https 走完整 URL 校验
    if (target.id !== DIRECT_GROUP_ID && !isLocal && !url.trim().startsWith('local://')
      && !SubscriptionFetchPolicy.isValidSubscriptionUrl(url.trim())) {
      this.showToast('请输入有效的订阅链接');
      return;
    }
    const dupe = target.id === DIRECT_GROUP_ID ? undefined
      : this.subs.find((s) => s.url === url.trim() && s.id !== target.id);
    if (dupe !== undefined) {
      this.showToast('该订阅链接已存在');
      return;
    }
    target.name = name.trim();
    if (target.id !== DIRECT_GROUP_ID && !isLocal) {
      target.url = url.trim();
    }
    await this.service.updateSubscription(target);
    this.reload();
    this.editTarget = null;
    this.showToast('订阅已更新');
  }

  private formatUpdateTime(ts: number): string {
    if (ts <= 0) {
      return '未更新';
    }
    const diff = Date.now() - ts;
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) {
      return '刚刚';
    }
    if (minutes < 60) {
      return `${minutes}分钟前`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return `${hours}小时前`;
    }
    const days = Math.floor(hours / 24);
    if (days < 7) {
      return `${days}天前`;
    }
    const d = new Date(ts);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层背景列（文档 §3.2：纯色底，不再用渐变/玻璃底）
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column() {
            // ── 顶部导航（页签页，无返回；右侧保留全部既有入口） ──
            TopNavBar({ title: '订阅与节点' }) {
              Row({ space: 8 }) {
                // 单列/双列节点排布切换
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_apps')).width(20).height(20)
                    .fillColor(TunBoxColors.textPrimary)
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.chipBg)
                .accessibilityText('切换单列双列排布')
                .onClick(() => { this.toggleNodeColumns(); })
                // 刷新全部
                Stack({ alignContent: Alignment.Center }) {
                  if (this.isRefreshing) {
                    LoadingProgress().width(18).height(18).color(TunBoxColors.primary)
                  } else {
                    Image($r('app.media.ic_refresh')).width(20).height(20)
                      .fillColor(TunBoxColors.textPrimary)
                      .rotate({ angle: this.spinTick * 360 })
                      .animation({ duration: 650, curve: Curve.EaseInOut })
                  }
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.chipBg)
                .accessibilityText('刷新全部订阅')
                .onClick(() => { this.refreshAll(); })
                // “+”添加订阅
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_plus')).width(20).height(20)
                    .fillColor(TunBoxColors.primary)
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.primaryLight)
                .accessibilityText('添加订阅')
                .onClick(() => { this.importDialog.open(); })
              }.alignItems(VerticalAlign.Center)
            }

            // 顶部提示不再放在这里（2026-10-18）：它曾是 Scroll 内容里的条件 Text，
            // 每次「正在测速…/✓ 测速完成/刷新完成」出现时都把下面的订阅卡整体下推一行。
            // 现在改为根 Stack 上的浮动胶囊（见 build() 末尾），绝不参与布局。

            Column({ space: 14 }) {
              // ── 1. 顶部全局概览卡（文档 §3.2 第 1 节） ──
              Row() {
                Column({ space: 4 }) {
                  Row() {
                    Circle({ width: 6, height: 6 }).fill(TunBoxColors.success).margin({ right: 6 })
                    Text('当前使用订阅组').fontSize(12).fontColor(TunBoxColors.textMuted)
                  }
                  Text(this.activeSub() !== null ? (this.activeSub() as Subscription).name : '暂无')
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: 6 }) {
                    Text('当前连接节点').fontSize(12).fontColor(TunBoxColors.textMuted)
                    Text(this.activeNode() !== null ? (this.activeNode() as ProxyNode).name : '未选择')
                      .fontSize(12).fontColor(TunBoxColors.primary).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Blank()
                Row({ space: 4 }) {
                  Text(`${this.subs.length} 订阅 · ${this.totalNodes()} 节点`)
                    .fontSize(11).fontColor(TunBoxColors.primary)
                }
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(TunBoxColors.primaryLight)
                .borderRadius(12)
              }
              .width('100%')
              .padding(TunBoxGeometry.cardPadding)
              .backgroundColor(TunBoxColors.surfaceCard)
              .borderRadius(TunBoxGeometry.cardRadiusSmall)
              .border({ width: 1, color: TunBoxColors.cardBorder })

              // ── 2. 内核智能优选条目（文档 §3.2 第 2 节，整行点击沿用既有切换逻辑） ──
              Column({ space: 0 }) {
                Row() {
                  Row() {
                    Image($r('app.media.ic_radar')).width(24).height(24).fillColor(TunBoxColors.success)
                  }
                  .width(42).height(42)
                  .borderRadius(12)
                  .backgroundColor(TunBoxColors.successLight)
                  .justifyContent(FlexAlign.Center)
                  .margin({ right: 12 })
                  Column({ space: 2 }) {
                    Row() {
                      Text('自动选择 · 内核智能优选')
                        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Circle({ width: 6, height: 6 })
                        .fill(this.autoSelectMode === AutoSelectModes.AUTO
                          ? TunBoxColors.success : TunBoxColors.textMuted)
                        .margin({ left: 6 })
                    }
                    Text(`跨订阅自动优选 · 故障毫秒切换 · ${this.totalNodes()} 个候选`)
                      .fontSize(11).fontColor(TunBoxColors.textMuted)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Blank()
                  Stack({ alignContent: Alignment.Center }) {
                    Circle({ width: 18, height: 18 })
                      .fill(this.autoSelectMode === AutoSelectModes.AUTO
                        ? TunBoxColors.success : Color.Transparent)
                      .stroke(this.autoSelectMode === AutoSelectModes.AUTO
                        ? TunBoxColors.success : TunBoxColors.textMuted)
                      .strokeWidth(1.6)
                    if (this.autoSelectMode === AutoSelectModes.AUTO) {
                      Circle({ width: 6, height: 6 }).fill(TunBoxColors.textOnPrimary)
                    }
                  }.width(18).height(18)
                  Text(this.autoSelectMode === AutoSelectModes.AUTO ? '已启用' : '未启用')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.autoSelectMode === AutoSelectModes.AUTO
                      ? TunBoxColors.success : TunBoxColors.textMuted)
                    .margin({ left: 6 })
                }
                .width('100%')
                .padding(14)
                // 2026-10-17 用户要求：点整行即选中（不再展开子列表），语义等价原展开区里的 smart 行
                .onClick(() => this.enableAutoSelect())
              }
              .width('100%')
              .borderRadius(18)
              .backgroundColor(TunBoxColors.successTint)
              .border({ width: 1, color: TunBoxColors.successBorder })
              .clip(true)

              // ── 3. 折叠式订阅分组（保留既有展开/收起与行头全部按钮逻辑） ──
              ForEach(this.subs, (sub: Subscription) => {
                Column({ space: 0 }) {
                  // 头部
                  Row({ space: 10 }) {
                    Stack({ alignContent: Alignment.Center }) {
                      Image($r('app.media.ic_nodes')).width(18).height(18)
                        .fillColor(TunBoxColors.primary)
                    }
                    .width(32).height(32)
                    .borderRadius(8)
                    .backgroundColor(TunBoxColors.primaryLight)
                    Column({ space: 2 }) {
                      Row({ space: 6 }) {
                        // ⚠ 名称必须 layoutWeight(1)：否则超长订阅名会按「理想宽度」撑开
                        // 这个 width('100%') 的 Row，把后面的「使用中」徽标挤出 Column 的
                        // 右边界，而 ArkUI 不裁剪溢出内容 —— 徽标会画到行头按钮区、与
                        // 闪电测速图标重叠（真机报障截图）。加权后名称吃掉剩余宽度并省略号，
                        // 徽标始终留在 Row 内。
                        Text(sub.name)
                          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        if (sub.id === this.activeSubId) {
                          Text('使用中')
                            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.success)
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .borderRadius(TunBoxGeometry.pillRadius)
                            .backgroundColor(TunBoxColors.successLight)
                            // 徽标永不压缩/永不被挤出去：它是状态标识，宽度必须完整
                            .flexShrink(0)
                        }
                      }.width('100%')
                      Text(`${this.service.nodesOf(sub.id).length} 个节点 · 更新于 ${this.formatUpdateTime(sub.lastFetchedAt)}`)
                        .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                    // ── 铁律：纯图标闪电测速按钮，位于刷新按钮左边，不得移动/不得加文字 ──
                    // 单节点分组（DIRECT_GROUP_ID）同样必须有：手工导入的节点就在该组，
                    // 测速路径与普通订阅完全一致（见 speedTestSub）。
                    Stack({ alignContent: Alignment.Center }) {
                      if (this.speedTestingIds.includes(sub.id)) {
                        LoadingProgress().width(15).height(15).color(TunBoxColors.primary)
                      } else {
                        Image($r('app.media.ic_bolt')).width(15).height(15)
                          .fillColor(TunBoxColors.primary)
                      }
                    }
                    .width(28).height(28)
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .accessibilityText('闪电测速')
                    .onClick(() => this.speedTestSub(sub.id))
                    // 单个刷新
                    Stack({ alignContent: Alignment.Center }) {
                      if (this.isRefreshingSub(sub.id)) {
                        LoadingProgress().width(15).height(15).color(TunBoxColors.primary)
                      } else {
                        Image($r('app.media.ic_refresh')).width(15).height(15)
                          .fillColor(TunBoxColors.textMuted)
                      }
                    }
                    .width(28).height(28)
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .accessibilityText('刷新订阅')
                    .onClick(() => this.refreshOne(sub))
                    // 重命名（常驻分组头，不用展开）
                    Stack({ alignContent: Alignment.Center }) {
                      Image($r('app.media.ic_tune')).width(15).height(15)
                        .fillColor(TunBoxColors.textMuted)
                    }
                    .width(28).height(28)
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .accessibilityText('编辑订阅')
                    .onClick(() => this.openEdit(sub))
                    if (sub.id !== DIRECT_GROUP_ID) {
                      Stack({ alignContent: Alignment.Center }) {
                        Image($r('app.media.ic_delete')).width(15).height(15)
                          .fillColor(TunBoxColors.textMuted)
                      }
                      .width(28).height(28)
                      .borderRadius(TunBoxGeometry.pillRadius)
                      .accessibilityText('删除订阅')
                      .onClick(() => {
                        this.deleteTargetId = sub.id;
                        this.deleteDialog.open();
                      })
                    }
                    // 展开指示
                    Image($r('app.media.ic_arrow_right')).width(14).height(14)
                      .fillColor(TunBoxColors.textMuted)
                      .rotate({ angle: this.isOpen(sub.id) ? 90 : 0 })
                      .animation({ duration: 250, curve: Curve.EaseInOut })
                  }
                  .width('100%')
                  .padding(14)
                  .onClick(() => this.toggleOpen(sub.id))

                  // 展开节点区
                  if (this.isOpen(sub.id)) {
                    Column({ space: 6 }) {
                      Row() {
                        Text('点击选用节点 · 长按可删除单个节点 · 点行头闪电图标测速')
                          .fontSize(11).fontColor(TunBoxColors.textMuted).layoutWeight(1)
                      }.width('100%').padding({ left: 2, right: 2, top: 2, bottom: 2 })
                      GridRow({ columns: this.nodeColumns, gutter: 10 }) {
                        ForEach(this.nodesSortedByLatency(sub.id), (node: ProxyNode) => {
                          GridCol() {
                            this.nodeCard(node)
                          }
                        }, (node: ProxyNode) => `${node.id}|${node.id === this.activeNodeId ? 1 : 0}|${this.latencyTick}`)
                      }
                      .width('100%')
                      // 编辑/删除行
                      if (sub.id !== DIRECT_GROUP_ID) {
                        Row({ space: 12 }) {
                          Blank()
                          Row({ space: 4 }) {
                            Image($r('app.media.ic_tune')).width(13).height(13)
                              .fillColor(TunBoxColors.textMuted)
                            Text('编辑').fontSize(12).fontColor(TunBoxColors.textMuted)
                          }
                          .onClick(() => this.openEdit(sub))
                          Row({ space: 4 }) {
                            Image($r('app.media.ic_delete')).width(13).height(13)
                              .fillColor(TunBoxColors.danger)
                            Text('删除').fontSize(12).fontColor(TunBoxColors.danger)
                          }
                          .onClick(() => {
                            this.deleteTargetId = sub.id;
                            this.deleteDialog.open();
                          })
                        }.width('100%').padding({ top: 4, right: 2 })
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, bottom: 12, top: 4 })
                    .backgroundColor(TunBoxColors.surfaceSubtle)
                    .borderWidth({ top: 1 })
                    .borderColor(TunBoxColors.cardBorder)
                  }
                }
                .width('100%')
                .borderRadius(TunBoxGeometry.cardRadius)
                .backgroundColor(TunBoxColors.surfaceCard)
                .border({
                  width: sub.id === this.activeSubId ? 1.5 : 1,
                  color: sub.id === this.activeSubId ? TunBoxColors.primary : TunBoxColors.cardBorder
                })
                .clip(true)
              }, (sub: Subscription) => `${sub.id}|${sub.name}|${this.service.nodesOf(sub.id).length}|${sub.lastFetchedAt}|${this.isOpen(sub.id) ? 1 : 0}|${sub.id === this.activeSubId ? 1 : 0}|${this.activeNodeId}|${this.latencyTick}`)

              if (this.subs.length === 0) {
                Column({ space: 10 }) {
                  Image($r('app.media.ic_nodes')).width(44).height(44)
                    .fillColor(TunBoxColors.textMuted)
                  Text('暂无订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textMuted)
                  Text('点击右上角 + 添加订阅').fontSize(12).fontColor(TunBoxColors.textMuted)
                }.width('100%').padding({ top: 50, bottom: 50 })
              }
            }
            .width('100%')
            // 底部为悬浮导航栏预留 TunBoxGeometry.dockClearance(96) 高度
            .padding({
              left: TunBoxGeometry.pagePadding,
              right: TunBoxGeometry.pagePadding,
              top: 4,
              bottom: TunBoxGeometry.dockClearance
            })
          }
          .width('100%')
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 顶部浮动提示（2026-10-18 用户要求：不挤占内容）──
      //
      // 为什么必须做成**叠层**而不是内容里的一行：
      // 测速/刷新的「正在测速…/✓ 测速完成/刷新完成…」是瞬态反馈，用户要的是
      // 「看得见、但不打断」；旧实现把它当 Scroll 内容里的条件 Text，出现一次就把
      // 下面所有订阅卡下推一行，反复测速时列表会持续跳动。
      //
      // 实现要点：
      //  · 根 Stack 的最后一个子节点 → 绘制在所有内容之上，且不参与 Column 布局；
      //  · 全屏透明容器 + 顶部内边距（让开 56vp 导航栏）→ 胶囊真正居中在顶部；
      //  · hitTestBehavior(None) → 提示层完全不拦截触摸（不会挡住底下的订阅卡/按钮）；
      //  · 只在 toastVisible 期间存在，配合 OPACITY 过渡淡入淡出。
      if (this.toastVisible) {
        Column() {
          Text(this.toastMsg)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            // 配色跟随主题（2026-10-18 用户要求）：白/深卡底 + 正文色字 + 品牌蓝描边，
            // 不再用写死的黑色底 + 白字（浅色主题里与整体白卡蓝调完全不搭）。
            .fontColor(TunBoxColors.toastText)
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(TunBoxGeometry.pillRadius)
            .backgroundColor(TunBoxColors.toastBg)
            .borderWidth(1)
            .borderColor(TunBoxColors.toastBorder)
            .shadow({ radius: 16, color: TunBoxColors.toastShadow, offsetX: 0, offsetY: 6 })
            .constraintSize({ maxWidth: '88%' })
            .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        }
        .width('100%')
        .height('100%')
        .padding({ top: TunBoxGeometry.navHeight + 8, left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .zIndex(20)
      }
    }
    .width('100%').height('100%')
  }
}
