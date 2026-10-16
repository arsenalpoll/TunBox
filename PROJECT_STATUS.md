# PROJECT_STATUS —— 项目现状速读（2026-10-16）

> 给任何新会话的 AI：读完本文件即可接手。更细的历史见「文档索引」一节。
> 数据可能滞后，以 git log 与各 `*_2026-*.md` 为准。

## 这是什么项目

**TunBox**（bundleName `com.tunbox.client`，versionName 0.3.1）——鸿蒙 NEXT 原生 VPN 客户端，
mihomo 内核（Go c-shared `libgojni.so`）+ ArkTS UI。仓库根 `C:\Worker\TunBox`，
应用工程在子目录 `TunBox_HarmonyOS/`（DevEco 打开它）。仓库根还放文档、签名脚本、自检脚本。

## 分支模型（2026-10-15 定）

| 分支 | 用途 |
| --- | --- |
| `main` | **正式发布分支，平时不动**。发布签名走仓库根 `sign-nexus-package.ps1`（AGC 发布证书） |
| `test-debug-sign` | **测试开发分支，日常改代码都在这里**。DevEco 调试签名安装测试 |

- 工作流：test-debug-sign 改代码 → DevEco Run（调试签名）装真机验证 → 确认没问题后
  `git checkout main && git merge test-debug-sign` 同步，再打发布包。
- **合并到 main 前必须把 `TunBox_HarmonyOS/build-profile.json5` 的 `signingConfigs` 恢复为空数组**
  （调试证书配置只留在测试分支工作区；发布签名脚本不读它，但它会污染 main）。
- 仓库无远程（本地 git）；`skills/nexus-push/SKILL.md` 有推 GitHub 的流程（含令牌，永不提交）。
- `.gitignore` 已完备（排除 skills/、_audit/、构建产物、签名材料）——**不要手改 .gitignore 放开密钥目录**。

## 构建 / 签名 / 安装

```bash
# 构建（git-bash，TunBox_HarmonyOS/ 下；jbr/bin 必须进 PATH，否则打包工具 spawn java ENOENT）
export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"
DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk" \
JAVA_HOME="C:/Program Files/Huawei/DevEco Studio/jbr" \
  node "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
```

- 产物 `entry/build/default/outputs/default/entry-default-{unsigned,signed}.hap`
  （build-profile `signingConfigs` 非空时出 signed 包，如测试分支的调试证书配置）。
- **发布包**：仓库根 `NEXUS_KEY_PASSWORD=... powershell -File sign-nexus-package.ps1 -Kind hap`
  → `dist/TunBox-<version>-release-signed.hap`（材料 `C:\Worker\AGC通用证书\`，不入库）。
- SDK：compatibleSdkVersion `6.1.1(24)` + targetSdkVersion `26.0.0` 混用可通过 hvigor
  （targetSDK 26 是沉浸光感硬性要求，compatible 保持向下兼容）。

## 主题系统（浅色 / 深色）

| 令牌 | 浅色 | 深色 | 落点 |
| --- | --- | --- | --- |
| 页面背景 | `#F7F8FA` | `#171B22` | `Nx.bg()`、`ui_background`、窗口底色（ThemeService.syncSystemBars） |
| 卡片背景 | `#FFFDFA`（玻璃 42%） | `#1E293B` 系 | `Nx.surface()`、`Nx.glassFill()`、`ui_surface_*` |
| 选中项背景 | `#E6EAF2` | — | `ui_selected_background`、`Nx.accentBg()` |
| 页签图标 | 选中 `#3268B2` / 未选中 `#827D75` | 亮蓝/灰 | `Nx.tabIconActive/Inactive()`，MainPage tabStyle fontColor |
| 窗口底色 | = 页面背景 | = 页面背景 | `ThemeService`（状态栏/底部系统区透出这层，必须与页面同色否则有分割感） |

- 沉浸光感：**targetSDK ≥ 26.0.0 + module.json5 metadata `ohos.arkui.UIMaterial.state=enable`**（应用级开关）。
  10 个 `@CustomDialog` 根容器只留 padding/borderRadius（不透明背景/模糊/shadow 会遮死系统 ULTRA_THICK 材质背板）。
  **内容区卡片/按钮不能挂 systemMaterial**（官方：仅标题栏/底部 TabBar 生效）——内容区玻璃走
  「半透明底 + COMPONENT_THICK blur」配方（`Nx.glassFill/glassEdge/glassBlur/glassEffect`）。
- 底部导航：HdsTabs 悬浮 `barFloatingStyle.systemMaterialEffect(IMMERSIVE+ADAPTIVE)` + gradientMask +
  lightColor；侧边形态（≥840vp）走 blur 通道（悬浮样式官方仅支持底部）。

## 功能特性速记

- **节点单列/双列排布**：订阅页右上角「左右分栏」图标按钮（刷新按钮左侧，纯 Rect 绘制，
  显示当前模式：单列→横框+中缝，双列→双竖框）。选择持久化在 `SettingsService`（key `node_columns`）。
  节点卡是 `SubscriptionPage.nodeCard()` @Builder（单列 100% / 双列 48.5% 共用样式）。
- 启动按钮：`components/StatusRing.ets` 三层（呼吸光晕/圆盘/核心）。动画候选已出（scratch/power-button-preview.html），**未实施**（用户暂缓）。
- HdsTabs 主导航（MainPage）+ router 推入式子页（无 Navigation 组件，顶栏为自绘 Row）。
- 弹窗全是 `@CustomDialog`（10 个）+ promptAction；无 bindMenu/Select/Slider，Toggle 用 Switch。

## 文档索引（仓库根）

| 文档 | 内容 |
| --- | --- |
| `LIGHT_SENSE_FULL_ADAPTATION_2026-10-15.md` | 沉浸光感完全适配（官方依据/改动清单/验证/回退） |
| `LIGHT_EFFECT_THEMING_2026-10-07.md` | 浅色光感/底部毛玻璃/配置页主题（前一轮） |
| `TEST_BRANCH_README.md` | 测试分支与调试签名流程 |
| `AGENTS.md` | 会话记忆约定、打包/推送 skills 指引 |
| `Nexus-HarmonyOS-开发踩坑记录.md` | 平台坑总集 |
| `TunBox_HarmonyOS/skills`、`scripts/verify-*.mjs` | 自检脚本（零新增失败纪律：基线存量失败先在备份上复跑对照） |

## 铁律（改代码前必读）

1. **仓库改文件前先备份**到 `_audit/<topic>-backup-<日期>/`，改完 diff 逐行核对只含本轮编辑。
2. 圆形一律纯色 `.fill`，禁 `.shadow`/渐变通用属性（ArkTS 按矩形渲染透出方形底）。
3. 系统材质开启处不得再设 backgroundColor/backgroundBlurStyle/shadow（层级在其之下，会被遮死）。
4. 生效范围外（内容区按钮/自绘顶栏）不写 systemMaterial——无效代码。
5. 自检失败先在改前备份上复跑，判定基线存量还是本轮引入（site-routing 2 项、app-routing 崩溃为基线）。
6. 版本发布：versionCode 必须高于设备历史最高（module.json5 + AppScope/app.json5 双改）。
