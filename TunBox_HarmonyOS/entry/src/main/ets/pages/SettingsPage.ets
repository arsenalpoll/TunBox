/**
 * 设置中心（2026-10-17 UI 重构：Nexus 设计令牌版）
 *
 * 职责：把第二阶段新增的设置项以分组形式呈现，读写均走既有服务：
 *   - 读取：SettingsService.load() → AppSettings（页面首次进入取持久化真实值）
 *   - 写入：SettingsService.save()（内部 fromJson(toJson()) 归一化，与 UI 夹取形成双重夹取）
 * 每项改动即时落盘并 showToast 反馈；返回主页后再次进入仍读回真实值（不丢状态）。
 *
 * 约束：本文件只调用既有服务的公开接口，不修改 Orchestrator/AppSettings/SettingsService。
 * 2026-10-17 用户要求：设置页不再暴露「重连退避上限」三档时间 —— 编排器固定用
 * 内置最优默认 8s（RECONNECT_MAX_MS），用户只需控制「自动重连」开关。
 */
import { router, promptAction } from '@kit.ArkUI';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { AppInfo } from '../commons/utils/AppInfo';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { GeoAssetStatus } from '../commons/services/ConnectionOrchestrator';

/**
 * 2026-10-17 用户要求：重连退避上限不再暴露三档时间选项 —— 固定为 8s
 * （与 Orchestrator 的 RECONNECT_MAX_MS 一致的最优默认值），用户只需
 * 开/关「自动重连」。退避上限的进程内记忆与设置 UI 一并移除。
 */
/** 内容列最大宽度（与原 UiTokens.pageMaxWidth 取值一致，平板/折叠屏防过宽） */

/** geo 资产下载源偏好选项（与 AppSettings.assetSource 白名单一致） */
const ASSET_SOURCE_OPTIONS: string[] = ['auto', 'jsdelivr', 'ghproxy', 'github'];
const ASSET_SOURCE_LABELS: Record<string, string> = {
  'auto': '默认',
  'jsdelivr': 'CDN',
  'ghproxy': '加速',
  'github': '官方'
};

