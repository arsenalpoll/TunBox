using System.IO;
using System.Windows;
using TunBox.App;
using TunBox.Core.Storage;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>「从已装应用选…」：枚举过滤 + 选择对话框的绑定与勾选。</summary>
public class AppPickerTests
{
    private static string TempHome(string tag)
    {
        var home = Path.Combine(Path.GetTempPath(), "tunbox-test-" + tag + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(home);
        return home;
    }

    [Fact]
    public void Filter_rejects_non_exe_uninstallers_and_system_paths()
    {
        Assert.True(InstalledApps.IsWorthListing("WeChat.exe", @"C:\Program Files\Tencent\WeChat\WeChat.exe"));
        Assert.True(InstalledApps.IsWorthListing("Some App.exe", @"D:\Apps\Some App\Some App.exe"));
        Assert.False(InstalledApps.IsWorthListing("uninstall.exe", @"C:\App\uninstall.exe"));
        Assert.False(InstalledApps.IsWorthListing("unins000.exe", @"C:\App\unins000.exe"));
        Assert.False(InstalledApps.IsWorthListing("setup.exe", @"C:\App\setup.exe"));
        Assert.False(InstalledApps.IsWorthListing("notepad.exe", @"C:\Windows\System32\notepad.exe"));
        Assert.False(InstalledApps.IsWorthListing("readme.txt", @"C:\App\readme.txt"));
        Assert.False(InstalledApps.IsWorthListing("", @"C:\App\"));
    }

    [Fact]
    public void Enumeration_finds_installed_apps_with_process_names()
    {
        var apps = InstalledApps.Enumerate();
        Assert.True(apps.Count > 0, "这台机器上一个已安装应用都没扫到");
        // 去重：进程名唯一（大小写不敏感）
        var dupes = apps.GroupBy(a => a.ExeName, StringComparer.OrdinalIgnoreCase)
            .Where(g => g.Count() > 1).ToList();
        Assert.Empty(dupes);
        // 全部是合法进程名：.exe、非卸载器
        Assert.All(apps, a =>
        {
            Assert.EndsWith(".exe", a.ExeName, StringComparison.OrdinalIgnoreCase);
            Assert.False(a.ExeName.StartsWith("uninst", StringComparison.OrdinalIgnoreCase));
        });
        // 排序：按显示名升序
        var sorted = apps.OrderBy(a => a.DisplayName, StringComparer.CurrentCulture).ToList();
        Assert.Equal(sorted, apps);
    }

    [Fact]
    public void Dialog_prechecks_existing_processes_and_collects_selection()
    {
        var apps = new[]
        {
            new InstalledApp("微信", "WeChat.exe"),
            new InstalledApp("Something", "Some App.exe"),
            new InstalledApp("QQ", "QQ.exe"),
        };
        var (_, picked) = WpfHost.OnUi(() =>
        {
            var dlg = new AppPickerDialog(apps, new[] { "wechat.exe" });
            dlg.BuildItems(apps);
            Assert.True(dlg.Selected.Count == 0, "构造后还没点确定不该有结果");
            // 已在文本框里的进程名默认勾上（大小写不敏感）
            Assert.Equal(1, dlg.CheckedCount);

            // 全选 / 清空
            dlg.SelectAllVisible();
            Assert.Equal(3, dlg.CheckedCount);
            dlg.SelectNoneVisible();
            Assert.Equal(0, dlg.CheckedCount);

            // 搜索过滤：只动可见行
            dlg.SetSearch("qq");
            dlg.SelectAllVisible();
            Assert.Equal(1, dlg.CheckedCount);
            dlg.SetSearch("");

            return (true, dlg.CollectSelected().Select(a => a.ExeName).ToList());
        }).Result;

        Assert.Equal(new[] { "QQ.exe" }, picked);
    }

    [Fact]
    public void Picker_dialog_fits_inside_the_main_window()
    {
        var home = TempHome("apppicker");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var window = new MainWindow(new MainViewModel(new Workspace(home)));
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                var dlg = new AppPickerDialog(new[]
                {
                    new InstalledApp("微信", "WeChat.exe"),
                    new InstalledApp("QQ", "QQ.exe"),
                }) { Owner = window };
                dlg.Show();
                WpfHost.PumpUntil(() => dlg.ActualWidth > 10);
                var msgs = new List<string>();
                if (dlg.ActualWidth >= window.ActualWidth) msgs.Add($"选择框 {dlg.ActualWidth:0} ≥ 主窗口 {window.ActualWidth:0}");
                if (dlg.ActualHeight >= window.ActualHeight) msgs.Add("选择框比主窗口还高");
                return msgs.Count > 0 ? string.Join("；", msgs) : null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }
}
