# TunBox for Windows

WPF (.NET 8) 桌面客户端，内核是 mihomo（Clash Meta）的 smart 分支。桌面横屏布局：
左侧栏五页导航（仪表盘 / 代理 / 请求 / 工具 / 设置），功能形态对齐 FlClash：

- **仪表盘**：桌面标准大开关（52×30，状态圆点灰/琥珀/绿）是唯一总闸——连接即接管系统代理，断开自动放手；出站模式分段、TUN 独立开关、实时速率图（与连接卡等高）、快捷出口下拉、端口摘要、出口 IP 对照。
- **代理**（配置与代理已合并）：一个订阅一张卡——卡头是订阅名、节点计数、更新时间、流量条、自动更新档位与彩色操作按钮（⚡测速琥珀 / ⟳更新蓝：顺时针旋转 700ms 一圈、成功变绿勾回弹反馈 / ✎编辑绿 / 🗑删除红），**展开即该订阅的节点网格**（点击选出口、点延迟数字单测）；smart「自动选择」置顶；搜索跨卡过滤、排序（默认/延迟/名称）、全部测速、全部更新、导入订阅。
- **请求**：完整连接表（目标 / 规则 / 链 / 进程 / 双向速率与累计 / 断开），搜索过滤、暂停刷新、断开全部。
- **工具**：网络检测（直连 vs 走代理对照）、Hosts 静态表、覆写（Merge YAML 深合并 + Script JS `main(config)`，Jint 引擎，出错自动跳过并提示）、内核日志实时查看。
- **设置**：外观（跟随系统/浅/深）、语言（简体中文 / English / 跟随系统，切换即时生效）、全局快捷键（打开窗口 / 连接断开 / 系统代理 / TUN，点击输入框直接按组合键）、端口与外部控制器密钥、TUN 协议栈 / MTU / 严格路由 / 端点独立 NAT、分流规则与应用分流、检查更新、关于（内核版本）。

其余：系统托盘（连接/断开快捷开关）、窗口位置与尺寸记忆、静默启动、单实例唤醒、关闭行为记忆。

视觉规格对齐桌面客户端（FlClash / Clash Verge Rev 一系）：基础字号 13.5、卡片标题 15 SemiBold、页头 19、侧栏 224px（图标 17 + 文字 14）；分组页签选中为实心品牌色白字，表格为「细底线表头 + 圆角悬停/选中行」的自绘样式，不再有 Win32 经典控件观感。

## 目录

```
TunBox-Windows/
├── TunBox.sln
├── src/TunBox.Core/      # 与界面无关的全部逻辑：订阅解析/拉取、配置生成、内核宿主、控制 API、分流库、系统代理/TUN
├── src/TunBox.App/       # WPF 界面（MainViewModel + MainWindow + 托盘 + 对话框）
├── tests/TunBox.Core.Tests/
└── scripts/              # 发布与打包
```

## 先决条件：内核文件（不入库）

`core/` 被 `.gitignore` 排除（66MB + 9.3MB 的二进制）。构建前需要放好两个文件：

| 文件 | 来源 |
| --- | --- |
| `core/tunbox-core.exe` | 仓库根 `mihomo-build/` 下的 mihomo-smart 构建产物 `mihomo.exe`，改名而来 |
| `core/Model.bin` | 仓库根 `mihomo-build/Model.bin`（smart 组的 LightGBM 模型） |

换内核的完整流程与踩坑见仓库根 `MIHOMO_SMART_KERNEL_SWAP.md`。缺这两个文件时
`scripts/publish.ps1` 会直接报错退出，不会给你一个装完打不开的安装包。

## 构建与测试

```powershell
dotnet build TunBox.sln -c Release
dotnet test  TunBox.sln -c Release      # 120 条：解析契约 / 配置生成不变量 / 真内核 E2E / UI 绑定与摆位
```

测试里有两条是「真起内核进程」的端到端：判据取内核 stdout 的 `RESTful API listening at:` 行，
不依赖本机回环 HTTP 是否通畅。

## 出包

```powershell
powershell -File scripts/publish.ps1          # 自包含目录 publish/（含 core/，缺文件即报错）
powershell -File scripts/make-installer.ps1   # NSIS 安装包 dist/TunBox-Setup-<版本>.exe
```

安装包是标准 NSIS 向导（欢迎 → 目录 → 进度 → 完成/运行），按当前用户装到
`%LOCALAPPDATA%\Programs\TunBox`，不需要管理员。`scripts/installer.nsi` 必须存成 **UTF-8 with BOM**，
否则 makensis 报 "Bad text version"。

## 运行期数据

- 配置与节点库：`%APPDATA%\TunBox\settings.json`、`nodes.json`
- 内核工作目录：`%APPDATA%\TunBox\runtime\`（`config.yaml`、`core.log`、`geoip.metadb`、`cache.db`）
- 崩溃与启动面包屑日志：`%APPDATA%\TunBox\logs\`

## 已知限制

- 安装包未做代码签名（SmartScreen 会拦一次）。
- 深色主题、配置备份/恢复未做。
- 只声明 `proxy-providers` 的订阅（节点要靠运行时下载）尚未支持。