function formatGeoSize(bytes: number): string {
  if (bytes <= 0) {
    return '-';
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

@Component
export struct SettingsView {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 宿主（底部页签 MainPage / 路由包装页 SettingsPage）「重新展示」通知桥（替代 onPageShow 语义） */
  shownBridge?: TabLifecycleBridge;
  @State appRoutingSummary: string = '正在读取应用分流…';
  /** 广告拦截规则状态（原首页「规则模式」卡片迁入，语义与首页 rulesStatusText 一致） */
  @State adRulesSummary: string = '正在读取规则状态…';
  // ── 网络重连 ──
  @State autoReconnect: boolean = true;
  // ── 故障切换 ──
  @State failoverEnabled: boolean = true;
  @State failoverThreshold: number = 3;
  @State failoverCooldown: number = 60;
  // ── 选点 ──
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  @State currentNodeName: string = '';
  @State switchReason: string = '';
  @State switchFrom: string = '';
  @State switchTo: string = '';
  // ── 诊断 ──
  @State healthEnabled: boolean = true;
  @State repairMaxSteps: number = 2;
  // ── 数据与规则（geo 资产） ──
  @State geoAssets: GeoAssetStatus[] = [];
  @State assetSource: string = 'auto';
  @State geoUpdatingId: string = '';
  @State quotaNotifyEnabled: boolean = true;
  // ── 关于与隐私 ──
  @State privacyUrl: string = '';
  /** 顶栏标题（app.string.settings_title 的本地化取值；TopNavBar.title 为 string 型） */
  private settingsTitle: string = '';

  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();

  aboutToAppear(): void {
    // 顶栏标题：读取当前语言的本地化文案（与原 Text($r(...)) 呈现一致）
    try {
      this.settingsTitle = getContext(this).resourceManager.getStringSync($r('app.string.settings_title'));
    } catch (e) {
      this.settingsTitle = '设置';
    }
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.bootstrap(); });
    }
  }

  aboutToDisappear(): void {
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.refreshAppRoutingSummary();
    // 每次进入：从持久化读取真实值回填（缺字段/脏值由 AppSettings.fromJson 兜底）
    this.autoReconnect = this.settings.autoReconnectOnNetworkChange;
    this.failoverEnabled = this.settings.failoverEnabled;
    this.failoverThreshold = this.settings.failoverFailureThreshold;
    this.failoverCooldown = this.settings.failoverCooldownSec;
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.healthEnabled = this.settings.healthCheckEnabled;
    this.repairMaxSteps = this.settings.healthRepairMaxSteps;
    this.quotaNotifyEnabled = this.settings.quotaNotifyEnabled;
    this.assetSource = this.settings.assetSource;
    this.refreshGeoStatuses();
    this.refreshNodeAndSwitchInfo();
    this.refreshPrivacyLink();
  }

  /** 查询华为应用市场托管的隐私声明链接（AppGallery Kit 隐私管理服务，官方要求应用内入口与弹窗内容一致） */
  private refreshPrivacyLink(): void {
    try {
      const info: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      const links: privacyManager.AppPrivacyLink[] = info.privacyInfo;
      for (let i = 0; i < links.length; i++) {
        const url = links[i].url;
        if (typeof url === 'string' && url.length > 0) {
          this.privacyUrl = url;
          break;
        }
      }
    } catch (e) {
      // 未关联隐私托管（debug 包 / 未在 AGC 生成协议）时接口抛错：保持空值，点击时给出提示
    }
  }

  private openPrivacyPolicy(): void {
    if (this.privacyUrl.length === 0) {
      promptAction.showToast({ message: $r('app.string.settings_privacy_unavailable') });
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(this.privacyUrl)
      .catch(() => {
        promptAction.showToast({ message: $r('app.string.settings_privacy_unavailable') });
      });
  }

  /** 只展示当前模式对应的数量，切回本页时与保存结果同步。 */
  private refreshAppRoutingSummary(): void {
    let summary = '全部应用 · 不限应用（0 个筛选项）';
    if (this.settings.appRoutingMode === 'exclude') {
      summary = `绕过所选应用 · 已选 ${this.settings.excludedApps.length} 个`;
    } else if (this.settings.appRoutingMode === 'include') {
      summary = `仅所选应用 · 已选 ${this.settings.includedApps.length} 个`;
    }
    this.adRulesSummary = this.settings.rulesEnabled
      ? (this.settings.hyperAdRulesEnabled ? '拦截规则生效中 · HyperADRules 智能去广告' : '规则生效中')
      : '规则已关闭';
    this.appRoutingSummary = this.settings.appRoutingNeedsReview
      ? summary + ' · 待确认，请进入检查' : summary;
  }

  private refreshNodeAndSwitchInfo(): void {
    const node = this.subs.findNode(this.settings.preferredNodeId);
    if (node !== null) {
      this.currentNodeName = node.name;
    } else {
      this.currentNodeName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.switchReason = this.orchestrator.autoSwitchReason();
    this.switchFrom = this.orchestrator.lastFailoverFromName();
    this.switchTo = this.orchestrator.lastFailoverToName();
  }

  /** UTF/模型双重夹取：本函数为 UI 侧夹取（保存时 SettingsService 再夹一次） */
  private clampInt(v: number, min: number, max: number, def: number): number {
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

  /** 落盘 + 轻量反馈（每项改动即时保存） */
  private persist(): void {
    this.settings.autoReconnectOnNetworkChange = this.autoReconnect;
    this.settings.failoverEnabled = this.failoverEnabled;
    this.settings.failoverFailureThreshold = this.failoverThreshold;
    this.settings.failoverCooldownSec = this.failoverCooldown;
    this.settings.autoSelectMode = AutoSelectModes.normalize(this.autoSelectMode);
    this.settings.healthCheckEnabled = this.healthEnabled;
    this.settings.healthRepairMaxSteps = this.repairMaxSteps;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── 各设置项交互 ──────────────────────────────────────────────────

  private onAutoReconnectChange(v: boolean): void {
    this.autoReconnect = v;
    this.persist();
  }

  private onFailoverEnabledChange(v: boolean): void {
    this.failoverEnabled = v;
    this.persist();
  }

  private stepThreshold(delta: number): void {
    const before = this.failoverThreshold;
    this.failoverThreshold = this.clampInt(before + delta, 1, 10, 3);
    if (this.failoverThreshold === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  private stepCooldown(delta: number): void {
    const before = this.failoverCooldown;
    this.failoverCooldown = this.clampInt(before + delta, 0, 3600, 60);
    if (this.failoverCooldown === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  private onHealthEnabledChange(v: boolean): void {
    this.healthEnabled = v;
    this.persist();
  }

  private stepRepair(delta: number): void {
    const before = this.repairMaxSteps;
    this.repairMaxSteps = this.clampInt(before + delta, 0, 3, 2);
    if (this.repairMaxSteps === before) {
      promptAction.showToast({ message: $r('app.string.settings_clamp_toast') });
      return;
    }
    this.persist();
  }

  // ── 数据与规则（geo 资产管理） ────────────────────────────────────

  private refreshGeoStatuses(): void {
    this.geoAssets = this.orchestrator.geoAssetStatuses();
  }

  private geoStatusText(asset: GeoAssetStatus): string {
    if (!asset.ready) {
      return '未就绪（连接时会后台补齐）';
    }
    let age = '';
    if (asset.mtimeMs > 0) {
      const days = Math.floor((Date.now() - asset.mtimeMs) / 86400000);
      age = days <= 0 ? '今天更新' : `${days} 天前更新`;
    }
    return `就绪 · ${formatGeoSize(asset.sizeBytes)} · ${age}`;
  }

  private async updateAsset(id: string): Promise<void> {
    if (this.geoUpdatingId.length > 0) {
      return;
    }
    this.geoUpdatingId = id;
    try {
      const err = await this.orchestrator.refreshGeoAsset(id, this.assetSource);
      promptAction.showToast({ message: err.length > 0 ? err : '更新完成' });
    } catch (e) {
      promptAction.showToast({ message: '更新失败，请重试' });
    } finally {
      this.geoUpdatingId = '';
      this.refreshGeoStatuses();
    }
  }

  private setAssetSource(source: string): void {
    if (this.assetSource === source) {
      return;
    }
    this.assetSource = source;
    this.settings.assetSource = source;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  private setQuotaNotify(v: boolean): void {
    this.quotaNotifyEnabled = v;
    this.settings.quotaNotifyEnabled = v;
    SettingsService.save(this.settings).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── UI ────────────────────────────────────────────────────────────

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 顶栏（底部页签页：无返回）──
        TopNavBar({ title: this.settingsTitle })

        Scroll() {
          Column({ space: 14 }) {
            // ── 应用分流：进入统一页面，不在设置页维护第二份编辑状态 ──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_apps'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('应用分流').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.appRoutingSummary)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => router.pushUrl({ url: 'pages/AppRoutingPage' }))

            // ── 网站分流策略：进入统一页面配置（2026-10-17 自首页「规则模式」卡片迁入）──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_swap'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('网站分流策略').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(`代理 ${this.settings.forceProxySites.length} · 直连 ${this.settings.forceDirectSites.length}`)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => router.pushUrl({ url: 'pages/SiteRoutingPage' }))

            // ── 广告拦截规则：进入统一页面配置（2026-10-17 自首页「规则模式」卡片迁入）──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_shield'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('广告拦截规则').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.adRulesSummary)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => router.pushUrl({ url: 'pages/RulesPage' }))

            // ── 网络重连（2026-10-17：只保留「自动重连」开关，退避上限固定最优默认 8s）──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_refresh'), $r('app.string.settings_network_reconnect_title'))
              this.ToggleRow($r('app.string.settings_auto_reconnect_label'),
                $r('app.string.settings_auto_reconnect_desc'),
                this.autoReconnect, (v: boolean): void => this.onAutoReconnectChange(v))
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 故障切换 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_swap'), $r('app.string.settings_failover_title'))
              this.ToggleRow($r('app.string.settings_failover_enable_label'),
                $r('app.string.settings_failover_enable_desc'),
                this.failoverEnabled, (v: boolean): void => this.onFailoverEnabledChange(v))
              this.StepperRow($r('app.string.settings_failover_threshold_label'),
                $r('app.string.settings_failover_threshold_desc'),
                this.failoverThreshold, false,
                (delta: number): void => this.stepThreshold(delta))
              this.StepperRow($r('app.string.settings_failover_cooldown_label'),
                $r('app.string.settings_failover_cooldown_desc'),
                this.failoverCooldown, true,
                (delta: number): void => this.stepCooldown(delta))
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 诊断 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_diagnostics_title'))
              this.ToggleRow($r('app.string.settings_health_enable_label'),
                $r('app.string.settings_health_enable_desc'),
                this.healthEnabled, (v: boolean): void => this.onHealthEnabledChange(v))
              this.StepperRow($r('app.string.settings_health_repair_steps_label'),
                $r('app.string.settings_health_repair_steps_desc'),
                this.repairMaxSteps, false,
                (delta: number): void => this.stepRepair(delta))
              Divider().color(TunBoxColors.cardBorder)
              Column({ space: 4 }) {
                Row() {
                  Text('订阅配额提醒')
                    .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.quotaNotifyEnabled })
                    .selectedColor(TunBoxColors.primary)
                    .onChange((v: boolean): void => this.setQuotaNotify(v))
                }.width('100%').alignItems(VerticalAlign.Center)
                Text('订阅流量剩余不足 10% 或 3 天内到期时发送系统通知（每次刷新订阅后检查，每天最多提醒一次）')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 数据与规则 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_doc'), $r('app.string.settings_geo_title'))
              ForEach(this.geoAssets, (asset: GeoAssetStatus) => {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Row({ space: 6 }) {
                      Text(asset.label).fontSize(14).fontWeight(FontWeight.Bold)
                        .fontColor(TunBoxColors.textPrimary)
                      Circle({ width: 8, height: 8 })
                        .fill(asset.ready ? TunBoxColors.success : TunBoxColors.textMuted)
                    }.width('100%').alignItems(VerticalAlign.Center)
                    Text(`${asset.detail} · ${this.geoStatusText(asset)}`)
                      .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text(this.geoUpdatingId === asset.id ? '更新中…' : '更新')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.geoUpdatingId === asset.id ? TunBoxColors.textMuted : TunBoxColors.primary)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(12)
                    .backgroundColor(TunBoxColors.surfaceCard)
                    .border({ width: 1, color: TunBoxColors.cardBorder })
                    .onClick(() => {
                      if (this.geoUpdatingId.length === 0) {
                        this.updateAsset(asset.id);
                      }
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(10)
                .borderRadius(14)
                .backgroundColor(TunBoxColors.surfaceSubtle)
              }, (asset: GeoAssetStatus) => `${asset.id}-${asset.ready}-${asset.sizeBytes}`)

              Column({ space: 8 }) {
                Text('下载源偏好')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).width('100%')
                Row({ space: 8 }) {
                  ForEach(ASSET_SOURCE_OPTIONS, (src: string) => {
                    Text(ASSET_SOURCE_LABELS[src] ?? src)
                      .fontSize(13)
                      .fontWeight(this.assetSource === src ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.assetSource === src ? TunBoxColors.primary : TunBoxColors.textSecondary)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .padding({ top: 7, bottom: 7 })
                      .borderRadius(12)
                      .backgroundColor(this.assetSource === src ? TunBoxColors.primaryLight : TunBoxColors.surfaceSubtle)
                      .border({
                        width: 1,
                        color: this.assetSource === src ? TunBoxColors.primaryBorder : TunBoxColors.cardBorder
                      })
                      .onClick(() => this.setAssetSource(src))
                  }, (src: string) => src)
                }.width('100%')
                Text('默认按实测可达性排序；CDN=jsdelivr 优先，加速=gh-proxy 前缀优先，官方=GitHub 直链优先。偏好源失败仍自动回退其余源。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 关于与隐私 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_globe'), $r('app.string.settings_about_title'))
              Row() {
                Text($r('app.string.settings_version_label'))
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Text(AppInfo.version())
                  .fontSize(13).fontColor(TunBoxColors.textSecondary)
              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
              Row() {
                Text($r('app.string.settings_privacy_policy_row'))
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              .onClick(() => this.openPrivacyPolicy())
              Text($r('app.string.settings_privacy_policy_desc'))
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // 页签页底部为悬浮 Dock 预留（契约：≥ TunBoxGeometry.dockClearance）
            Blank().height(TunBoxGeometry.dockClearance)
          }
          .width('100%')
          .padding({
            left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 8, bottom: 24
          })
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  @Builder
  SectionHeader(icon: Resource, title: Resource) {
    Row({ space: 8 }) {
      Image(icon).width(18).height(18).fillColor(TunBoxColors.primary)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ToggleRow(label: Resource, desc: Resource, isOn: boolean, onChange: (v: boolean) => void) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor(TunBoxColors.primary)
          .onChange(onChange)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(desc).fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
    }
    .width('100%')
  }

  @Builder
  StepperRow(label: Resource, desc: Resource, value: number, useSeconds: boolean,
    onStep: (delta: number) => void) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
        Row({ space: 0 }) {
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_minus')).width(15).height(15).fillColor(TunBoxColors.textPrimary)
          }
          .width(34).height(30)
          .borderRadius(8).backgroundColor(TunBoxColors.surfaceSubtle)
          .border({ width: 1, color: TunBoxColors.cardBorder })
          .onClick(() => onStep(-1))
          Text(useSeconds ? $r('app.string.settings_seconds_value', value) : `${value}`)
            .fontSize(14).fontColor(TunBoxColors.textPrimary)
            .constraintSize({ minWidth: 62 })
            .textAlign(TextAlign.Center)
            .padding({ left: 6, right: 6 })
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_plus')).width(15).height(15).fillColor(TunBoxColors.textPrimary)
          }
          .width(34).height(30)
          .borderRadius(8).backgroundColor(TunBoxColors.surfaceSubtle)
          .border({ width: 1, color: TunBoxColors.cardBorder })
          .onClick(() => onStep(1))
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(desc).fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
    }
    .width('100%')
  }

}

/**
 * 路由兼容入口（2026-10-17 UI 重构）：设置页内容已抽为 SettingsView，
 * 底部页签（MainPage）直接挂 SettingsView；外部深链仍走本 @Entry 页。
 */
@Entry
@Component
struct SettingsPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  private bridge: TabLifecycleBridge = new TabLifecycleBridge();

  onPageShow(): void {
    this.bridge.notifyShown();
  }

  build() {
    // @Entry 的 build 根必须是容器组件，故用 Stack 承载页签内容视图
    Stack() {
      SettingsView({ shownBridge: this.bridge })
    }
    .width('100%')
    .height('100%')
  }
}
