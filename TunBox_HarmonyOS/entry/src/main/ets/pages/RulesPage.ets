import { router, promptAction, LengthMetrics } from '@kit.ArkUI';
import { Ui } from '../theme/UiTokens';
import { AppSettings, CustomRuleSet } from '../commons/models/AppSettings';
import { SettingsService } from '../commons/services/SettingsService';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

@Entry
@Component
struct RulesPage {
  @State rulesEnabled: boolean = true;
  /** 去广告默认关闭：与 AppSettings.hyperAdRulesEnabled 的默认值保持一致 */
  @State hyperAdRulesEnabled: boolean = false;
  @State customRulesText: string = '';
  /** 逐行校验错误（"第 N 行：原因"），输入即刷新（M8：所见校验 = 实际落盘） */
  @State ruleErrors: string[] = [];
  /** 用户自定义远程规则集（P1-2）：条目列表 + 新增表单状态 */
  @State ruleSets: CustomRuleSet[] = [];
  @State rsName: string = '';
  @State rsUrl: string = '';
  @State rsBehavior: string = 'domain';
  @State rsPolicy: string = 'REJECT';
  @State rsFormat: string = 'yaml';
  /** 规则调试（P1-5）：输入域名 → 实时命中判定 */
  @State debugDomain: string = '';
  @State debugResult: string = '';
  /** YAML 覆盖层（P2）：settings.yamlOverride 双向绑定 */
  @State yamlOverrideText: string = '';
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  onPageShow(): void {
    this.bootstrap();
  }

