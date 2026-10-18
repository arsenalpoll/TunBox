using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;
using TunBox.App;
using TunBox.Core.Storage;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>共享的 WPF STA 宿主：UI 层的 bug 只有真的起了消息泵才测得出来。</summary>
internal static class WpfHost
{
    private static readonly object Gate = new();
    private static System.Windows.Threading.Dispatcher? _dispatcher;

    public static System.Windows.Threading.Dispatcher Ui
    {
        get
        {
            lock (Gate)
            {
                if (_dispatcher != null) return _dispatcher;
                Exception? bootError = null;
                var ready = new ManualResetEventSlim(false);
                var thread = new Thread(() =>
                {
                    try
                    {
                        _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                        _dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
                        ready.Set();
                        System.Windows.Threading.Dispatcher.Run();
                    }
                    catch (Exception e) { bootError = e; ready.Set(); }
                });
                thread.SetApartmentState(ApartmentState.STA);
                thread.IsBackground = true;
                thread.Name = "tunbox-wpf-test-pump";
                thread.Start();
                if (!ready.Wait(TimeSpan.FromSeconds(15))) throw new TimeoutException("STA 宿主启动超时");
                if (bootError != null) throw bootError;
                return _dispatcher!;
            }
        }
    }

    public static void OnUi(Action action) => Ui.Invoke(action);

    public static Task<T> OnUi<T>(Func<T> func) => Task.FromResult(Ui.Invoke(func));

    public static bool PumpUntil(Func<bool> predicate, int milliseconds = 8000)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromMilliseconds(milliseconds);
        var frame = new System.Windows.Threading.DispatcherFrame();
        Ui.InvokeAsync(() =>
        {
            while (DateTime.UtcNow < deadline && !predicate())
            {
                System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(
                    System.Windows.Threading.DispatcherPriority.Background, new Action(() => { }));
                Thread.Sleep(20);
            }
            frame.Continue = false;
        });
        System.Windows.Threading.Dispatcher.PushFrame(frame);
        return predicate();
    }
}

