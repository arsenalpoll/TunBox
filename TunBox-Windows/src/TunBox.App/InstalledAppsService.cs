using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace TunBox.App;

/// <summary>一个可选的应用：DisplayName 给人看，ExeName 就是应用分流要填的进程名。</summary>
public sealed record InstalledApp(string DisplayName, string ExeName);

/// <summary>
/// 本地已安装应用的枚举。开始菜单 .lnk（全体用户 + 当前用户）为主，注册表
/// Uninstall 的 DisplayIcon 为辅——目标是拿到 exe 文件名，和应用分流走
/// PROCESS-NAME 规则的口径一致（见 Models.cs 的 AppProcesses 注释）。
/// </summary>
public static class InstalledApps
{
    /// <summary>
    /// 扫描已安装应用，按进程名去重（大小写不敏感），按显示名排序。
    /// 任何一路（开始菜单 / 注册表 / 单个 lnk）失败都不影响其余，最多少扫到几个。
    /// </summary>
    public static IReadOnlyList<InstalledApp> Enumerate()
    {
        var byExe = new Dictionary<string, InstalledApp>(StringComparer.OrdinalIgnoreCase);

        void Add(string? display, string? exePath)
        {
            if (string.IsNullOrWhiteSpace(exePath)) return;
            var path = exePath.Trim().Trim('"');
            var exeName = Path.GetFileName(path);
            if (!IsWorthListing(exeName, path)) return;
            if (byExe.ContainsKey(exeName)) return;
            var name = string.IsNullOrWhiteSpace(display)
                ? Path.GetFileNameWithoutExtension(exeName)
                : display.Trim();
            byExe[exeName] = new InstalledApp(name, exeName);
        }

        // 开始菜单 .lnk：最贴近「用户真的装了、会去点开」的应用
        foreach (var root in new[]
                 {
                     Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
                     Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
                 })
        {
            var dir = Path.Combine(root, "Programs");
            if (!Directory.Exists(dir)) continue;
            try
            {
                foreach (var lnk in Directory.EnumerateFiles(dir, "*.lnk", SearchOption.AllDirectories))
                {
                    try
                    {
                        var target = ResolveShortcut(lnk);
                        if (target != null) Add(Path.GetFileNameWithoutExtension(lnk), target);
                    }
                    catch { /* 单个 lnk 解析失败不算事 */ }
                }
            }
            catch { /* 整个目录扫不了（权限等）不算事 */ }
        }

        // 注册表 Uninstall：补上没有开始菜单快捷方式的装机软件
        ScanRegistry(RegistryHive.LocalMachine, RegistryView.Registry64, Add);
        ScanRegistry(RegistryHive.LocalMachine, RegistryView.Registry32, Add);
        ScanRegistry(RegistryHive.CurrentUser, RegistryView.Default, Add);

        return byExe.Values.OrderBy(a => a.DisplayName, StringComparer.CurrentCulture).ToList();
    }

    /// <summary>解析出的 exe 是否值得列为可选应用：得是 exe、不是卸载器/安装器，也不在系统目录。</summary>
    public static bool IsWorthListing(string? exeName, string? exePath)
    {
        if (string.IsNullOrWhiteSpace(exeName)) return false;
        if (!exeName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return false;
        var lower = exeName.ToLowerInvariant();
        if (lower.StartsWith("unins") || lower.StartsWith("setup") || lower.StartsWith("update")) return false;
        var full = exePath?.ToLowerInvariant() ?? "";
        if (full.Contains("\\windows\\")) return false;
        return true;
    }

    private static void ScanRegistry(RegistryHive hive, RegistryView view, Action<string?, string?> add)
    {
        try
        {
            using var root = RegistryKey.OpenBaseKey(hive, view);
            using var uninstall = root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall");
            if (uninstall == null) return;
            foreach (var sub in uninstall.GetSubKeyNames())
            {
                try
                {
                    using var key = uninstall.OpenSubKey(sub);
                    var display = key?.GetValue("DisplayName") as string;
                    var icon = key?.GetValue("DisplayIcon") as string;
                    if (display == null || icon == null) continue;
                    // DisplayIcon 可能带图标索引后缀：C:\App\app.exe,0
                    add(display, icon.Split(',')[0]);
                }
                catch { /* 单个条目读不了不算事 */ }
            }
        }
        catch { /* 整个 hive 读不了不算事 */ }
    }

    /// <summary>WScript.Shell 解析 .lnk 的目标路径；解析失败返回 null。</summary>
    private static string? ResolveShortcut(string lnkPath)
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) return null;
        object? shell = null;
        object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember("CreateShortcut",
                System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
            if (shortcut == null) return null;
            var targetType = shortcut.GetType();
            var target = targetType.InvokeMember("TargetPath",
                System.Reflection.BindingFlags.GetProperty, null, shortcut, null) as string;
            return string.IsNullOrWhiteSpace(target) ? null : target;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (shortcut != null) Marshal.FinalReleaseComObject(shortcut);
            if (shell != null) Marshal.FinalReleaseComObject(shell);
        }
    }
}