  /** 输入变化时逐行校验；规则为空的行跳过（不报错） */
  private refreshRuleErrors(): void {
    const errors: string[] = [];
    const lines = this.customRulesText.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const error = ClashConfigGenerator.validateCustomRuleDetailed(line);
      if (error.length > 0) {
        errors.push(`第 ${i + 1} 行：${error}`);
      }
    }
    this.ruleErrors = errors;
  }

  private async bootstrap(): Promise<void> {
    await SettingsService.init(getContext(this) as Context);
    this.settings = await SettingsService.load();
    this.rulesEnabled = this.settings.rulesEnabled;
    this.hyperAdRulesEnabled = this.settings.hyperAdRulesEnabled;
    this.customRulesText = this.settings.customRules.join('\n');
    this.ruleSets = this.settings.customRuleSets;
    this.yamlOverrideText = this.settings.yamlOverride;
    this.refreshRuleErrors();
  }

  /** 保存 YAML 覆盖层（P2）：生成器侧 validateYamlOverride 白名单在生成时把关 */
  private async saveYamlOverride(): Promise<void> {
    const text = this.yamlOverrideText.slice(0, 8192);
    this.settings.yamlOverride = text;
    await SettingsService.save(this.settings);
    promptAction.showToast({ message: '覆盖层已保存，下次连接/热重载生效' });
  }

  /** 新增自定义规则集（P1-2）：走 normalizeRuleSets 统一校验（名称/URL/白名单） */
  private async addRuleSet(): Promise<void> {
    const name = this.rsName.trim();
    const url = this.rsUrl.trim();
    if (name.length === 0 || url.length === 0) {
      promptAction.showToast({ message: '请填写规则集名称与 https URL' });
      return;
    }
    if (this.ruleSets.length >= 20) {
      promptAction.showToast({ message: '最多 20 条自定义规则集' });
      return;
    }
    const candidate = new CustomRuleSet();
    candidate.name = name;
    candidate.url = url;
    candidate.behavior = this.rsBehavior;
    candidate.format = this.rsFormat;
    candidate.policy = this.rsPolicy;
    candidate.interval = 86400;
    const merged = this.ruleSets.slice(0);
    merged.push(candidate);
    const normalized = AppSettings.normalizeRuleSets(merged);
    if (normalized.length === this.ruleSets.length) {
      promptAction.showToast({ message: '规则集无效：名称限字母数字-_，URL 必须 https 且 ≤512 字符' });
      return;
    }
    this.ruleSets = normalized;
    this.settings.customRuleSets = normalized;
    this.rsName = '';
    this.rsUrl = '';
    await SettingsService.save(this.settings);
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({ message: `规则集已添加，${effect}` });
  }

  private async removeRuleSet(name: string): Promise<void> {
    const kept: CustomRuleSet[] = [];
    for (const entry of this.ruleSets) {
      if (entry.name !== name) {
        kept.push(entry);
      }
    }
    this.ruleSets = kept;
    this.settings.customRuleSets = kept;
    await SettingsService.save(this.settings);
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({ message: `规则集已删除，${effect}` });
  }

  private async save(): Promise<void> {
    const supplied = this.customRulesText.split('\n')
      .map((v: string) => v.trim()).filter((v: string) => v.length > 0);
    const normalized = ClashConfigGenerator.normalizeCustomRules(supplied);
    const invalidCount = Math.max(0, supplied.length - normalized.length);
    this.settings.rulesEnabled = this.rulesEnabled;
    this.settings.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    this.settings.customRules = normalized;
    this.settings.customRuleSets = this.ruleSets;
    this.customRulesText = normalized.join('\n');
    this.refreshRuleErrors();
    await SettingsService.save(this.settings);
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const suffix = invalidCount > 0 ? `，已忽略 ${invalidCount} 条无效规则` : '';
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({
      message: `规则已保存，${effect}${suffix}`
    });
  }

  build() {
    Stack() {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column() {
        Row() {
          Text('←').fontSize(22).fontColor(Ui.textPrimary).padding({ left: 4, right: 10 })
            .onClick(() => router.back())
          Text('规则').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Text('保存').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textBlue)
            .padding({ left: 10, right: 4, top: 8, bottom: 8 }).onClick(() => this.save())
        }.width('100%').height(48).padding({ left: 14, right: 14 })
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                Text('启用规则功能').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                Text(this.rulesEnabled ? '规则将在连接时生效' : '已关闭，将使用基础代理配置')
                  .fontSize(12).fontColor(Ui.textTertiary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.rulesEnabled })
                .selectedColor(Ui.primaryBlueFill)
                .onChange((value: boolean) => { this.rulesEnabled = value; })
            }.width('100%').alignItems(VerticalAlign.Center).padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            Column({ space: 10 }) {
              Row() {
                Column({ space: 4 }) {
                  Text('HyperADRules 去广告').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                  Text('默认关闭。开启后每日自动更新官方 MRS 规则集；全局代理下可能影响个别应用商店加载')
                    .fontSize(12).fontColor(Ui.textTertiary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.hyperAdRulesEnabled })
                  .selectedColor(Ui.primaryBlueFill)
                  .enabled(this.rulesEnabled)
                  .onChange((value: boolean) => { this.hyperAdRulesEnabled = value; })
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('来源：Lynricsy/HyperADRules · 广告域名命中后直接 REJECT')
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            Column({ space: 10 }) {
              Text('自定义规则').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
              Text('每行一条，例如 DOMAIN-SUFFIX,example.com,REJECT').fontSize(12).fontColor(Ui.textTertiary).width('100%')
              TextArea({
                placeholder: 'DOMAIN-SUFFIX,example.com,REJECT\nDOMAIN,example.org,DIRECT',
                text: this.customRulesText
              })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => {
                  this.customRulesText = value;
                  this.refreshRuleErrors();
                })
                .height(260).fontSize(13).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                .backgroundColor(Ui.inputBackground).borderRadius(14).padding(12)
                .borderWidth(1)
                .borderColor(this.ruleErrors.length > 0 ? Ui.error : Ui.glassEdge)
              if (this.ruleErrors.length > 0) {
                Column({ space: 3 }) {
                  ForEach(this.ruleErrors, (err: string) => {
                    Text(`⚠ ${err}`)
                      .fontSize(11).fontColor(Ui.error).width('100%')
                  }, (err: string, idx: number) => `${idx}-${err}`)
                }
                .width('100%')
                .padding(10)
                .borderRadius(12)
                .backgroundColor(Ui.inputBackground)
                .borderWidth(1)
                .borderColor(Ui.error)
                .alignItems(HorizontalAlign.Start)
              }
              Text('支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、GEOIP；策略支持 DIRECT、PROXY、REJECT、PASS、REJECT-DROP；IP 类规则可追加 no-resolve。')
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')
              Divider().strokeWidth(1).color(Ui.glassEdge).margin({ top: 6, bottom: 6 })
              Text('规则调试').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
              TextInput({ placeholder: '输入域名（如 www.example.com）看命中哪条规则', text: this.debugDomain })
                .onChange((value: string) => {
                  this.debugDomain = value;
                  this.debugResult = ClashConfigGenerator.debugDomainMatch(value, this.customRulesText.split('\n'));
                })
                .height(38).fontSize(13).backgroundColor(Ui.inputBackground)
                .borderRadius(12).padding({ left: 10, right: 10 })
              Text(this.debugResult.length > 0 ? `命中：${this.debugResult}` : (this.debugDomain.trim().length > 0 ? '未命中自定义域名规则（走 DIRECT/PROXY 名单或 GEOIP/MATCH）' : ''))
                .fontSize(12).fontColor(this.debugResult.length > 0 ? Ui.textPrimary : Ui.textTertiary).width('100%')
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            // ── 自定义远程规则集（P1-2）：条目列表 + 新增表单，对标 iOS 六家 RULE-SET 能力 ──
            Column({ space: 10 }) {
              Text('自定义规则集').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
              Text('添加远程 RULE-SET（URL+格式+策略），命中后整体应用一条策略，比逐条规则更高效。内核自动下载与定时更新，失败保留上一版。')
                .fontSize(12).fontColor(Ui.textTertiary).width('100%')
              ForEach(this.ruleSets, (rs: CustomRuleSet) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(`${rs.name} → ${rs.policy}`)
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
                    Text(`${rs.behavior}/${rs.format} · ${rs.url}`)
                      .fontSize(11).fontColor(Ui.textTertiary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('删除').fontSize(12).fontColor(Ui.error).padding(6)
                    .onClick(() => this.removeRuleSet(rs.name))
                }.width('100%').padding(10).borderRadius(12)
                  .backgroundColor(Ui.inputBackground).borderWidth(1).borderColor(Ui.glassEdge)
              }, (rs: CustomRuleSet) => rs.name)
              TextInput({ placeholder: '名称（字母数字-_，如 my-rules）', text: this.rsName })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => { this.rsName = value; })
                .height(40).fontSize(13).backgroundColor(Ui.inputBackground)
                .borderRadius(12).padding({ left: 10, right: 10 })
              TextInput({ placeholder: 'https://… 规则集 URL（yaml/text/mrs）', text: this.rsUrl })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => { this.rsUrl = value; })
                .height(40).fontSize(13).backgroundColor(Ui.inputBackground)
                .borderRadius(12).padding({ left: 10, right: 10 })
              // 格式 chip 换行（Flex wrap，Row 无 flexWrap 属性）：窄屏下 chip 挤一行
              // 会超出卡片边界，允许换行。
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                Text('格式').fontSize(12).fontColor(Ui.textTertiary)
                ForEach(['yaml', 'text', 'mrs'], (f: string) => {
                  Text(f).fontSize(12).padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(9999)
                    .fontColor(this.rsFormat === f ? Color.White : Ui.textTertiary)
                    .backgroundColor(this.rsFormat === f ? '#2563EB' : Ui.inputBackground)
                    .onClick(() => { this.rsFormat = f; })
                }, (f: string) => f)
              }.width('100%')
              // 策略 chip 换行（Flex wrap）：窄屏下 REJECT/DIRECT/PROXY 三枚 chip
              // 与「策略」标签挤在一行会超出卡片边界，允许换行。
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                Text('策略').fontSize(12).fontColor(Ui.textTertiary)
                ForEach(['REJECT', 'DIRECT', 'PROXY'], (p: string) => {
                  Text(p).fontSize(12).padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(9999)
                    .fontColor(this.rsPolicy === p ? Color.White : Ui.textTertiary)
                    .backgroundColor(this.rsPolicy === p ? '#2563EB' : Ui.inputBackground)
                    .onClick(() => { this.rsPolicy = p; })
                }, (p: string) => p)
              }.width('100%')
              Text('添加').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Color.White)
                .textAlign(TextAlign.Center).width('100%').padding(10).borderRadius(12)
                .backgroundColor(this.rulesEnabled ? '#2563EB' : Ui.inputBackground)
                .onClick(() => this.addRuleSet())
              Text('behavior 由格式推断：yaml/text 默认 domain，可在生成器侧自动匹配 ipcidr/classical；名称将生成 rs-<名称> 的 provider 键。')
                .fontSize(11).fontColor(Ui.textTertiary).width('100%')
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
            // ── YAML 覆盖层（P2）：对标 Stash JS Override 的无脚本形态 ──
            Column({ space: 10 }) {
              Text('YAML 覆盖层').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary).width('100%')
              Text('追加在生成配置尾部的高级 YAML 片段，同名键覆盖默认值（如 sniffer/keep-alive/profile）。rules/proxies/proxy-groups/external-controller/secret/tun 六键被拦截，由程序管理。')
                .fontSize(12).fontColor(Ui.textTertiary).width('100%')
              TextArea({ placeholder: '如：\nprofile:\n  store-selected: true', text: this.yamlOverrideText })
                .enabled(true)
                .onChange((value: string) => { this.yamlOverrideText = value; })
                .height(120).fontSize(12).backgroundColor(Ui.inputBackground)
                .borderRadius(12).padding(10)
              Text('保存').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Color.White)
                .textAlign(TextAlign.Center).width('100%').padding(10).borderRadius(12)
                .backgroundColor('#2563EB')
                .onClick(() => this.saveYamlOverride())
            }.width('100%').padding(18).borderRadius(22)
              .backgroundColor(Ui.surfaceTranslucent)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
              })
              .backgroundEffect({
                radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft
              })
              .borderWidth(1).borderColor(Ui.glassEdge).shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
          }.width('100%').constraintSize({ maxWidth: Ui.pageMaxWidth })
            .padding({ left: 18, right: 18, top: 8, bottom: 30 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 360, curve: Curve.EaseInOut })
      .translate({ x: '4%', y: 0 }).opacity(0.68)
    PageTransitionExit({ duration: 300, curve: Curve.EaseInOut })
      .translate({ x: '2%', y: 0 }).opacity(0.72)
  }
}
