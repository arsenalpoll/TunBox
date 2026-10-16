using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace TunBox.App;

/// <summary>列表里的一行。勾选状态是勾选框写进来，不反向通知，不需要 INPC。</summary>
public sealed class AppPickItem
{
    public string DisplayName { get; init; } = "";
    public string ExeName { get; init; } = "";
    public bool IsChecked { get; set; }
}

/// <summary>
/// 应用分流的「从已装应用选…」：开始菜单 + 注册表 Uninstall 扫出来的应用列表，
/// 勾选确定后把进程名并回主界面的 AppProcesses 文本框。Result 为 null = 取消。
/// </summary>
public partial class AppPickerDialog : Window
{
    /// <summary>确定时勾选的应用，取消为空列表。</summary>
    public IReadOnlyList<InstalledApp> Selected { get; private set; } = Array.Empty<InstalledApp>();

    private readonly List<AppPickItem> _all = new();
    private readonly IReadOnlyList<InstalledApp>? _preScanned;
    private readonly HashSet<string> _preChecked;
    private bool _loaded;

    /// <summary>preScanned 传预扫好的列表（测试用，跳过真实扫描）；preChecked 是已在文本框里的进程名。</summary>
    public AppPickerDialog(IEnumerable<InstalledApp>? preScanned = null, IEnumerable<string>? preChecked = null)
    {
        InitializeComponent();
        _preScanned = preScanned as IReadOnlyList<InstalledApp> ?? preScanned?.ToList();
        _preChecked = new HashSet<string>(preChecked ?? Enumerable.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        Loaded += OnLoaded;
    }

    /// <summary>把扫描结果填进列表：已存在于文本框的进程名默认勾上。</summary>
    internal void BuildItems(IEnumerable<InstalledApp> apps)
    {
        _all.Clear();
        _all.AddRange(apps.Select(a => new AppPickItem
        {
            DisplayName = a.DisplayName,
            ExeName = a.ExeName,
            IsChecked = _preChecked.Contains(a.ExeName),
        }));
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        DialogFit.ToOwner(this);
        // Owner 是调用方用对象初始化器赋的，构造函数里还是 null —— 图标只能在这里补
        if (Owner?.Icon != null) Icon = Owner.Icon;
        if (_loaded) return;
        _loaded = true;
        if (_preScanned == null)
        {
            Status.Text = "正在扫描已安装的应用…";
            var scanned = await Task.Run(InstalledApps.Enumerate);
            if (!IsLoaded) return; // 扫描期间窗口被关了
            BuildItems(scanned);
        }
        else
        {
            BuildItems(_preScanned);
        }
        Status.Text = _all.Count == 0
            ? "没扫到可列出的应用，可以直接在主界面手动填进程名。"
            : $"共 {_all.Count} 个应用，已勾选 {_all.Count(i => i.IsChecked)} 个";
        Search.Focus();
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => Render();

    /// <summary>按搜索词重新填列表；勾选状态留在 item 上，过滤来回切不会丢。</summary>
    private void Render()
    {
        var q = Search.Text.Trim();
        var visible = _all.Where(i => q.Length == 0
            || i.DisplayName.Contains(q, StringComparison.OrdinalIgnoreCase)
            || i.ExeName.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        List.ItemsSource = visible;
    }

    private List<AppPickItem> Visible() => List.ItemsSource as List<AppPickItem> ?? new List<AppPickItem>();

    private void OnItemToggled(object sender, RoutedEventArgs e) => UpdateOkCount();

    private void UpdateOkCount()
    {
        var n = _all.Count(i => i.IsChecked);
        OkButton.Content = n > 0 ? $"确定（{n}）" : "确定";
        Status.Text = _all.Count == 0
            ? "没扫到可列出的应用，可以直接在主界面手动填进程名。"
            : $"共 {_all.Count} 个应用，已勾选 {n} 个";
    }

    /// <summary>全选 / 清空只动当前过滤出来的可见行：搜索里的选择不受影响。</summary>
    private void OnSelectAll(object sender, RoutedEventArgs e) => SetVisible(true);

    private void OnSelectNone(object sender, RoutedEventArgs e) => SetVisible(false);

    private void SetVisible(bool value)
    {
        foreach (var item in Visible()) item.IsChecked = value;
        List.Items.Refresh();
        UpdateOkCount();
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        Selected = CollectSelected();
        DialogResult = true;
    }

    /// <summary>把当前勾选收集为结果；确定按钮和测试入口共用。</summary>
    internal List<InstalledApp> CollectSelected() => _all.Where(i => i.IsChecked)
        .Select(i => new InstalledApp(i.DisplayName, i.ExeName)).ToList();

    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;

    // —— 测试入口：单测不点真按钮，直接走这些内部方法 ——
    internal List<AppPickItem> VisibleItems() => Visible();
    internal int CheckedCount => _all.Count(i => i.IsChecked);
    internal void SetSearch(string q) { Search.Text = q; Render(); }
    internal void SelectAllVisible() => OnSelectAll(this, new RoutedEventArgs());
    internal void SelectNoneVisible() => OnSelectNone(this, new RoutedEventArgs());
}
