# test-debug-sign 测试分支（DevEco 调试签名安装用）

> 基线：`main` @ `6e15422`（2026-10-15，含沉浸光感适配、暖灰白/石墨蓝灰主题、节点单列/双列排布）。
> 本分支与 main 代码一致，仅用于 DevEco 托管调试签名安装测试；发布时合并回 main。

## 目录

- **DevEco 打开的工程目录**：`C:\Worker\TunBox\TunBox_HarmonyOS`
- 仓库根：`C:\Worker\TunBox`（当前分支 `test-debug-sign`）
- 调试签名产物（DevEco Run 自动产出）：`TunBox_HarmonyOS\entry\build\default\outputs\default\entry-default-signed.hap`

## 测试安装步骤（DevEco 托管调试签名）

1. DevEco Studio 打开 `C:\Worker\TunBox\TunBox_HarmonyOS`。
2. `File → Project Structure → Signing Configs`，勾选 **Automatically generate signature**（登录华为账号，自动生成调试证书 `.cer`/`.p7b`/`.p12`，写入 `build-profile.json5` 的 `signingConfigs.debug`）。
   - 自动生成的调试签名材料默认在 `C:\Users\<user>\.ohos\config\`，已入 .gitignore（*.p12/*.cer/*.p7b），不会进仓库。
3. 连接真机（hdc 或 USB），点 **Run**：DevEco 编译 + 调试签名 + 安装启动。
4. 验证项：沉浸光感（弹窗背板/底部栏/卡片玻璃）、浅色暖灰白 `#F7F8FA` / 深色石墨蓝灰 `#171B22` 主题、右上角「左右分栏」按钮的单列/双列切换。

## 发布时合并

```bash
cd C:\Worker\TunBox
git checkout main
git merge test-debug-sign        # 若调试签名只改了 build-profile（signingConfigs），合并后删掉该段再提交
git branch -d test-debug-sign    # 可选：合并后删除测试分支
```

注意：DevEco 自动生成的 `signingConfigs` 含调试证书路径，**合并回 main 前应把 `build-profile.json5` 的 signingConfigs 恢复为空数组**（发布签名走仓库根 `sign-nexus-package.ps1`，见 AGENTS.md / nexus-pack skill）。