/// <summary>
/// UI 层回归。XAML 写错绑定名是**静默**的（不报错、那块区域永远空白），
/// 所以绑定名当成契约逐个验；导入后的列表刷新必须真的发生。
/// 布局契约是桌面横屏：左侧栏五页（仪表盘/代理/请求/配置/设置），对齐 FlClash。
/// </summary>
public class UiTests
{
    private static string TempHome(string tag) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "TunBox", "ui-" + tag + "-" + Guid.NewGuid().ToString("N")[..6]);

    private static readonly string[] Pages = { "仪表盘", "代理", "请求", "工具", "设置" };

    /// <summary>
    /// 命令里冒出来的异常（真机：热重载超时抛 TaskCanceledException → 「未处理的异常」弹窗）
    /// 必须落在 Failed 上，而不是把弹窗糊在用户脸上。
    /// </summary>
    [Fact]
    public void Async_command_reports_failure_instead_of_popping_a_crash_dialog()
    {
        var seen = WpfHost.OnUi(() =>
        {
            var cmd = new AsyncRelayCommand(_ => Task.FromException(new TaskCanceledException("The operation was canceled.")));
            Exception? caught = null;
            cmd.Failed += e => caught = e;
            cmd.Execute(null);
            WpfHost.PumpUntil(() => caught != null);
            return caught?.GetType().Name;
        }).Result;
        Assert.Equal(nameof(TaskCanceledException), seen);
    }

    /// <summary>总开关要能用颜色分状态：未接管 = 品牌蓝，已接管 = 绿（同色被用户点过名）。</summary>
    [Fact]
    public void Connect_button_changes_color_when_traffic_is_taken_over()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var styles = File.ReadAllText(FindSourceFile(Path.Combine("Assets", "Styles.xaml")));
        Assert.Contains("<SolidColorBrush x:Key=\"Running\"", styles);
        Assert.Contains(@"<DataTrigger Binding=""{Binding IsConnected}"" Value=""True"">", xaml);
        Assert.Contains(@"Value=""{StaticResource Running}""", xaml);
    }

    private static string FindSourceFile(string name)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; dir != null && depth < 8; depth++, dir = dir.Parent)
        {
            foreach (var candidate in new[]
                     {
                         Path.Combine(dir.FullName, "src", "TunBox.App", name),
                         Path.Combine(dir.FullName, "TunBox-Windows", "src", "TunBox.App", name),
                     })
                if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("找不到 " + name);
    }

    [Fact]
    public void Every_binding_name_in_the_main_window_resolves_to_a_real_property()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var owners = new[] { typeof(MainViewModel), typeof(NodeItem),
                              typeof(SubscriptionItem), typeof(ConnectionItem),
                              typeof(MainViewModel.NetCheckRow) };
        var unknown = new List<string>();
        foreach (Match m in Regex.Matches(xaml,
                     @"\{Binding\s+(?:Path=)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"))
        {
            var path = m.Groups[1].Value.StartsWith("DataContext.", StringComparison.Ordinal)
                ? m.Groups[1].Value["DataContext.".Length..]
                : m.Groups[1].Value;
            var segments = path.Split('.');
            var candidates = owners;
            var ok = true;
            foreach (var segment in segments)
            {
                var next = new List<Type>();
                foreach (var t in candidates)
                {
                    var prop = t.GetProperty(segment);
                    if (prop != null) next.Add(prop.PropertyType);
                }
                candidates = next.ToArray();
                if (candidates.Length == 0) { ok = false; break; }
            }
            if (!ok) unknown.Add(path);
        }
        Assert.Empty(unknown);
    }

    [Fact]
    public void Main_window_xaml_loads_and_viewmodel_initialises()
    {
        var home = TempHome("load");
        var failure = WpfHost.OnUi(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                if (!ReferenceEquals(window.ViewModel, window.DataContext)) return "DataContext 未接上";
                if (window.ViewModel.ProxyMode != "rule") return "默认应为规则模式";
                return null;
            }
            catch (Exception e) { var msg = ""; for (var x = e; x != null; x = x.InnerException) msg += " || " + x.GetType().Name + " " + x.Message; return msg; }
        }).Result;
        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    [Fact]
    public void Importing_share_links_populates_nodes_and_profiles()
    {
        var home = TempHome("import");
        var (error, nodeCount, subCount) = WpfHost.OnUi(() =>
        {
            try
            {
                var vm = new MainViewModel(new Workspace(home));
                vm.ImportAsync(
                    "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                    + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
                var pumped = WpfHost.PumpUntil(() => vm.Nodes.Count > 0);
                if (!pumped) return ("等待超时，列表没有刷新", 0, 0);
                return ((string?)null, vm.Nodes.Count, vm.Subscriptions.Count);
            }
            catch (Exception e) { return (e.GetType().Name + ": " + e.Message, 0, 0); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(error);
        Assert.Equal(2, nodeCount);
        Assert.Equal(1, subCount);
    }

    /// <summary>选中态必须有视觉反馈，且只有一行被选中（用户报告的「点了没反应」）。</summary>
    [Fact]
    public void Selecting_a_node_marks_it_and_only_it()
    {
        var home = TempHome("select");
        var (first, second, selectedName) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
            WpfHost.PumpUntil(() => vm.Nodes.Count > 0);
            var target = vm.Nodes.First(n => n.Name == "HK 02");
            vm.SelectedNode = target;
            return (vm.Nodes[0].IsSelectedNow, vm.Nodes[1].IsSelectedNow, vm.SelectedNode.Name);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.False(first);
        Assert.True(second);
        Assert.Equal("HK 02", selectedName);
    }

    [Fact]
    public void Latency_colors_follow_the_verge_thresholds()
    {
        var item = WpfHost.OnUi(() =>
        {
            Brush Get(TunBox.Core.Models.ProxyNode n) =>
                (Brush)new NodeItem(n).LatencyBrush;
            return new[]
            {
                (Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 120 }),
                 Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 300 })),
                (Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 500 }),
                 Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Timeout, LastLatency = -1 })),
            };
        }).Result;

        Assert.NotEqual(item[0].Item1, item[0].Item2);   // <250 与 250-400 不同色
        Assert.NotEqual(item[1].Item1, item[1].Item2);   // ≥400 与 超时 不同色（橙 vs 红）
    }

    [Fact]
    public void Settings_round_trip_through_disk()
    {
        var home = TempHome("settings");
        var readback = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.MixedPortText = "7897";
            vm.TunOn = false;
            vm.TestUrlText = "http://www.google.com/generate_204";
            vm.ApplySettingsCommand.Execute(null);
            WpfHost.PumpUntil(() => !vm.ApplySettingsCommand.IsRunning);
            var again = new MainViewModel(new Workspace(home));
            return (again.MixedPortText, again.TestUrlText);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("7897", readback.MixedPortText);
        Assert.Equal("http://www.google.com/generate_204", readback.TestUrlText);
    }

    /// <summary>
    /// 复现「导入订阅弹一堆窗然后退出」：大订阅（200 节点 + 机场分组 + 信息条伪节点）
    /// 走真实窗口与消息泵，五个页面每一页都要真正渲染一遍，任何 UI 线程异常都会被记进 handler。
    /// </summary>
    [Fact]
    public void Importing_a_large_subscription_does_not_throw_on_the_ui_thread()
    {
        var home = TempHome("stress");
        var failures = new List<string>();
        var home2 = home;
        var (error, nodeCount, subCount) = WpfHost.OnUi(() =>
        {
            var app = Application.Current;
            System.Windows.Threading.DispatcherUnhandledExceptionEventHandler onErr = (_, e) =>
            {
                failures.Add(e.Exception.GetType().Name + ": " + e.Exception.Message);
                e.Handled = true;
            };
            app!.DispatcherUnhandledException += onErr;
            try
            {
                var sb = new System.Text.StringBuilder("proxies:\n");
                for (var i = 1; i <= 200; i++)
                {
                    sb.Append($"  - {{name: HK {i:D3}, type: ss, server: 1.2.3.{i % 250 + 1}, port: {8000 + i}, "
                        + "cipher: aes-256-gcm, password: pw, udp: true}\n");
                }
                sb.Append("  - {name: \"剩余流量：100 GB\", type: ss, server: info.example.com, port: 80, "
                    + "cipher: aes-256-gcm, password: x}\n");
                sb.Append("proxy-groups:\n");
                sb.Append("  - {name: \"🚀 节点选择\", type: select, proxies: [\"HK 001\", \"HK 002\"]}\n");
                sb.Append("  - {name: 自动, type: url-test, proxies: [\"HK 001\", \"HK 002\", \"HK 003\"], "
                    + "url: \"http://cp.cloudflare.com/generate_204\", interval: 300}\n");

                var window = new MainWindow(new MainViewModel(new Workspace(home2)));
                window.Show();
                try
                {
                    window.ViewModel.ImportAsync(sb.ToString());
                    WpfHost.PumpUntil(() => window.ViewModel.Nodes.Count > 0, 15000);
                    WpfHost.PumpUntil(() => window.ViewModel.Subscriptions.Count > 0, 8000);
                    // 每一页都要真正渲染一遍：TwoWay 绑到只读属性这类错，
                    // 只在那一页被实例化时才炸
                    foreach (var header in Pages)
                    {
                        var tab = FindTab(window, header);
                        if (tab == null) { failures.Add("找不到页签「" + header + "」"); continue; }
                        tab.IsSelected = true;
                        WpfHost.PumpUntil(() => tab.IsSelected);
                        PumpIdle(600);
                    }
                    return ((string?)null, window.ViewModel.Nodes.Count, window.ViewModel.Subscriptions.Count);
                }
                finally { window.Close(); }
            }
            finally { app.DispatcherUnhandledException -= onErr; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.True(string.IsNullOrEmpty(error), error ?? "");
        Assert.True(nodeCount >= 200, "节点数 " + nodeCount);
        Assert.True(subCount >= 1, "订阅卡数 " + subCount);
        Assert.Empty(failures);
    }

    /// <summary>左侧栏五页竖排、一列、顺序稳定（桌面横屏形态，对齐 FlClash）；切页页头要跟着变。</summary>
    [Fact]
    public void Sidebar_navigation_has_five_pages_in_one_stable_column()
    {
        var home = TempHome("nav");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    WpfHost.PumpUntil(() => window.ActualWidth > 100);
                    var tabs = Descendants(window).OfType<System.Windows.Controls.TabItem>()
                        .Where(t => window.Shell.Items.Contains(t)).ToList();
                    if (tabs.Count != Pages.Length)
                        return "侧栏页签数量 " + tabs.Count + "（应为 " + string.Join("/", Pages) + "）";
                    for (var i = 0; i < tabs.Count; i++)
                        if ((string)tabs[i].Header != Pages[i]) return $"第 {i + 1} 项应是「{Pages[i]}」，实际「{tabs[i].Header}」";
                    // 同一列、从上到下：侧栏不能换行，也不能随选中项重排
                    var pts = tabs.Select(t => t.TranslatePoint(new Point(0, 0), window)).ToList();
                    for (var i = 1; i < pts.Count; i++)
                    {
                        if (Math.Abs(pts[0].X - pts[i].X) > 0.5) return $"「{tabs[i].Header}」不在同一列";
                        if (pts[i].Y <= pts[i - 1].Y) return $"「{tabs[i].Header}」没有排在「{tabs[i - 1].Header}」下面";
                    }
                    // 侧栏必须在窗口左半边
                    if (pts[0].X >= window.ActualWidth / 2) return "侧栏不在窗口左侧";
                    // 切页 = 页头大标题跟着变
                    var settings = FindTab(window, "设置");
                    settings!.IsSelected = true;
                    WpfHost.PumpUntil(() => window.ViewModel.ActivePage == "设置");
                    if (window.ViewModel.ActivePage != "设置") return "切页后页头没有变成「设置」";
                    return null;
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 「关闭主窗口时」的三个选择必须选完就落盘。以前它只改内存，要等「应用设置」那颗按钮才写。
    /// </summary>
    [Fact]
    public void Choosing_a_close_behavior_persists_immediately()
    {
        var home = TempHome("close");
        var (exitReadback, trayReadback, liveMode) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.CloseChoice = "exit";
            var afterExit = new MainViewModel(new Workspace(home)).CloseMode;
            vm.CloseChoice = "tray";
            return (afterExit, new MainViewModel(new Workspace(home)).CloseMode, vm.CloseMode);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("exit", exitReadback);
        Assert.Equal("tray", trayReadback);
        Assert.Equal("tray", liveMode);   // 窗口自己也得立刻知道现在是哪个模式
    }

    /// <summary>横屏界面契约：测速入口两颗都在代理页、分组页签是筛选器、退出在侧栏且只有一颗。
    /// 文案本体在 zh.xaml（i18n 后 XAML 只放键），这里两边都验。</summary>
    [Fact]
    public void Proxies_page_contract_test_buttons_group_tabs_and_sidebar_exit()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var zh = File.ReadAllText(FindSourceFile(Path.Combine("Assets", "Lang", "zh.xaml")));
        Assert.Contains("x:Key=\"L.Proxy.TestGroup\">测速本组<", zh);
        Assert.Contains("x:Key=\"L.Proxy.TestAll\">全部测速<", zh);
        Assert.Contains("Command=\"{Binding TestAllCommand}\"", xaml);
        Assert.Contains("Click=\"OnTestSubClick\"", xaml);
        Assert.Contains("MouseLeftButtonUp=\"OnNodeRowClick\"", xaml);
        Assert.DoesNotContain("OnGroupChipClick", xaml);
        Assert.DoesNotContain("OnGroupTabClick", xaml);
        // FlClash 对齐：请求页有「断开全部」
        Assert.Contains("Command=\"{Binding CloseAllConnectionsCommand}\"", xaml);
        Assert.Contains("x:Key=\"L.Req.CloseAll\">断开全部<", zh);

        var exitAt = xaml.IndexOf("Content=\"{DynamicResource L.Nav.Exit}\"", StringComparison.Ordinal);
        var firstTabAt = xaml.IndexOf("<TabItem Header=", StringComparison.Ordinal);
        Assert.True(exitAt >= 0 && firstTabAt > exitAt, "退出按钮应在侧栏模板里，位于所有页签之前");
        Assert.Equal(exitAt, xaml.LastIndexOf("Content=\"{DynamicResource L.Nav.Exit}\"", StringComparison.Ordinal));
    }

    /// <summary>
    /// 测速排序必须作用在**当前订阅卡**上，而且不能被随后的列表重建弹回去。
    /// </summary>
    [Fact]
    public void Latency_sorting_reorders_the_visible_grid_and_survives_a_rebuild()
    {
        var home = TempHome("sort");
        var (before, after, kept) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\n"
                + "  - {name: A slow, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: B fast, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: C mid, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var b = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name.StartsWith("A") ? 900 : n.Model.Name.StartsWith("B") ? 30 : 300);
            vm.SortForTests();
            var a = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            vm.RebuildForTests();
            return (b, a, vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList());
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(new[] { "A slow", "B fast", "C mid" }, before);
        Assert.Equal(new[] { "B fast", "C mid", "A slow" }, after);
        Assert.Equal(after, kept);
    }

    private static void ApplyLatency(NodeItem item, int ms)
    {
        item.Model.State = TunBox.Core.Models.DelayState.Ok;
        item.Model.LastLatency = ms;
    }

    /// <summary>
    /// 从界面一路走到磁盘：打开重绘过的下拉框 → 选中「直接退出」→ CloseMode 变 → 重启还记住。
    /// ComboBox 换了模板，绑定和容器生成都得在真视觉树里验一遍，光看字符串看不出问题。
    /// </summary>
    [Fact]
    public void Closing_choice_combo_box_flows_from_the_ui_to_disk()
    {
        var home = TempHome("combobox");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    var tab = FindTab(window, "设置");
                    if (tab == null) return "找不到设置页";
                    tab.IsSelected = true;
                    WpfHost.PumpUntil(() => tab.IsSelected);
                    // 「应用」现在默认折叠，下拉框在折叠里 —— 先展开（也证明折叠可用）
                    window.ViewModel.GeneralExpanded = true;
                    PumpIdle(500);

                    var box = Descendants(window).OfType<System.Windows.Controls.ComboBox>()
                        .FirstOrDefault(b => b.Items.OfType<System.Windows.Controls.ComboBoxItem>()
                            .Any(i => (i.Tag as string) == "exit"));
                    if (box == null) return "找不到「关闭主窗口时」的下拉框";

                    box.IsDropDownOpen = true;
                    WpfHost.PumpUntil(() => box.IsDropDownOpen);
                    var item = box.ItemContainerGenerator.ContainerFromIndex(2)
                        as System.Windows.Controls.ComboBoxItem;
                    if (item == null) return "下拉列表没渲染出第三项（模板或容器出问题了）";
                    item.IsSelected = true;
                    WpfHost.PumpUntil(() => (box.SelectedValue as string) == "exit");
                    if ((box.SelectedValue as string) != "exit") return "SelectedValue 没变成 exit";
                    if (window.ViewModel.CloseMode != "exit") return "CloseMode 没跟着界面变";
                    return new MainViewModel(new Workspace(home)).CloseMode == "exit"
                        ? null : "重启后关闭方式没记住";
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>摆位用坐标断言：横屏窗口、退出按钮在左侧栏、下拉框真的画出一颗控件。</summary>
    [Fact]
    public void Landscape_window_keeps_exit_in_the_sidebar_and_combo_boxes_render()
    {
        var home = TempHome("layout");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    WpfHost.PumpUntil(() => window.ActualWidth > 100);
                    if (window.ActualWidth <= window.ActualHeight) return "窗口不是横屏（宽 ≤ 高）";
                    var exit = Descendants(window).OfType<System.Windows.Controls.Button>()
                        .FirstOrDefault(b => (b.Content as string) == "退出");
                    if (exit == null) return "侧栏里没有退出按钮";
                    var p = exit.TranslatePoint(new Point(0, 0), window);
                    if (p.X > 220) return "退出按钮不在左侧栏（X=" + p.X + "）";
                    var dash = FindTab(window, "仪表盘");
                    var dp = dash!.TranslatePoint(new Point(0, 0), window);
                    if (dp.Y >= p.Y) return "导航项应在退出按钮上面";

                    var settings = FindTab(window, "设置");
                    if (settings == null) return "找不到设置页";
                    settings.IsSelected = true;
                    WpfHost.PumpUntil(() => settings.IsSelected);
                    // 三张卡默认折叠，下拉框藏在折叠里 —— 先展开（顺带证明折叠可用）
                    window.ViewModel.PortsExpanded = true;
                    window.ViewModel.GeneralExpanded = true;
                    window.ViewModel.KernelExpanded = true;
                    PumpIdle(500);
                    var boxes = Descendants(window).OfType<System.Windows.Controls.ComboBox>().ToList();
                    if (boxes.Count < 3) return "设置页上的下拉框数量 " + boxes.Count;
                    foreach (var b in boxes)
                    {
                        if (!b.IsVisible) return "有下拉框没显示出来";
                        if (b.ActualHeight < 26) return "下拉框高度只有 " + b.ActualHeight + "，新模板没撑开";
                    }
                    return null;
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>底部提示必须 3 秒自己消失（用户：导入完那句「已导入 24 个节点」一直挂着）。</summary>
    [Fact]
    public void Bottom_hint_disappears_after_three_seconds()
    {
        var home = TempHome("hint");
        var (shown, goneAway) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.DetailText = "已导入，当前 3 个节点。";
            var shownNow = vm.DetailText;
            var pumped = WpfHost.PumpUntil(() => vm.DetailText.Length == 0, 6000);
            return (shownNow, pumped);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("已导入，当前 3 个节点。", shown);
        Assert.True(goneAway, "提示没有自动消失");
    }

    /// <summary>子对话框必须比主窗口小（矮窗口下也要成立）。</summary>
    [Fact]
    public void Dialogs_fit_inside_the_main_window()
    {
        var home = TempHome("dialogs");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var window = new MainWindow(new MainViewModel(new Workspace(home)));
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                var import = new ImportDialog { Owner = window };
                import.Show();
                WpfHost.PumpUntil(() => import.ActualWidth > 10);
                var edit = new EditDialog("订阅 A", "https://example.com/sub") { Owner = window };
                edit.Show();
                WpfHost.PumpUntil(() => edit.ActualWidth > 10);
                var msgs = new List<string>();
                if (import.ActualWidth >= window.ActualWidth) msgs.Add($"导入框 {import.ActualWidth:0} ≥ 主窗口 {window.ActualWidth:0}");
                if (edit.ActualWidth >= window.ActualWidth) msgs.Add($"编辑框 {edit.ActualWidth:0} ≥ 主窗口");
                if (import.ActualHeight >= window.ActualHeight) msgs.Add("导入框比主窗口还高");
                import.Close(); edit.Close();
                return msgs.Count > 0 ? string.Join("；", msgs) : null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 配置页的自动更新档位（对齐 FlClash）选完就落盘：卡片改动 → 订阅模型 → 重启读回。
    /// </summary>
    [Fact]
    public void Auto_update_choice_persists_through_a_reload()
    {
        var home = TempHome("autoupdate");
        var (choiceOnCard, reloaded) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var card = vm.Subscriptions.First();
            Assert.Equal("0", card.AutoUpdateChoice);   // 默认手动
            card.AutoUpdateChoice = "60";
            var vm2 = new MainViewModel(new Workspace(home));
            return (card.Model.AutoUpdateMinutes, vm2.Subscriptions.First().AutoUpdateChoice);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(60, choiceOnCard);
        Assert.Equal("60", reloaded);
    }

    /// <summary>
    /// 配置页的自动更新下拉框必须真的显示当前档位（漏了 SelectedValuePath 时
    /// SelectedValue 永远匹配不上，框是空的——用户看到的就是一个谜之空白框）。
    /// </summary>
    [Fact]
    public void Profile_auto_update_combo_shows_the_current_choice()
    {
        var home = TempHome("autoupdatecombo");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var vm = new MainViewModel(new Workspace(home));
                vm.ImportAsync(
                    "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                    + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
                WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
                var window = new MainWindow(vm);
                window.Show();
                try
                {
                    var tab = FindTab(window, "代理");
                    if (tab == null) return "找不到代理页";
                    tab.IsSelected = true;
                    WpfHost.PumpUntil(() => tab.IsSelected);
                    PumpIdle(500);
                    var box = Descendants(window).OfType<System.Windows.Controls.ComboBox>()
                        .FirstOrDefault(b => b.Items.OfType<System.Windows.Controls.ComboBoxItem>()
                            .Any(i => (i.Tag as string) == "1440"));
                    if (box == null) return "找不到自动更新下拉框";
                    if ((box.SelectedValue as string) != "0") return $"当前档位应选中「0」，实际「{box.SelectedValue}」";
                    // 换一档 → 卡片与落盘跟着走
                    var hourly = box.Items.OfType<System.Windows.Controls.ComboBoxItem>()
                        .First(i => (i.Tag as string) == "60");
                    hourly.IsSelected = true;
                    WpfHost.PumpUntil(() => vm.Subscriptions.First().AutoUpdateChoice == "60");
                    return new MainViewModel(new Workspace(home)).Subscriptions.First().Model.AutoUpdateMinutes == 60
                        ? null : "换档后没有落盘";
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>横屏界面契约：电源环、系统代理开关、FlClash 全套新件（语言/快捷键/覆写/Hosts/网络检测/
    /// TUN 高级项/排序/全部更新/关于）都挂上了；文案本体在 zh.xaml。</summary>
    [Fact]
    public void Landscape_contracts_power_ring_system_proxy_and_flclash_features()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var zh = File.ReadAllText(FindSourceFile(Path.Combine("Assets", "Lang", "zh.xaml")));
        // 连接控制是桌面标准大开关（用户点名：不要鸿蒙电源环）；开关样式在 Styles.xaml
        Assert.DoesNotContain("PowerRing", xaml);
        Assert.Contains("x:Key=\"SwitchLarge\"", File.ReadAllText(FindSourceFile(Path.Combine("Assets", "Styles.xaml"))));
        Assert.Contains("IsChecked=\"{Binding IsConnected, Mode=OneWay}\"", xaml);
        // 单开关总闸:只有「代理连接」一颗开关,系统代理没有独立开关
        Assert.DoesNotContain("SystemProxyOn", xaml);
        Assert.Contains("IsChecked=\"{Binding IsConnected, Mode=OneWay}\"", xaml);
        Assert.Equal(1, xaml.Split("Command=\"{Binding SaveAllCommand}\"").Length - 1);
        Assert.Contains("x:Key=\"L.Set.DnsOverride\">DNS 覆写", zh);
        Assert.DoesNotContain("DNS 复写", zh);
        Assert.Contains("Command=\"{Binding SaveAllCommand}\"", xaml);
        // FlClash 对齐的新件
        Assert.Contains("TunStackChoice", xaml);
        Assert.Contains("StartMinimizedOn", xaml);
        Assert.Contains("AutoUpdateChoice", xaml);
        Assert.Contains("local:TrafficChart", xaml);
        Assert.Contains("LanguageChoice", xaml);                  // 多语言
        Assert.Contains("HotkeyShowText", xaml);                  // 全局快捷键
        Assert.Contains("OverrideMergeText", xaml);               // 覆写
        Assert.Contains("HostsText", xaml);                       // Hosts
        Assert.Contains("RunNetCheckCommand", xaml);              // 网络检测
        Assert.Contains("SortChoice", xaml);                      // 代理排序
        Assert.Contains("UpdateAllCommand", xaml);                // 全部更新
        Assert.Contains("CoreVersionText", xaml);                 // 关于：内核版本
        Assert.Contains("TunStrictRouteOn", xaml);                // TUN 严格路由
        Assert.Contains("TunEinatOn", xaml);                      // TUN EINAT
        // 侧栏六页
        foreach (var page in Pages)
            Assert.Contains($"Header=\"{{DynamicResource L.Nav.{PageKey(page)}}}\"", xaml);

        var home = TempHome("dns-default");
        var text = WpfHost.OnUi(() => new MainViewModel(new Workspace(home)).DnsServersText).Result;
        try { Directory.Delete(home, true); } catch { }
        Assert.Contains("tls://223.5.5.5", text);                // 默认值填好，不让用户面对空框
        Assert.Contains("tls://1.12.12.12", text);
    }

    private static string PageKey(string page) => page switch
    {
        "仪表盘" => "Dashboard", "代理" => "Proxies", "请求" => "Requests",
        "配置" => "Profiles", "工具" => "Tools", "设置" => "Settings", _ => page,
    };

    /// <summary>
    /// 顶栏那条流量串可以很长（速率 + 累计）。它必须完整待在页头里，
    /// 也不能压到侧栏的退出按钮上（用户截图里曾经的遮挡事故）。
    /// </summary>
    [Fact]
    public void Long_traffic_line_stays_inside_the_header_and_off_the_exit_button()
    {
        var home = TempHome("overlap");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            var conns = new List<TunBox.Core.Api.Connection>();
            for (var i = 0; i < 34; i++)
                conns.Add(new TunBox.Core.Api.Connection("id" + i, "日本01·移", "api.example-long-host.com",
                    "198.18.0.1", 443, "WeChatAppEx.exe", "tcp", "GEOIP,CN", DateTime.Now, 40_000_000, 14_400_000));
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(1_189_000, 14_400_000, conns));
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                // 喂快照必须在窗口出来之后：仪表盘一显示就会起轮询，内核没跑时第一轮就把
                // TrafficText 打回「↑ 0 B/s ↓ 0 B/s」了。
                vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(1_189_000, 14_400_000, conns));
                if (vm.TrafficText.Length < 30) return "流量串太短，测不出遮挡：" + vm.TrafficText;
                var exit = Descendants(window).OfType<System.Windows.Controls.Button>()
                    .FirstOrDefault(b => (b.Content as string) == "退出");
                var traffic = Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                    .FirstOrDefault(t => (t.Text ?? "").Contains("累计"));
                if (exit == null) return "找不到退出按钮";
                if (traffic == null)
                {
                    var seen = string.Join(" | ", Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                        .Select(t => t.Text).Where(s => !string.IsNullOrEmpty(s)).Take(12));
                    return $"找不到流量文字（TrafficText={vm.TrafficText}）；树里的文字：{seen}";
                }
                var exitRight = exit.TranslatePoint(new Point(exit.ActualWidth, exit.ActualHeight), window);
                var exitTopLeft = exit.TranslatePoint(new Point(0, 0), window);
                var trafficTopLeft = traffic.TranslatePoint(new Point(0, 0), window);
                var trafficBottomRight = traffic.TranslatePoint(new Point(traffic.ActualWidth, traffic.ActualHeight), window);
                if (trafficBottomRight.X > window.ActualWidth + 0.5) return "流量串超出窗口右沿";
                var intersects = trafficTopLeft.X < exitRight.X && exitTopLeft.X < trafficBottomRight.X
                                 && trafficTopLeft.Y < exitRight.Y && exitTopLeft.Y < trafficBottomRight.Y;
                return intersects
                    ? $"流量串压到退出按钮：{vm.TrafficText}" : null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 设置页四节的顺序是固定的（应用 / 网络配置 / 分流规则 / 内核）：
    /// 展开某一节只能在原位撑开，不许跳到页尾。
    /// </summary>
    [Fact]
    public void Settings_sections_keep_their_order_when_one_expands()
    {
        var home = TempHome("sectionorder");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.PortsExpanded = vm.KernelExpanded = vm.RulesExpanded = vm.GeneralExpanded = false;
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                var settings = FindTab(window, "设置");
                if (settings == null) return "找不到设置页";
                settings.IsSelected = true;
                WpfHost.PumpUntil(() => settings.IsSelected);
                PumpIdle(400);

                string? TopDown()
                {
                    var known = new[] { "应用", "网络配置", "分流规则", "内核" };
                    var cards = Descendants(window).OfType<System.Windows.Controls.Border>()
                        .Where(b => b.Child is System.Windows.Controls.Expander
                            && known.Contains(((System.Windows.Controls.Expander)b.Child).Header as string))
                        .OrderBy(b => b.TranslatePoint(new Point(0, 0), window).Y)
                        .Select(b => (string)((System.Windows.Controls.Expander)b.Child).Header!)
                        .ToList();
                    return cards.Count != 4 ? "设置页的四节数量 " + string.Join("/", cards) : string.Join(",", cards);
                }

                var declared = TopDown();
                if (declared!.Contains("数量")) return declared;

                vm.KernelExpanded = true;
                PumpIdle(800);

                var after = TopDown()!;
                return after == declared ? null : $"展开「内核」后排位变了：{declared} → {after}";
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    private static System.Windows.Controls.TabItem? FindTab(Window window, string header) =>
        Descendants(window).OfType<System.Windows.Controls.TabItem>()
            .FirstOrDefault(t => (t.Header as string) == header);

    /// <summary>
    /// 仪表盘的卡片必须齐全（连接+系统代理 / TUN / 实时速率 / 快捷出口 / 出口信息），
    /// 出口信息四行标签都要有值 —— 绑错名字的后果是卡片一片空白，用户只会以为程序坏了。
    /// </summary>
    [Fact]
    public void Dashboard_shows_all_flclash_cards_and_the_traffic_chart()
    {
        var home = TempHome("dashboard");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                foreach (var title in new[] { "代理连接", "虚拟网卡（TUN）", "实时速率", "出口信息", "快捷出口" })
                {
                    var found = Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                        .Any(t => t.Text == title);
                    if (!found) return "仪表盘缺「" + title + "」卡";
                }
                if (vm.PortsSummaryText.Length == 0) return "端口摘要没有内容";
                if (!Descendants(window).Any(d => d is TrafficChart)) return "仪表盘没有速率图控件";
                foreach (var label in new[] { "出口 IP", "位置", "运营商", "本机 IP" })
                {
                    var found = Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                        .Any(t => t.Text == label);
                    if (!found) return $"出口信息卡少了「{label}」这一行";
                }
                // 没连接时不许显示成「查到了」，但要有一句话解释为什么是空的
                if (vm.EgressIpText.Length == 0) return "出口 IP 一格没有初值";
                if (vm.EgressNote.Length == 0 && vm.IsConnected) return "已连接却没有说明文案";
                return null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 请求页：快照进表、逐条速率、搜索只过滤显示、暂停冻结表格（FlClash 的暂停键）。
    /// </summary>
    [Fact]
    public void Requests_page_filters_search_and_pauses_on_live_snapshots()
    {
        var home = TempHome("requests");
        var (rows, filtered, pausedRows, resumedRows, firstSpeed, secondSpeed) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            System.Collections.Generic.List<TunBox.Core.Api.Connection> Make(long up) => new()
            {
                new("id-a", "日本01", "a.example-long-host.com", "1.2.3.4", 443, "WeChatAppEx.exe",
                    "tcp", "GEOIP,CN", DateTime.Now, up, 14_400_000),
                new("id-b", "HK 01", "b.example-long-host.com", "1.2.3.5", 443, "chrome.exe",
                    "tcp", "DOMAIN-SUFFIX,example.com", DateTime.Now, 1000, 2000),
            };
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(40_001_000, 14_402_000, Make(40_000_000)));
            var rows0 = vm.Connections.Count;
            var speed0 = vm.Connections.First(c => c.Id == "id-a").UpSpeedText;   // 第一拍没有上一拍可差分
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(41_001_000, 14_402_000, Make(41_000_000)));
            var speed1 = vm.Connections.First(c => c.Id == "id-a").UpSpeedText;
            vm.ConnectionSearchText = "chrome";
            var view = vm.ConnectionsView.OfType<ConnectionItem>().ToList();
            var filteredCount = view.Count;
            vm.ConnectionSearchText = "";
            vm.UpdatesPaused = true;
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(42_001_000, 14_402_000, Make(42_000_000)));
            var pausedCount = vm.Connections.Count;
            vm.UpdatesPaused = false;
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(42_001_000, 14_402_000, Make(42_000_000)));
            var resumedCount = vm.Connections.Count;
            return (rows0, filteredCount, pausedCount, resumedCount, speed0, speed1);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(2, rows);
        Assert.Equal("0 B/s", firstSpeed);          // 首拍速率从 0 起，不拿总量编一个假速率
        Assert.NotEqual("0 B/s", secondSpeed);      // 有了上一拍，速率要真算出来
        Assert.Equal(1, filtered);                  // 搜「chrome」只剩一行，底层列表不动
        Assert.Equal(2, pausedRows);                // 暂停时表格冻在原地
        Assert.Equal(2, resumedRows);               // 恢复后同一份快照回来，行数不变
    }

    /// <summary>TUN 协议栈选择落盘，且写配置时归一化（非法值回 system）。</summary>
    [Fact]
    public void Tun_stack_choice_persists_and_normalizes()
    {
        var home = TempHome("tunstack");
        var readback = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.TunStackChoice = "gvisor";
            vm.ApplySettingsCommand.Execute(null);
            WpfHost.PumpUntil(() => !vm.ApplySettingsCommand.IsRunning);
            var again = new MainViewModel(new Workspace(home));
            return again.TunStackChoice;
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("gvisor", readback);
        Assert.Equal("system", TunBox.Core.Config.ClashConfigGenerator.StackSlug("weird"));
        Assert.Equal("gvisor", TunBox.Core.Config.ClashConfigGenerator.StackSlug("gvisor"));
        Assert.Equal("system", TunBox.Core.Config.ClashConfigGenerator.StackSlug(null));
    }

    /// <summary>页内跳转：GoToPageCommand 触发导航事件，窗口代码后置据此翻页签。</summary>
    [Fact]
    public void Go_to_page_command_requests_navigation()
    {
        var seen = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(TempHome("goto")));
            string? page = null;
            vm.NavigateRequested += p => page = p;
            vm.GoToPageCommand.Execute("请求");
            return page;
        }).Result;
        Assert.Equal("请求", seen);
    }

    /// <summary>速率图：容量封顶（旧样本滑出窗口），事件带着真实速率出来。</summary>
    [Fact]
    public void Traffic_chart_caps_capacity_and_speed_event_carries_rates()
    {
        var home = TempHome("chart");
        var (samples, upSeen, downSeen) = WpfHost.OnUi(() =>
        {
            var chart = new TrafficChart();
            for (var i = 0; i < 130; i++) chart.Push(1000, 2000);
            var vm = new MainViewModel(new Workspace(home));
            double up = -1, down = -1;
            vm.SpeedSampled += (u, d) => { up = u; down = d; };
            var conns = Array.Empty<TunBox.Core.Api.Connection>();
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(0, 0, conns));
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(1_000_000, 2_000_000, conns));
            return (chart.SampleCount, up, down);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(120, samples);
        Assert.True(upSeen > 0 && downSeen > 0, $"速率事件没带出正数：up={upSeen} down={downSeen}");
    }

    /// <summary>
    /// 连着点节点时，「800ms 后查一次出口」的排队不许把界面刷崩。
    /// </summary>
    [Fact]
    public void Egress_requeue_survives_clicks_spaced_apart()
    {
        var home = TempHome("egressstorm");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            try
            {
                for (var i = 0; i < 4; i++)
                {
                    vm.PokeEgressForTests($"node-{i}");
                    PumpIdle(1000);   // 让上一轮的延时任务跑完并释放自己
                }
                return null;
            }
            catch (Exception e) { return e.GetType().Name + " " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>多语言：切到英文 UI 文案即时换掉，切回中文恢复；选择落盘。</summary>
    [Fact]
    public void Language_switch_retranslates_the_ui()
    {
        var home = TempHome("lang");
        var readback = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.LanguageChoice = "en";
            var enNav = Application.Current?.TryFindResource("L.Nav.Dashboard") as string;
            var enClose = Application.Current?.TryFindResource("L.Req.CloseAll") as string;
            vm.LanguageChoice = "zh";
            var zhNav = Application.Current?.TryFindResource("L.Nav.Dashboard") as string;
            var again = new MainViewModel(new Workspace(home)).LanguageChoice;
            return (enNav, enClose, zhNav, again);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("Dashboard", readback.enNav);
        Assert.Equal("Close All", readback.enClose);
        Assert.Equal("仪表盘", readback.zhNav);
        Assert.Equal("zh", readback.again);
    }

    /// <summary>快捷键组合键解析与规范化；无效写法直接拒绝。</summary>
    [Fact]
    public void Hotkey_specs_parse_and_normalize()
    {
        var home = TempHome("hotkey");
        var parsed = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.HotkeyConnectText = "ctrl+alt+p";
            var ok = Hotkeys.Parse(vm.HotkeyConnectText) is { } p
                && (p.Modifiers & 0x2) != 0 && (p.Modifiers & 0x1) != 0 && p.VirtualKey == 0x50;
            return (vm.HotkeyConnectText, ok,
                Hotkeys.Parse("P") is null,
                Hotkeys.Parse("Ctrl+Shift+F5") is not null,
                Hotkeys.Parse("Ctrl+Ctrl") is null);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("Ctrl+Alt+P", parsed.Item1);
        Assert.True(parsed.Item2, "修饰键与键码没解析对");
        Assert.True(parsed.Item3, "无修饰键的单键不该被接受");
        Assert.True(parsed.Item4, "F 键组合没被接受");
        Assert.True(parsed.Item5, "重复修饰键不该被接受");
    }

    /// <summary>覆写引擎：Merge 深合并 + Script 覆写都作用于最终配置；关掉开关 = 原样通过；脚本报错不拖垮生成。</summary>
    [Fact]
    public void Override_merge_and_script_transform_the_config()
    {
        var baseYaml = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\ndns:\n  enable: false\n";
        var settings = new TunBox.Core.Models.AppSettings
        {
            OverrideEnabled = true,
            OverrideMergeYaml = "mixed-port: 7897\ndns:\n  enable: true\n  nameserver:\n    - 223.5.5.5\n",
            OverrideScript = "function main(config) { config[\"mode\"] = \"global\"; return config; }",
        };
        var result = TunBox.Core.Config.ConfigOverride.Apply(baseYaml, settings);
        Assert.Contains("mixed-port: 7897", result.Yaml);
        Assert.Contains("enable: true", result.Yaml);
        Assert.Contains("223.5.5.5", result.Yaml);
        Assert.True(result.Yaml.Contains("mode: global"), "yaml=" + result.Yaml + " note=" + result.Note);
        Assert.Null(result.Note);

        var passthrough = TunBox.Core.Config.ConfigOverride.Apply(baseYaml,
            new TunBox.Core.Models.AppSettings { OverrideEnabled = false });
        Assert.Equal(baseYaml, passthrough.Yaml);

        var broken = TunBox.Core.Config.ConfigOverride.Apply(baseYaml, new TunBox.Core.Models.AppSettings
        {
            OverrideEnabled = true,
            OverrideScript = "function main(config) { throw new Error('boom'); }",
        });
        Assert.Equal(baseYaml, broken.Yaml);
        Assert.NotNull(broken.Note);
    }

    /// <summary>Hosts 表与 TUN 高级项（MTU / 严格路由 / EINAT）都要真的写进内核配置。</summary>
    [Fact]
    public void Hosts_and_tun_advanced_flow_into_generated_config()
    {
        var home = TempHome("tunhost");
        var settings = new TunBox.Core.Models.AppSettings
        {
            TunEnabled = true,
            TunMtu = 1400,
            TunStrictRoute = true,
            TunEndpointIndependentNat = true,
        };
        settings.Hosts["router.local"] = "192.168.1.1";
        settings.Hosts["nas.home"] = "192.168.1.2";
        var nodes = new List<TunBox.Core.Models.ProxyNode>
        {
            new() { Id = "1", Name = "HK 01", OriginalName = "HK 01", Kind = TunBox.Core.Models.ProxyKind.Ss,
                    Server = "127.0.0.1", Port = 1, Password = "pw", Method = "aes-256-gcm" },
        };
        var yaml = TunBox.Core.Config.ClashConfigGenerator.Generate(nodes,
            Array.Empty<TunBox.Core.Models.ProxyGroup>(), settings, new Workspace(home).DetectGates());
        try { Directory.Delete(home, true); } catch { }
        Assert.Contains("\"router.local\": \"192.168.1.1\"", yaml);
        Assert.Contains("\"nas.home\": \"192.168.1.2\"", yaml);
        Assert.Contains("mtu: 1400", yaml);
        Assert.Contains("strict-route: true", yaml);
        Assert.Contains("endpoint-independent-nat: true", yaml);
    }

    /// <summary>Hosts 编辑器：两种写法都收，坏行当场点名，保存后落盘。</summary>
    [Fact]
    public void Hosts_text_parses_bad_lines_and_persists()
    {
        var home = TempHome("hosts");
        var (feedback, count, badLineCalledOut) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.OverrideEnabledOn = true;
            vm.HostsText = "a.com 1.2.3.4\nb.com=2.2.2.2\ngarbage-line";
            vm.SaveOverrideCommand.Execute(null);
            WpfHost.PumpUntil(() => !vm.SaveOverrideCommand.IsRunning);
            var saved = new MainViewModel(new Workspace(home)).ManagerSettings.Hosts;
            return (vm.HostsFeedback, saved.Count, vm.HostsFeedback.Contains("3"));
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(2, count);
        Assert.True(badLineCalledOut, "坏行没有被点名：" + feedback);
    }

    /// <summary>代理页排序选择器：按名称 / 按延迟都要真的重排当前网格。</summary>
    [Fact]
    public void Sort_choice_orders_the_proxy_grid()
    {
        var home = TempHome("sortchoice");
        var (byName, byDelay) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\n"
                + "  - {name: Ccc, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: Aaa, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: Bbb, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name switch { "Aaa" => 500, "Bbb" => 100, _ => 300 });
            vm.SortChoice = "name";
            var names = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            vm.SortChoice = "delay";
            var delays = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            return (names, delays);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(new[] { "Aaa", "Bbb", "Ccc" }, byName);
        Assert.Equal(new[] { "Bbb", "Ccc", "Aaa" }, byDelay);
    }

    /// <summary>仪表盘快捷出口：选项 = 自动选择 + 节点名；选节点 = 出口真的切过去。</summary>
    [Fact]
    public void Quick_egress_options_switch_the_outbound()
    {
        var home = TempHome("quick");
        var (hasSmart, hasNode, selectedName) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
            WpfHost.PumpUntil(() => vm.Nodes.Count > 0);
            var hasSmartNow = vm.QuickEgressOptions.Contains(Lang.T("Proxy.Smart"));
            var hasNodeNow = vm.QuickEgressOptions.Contains("HK 02");
            vm.QuickEgressSelected = "HK 02";
            WpfHost.PumpUntil(() => vm.SelectedNode is { Name: "HK 02" }, 4000);
            return (hasSmartNow, hasNodeNow, vm.SelectedNode?.Name ?? "");
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.True(hasSmart, "快捷出口缺「自动选择」选项");
        Assert.True(hasNode, "快捷出口缺节点名");
        Assert.Equal("HK 02", selectedName);
    }

    /// <summary>窗口尺寸/位置要记住：关窗时写盘，重启读回。</summary>
    [Fact]
    public void Window_bounds_persist_through_a_close()
    {
        var home = TempHome("winbounds");
        var saved = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            window.Width = 1100;
            window.Height = 720;
            window.Left = 33;
            window.Top = 44;
            window.Close();
            return true;
        }).Result;
        var s = new Workspace(home).LoadSettings();
        try { Directory.Delete(home, true); } catch { }
        Assert.True(saved);
        // DPI 缩放会把坐标吸附到物理像素，留一点余量
        Assert.InRange(s.WindowWidth, 1099, 1101);
        Assert.InRange(s.WindowHeight, 719, 721);
        Assert.InRange(s.WindowLeft, 32.5, 34.5);
        Assert.InRange(s.WindowTop, 43.5, 45.5);
    }

    /// <summary>语言字典守卫：zh/en 键集必须一致，XAML 引用的每个 L.* 键都必须存在于 zh 字典
    /// —— 缺键的表现是英文界面某块文字凭空消失，编译器不报、只有这里拦得住。</summary>
    [Fact]
    public void Language_dictionaries_have_parity_and_cover_every_reference()
    {
        static HashSet<string> KeysOf(string file)
        {
            var text = File.ReadAllText(file);
            return new HashSet<string>(System.Text.RegularExpressions.Regex.Matches(
                         text, @"x:Key=""(L\.[^""]+)""").Select(m => m.Groups[1].Value), StringComparer.Ordinal);
        }
        var zh = KeysOf(FindSourceFile(Path.Combine("Assets", "Lang", "zh.xaml")));
        var en = KeysOf(FindSourceFile(Path.Combine("Assets", "Lang", "en.xaml")));
        Assert.True(zh.SetEquals(en),
            "键集不一致。en 缺: " + string.Join(",", zh.Except(en)) + " / zh 缺: " + string.Join(",", en.Except(zh)));

        var referenced = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var xaml in new[] { "MainWindow.xaml", "ImportDialog.xaml", "AppPickerDialog.xaml" })
            foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(
                         File.ReadAllText(FindSourceFile(xaml)), @"DynamicResource\s+(L\.[^}\s]+)"))
                referenced.Add(m.Groups[1].Value);
        var missing = referenced.Where(k => !zh.Contains(k)).ToList();
        Assert.True(missing.Count == 0, "XAML 引用了字典里不存在的键: " + string.Join(",", missing));
    }

    private static void PumpIdle(int ms) =>
        WpfHost.PumpUntil(() => false, ms);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        var n = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < n; i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            yield return c;
            foreach (var d in Descendants(c)) yield return d;
        }
    }
}
