using System.Diagnostics;
using System.IO;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using TunBox.App;
using TunBox.Core.Models;
using TunBox.Core.Services;

namespace TunBox.App;

public partial class MainWindow : Window
{
    public MainViewModel ViewModel { get; }

    public MainWindow() : this(null) { }

    /// <summary>可注入视图模型：默认构造会落到用户真实的 %APPDATA%\TunBox，测试必须能注入。</summary>
    public MainWindow(MainViewModel? viewModel)
    {
        // 先建 VM（注入优先）：主题与语言都按「这一份」设置来，测试注入的设置不能被真实盘上的覆盖。
        ViewModel = viewModel ?? new MainViewModel();
        try
        {
            var settings = ViewModel.ManagerSettings;
            // 暗色覆盖必须在 InitializeComponent 之前合并：StaticResource 在 XAML 解析时取值。
            if (ThemeManager.ShouldBeDark(settings.DarkTheme))
                ThemeManager.ApplyDark(Resources);
        }
        catch { /* 设置读不到就按系统偏好 */ }
        InitializeComponent();
        // 语言是 DynamicResource，在 InitializeComponent 之后应用也能立即解析。
        try
        {
            Lang.EnsureApplied(Lang.Resolve(ViewModel.ManagerSettings.Language));
            ViewModel.RefreshLocalizedOptions();   // VM 可能在字典挂上前就构造好了
        }
        catch { /* 语言字典挂不上就按默认中文 */ }
        DataContext = ViewModel;
        // 仪表盘的速率图：采样事件 → 图表（窗口关了要摘掉，VM 比窗口活得久）
        ViewModel.SpeedSampled += OnSpeedSampled;
        ViewModel.NavigateRequested += OnNavigateRequested;
        try
        {
            // 任务栏/标题栏的大图标从磁盘上的 ico 取：WPF 对多帧 ico 取帧的大小
            // 与位图来源有关，直接用文件最稳。SetupTray 已把它写到 %APPDATA%\TunBox。
            var iconPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TunBox", "tray.ico");
            if (File.Exists(iconPath))
                Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(iconPath));
            else
                Icon = System.Windows.Media.Imaging.BitmapFrame.Create(
                    new Uri("pack://application:,,,/Assets/tunbox.ico"));
        }
        catch { /* 图标失败不影响功能 */ }
        RestoreWindowPlacement();
    }

    // ── 速率图与导航 ─────────────────────────────────────────────────────

    /// <summary>速率采样 → 仪表盘速率图（VM 只发事件，不摸控件）。</summary>
    private void OnSpeedSampled(double up, double down) => RateChart.Push(up, down);

    /// <summary>页内跳转（仪表盘「查看请求」等）→ 翻到对应页签。</summary>
    private void OnNavigateRequested(string page)
    {
        var tab = Shell.Items.OfType<TabItem>().FirstOrDefault(t => (t.Header as string) == page);
        if (tab != null) tab.IsSelected = true;
    }

    protected override void OnClosed(EventArgs e)
    {
        ViewModel.SpeedSampled -= OnSpeedSampled;
        ViewModel.NavigateRequested -= OnNavigateRequested;
        base.OnClosed(e);
    }

    // ── 窗口位置/尺寸记忆 ────────────────────────────────────────────────

    private void RestoreWindowPlacement()
    {
        try
        {
            var s = ViewModel.ManagerSettings;
            if (s.WindowWidth is >= 400 and <= 10000) Width = s.WindowWidth;
            if (s.WindowHeight is >= 300 and <= 10000) Height = s.WindowHeight;
            if (s.WindowMaximized) WindowState = WindowState.Maximized;
            else if (!double.IsNaN(s.WindowLeft) && !double.IsNaN(s.WindowTop))
            {
                Left = s.WindowLeft;
                Top = s.WindowTop;
            }
        }
        catch { /* 记忆坏了就用默认位置 */ }
    }

    private void SaveWindowPlacement()
    {
        try
        {
            var s = ViewModel.ManagerSettings;
            s.WindowMaximized = WindowState == WindowState.Maximized;
            if (WindowState == WindowState.Normal)
            {
                s.WindowWidth = ActualWidth;
                s.WindowHeight = ActualHeight;
                s.WindowLeft = Left;
                s.WindowTop = Top;
            }
            ViewModel.SaveSettingsQuiet();
        }
        catch { /* 记不上就算了 */ }
    }

    // ── 页面事件 ─────────────────────────────────────────────────────────

    /// <summary>「＋」导入：链接 / 本地文件 / 粘贴节点（对话框里三选一）。</summary>
    private async void OnImportClick(object sender, RoutedEventArgs e)
    {
        var dialog = new ImportDialog { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result == null) return;
        var (kind, value) = dialog.Result.Value;
        switch (kind)
        {
            case "file": await ViewModel.ImportFileAsync(value); break;
            case "url" or "text": await ViewModel.ImportAsync(value); break;
        }
    }

    /// <summary>仪表盘的开关：拨一下就把「保存 + 立刻接管/放手」整条路走完。</summary>
    private async void OnToggleApply(object sender, RoutedEventArgs e)
    {
        await ViewModel.ApplySwitchAsync();
    }

    /// <summary>点订阅卡上的测速：只测这张卡当前显示的节点。直接调视图模型，不走命令绑定（绑定失败是静默的，踩过）。</summary>
    private void OnTestSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            ViewModel.TestSubscription(item);
    }

    /// <summary>编辑订阅（名称 / 链接）。</summary>
    private void OnEditSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: SubscriptionItem item }) return;
        var dialog = new EditDialog(item.Name, item.Model.Url) { Owner = this };
        if (dialog.ShowDialog() != true) return;
        var (name, url) = dialog.Values;
        if (name.Length == 0) { ViewModel.DetailText = Lang.T("Msg.SubNameEmpty"); return; }
        ViewModel.EditSubscription(item, name, url);
    }

    /// <summary>应用分流的「从已装应用选…」：勾选后把进程名并回文本框（手动填的保留）。</summary>
    private void OnPickAppsClick(object sender, RoutedEventArgs e)
    {
        var existing = ViewModel.AppProcesses
            .Split(new[] { ',', '\n', ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim()).Where(p => p.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var dialog = new AppPickerDialog(preChecked: existing) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Selected.Count == 0) return;
        foreach (var app in dialog.Selected) existing.Add(app.ExeName);
        ViewModel.AppProcesses = string.Join(", ", existing.OrderBy(n => n, StringComparer.CurrentCulture));
    }

    /// <summary>页签切换 → 连接页/工具页要轮询，别的页不该摊上这份开销。</summary>
    private void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is TabControl { SelectedItem: TabItem tab })
            ViewModel.SetActiveTab(tab.Header as string);
    }

    /// <summary>点节点行 = 把出口切到这一行。</summary>
    private void OnNodeRowClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: NodeItem item })
            ViewModel.SelectedNode = item;
    }

    /// <summary>点延迟数字 = 只测这一个节点。</summary>
    private void OnLatencyClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: NodeItem item })
        {
            ViewModel.TestOne(item);
            e.Handled = true;   // 别让同一次点击又触发整行的选中
        }
    }

    private void OnUpdateSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            _ = ViewModel.UpdateSubscriptionAsync(item);
    }

    private void OnRemoveSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            ViewModel.RemoveSubscription(item);
    }

    private void OnCloseConnClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ConnectionItem item })
            ViewModel.CloseConnection(item);
    }

    /// <summary>点出口 IP = 复制到剪贴板。测试环境没有剪贴板也无所谓：失败静默。</summary>
    private void OnCopyEgressIp(object sender, MouseButtonEventArgs e)
    {
        var ip = ViewModel.EgressIpText;
        if (ip.Length == 0) return;
        try { Clipboard.SetText(ip); ViewModel.DetailText = Lang.F("Msg.CopyIp", ip); }
        catch { /* 剪贴板被拦不挡其它流程 */ }
    }

    /// <summary>工具页清空日志显示（不动磁盘上的文件）。</summary>
    private void OnClearLogClick(object sender, RoutedEventArgs e) => ViewModel.ClearToolsLog();

    /// <summary>关于页的开源地址。</summary>
    private void OnOpenRepoClick(object sender, MouseButtonEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "https://" + UpdateChecker.Repo.Replace("github.com/", ""),
                UseShellExecute = true,
            });
        }
        catch { /* 浏览器打不开就算了 */ }
    }

    /// <summary>
    /// 点 X 的去向：问一次并记住，或者按记住的选择走。托盘不可用时不给「缩到托盘」这个选项。
    /// 顺手把窗口位置/尺寸记住（下次打开还原）。
    /// </summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        SaveWindowPlacement();
        if (Application.Current is not App app || app.IsExiting)
        {
            base.OnClosing(e);
            return;
        }
        e.Cancel = true;
        var choice = ViewModel.CloseMode;
        if (choice == "ask")
        {
            var allowTray = app.TrayAvailable;
            var result = MessageBox.Show(this,
                allowTray ? Lang.T("Msg.CloseAskTray") : Lang.T("Msg.CloseAskExit"),
                "TunBox", MessageBoxButton.YesNo, MessageBoxImage.Question);
            choice = result == MessageBoxResult.Yes ? (allowTray ? "tray" : "exit") : "cancel";
            if (choice == "cancel") return;
            ViewModel.RememberCloseBehavior(choice);
        }
        if (choice == "tray" && app.TrayAvailable) app.MinimizeToTray();
        else app.ExitApplication();
    }
}
