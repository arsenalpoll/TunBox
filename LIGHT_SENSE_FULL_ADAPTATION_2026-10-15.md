# 沉浸光感完全适配（2026-10-15）

依据：华为官方开发指南《组件适配沉浸光感》《开启沉浸光感》《沉浸光感常见问题》《沉浸光感功耗优化》
（HarmonyOS Developer Knowledge MCP，`arkts-immersive-light-sense-*` 全文，2026-10-15 拉取）。

## 官方约束（本轮依据）

1. **targetSDK 硬性要求**：《开启沉浸光感》——「开启沉浸光感，要确保应用的 targetSDKVersion 不低于 26.0.0」。
2. **应用级开关**：`module.json5`（entry 类型 module）metadata `ohos.arkui.UIMaterial.state = "enable"`。
   enable 模式下默认开启沉浸光感的组件：Toast（THICK）、Menu（THICK）、Dialog/AlertDialog/CustomDialog/半模态
   （ULTRA_THICK）、Toggle、Slider、Select 下拉按钮+下拉菜单、AlphabetIndexer 提示弹窗（THICK）、
   Navigation 标题栏（返回键/非自定义 Menu，ULTRA_THIN）。
   Popup/Tips 与 Button 无应用级默认，需组件级开启。
3. **生效范围（官方反模式清单）**：
   - `Button` 组件级 systemMaterial **仅在 Navigation/NavDestination 标题栏或横向 Tabs 的底部 TabBar 生效**，
     主页内容区的 Button 设置后不生效——内容区按钮不挂 systemMaterial。
   - 普通容器（Row/Column 自绘顶栏）走通用属性 systemMaterial 同样只在标题栏/底部 TabBar 生效。
   - 底部页签：barFloatingStyle 仅在 `barOverlap=true + vertical=false + barPosition=End` 三条件同时满足时生效。
   - 材质层级位于 `backgroundColor`/`backgroundBlurStyle` 之下：不透明背景色、背景模糊、自定义 shadow
     都会遮挡材质（《FAQ》「背景色或背景模糊遮挡材质效果」）。
   - `shadow` 通用属性与材质并存时自定义 shadow 不生效（材质 applyShadow 默认 true）。

## 改动清单（全部可单独回退）

| # | 文件 | 改动 |
| --- | --- | --- |
| 1 | `build-profile.json5` | `targetSdkVersion` `6.1.1(24)` → `26.0.0`（compatibleSdkVersion 保持 6.1.1(24) 向下兼容；本机 SDK 为 HarmonyOS 26.0.0(105)） |
| 2 | `entry/src/main/module.json5` | 新增 module 级 metadata `ohos.arkui.UIMaterial.state = "enable"`（应用级开关） |
| 3 | `pages/HomePage.ets` | NetworkRulesDialog / BackupDialog / BackupPasswordDialog 根容器移除遮挡材质的 `backgroundColor`/`borderWidth`/`borderColor`/`shadow` |
| 4 | `pages/SubscriptionPage.ets` | ImportDialog / DeleteConfirmDialog / NodeDeleteConfirmDialog / EditSubscriptionDialog 根容器同上 |
| 5 | `pages/AppRoutingPage.ets` | RoutingInputDialog 根容器移除玻璃配方链（`surfaceTranslucent`+`COMPONENT_THICK` blur+`backgroundEffect`+描边+阴影） |
| 6 | `pages/SiteRoutingPage.ets` | SiteInputDialog 根容器同上 |
| 7 | `pages/NodeSelectionPage.ets` | NodeDeleteDialog 根容器同上 |

10 个 `@CustomDialog` 均未设 `customStyle`（官方 FAQ：customStyle=true 时弹窗背板完全自定义，
**暂不支持**沉浸式系统材质适配），因此应用级 enable 后默认获得系统 ULTRA_THICK 沉浸材质背板；
根容器的不透明背景/模糊/阴影是材质被遮挡的唯一原因，移除后由系统材质统一接管（含圆角与自带阴影）。
弹窗内部内容层（行卡片、输入框、按钮的主题色）全部保持不动。

## 明确没有做的事

- **主页内容区按钮不挂 systemMaterial**：官方明确 Button 沉浸光感仅在标题栏/底部 TabBar 生效，
  内容区设置不生效；不写无效代码，按钮保持主题色+点击态。
- **不引入 Navigation**：现有 router+自绘顶栏结构不动；自绘顶栏属于普通容器，不在沉浸光感生效范围。
- **底部 HdsTabs 不动**：已是官方标准写法（`barFloatingStyle.systemMaterialEffect(IMMERSIVE + ADAPTIVE)`
  + `gradientMask` + `lightColor`，见 `LIGHT_EFFECT_THEMING_2026-10-07.md`）。
- **宽屏侧边页签不动**：barFloatingStyle 官方仅支持 `End + vertical=false`，侧边形态继续走
  `barBackgroundBlurStyle(COMPONENT_ULTRA_THICK)` 官方 blur 通道。
- **Toggle 不加组件级配置**：ToggleType.Switch 在 enable 模式下默认开启沉浸光感
  （材质参数仅作开关标记，实际视觉用组件内部预设）。
- **promptAction.showDialog / showToast 不改**：enable 模式下默认沉浸材质（ULTRA_THICK / THICK），
  且调用处未设背景色，无遮挡。
- 不自绘光效、不加动画/定时器（功耗优化：控制面积与层数，材质交系统按算力渲染）。

## 验证结果

### 编译（hvigor 命令行，本机 SDK HarmonyOS 26.0.0(105)）

```
export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"   # java 必须在 PATH（打包工具 spawn java）
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
JAVA_HOME='C:\Program Files\Huawei\DevEco Studio\jbr'
node 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' \
  --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
```

- **BUILD SUCCESSFUL**（22.6s）——`targetSdkVersion "26.0.0"` 与 `compatibleSdkVersion "6.1.1(24)"` 混用通过校验
- 产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（20,727,752 bytes）
- 打包产物 `module.json` 已含 `"UIMaterial.state","value":"enable"`（已验证）

### 自检脚本

| 脚本 | 结果 |
| --- | --- |
| verify-logic-pure | 228 passed, 0 failed |
| verify-site-routing | 54 passed, 2 failed（**均为基线存量**：「Home network rules dialog merges rule entries」在改动前备份上同样失败——`Text('网络规则')` 基线缺失；另一项检查保存逻辑，本轮 diff 未触及） |
| verify-app-routing | 崩溃于基线断言（VpnExtensionAbility `cleanupResources`，与本轮无关的存量问题） |

**零新增失败**；所有改动文件与改前备份（`_audit/light-sense-backup-2026-10-15/`）diff 逐行核对，
仅含本轮移除的样式链与新增配置。

### 真机待确认（需 DevEco Studio Run 走托管调试签名）

1. 任意弹窗（规则模式设置 / 备份 / 删除确认 / 添加名单）：背板是否呈 ULTRA_THICK 沉浸材质（深浅主题）。
2. 所有 Toast / promptAction 确认框：是否呈沉浸材质。
3. 规则页 / 设置页的 Toggle 开关：滑块视觉是否随材质（官方内部预设）。
4. 底部页签栏：浅色蓝色光感 + 毛玻璃透光（上一轮改动，随本轮 targetSDK=26 一并生效）。
5. 低算力设备：沉浸光感自动降级（官方：低算力不显示光感、材质层退化为背景色）。

## 回退方式

备份在 `_audit/light-sense-backup-2026-10-15/`，逐文件拷回即可；或按上表逐文件单独回退
（每项互不依赖：#1/#2 是配置，#3–#7 是各页面独立的根容器样式移除）。
