using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.IO;
using TunBox.Core.Api;
using System.Windows.Media;
using TunBox.Core.Config;
using TunBox.Core.Fetching;
using TunBox.Core.Geo;
using TunBox.Core.Models;
using TunBox.Core.Runtime;
using TunBox.Core.Services;
using TunBox.Core.Storage;

namespace TunBox.App;

/// <summary>MVVM 的最小底座：通知 + 两种命令。</summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

public sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;
    private readonly Func<object?, bool>? _canExecute;
    public RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null)
        => (_execute, _canExecute) = (execute, canExecute);
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => _execute(parameter);
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<object?, Task> _execute;
    private readonly Func<object?, bool>? _canExecute;
    private bool _running;
    public AsyncRelayCommand(Func<object?, Task> execute, Func<object?, bool>? canExecute = null)
        => (_execute, _canExecute) = (execute, canExecute);
    public event EventHandler? CanExecuteChanged;

    /// <summary>
    /// 命令里漏出来的异常落到这里，而不是弹「未处理的异常」对话框：
    /// 用户点一下开关就吃一个模态窗，比功能没生效更让人不信任这个软件。
    /// </summary>
    public event Action<Exception>? Failed;

    /// <summary>正在跑时一律拒绝重入：连接被点两次会留下半启动的内核。</summary>
    public bool CanExecute(object? parameter) => !_running && (_canExecute?.Invoke(parameter) ?? true);
    public bool IsRunning => _running;

    /// <summary>供代码后置直接等待（async void 的 Execute 没法 await）。</summary>
    public Task ExecuteAsync(object? parameter) => RunAsync(parameter);

    private async Task RunAsync(object? parameter)
    {
        _running = true;
        Refresh();
        try
        {
            await _execute(parameter).ConfigureAwait(true);
        }
        catch (Exception e)
        {
            if (Failed != null) Failed(e);
            else Debug.WriteLine(e);
        }
        finally { _running = false; Refresh(); }
    }

    public async void Execute(object? parameter) => await RunAsync(parameter);
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>
/// 延迟配色（四档 + 超时/失败红，macOS 客户端的口径）：
/// &lt;250 绿 / 250-399 琥珀 / ≥400 橙红 / 超时与失败红 / 测速中品牌蓝 / 未测灰。
/// </summary>
public sealed class NodeItem : ObservableObject
{
    private static SolidColorBrush B(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    private static readonly SolidColorBrush Fast = B(0x16, 0xA3, 0x4A);
    private static readonly SolidColorBrush Amber = B(0xD9, 0x77, 0x06);
    private static readonly SolidColorBrush Slow = B(0xEA, 0x58, 0x0C);
    private static readonly SolidColorBrush Bad = B(0xDC, 0x26, 0x26);
    private static readonly SolidColorBrush TestingBrush = B(0x00, 0x7A, 0xFF);

    public ProxyNode Model { get; }
    public NodeItem(ProxyNode model) { Model = model; }

    public string Name => Model.Name;
    public string Kind => ClashConfigGenerator.KindSlug(Model.Kind).ToUpperInvariant();

    private bool _isSelectedNow;
    /// <summary>这一行是不是当前出口。选中态必须有视觉反馈，否则「点了没反应」。</summary>
    public bool IsSelectedNow
    {
        get => _isSelectedNow;
        set
        {
            if (Set(ref _isSelectedNow, value)) Raise(nameof(RowState));
        }
    }

    /// <summary>卡片状态：选中 = 品牌浅底（DataTrigger 绑它）。</summary>
    public string RowState => _isSelectedNow ? "selected" : "";

    public void Refresh()
    {
        Raise(nameof(LatencyText));
        Raise(nameof(LatencyBrush));
        Raise(nameof(LatencyTip));
    }

    public string LatencyText => Model.State switch
    {
        DelayState.Ok => $"{Model.LastLatency} ms",
        DelayState.Testing => "⚡",
        DelayState.Timeout => "超时",
        DelayState.Failed => "不通",
        _ => "-",
    };

    public System.Windows.Media.Brush LatencyBrush => Model.State switch
    {
        DelayState.Ok when Model.LastLatency < 250 => Fast,
        DelayState.Ok when Model.LastLatency < 400 => Amber,
        DelayState.Ok => Slow,
        DelayState.Timeout or DelayState.Failed => Bad,
        DelayState.Testing => TestingBrush,
        _ => System.Windows.Media.Brushes.Gray,
    };

    /// <summary>失败必须能说出原因，不然「不通」和「超时」在用户眼里是同一件事。</summary>
    public string LatencyTip => Model.State switch
    {
        DelayState.Ok => $"{Model.Name} · 延迟 {Model.LastLatency} ms，点击可重测",
        DelayState.Testing => Lang.T("Tip.TestingNode"),
        DelayState.Untested => Lang.F("Tip.TestOne", Model.Server, Model.Port),
        _ => $"{Model.Name} · " + (Model.DelayError ?? "测速失败") + "（点击重试）",
    };

    public bool IsSelected => Model.Id.Length > 0;
}

/// <summary>
/// 一条订阅（配置页的资料卡，对齐 FlClash 的 Profile）：名字 / 地址 / 流量 / 更新时间 /
/// 自动更新档位。节点本身全部在「代理」页展示。
/// </summary>
public sealed class SubscriptionItem : ObservableObject
{
    public Subscription Model { get; }
    public SubscriptionItem(Subscription model)
    {
        Model = model;
        _autoUpdateChoice = model.AutoUpdateMinutes.ToString();
    }

    private bool _isUpdating;

    /// <summary>更新中：图标顺时针连续旋转（700ms 一圈）。</summary>
    public bool IsUpdating { get => _isUpdating; internal set => Set(ref _isUpdating, value); }

    private bool _updateFlash;

    /// <summary>完成反馈:图标变绿勾并轻微回弹(~1.4s),失败直接回原样(错误在状态条)。</summary>
    public bool UpdateFlash { get => _updateFlash; internal set => Set(ref _updateFlash, value); }

    /// <summary>这条订阅的全部节点行（与总表 Nodes 同一批实例：测速结果自动跟着变）。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> Nodes { get; } = new();

    /// <summary>搜索过滤 + 排序后实际显示的节点。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> VisibleNodes { get; } = new();

    private bool _isExpanded = true;

    /// <summary>展开 = 显示节点列表。折叠态要活过每一次列表重建（内核事件一秒好几次）。</summary>
    public bool IsExpanded { get => _isExpanded; set => Set(ref _isExpanded, value); }

    public string NodeCountText => Lang.F("Proxy.CountAll", VisibleNodes.Count, Nodes.Count, "");

    /// <summary>空状态提示用：这张卡当前有没有可见节点。</summary>
    public bool HasVisibleNodes => VisibleNodes.Count > 0;

    /// <summary>按搜索词过滤 + 按所选方式排序。只挪不重建：滚动位置与测速结果都不丢。</summary>
    internal void ApplyCardFilter(string search, string sort)
    {
        var q = (search ?? "").Trim();
        IEnumerable<NodeItem> matched = Nodes;
        if (q.Length > 0)
            matched = matched.Where(n =>
                n.Model.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                || n.Model.OriginalName.Contains(q, StringComparison.OrdinalIgnoreCase));
        var want = sort switch
        {
            "name" => matched.OrderBy(n => n.Model.Name, StringComparer.OrdinalIgnoreCase).ToList(),
            "delay" => matched.OrderBy(n => n.Model.State switch
            {
                TunBox.Core.Models.DelayState.Ok => n.Model.LastLatency,
                TunBox.Core.Models.DelayState.Testing => 1_000_000,
                _ => 2_000_000,
            }).ThenBy(n => n.Model.Name, StringComparer.OrdinalIgnoreCase).ToList(),
            _ => matched.ToList(),
        };
        for (var i = 0; i < want.Count; i++)
        {
            var at = VisibleNodes.IndexOf(want[i]);
            if (at < 0) VisibleNodes.Insert(i, want[i]);
            else if (at != i) VisibleNodes.Move(at, i);
        }
        for (var i = VisibleNodes.Count - 1; i >= 0; i--)
            if (!want.Contains(VisibleNodes[i])) VisibleNodes.RemoveAt(i);
        Raise(nameof(NodeCountText));
        Raise(nameof(HasVisibleNodes));
    }

    private string _autoUpdateChoice;

    /// <summary>自动更新档位（分钟字符串；"0" = 手动）。改动立刻落盘，选完就是保存。</summary>
    public string AutoUpdateChoice
    {
        get => _autoUpdateChoice;
        set
        {
            if (!Set(ref _autoUpdateChoice, value ?? "0")) return;
            AutoUpdateChanged?.Invoke(this, _autoUpdateChoice);
        }
    }

    /// <summary>视图模型挂进来的回调：把档位写进设置并落盘（卡片自己摸不到管理器）。</summary>
    public Action<SubscriptionItem, string>? AutoUpdateChanged { get; set; }

    /// <summary>订阅是否启用了自动更新（图标提示用）。</summary>
    public bool AutoUpdateOn => Model.AutoUpdateMinutes > 0;

    public string Name => string.IsNullOrWhiteSpace(Model.Name) ? Model.Url : Model.Name;
    public string UrlText => Model.Url.Length > 0 ? Model.Url : Lang.T("Profile.UrlNone");
    public string Updated => Model.UpdatedAtMs > 0
        ? DateTimeOffset.FromUnixTimeMilliseconds(Model.UpdatedAtMs).LocalDateTime.ToString("MM-dd HH:mm")
        : "未更新";

    public string TrafficText
    {
        get
        {
            if (Model.TotalBytes <= 0) return "";
            var used = Math.Max(0, Model.UploadBytes + Model.DownloadBytes);
            return $"{Fmt(used)} / {Fmt(Model.TotalBytes)}"
                + (Model.ExpireAtMs > 0 ? " · " + DateTimeOffset.FromUnixTimeMilliseconds(Model.ExpireAtMs).LocalDateTime.ToString("yyyy-MM-dd 到期") : "");
        }
    }

    public double TrafficRatio
    {
        get
        {
            if (Model.TotalBytes <= 0) return 0;
            var used = Math.Max(0, Model.UploadBytes + Model.DownloadBytes);
            return Math.Clamp((double)used / Model.TotalBytes, 0.01, 1.0);
        }
    }

    /// <summary>流量条颜色：健康 = 品牌蓝，用量 &gt;80% 转琥珀，&gt;95% 转红。</summary>
    public System.Windows.Media.Brush TrafficRatioBrush
    {
        get
        {
            var ratio = TrafficRatio;
            if (ratio > 0.95) return DangerBrush;
            if (ratio > 0.80) return WarnBrush;
            return BrandBrush;
        }
    }

    public bool HasTraffic => Model.TotalBytes > 0;

    private static System.Windows.Media.SolidColorBrush B(byte r, byte g, byte b)
    {
        var brush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    private static readonly System.Windows.Media.Brush BrandBrush = B(0x00, 0x7A, 0xFF);
    private static readonly System.Windows.Media.Brush WarnBrush = B(0xD9, 0x77, 0x06);
    private static readonly System.Windows.Media.Brush DangerBrush = B(0xDC, 0x26, 0x26);

    public void Refresh()
    {
        Raise(nameof(TrafficText));
        Raise(nameof(Updated));
        Raise(nameof(TrafficRatio));
        Raise(nameof(TrafficRatioBrush));
        Raise(nameof(AutoUpdateOn));
        Raise(nameof(UrlText));
    }

    private static string Fmt(long b) => b switch
    {
        >= 1_073_741_824 => $"{b / 1_073_741_824.0:0.00} GB",
        >= 1_048_576 => $"{b / 1_048_576.0:0.0} MB",
        >= 1024 => $"{b / 1024.0:0} KB",
        _ => b + " B",
    };
}

/// <summary>请求表的一行。按 Id 复用实例、只刷新数字，用户的鼠标底下不会换行。</summary>
public sealed class ConnectionItem : ObservableObject
{
    public string Id { get; }
    public ConnectionItem(string id) { Id = id; }

    private string _target = "";
    public string Target { get => _target; private set => Set(ref _target, value); }
    private string _chain = "";
    public string Chain { get => _chain; private set => Set(ref _chain, value); }
    private string _process = "";
    public string Process { get => _process; private set => Set(ref _process, value); }
    private string _rule = "";
    public string Rule { get => _rule; private set => Set(ref _rule, value); }
    private string _protocol = "";
    public string Protocol { get => _protocol; private set => Set(ref _protocol, value); }
    private string _started = "";
    public string Started { get => _started; private set => Set(ref _started, value); }
    private long _upload;
    public long Upload
    {
        get => _upload;
        private set { if (Set(ref _upload, value)) Raise(nameof(UploadText)); }
    }
    private long _download;
    public long Download
    {
        get => _download;
        private set { if (Set(ref _download, value)) Raise(nameof(DownloadText)); }
    }
    public string DownloadText => FmtBytes(Download);
    public string UploadText => FmtBytes(Upload);
    private string _upSpeedText = "";
    public string UpSpeedText { get => _upSpeedText; private set => Set(ref _upSpeedText, value); }
    private string _downSpeedText = "";
    public string DownSpeedText { get => _downSpeedText; private set => Set(ref _downSpeedText, value); }
    public DateTime StartAt { get; private set; }

    private long _prevUpload = -1;
    private long _prevDownload = -1;

    public void Apply(Connection c, DateTime now, double seconds)
    {
        Target = c.Target;
        Chain = c.Chain;
        Process = c.Process;
        Rule = c.Rule;
        Protocol = c.Network.Length == 0 ? "" : c.Network.ToUpperInvariant() + (c.Port > 0 ? " " + c.Port : "");
        StartAt = c.Start == default ? DateTime.MinValue : c.Start.ToLocalTime();
        Started = c.Start == default ? "" : StartAt.ToString("HH:mm:ss");
        // 首次见到的连接没有上一拍可差分，速率从 0 起，别拿「总量/时长」编一个假速率
        var upSpeed = _prevUpload >= 0 && seconds > 0 ? Math.Max(0, c.Upload - _prevUpload) / seconds : 0;
        var downSpeed = _prevDownload >= 0 && seconds > 0 ? Math.Max(0, c.Download - _prevDownload) / seconds : 0;
        _prevUpload = c.Upload;
        _prevDownload = c.Download;
        Upload = c.Upload;
        Download = c.Download;
        UpSpeedText = FmtSpeed(upSpeed);
        DownSpeedText = FmtSpeed(downSpeed);
    }

    internal static string FmtBytes(long b) => b switch
    {
        >= 1_073_741_824 => $"{b / 1_073_741_824.0:0.00} GB",
        >= 1_048_576 => $"{b / 1_048_576.0:0.0} MB",
        >= 1024 => $"{b / 1024.0:0} KB",
        _ => b + " B",
    };

    internal static string FmtSpeed(double perSecond) => perSecond switch
    {
        >= 1_048_576 => $"{perSecond / 1_048_576:0.0} MB/s",
        >= 1024 => $"{perSecond / 1024:0} KB/s",
        _ => $"{perSecond:0} B/s",
    };
}

/// <summary>主视图模型：五个页面共一份数据，导航只是切换显示哪一块。</summary>
public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly Workspace _workspace;
    private readonly ConnectionManager _manager;

    public ObservableCollection<NodeItem> Nodes { get; } = new();
    public ObservableCollection<SubscriptionItem> Subscriptions { get; } = new();
    public ObservableCollection<ConnectionItem> Connections { get; } = new();
    /// <summary>请求表的筛选视图：搜索框只过滤显示，底层顺序不动。</summary>
    public ICollectionView ConnectionsView { get; }

    // ── 页面导航（对齐 FlClash：仪表盘 / 代理 / 请求 / 配置 / 设置） ──────
    public const string PageDashboard = "仪表盘";
    public const string PageProxies = "代理";
    public const string PageRequests = "请求";
    public const string PageSettings = "设置";

    private string _activePage = PageDashboard;

    /// <summary>当前页；页头大标题绑它。</summary>
    public string ActivePage { get => _activePage; private set => Set(ref _activePage, value); }

    /// <summary>页内跳转（仪表盘「查看请求」等）：窗口代码后置接到后翻页签。</summary>
    public event Action<string>? NavigateRequested;

    public RelayCommand GoToPageCommand { get; }

    private void GoToPage(object? p)
    {
        if (p is string page && page.Length > 0) NavigateRequested?.Invoke(page);
    }

    private NodeItem? _selectedNode;
    public NodeItem? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (!Set(ref _selectedNode, value) || value == null) return;
            if (_rebuilding) return;
            _ = SelectNodeAsync(value);
        }
    }

    private async Task SelectNodeAsync(NodeItem item)
    {
        // 统一落在总出口 PROXY：点了哪张卡哪张卡就是出口。
        var ok = await _manager.SelectNodeAsync(item.Model.Name, "PROXY");
        // 内核拒了（Manager 已经把原因写进 LastError）：不假装选中，也不给用户瞎指一条路
        if (!ok) { DetailText = _manager.LastError ?? Lang.F("Msg.SwitchRejected", item.Name); return; }
        foreach (var n in Nodes) n.IsSelectedNow = ReferenceEquals(n, item);
        Raise(nameof(SelectedNode));
        // 手点一个节点 = 退出自动优选
        Raise(nameof(SmartActive));
        Raise(nameof(SelectedEgressText));
    }

    /// <summary>SelectedNodeId 的这个取值表示「出口交给内核的 smart 组」，不是某个具体节点。</summary>
    public const string SmartEgressId = ConnectionManager.AutoEgressId;

    /// <summary>模型在盘上 + 开了开关 + 至少两个节点，才有自动优选可选。</summary>
    public bool SmartAvailable => _manager.SmartGroupReady;

    /// <summary>
    /// 当前出口是不是「自动选择」。**没显式选过节点时默认就是它** ——
    /// mihomo-smart 的卖点就是内置小模型按每条连接的目标自动择优，用户第一次打开就该在用它。
    /// </summary>
    public bool SmartActive => SmartAvailable &&
        (_manager.Settings.SelectedNodeId.Length == 0 || _manager.Settings.SelectedNodeId == SmartEgressId);

    public string SmartSubtitle => Lang.F("Tip.SmartSubtitle", Nodes.Count);

    /// <summary>仪表盘「当前出口」：自动优选时显示组名，不假装是某个节点。</summary>
    public string SelectedEgressText => SmartActive
        ? ClashConfigGenerator.SmartGroupName
        : SelectedNode?.Name ?? "还没选节点";

    // ── 全局反馈条 ───────────────────────────────────────────────────────

    private string _detailText = "";

    /// <summary>
    /// 底部状态条：报完就自己消失（3 秒）。
    /// </summary>
    public string DetailText
    {
        get => _detailText;
        set
        {
            if (_detailText == value && value.Length > 0) return;
            _detailText = value;
            Raise(nameof(DetailText));
            RestartHintTimer();
        }
    }

    private System.Windows.Threading.DispatcherTimer? _hintTimer;

    private void RestartHintTimer()
    {
        if (_detailText.Length == 0) return;
        _hintTimer ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _hintTimer.Stop();
        _hintTimer.Tick -= OnHintExpired;
        _hintTimer.Tick += OnHintExpired;
        _hintTimer.Start();
    }

    private void OnHintExpired(object? sender, EventArgs e)
    {
        _hintTimer?.Stop();
        _detailText = "";
        Raise(nameof(DetailText));
    }

    private bool _isConnected;
    private bool _isConnecting;
    public bool IsConnected { get => _isConnected; private set => Set(ref _isConnected, value); }
    public bool IsConnecting { get => _isConnecting; private set { if (Set(ref _isConnecting, value)) Raise(nameof(RingStateText)); } }

    /// <summary>电源环中间那行字：只有 未连接 / 正在连接 / 已连接 三种。</summary>
    public string RingStateText => IsConnected ? Lang.T("State.Connected") : IsConnecting ? Lang.T("State.Connecting") : Lang.T("State.Disconnected");

    private bool _isCoreAlive;
    public bool IsCoreAlive { get => _isCoreAlive; private set => Set(ref _isCoreAlive, value); }

    private string _proxyMode = "rule";
    public string ProxyMode { get => _proxyMode; private set => Set(ref _proxyMode, value); }

    private string _trafficText = "↑ 0 B/s   ↓ 0 B/s";
    public string TrafficText { get => _trafficText; private set => Set(ref _trafficText, value); }

    private string _upSpeedText = "0 B/s";
    public string UpSpeedText { get => _upSpeedText; private set => Set(ref _upSpeedText, value); }
    private string _downSpeedText = "0 B/s";
    public string DownSpeedText { get => _downSpeedText; private set => Set(ref _downSpeedText, value); }

    /// <summary>速率采样（字节/秒）。流量图控件借窗口订阅它，VM 不持有控件。</summary>
    public event Action<double, double>? SpeedSampled;

    // ── 命令 ─────────────────────────────────────────────────────────────
    public AsyncRelayCommand ToggleConnectCommand { get; }
    public AsyncRelayCommand TestAllCommand { get; }
    public AsyncRelayCommand ImportSubscriptionCommand { get; }
    public AsyncRelayCommand ApplySettingsCommand { get; }
    public AsyncRelayCommand SaveAllCommand { get; }
    public AsyncRelayCommand RefreshGeoCommand { get; }
    public AsyncRelayCommand CloseAllConnectionsCommand { get; }
    public AsyncRelayCommand UpdateAllCommand { get; }
    public AsyncRelayCommand RunNetCheckCommand { get; }
    public AsyncRelayCommand SaveOverrideCommand { get; }
    public RelayCommand SetModeCommand { get; }
    public RelayCommand PauseToggleCommand { get; }
    public RelayCommand RemoveSubscriptionCommand { get; }
    public RelayCommand OpenLogCommand { get; }
    public RelayCommand ViewConfigCommand { get; }
    public RelayCommand RestartAsAdminCommand { get; }
    public RelayCommand ExitCommand { get; }
    public RelayCommand ToggleTunCommand { get; }
    public AsyncRelayCommand SelectSmartCommand { get; }

    /// <summary>手动查一次出口信息（卡片右上角那个刷新）。</summary>
    public AsyncRelayCommand RefreshEgressCommand { get; }

    /// <summary>把总出口交给 smart 组：PROXY 选到 ♻️ 自动选择，之后每条连接由模型决定走哪个节点。</summary>
    private async Task SelectSmartAsync()
    {
        if (!SmartAvailable)
        {
            DetailText = Lang.T("Msg.SmartUnavailable");
            return;
        }
        var ok = await _manager.SelectNodeAsync(ClashConfigGenerator.SmartGroupName, "PROXY");
        // SelectNodeAsync 按节点名找 id，smart 组不是节点所以找不到 —— 出口标记要自己写
        _manager.Settings.SelectedNodeId = SmartEgressId;
        _manager.SaveSettings();
        foreach (var n in Nodes) n.IsSelectedNow = false;
        Raise(nameof(SmartActive));
        Raise(nameof(SelectedEgressText));
        // 切换成功不播报：页签高亮 + 当前出口名就是反馈
        if (!ok) DetailText = Lang.T("Msg.SmartRejected");
    }

    private string _subscriptionInput = "";
    public string SubscriptionInput { get => _subscriptionInput; set => Set(ref _subscriptionInput, value); }

    private string _mixedPortText = "7890";
    public string MixedPortText { get => _mixedPortText; set => Set(ref _mixedPortText, value); }
    private string _httpPortText = "0";
    public string HttpPortText { get => _httpPortText; set => Set(ref _httpPortText, value); }
    private string _socksPortText = "0";
    public string SocksPortText { get => _socksPortText; set => Set(ref _socksPortText, value); }
    private string _apiPortText = "9090";
    public string ApiPortText { get => _apiPortText; set => Set(ref _apiPortText, value); }
    private bool _allowLan;
    public bool AllowLan { get => _allowLan; set => Set(ref _allowLan, value); }
    private bool _tunOn;
    public bool TunOn { get => _tunOn; set { if (Set(ref _tunOn, value)) SyncTunStatus(); } }
    private string _testUrlText = "";
    public string TestUrlText { get => _testUrlText; set => Set(ref _testUrlText, value); }
    private string _logLevelChoice = "info";
    public string LogLevelChoice { get => _logLevelChoice; set => Set(ref _logLevelChoice, value); }
    private bool _snifferOn = true;
    public bool SnifferOn { get => _snifferOn; set => Set(ref _snifferOn, value); }
    private bool _smartOn = true;
    public bool SmartOn { get => _smartOn; set => Set(ref _smartOn, value); }
    private bool _ipv6On;
    public bool Ipv6On { get => _ipv6On; set => Set(ref _ipv6On, value); }
    private bool _dnsOverrideOn;
    public bool DnsOverrideOn { get => _dnsOverrideOn; set => Set(ref _dnsOverrideOn, value); }
    private string _dnsServersText = "";
    public string DnsServersText { get => _dnsServersText; set => Set(ref _dnsServersText, value); }

    /// <summary>
    /// DNS 覆写的默认值：阿里 + 腾讯的 DoT 端点（国内可达、加密、不用翻墙），
    /// 和没开覆写时内核内置的那组一致 —— 用户打开开关就能看到能用的东西，而不是面对一个空框。
    /// </summary>
    public const string DefaultDnsServers = "tls://223.5.5.5:853\ntls://1.12.12.12:853";

    private string _dnsFeedback = "";

    /// <summary>DNS 覆写的逐行校验结果，写不进内核的那几条必须当场说出来。</summary>
    public string DnsFeedback { get => _dnsFeedback; private set => Set(ref _dnsFeedback, value); }
    private bool _rulesOn = true;
    public bool RulesOn { get => _rulesOn; set => Set(ref _rulesOn, value); }
    private bool _adRulesOn;
    public bool AdRulesOn { get => _adRulesOn; set => Set(ref _adRulesOn, value); }
    private string _customRulesText = "";
    public string CustomRulesText { get => _customRulesText; set => Set(ref _customRulesText, value); }
    private string _forceProxyText = "";
    public string ForceProxyText { get => _forceProxyText; set => Set(ref _forceProxyText, value); }
    private string _forceDirectText = "";
    public string ForceDirectText { get => _forceDirectText; set => Set(ref _forceDirectText, value); }
    private string _appProcesses = "";
    public string AppProcesses { get => _appProcesses; set => Set(ref _appProcesses, value); }
    private string _appRoutingChoice = "all";
    public string AppRoutingChoice { get => _appRoutingChoice; set => Set(ref _appRoutingChoice, value); }
    private bool _autoStartOn;
    public bool AutoStartOn { get => _autoStartOn; set => Set(ref _autoStartOn, value); }
    private bool _startMinimizedOn;

    /// <summary>静默启动：开机/快捷方式启动不开主窗口。选完立刻落盘（App 启动时读）。</summary>
    public bool StartMinimizedOn
    {
        get => _startMinimizedOn;
        set { if (Set(ref _startMinimizedOn, value)) { _manager.Settings.StartMinimized = value; _manager.SaveSettings(); } }
    }

    private string _tunStackChoice = "system";

    /// <summary>TUN 协议栈（对齐 FlClash 的 TUN 设置）：system 快 / gvisor 兼容 / mixed 兼顾。随「保存设置」生效。</summary>
    public string TunStackChoice { get => _tunStackChoice; set => Set(ref _tunStackChoice, value); }

    private string _tunMtuText = "1500";

    /// <summary>TUN 网卡 MTU（对齐 FlClash 的 TUN 高级项）。非法值在保存时归一回 1500。</summary>
    public string TunMtuText { get => _tunMtuText; set => Set(ref _tunMtuText, value); }

    private bool _tunStrictRoute;

    /// <summary>严格路由：拒绝绕过 TUN 的流量（防漏，内网工具多时可能失联）。</summary>
    public bool TunStrictRouteOn { get => _tunStrictRoute; set => Set(ref _tunStrictRoute, value); }

    private bool _tunEinat;

    /// <summary>端点独立 NAT（UDP 对称 NAT 兼容）。</summary>
    public bool TunEinatOn { get => _tunEinat; set => Set(ref _tunEinat, value); }

    private string _apiSecretText = "";

    /// <summary>external-controller 的 Bearer 密钥；随「保存设置」生效。</summary>
    public string ApiSecretText { get => _apiSecretText; set => Set(ref _apiSecretText, value); }

    // ── 多语言（对齐 FlClash 的语言设置）────────────────────────────────

    private string _languageChoice = "";

    /// <summary>auto = 跟随系统；zh / en 手动锁定。切换即时生效并落盘。</summary>
    public string LanguageChoice
    {
        get => _languageChoice;
        set
        {
            if (!Set(ref _languageChoice, value)) return;
            _manager.Settings.Language = value;
            _manager.SaveSettings();
            ApplyLanguage();
        }
    }

    /// <summary>把语言应用到所有已打开的窗口（主窗口 + 对话框都读 Application 级字典）。</summary>
    internal void ApplyLanguage()
    {
        if (System.Windows.Application.Current == null) return;
        Lang.Apply(System.Windows.Application.Current.Resources, Lang.Resolve(_manager.Settings.Language));
        RefreshLocalizedOptions();
        // 静态拼接过的文案不重算（下一次触发时用新语言），动态绑定随字典自动换。
    }

    /// <summary>
    /// 语言字典就位后调用：VM 可能在字典挂上之前就构造好了（测试宿主 / 窗口构造顺序），
    /// 那一刻捕获的本地化字符串是原始键名 —— 这里把这类缓存重算一遍。
    /// </summary>
    internal void RefreshLocalizedOptions()
    {
        SyncTunStatus();
        RebuildQuickEgress();
        ApplyCardFilters();
        Raise(nameof(SmartSubtitle));
        Raise(nameof(SubscriptionCountText));
        Raise(nameof(RequestsCountText));
    }

    // ── 全局快捷键（对齐 FlClash 的快捷键设置）──────────────────────────

    /// <summary>快捷键改动后通知窗口重新注册（RegisterHotKey 挂在窗口消息循环上）。</summary>
    public event Action? HotkeysChanged;

    private string _hotkeyShow = "";
    public string HotkeyShowText
    {
        get => _hotkeyShow;
        set { var norm = Hotkeys.Normalize(value); if (Set(ref _hotkeyShow, norm)) SaveHotkey(norm, s => s.HotkeyShowWindow = norm); }
    }

    private string _hotkeyConnect = "";
    public string HotkeyConnectText
    {
        get => _hotkeyConnect;
        set { var norm = Hotkeys.Normalize(value); if (Set(ref _hotkeyConnect, norm)) SaveHotkey(norm, s => s.HotkeyToggleConnect = norm); }
    }

    private string _hotkeyTun = "";
    public string HotkeyTunText
    {
        get => _hotkeyTun;
        set { var norm = Hotkeys.Normalize(value); if (Set(ref _hotkeyTun, norm)) SaveHotkey(norm, s => s.HotkeyToggleTun = norm); }
    }

    private void SaveHotkey(string normalized, Action<TunBox.Core.Models.AppSettings> write)
    {
        write(_manager.Settings);
        _manager.SaveSettings();
        HotkeysChanged?.Invoke();
        DetailText = normalized.Length == 0 ? "" : Lang.F("Set.Hotkey.Registered", normalized);
    }

    /// <summary>设置页捕获框的占位文案。</summary>
    public string HotkeyPlaceholder => Lang.T("Set.Hotkey.Empty");

    // ── 代理页排序（对齐 FlClash 的排序选项）────────────────────────────

    private string _sortChoice = "default";

    /// <summary>default = 保留测速后的排序历史；delay/name = 强制排序。</summary>
    public string SortChoice
    {
        get => _sortChoice;
        set
        {
            if (!Set(ref _sortChoice, value ?? "default")) return;
            ApplyCardFilters();
        }
    }

    private string _nodeSearchText = "";

    /// <summary>节点搜索：所有订阅卡一起过滤，一个字就重筛（列表量级 ≤几百，够快）。</summary>
    public string NodeSearchText
    {
        get => _nodeSearchText;
        set { if (!Set(ref _nodeSearchText, value ?? "")) return; ApplyCardFilters(); }
    }

    private void ApplyCardFilters()
    {
        foreach (var card in Subscriptions) card.ApplyCardFilter(_nodeSearchText, _sortChoice);
    }

    // ── 仪表盘快捷出口（不进代理页直接切点）────────────────────────────

    /// <summary>快捷出口下拉的选项：自动选择（可用时）+ 全部节点名。</summary>
    public System.Collections.ObjectModel.ObservableCollection<string> QuickEgressOptions { get; } = new();

    private string _quickEgressSelected = "";

    /// <summary>下拉当前值；改了就真的切出口（smart 或具体节点）。</summary>
    public string QuickEgressSelected
    {
        get => _quickEgressSelected;
        set
        {
            if (!Set(ref _quickEgressSelected, value ?? "")) return;
            if (value.Length == 0 || _rebuilding) return;
            if (SmartActive && value == SmartOptionLabel) return;   // 已经是自动选择，别重复切
            var node = Nodes.FirstOrDefault(n => n.Model.Name == value);
            if (node != null) { SelectedNode = node; return; }
            if (SmartAvailable && value == SmartOptionLabel) _ = SelectSmartAsync();
        }
    }

    private string SmartOptionLabel => Lang.T("Proxy.Smart");

    private void RebuildQuickEgress()
    {
        var want = new List<string>();
        if (SmartAvailable) want.Add(SmartOptionLabel);
        foreach (var n in Nodes) want.Add(n.Model.Name);
        // 内容没变就别动集合：内核事件一秒好几次，每次都 Clear+重加会让下拉框闪烁
        var changed = want.Count != QuickEgressOptions.Count
                      || !want.SequenceEqual(QuickEgressOptions);
        if (changed)
        {
            QuickEgressOptions.Clear();
            foreach (var name in want) QuickEgressOptions.Add(name);
        }
        var keep = _quickEgressSelected;
        var match = want.FirstOrDefault(x => x == keep)
                    ?? (SmartActive ? SmartOptionLabel : SelectedNode?.Model.Name)
                    ?? want.FirstOrDefault();
        _quickEgressSelected = match ?? "";
        if (changed || _quickEgressSelected != keep) Raise(nameof(QuickEgressSelected));
    }

    /// <summary>仪表盘端口卡的摘要行。</summary>
    public string PortsSummaryText => Lang.F("Dash.PortsFormat",
        _manager.Settings.MixedPort, _manager.Settings.HttpPort,
        _manager.Settings.SocksPort, _manager.Settings.ApiPort);

    // ── 配置页全部更新 ──────────────────────────────────────────────────

    private bool _updatingAll;

    public bool UpdatingAll { get => _updatingAll; private set { if (Set(ref _updatingAll, value)) Raise(nameof(UpdateAllLabel)); } }

    public string UpdateAllLabel => UpdatingAll ? Lang.T("Profile.Updating") : Lang.T("Profile.UpdateAll");

    private async Task UpdateAllAsync()
    {
        if (_updatingAll) return;
        var targets = _manager.Subscriptions.Where(s => s.Url.Length > 0).ToList();
        if (targets.Count == 0) { DetailText = Lang.T("Profile.None"); return; }
        UpdatingAll = true;
        try
        {
            var failed = 0;
            foreach (var s in targets)
                if (!await _manager.RefreshSubscriptionAsync(s.Id)) failed++;
            RebuildLists();
            DetailText = failed == 0
                ? Lang.T("Msg.UpdateAllDone")
                : Lang.F("Msg.UpdateAllPartial", targets.Count - failed, failed);
        }
        finally { UpdatingAll = false; }
    }

    // ── 工具页：Hosts / 覆写 / 网络检测 / 内核日志 ──────────────────────

    private string _hostsText = "";

    /// <summary>Hosts 编辑器的文本；一行一条「域名 IP」或「域名=IP」。随「保存覆写」一起落盘。</summary>
    public string HostsText { get => _hostsText; set => Set(ref _hostsText, value); }

    private string _hostsFeedback = "";
    public string HostsFeedback { get => _hostsFeedback; private set => Set(ref _hostsFeedback, value); }

    internal static List<KeyValuePair<string, string>> ParseHosts(string text, List<string>? problems = null)
    {
        var outPairs = new List<KeyValuePair<string, string>>();
        var lines = text.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var sep = line.IndexOfAny(new[] { ' ', '\t', '=', ':' });
            if (sep <= 0 || sep == line.Length - 1)
            {
                problems?.Add(Lang.F("Tools.Hosts.LineBad", i + 1));
                continue;
            }
            var host = line[..sep].Trim().TrimEnd('.');
            var ip = line[(sep + 1)..].Trim();
            if (host.Length == 0 || ip.Length == 0)
            {
                problems?.Add(Lang.F("Tools.Hosts.LineBad", i + 1));
                continue;
            }
            outPairs.Add(new(host, ip));
        }
        return outPairs;
    }

    private bool _overrideEnabled;
    public bool OverrideEnabledOn { get => _overrideEnabled; set => Set(ref _overrideEnabled, value); }

    private string _overrideMergeText = "";
    public string OverrideMergeText { get => _overrideMergeText; set => Set(ref _overrideMergeText, value); }

    private string _overrideScriptText = "";
    public string OverrideScriptText { get => _overrideScriptText; set => Set(ref _overrideScriptText, value); }

    private async Task SaveOverrideAsync()
    {
        var s = _manager.Settings;
        var problems = new List<string>();
        var hosts = ParseHosts(HostsText, problems);
        s.Hosts.Clear();
        foreach (var (k, v) in hosts) s.Hosts[k] = v;
        s.OverrideEnabled = OverrideEnabledOn;
        s.OverrideMergeYaml = OverrideMergeText;
        s.OverrideScript = OverrideScriptText;
        _manager.SaveSettings();
        HostsFeedback = problems.Count > 0 ? string.Join("；", problems.Take(4))
            : Lang.F("Tools.Hosts.Feedback", hosts.Count);
        // 覆写与 Hosts 都影响配置：让内核立刻热重载一份新的。
        await ApplyChangesAsync("覆写");
        if (_manager.LastOverrideNote is { Length: > 0 } note)
            DetailText = Lang.F("Tools.Override.Warn", note);
        else if (problems.Count == 0)
            DetailText = Lang.T("Tools.Override.Ok");
        if (!OverrideEnabledOn && (OverrideMergeText.Length > 0 || OverrideScriptText.Length > 0))
            Raise(nameof(OverrideDisabledHint));
    }

    /// <summary>覆写开关没开但写了内容的提醒（编辑区顶部）。</summary>
    public bool OverrideDisabledHint => !_overrideEnabled &&
        (OverrideMergeText.Length > 0 || OverrideScriptText.Length > 0);

    // ── 网络检测（对齐 FlClash 的网络检测）──────────────────────────────

    public sealed record NetCheckRow(string Url)
    {
        public string DirectText { get; internal set; } = "";
        public string ProxyText { get; internal set; } = "";
    }

    public System.Collections.ObjectModel.ObservableCollection<NetCheckRow> NetCheckRows { get; } = new();

    /// <summary>测试接缝：网络检测的探针可以注入（测试不打真网）。</summary>
    internal static Func<HttpClient, string, CancellationToken, Task<(bool Ok, int Ms)>> NetCheckProbe =
        static async (client, url, ct) =>
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            using var resp = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
            sw.Stop();
            return (resp.IsSuccessStatusCode, (int)sw.ElapsedMilliseconds);
        };

    private static readonly string[] NetCheckUrls =
    {
        "https://www.gstatic.com/generate_204",
        "https://github.com/robots.txt",
        "https://www.baidu.com/favicon.ico",
    };

    private bool _netChecking;
    public bool NetChecking { get => _netChecking; private set => Set(ref _netChecking, value); }

    private async Task RunNetCheckAsync()
    {
        if (_netChecking) return;
        NetCheckRows.Clear();
        foreach (var url in NetCheckUrls) NetCheckRows.Add(new NetCheckRow(url));
        NetChecking = true;
        try
        {
            using var direct = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
            using var proxied = _manager.Settings.SystemProxyPort() > 0
                ? new HttpClient(new HttpClientHandler
                {
                    UseProxy = true,
                    Proxy = new System.Net.WebProxy($"127.0.0.1:{_manager.Settings.SystemProxyPort()}"),
                })
                { Timeout = TimeSpan.FromSeconds(6) }
                : null;
            for (var i = 0; i < NetCheckRows.Count; i++)
            {
                var row = NetCheckRows[i];
                row.DirectText = await ProbeAsync(direct, row.Url);
                row.ProxyText = proxied == null
                    ? Lang.T("Tools.NetCheck.CoreOff")
                    : await ProbeAsync(proxied, row.Url);
            }
        }
        finally { NetChecking = false; }
    }

    private async Task<string> ProbeAsync(HttpClient client, string url)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            var (ok, ms) = await NetCheckProbe(client, url, cts.Token);
            return ok ? $"{ms} ms" : Lang.T("Tools.NetCheck.Fail");
        }
        catch (OperationCanceledException) { return Lang.T("Tools.NetCheck.Timeout"); }
        catch (Exception) { return Lang.T("Tools.NetCheck.Fail"); }
    }

    // ── 内核日志（工具页实时看）────────────────────────────────────────

    private string _toolsLogText = "";
    public string ToolsLogText { get => _toolsLogText; private set => Set(ref _toolsLogText, value); }

    private long _logLength;

    private void PollCoreLog()
    {
        try
        {
            var path = Path.Combine(_workspace.RuntimeDir, "core.log");
            if (!File.Exists(path))
            {
                if (ToolsLogText.Length == 0) ToolsLogText = Lang.T("Tools.Log.Empty");
                return;
            }
            var len = new FileInfo(path).Length;
            if (len == _logLength && ToolsLogText.Length > 0) return;
            _logLength = len;
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            // 只读尾部 256KB：内核 info 日志一天也写不满这么多，够用户看现场了。
            if (stream.Length > 256 * 1024) stream.Seek(-256 * 1024, SeekOrigin.End);
            using var reader = new StreamReader(stream);
            var text = reader.ReadToEnd();
            var lines = text.Split('\n');
            if (lines.Length > 400) text = string.Join('\n', lines[^400..]);
            ToolsLogText = text.TrimEnd() is { Length: > 0 } t ? t : Lang.T("Tools.Log.Empty");
        }
        catch { /* 日志正被内核写：这一拍读不到就等下一拍 */ }
    }

    public void ClearToolsLog()
    {
        _logLength = 0;
        ToolsLogText = "";
    }

    // ── 内核版本（关于 + 仪表盘端口卡旁边）──────────────────────────────

    private string _coreVersionText = "";
    public string CoreVersionText
    {
        get => _coreVersionText;
        private set => Set(ref _coreVersionText, value);
    }

    private async Task FetchCoreVersionAsync()
    {
        if (!_manager.CoreAlive) { CoreVersionText = ""; return; }
        if (CoreVersionText.Length > 0) return;
        try { CoreVersionText = await _manager.Api.VersionAsync() ?? ""; } catch { /* 下一拍再试 */ }
    }


    // 系统代理不再有独立开关（用户钦定：只保留一个「代理连接」开关）。
    // 语义 = 单开关总闸:连接即接管系统代理(ConnectNowAsync 里 EnsureSystemProxy),断开即放手(TryDisableProxy)。

    private string _closeChoice = "ask";

    /// <summary>选完立刻落盘。</summary>
    public string CloseChoice
    {
        get => _closeChoice;
        set
        {
            if (!Set(ref _closeChoice, value)) return;
            _manager.Settings.Close = ToCloseBehavior(value);
            _manager.SaveSettings();
            Raise(nameof(CloseMode));
        }
    }

    internal static CloseBehavior ToCloseBehavior(string choice) => choice switch
    {
        "tray" => CloseBehavior.Tray,
        "exit" => CloseBehavior.Exit,
        _ => CloseBehavior.Ask,
    };

    private string _themeChoice = "auto";

    /// <summary>外观选择：auto=跟随系统，light/dark=手动锁定。改完立刻生效并落盘。</summary>
    public string ThemeChoice
    {
        get => _themeChoice;
        set
        {
            if (!Set(ref _themeChoice, value)) return;
            _manager.Settings.DarkTheme = value switch
            {
                "light" => false,
                "dark" => true,
                _ => null,
            };
            _manager.SaveSettings();
            ApplyTheme();
        }
    }

    /// <summary>把 ThemeChoice 应用到所有已打开的窗口（主窗口 + 对话框都是独立合并 Styles 的）。</summary>
    internal void ApplyTheme()
    {
        if (System.Windows.Application.Current == null) return;
        var dark = ThemeManager.ShouldBeDark(_manager.Settings.DarkTheme);
        foreach (System.Windows.Window w in System.Windows.Application.Current.Windows)
        {
            try
            {
                if (dark) ThemeManager.ApplyDark(w.Resources);
                else ThemeManager.RemoveDark(w.Resources);
            }
            catch { /* 单个窗口失败不挡其它窗口 */ }
        }
    }

    private string _geoSummaryText = "";
    public string GeoSummaryText { get => _geoSummaryText; private set => Set(ref _geoSummaryText, value); }

    private string _ruleFeedback = "";
    public string RuleFeedback { get => _ruleFeedback; private set => Set(ref _ruleFeedback, value); }

    private string _tunStatusText = "";
    public string TunStatusText { get => _tunStatusText; private set => Set(ref _tunStatusText, value); }

    public bool IsAdmin { get; } = Elevation.IsAdmin;
    public bool ShowElevationHint => !IsAdmin;

    /// <summary>侧栏上的版本号：用户反复重装测试时，得能一眼看出自己跑的是哪一版。</summary>
    public string VersionText { get; } = typeof(MainViewModel).Assembly
        .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        .Cast<System.Reflection.AssemblyInformationalVersionAttribute>()
        .FirstOrDefault()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public string SubscriptionCountText => Subscriptions.Count == 0
        ? Lang.T("Profile.None") : Lang.F("Profile.CountFormat", Subscriptions.Count, Nodes.Count);

    public string RequestsCountText => Connections.Count == 0
        ? Lang.T("Req.None") : Lang.F("Req.CountFormat", Connections.Count);

    // ── 检查更新 ─────────────────────────────────────────────────────────
    // 设置页那颗「检查更新」：查 GitHub 上比当前版本新的 windows-v* Release。

    public AsyncRelayCommand CheckUpdateCommand { get; }

    private bool _checkingUpdate;
    private string _updateStatusText = "";

    /// <summary>检查结果落在按钮旁边，不打扰状态条。</summary>
    public string UpdateStatusText
    {
        get => _updateStatusText;
        private set { _updateStatusText = value; Raise(nameof(UpdateStatusText)); }
    }

    private async Task CheckUpdateAsync()
    {
        if (_checkingUpdate) return;
        _checkingUpdate = true;
        UpdateStatusText = "正在检查更新…";
        try
        {
            var info = await new UpdateChecker().CheckAsync(VersionText, _manager.Settings.MixedPort);
            if (info == null)
            {
                UpdateStatusText = $"已是最新版本（v{VersionText}）。";
                return;
            }
            UpdateStatusText = $"发现新版本 v{info.Version}，正在打开下载页…";
            Process.Start(new ProcessStartInfo { FileName = info.Url, UseShellExecute = true });
        }
        catch (Exception)
        {
            UpdateStatusText = "检查更新失败：连不上 GitHub，检查网络后稍后再试。";
        }
        finally
        {
            _checkingUpdate = false;
        }
    }

    /// <summary>workspace 可注入：测试用默认值会写到用户真实的 %APPDATA%\TunBox。</summary>
    public MainViewModel(Workspace? workspace = null)
    {
        _workspace = workspace ?? new Workspace();
        _manager = new ConnectionManager(_workspace);
        _manager.Changed += OnManagerChanged;

        ConnectionsView = CollectionViewSource.GetDefaultView(Connections);
        ConnectionsView.Filter = o => o is ConnectionItem c && MatchesConnectionSearch(c);

        ToggleConnectCommand = new AsyncRelayCommand(_ => ToggleConnectAsync());
        TestAllCommand = new AsyncRelayCommand(_ => TestAllAsync(), _ => _manager.Nodes.Count > 0);
        ImportSubscriptionCommand = new AsyncRelayCommand(_ => ImportAsync());
        ApplySettingsCommand = new AsyncRelayCommand(_ => ApplySettingsAsync());
        SaveAllCommand = new AsyncRelayCommand(_ => SaveAllAsync());
        RefreshGeoCommand = new AsyncRelayCommand(_ => RefreshGeoAsync());
        CloseAllConnectionsCommand = new AsyncRelayCommand(_ => CloseAllConnsAsync());
        UpdateAllCommand = new AsyncRelayCommand(_ => UpdateAllAsync());
        RunNetCheckCommand = new AsyncRelayCommand(_ => RunNetCheckAsync());
        SaveOverrideCommand = new AsyncRelayCommand(_ => SaveOverrideAsync());
        SetModeCommand = new RelayCommand(p =>
        {
            var mode = (string?)p ?? "rule";
            _ = _manager.SetProxyModeAsync(mode);
            ProxyMode = mode;
        });
        PauseToggleCommand = new RelayCommand(_ => UpdatesPaused = !UpdatesPaused);
        SelectSmartCommand = new AsyncRelayCommand(_ => SelectSmartAsync());
        RefreshEgressCommand = new AsyncRelayCommand(_ => QueryEgressAsync());
        CheckUpdateCommand = new AsyncRelayCommand(_ => CheckUpdateAsync());
        RemoveSubscriptionCommand = new RelayCommand(p =>
        {
            if (p is SubscriptionItem item) _manager.RemoveSubscription(item.Model.Id);
        });
        GoToPageCommand = new RelayCommand(GoToPage);
        OpenLogCommand = new RelayCommand(_ =>
        {
            var path = Path.Combine(_workspace.RuntimeDir, "core.log");
            if (File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            else DetailText = Lang.T("Msg.NoLog");
        });
        ViewConfigCommand = new RelayCommand(_ =>
        {
            var path = Path.Combine(_workspace.RuntimeDir, "config.yaml");
            if (File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            else DetailText = Lang.T("Msg.NoLog");
        });
        RestartAsAdminCommand = new RelayCommand(_ => RestartElevated(), _ => !IsAdmin);
        ExitCommand = new RelayCommand(_ =>
        {
            if (Application.Current is App app) app.ExitApplication();
            else Application.Current?.Shutdown();
        });
        ToggleTunCommand = new RelayCommand(_ =>
        {
            TunOn = !TunOn;
            _ = ApplySettingsAsync();
        });
        // 任何命令漏出来的异常都落到状态栏：不弹窗、也不再把进程带崩。
        foreach (var c in new[] { ToggleConnectCommand, TestAllCommand, ImportSubscriptionCommand,
                                  ApplySettingsCommand, SaveAllCommand, RefreshGeoCommand,
                                  CloseAllConnectionsCommand })
            c.Failed += OnCommandFailed;

        RebuildLists();
        SyncFromSettings();
        if (_manager.Nodes.Count > 0) _ = _manager.EnsureStandbyAsync();

        // 订阅自动更新（对齐 FlClash 的「自动更新」）：每分钟看一眼哪些到了点，串行拉取。
        _autoUpdateTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _autoUpdateTimer.Tick += (_, _) => _ = RunDueAutoUpdatesAsync();
        _autoUpdateTimer.Start();
    }

    // ── 状态同步 ─────────────────────────────────────────────────────────

    /// <summary>命令里冒出来的异常：说人话落在状态栏，绝不弹模态窗。</summary>
    private void OnCommandFailed(Exception e)
        => DetailText = e is OperationCanceledException
            ? Lang.T("Msg.TimeoutRetry")
            : Lang.F("Msg.StepFailed", e.Message);

    private void SyncFromSettings()
    {
        var s = _manager.Settings;
        ProxyMode = s.ProxyMode;
        MixedPortText = s.MixedPort.ToString();
        HttpPortText = s.HttpPort.ToString();
        SocksPortText = s.SocksPort.ToString();
        ApiPortText = s.ApiPort.ToString();
        AllowLan = s.AllowLan;
        TunOn = s.TunEnabled;
        TestUrlText = s.TestUrl;
        LogLevelChoice = s.CoreLogLevel;
        SnifferOn = s.SniffingEnabled;
        SmartOn = s.UseSmartGroup;
        RulesOn = s.RulesEnabled;
        AdRulesOn = s.AdRulesEnabled;
        CustomRulesText = string.Join("\n", s.CustomRules);
        ForceProxyText = string.Join(", ", s.ForceProxySites);
        ForceDirectText = string.Join(", ", s.ForceDirectSites);
        AppProcesses = string.Join(", ", s.AppProcesses);
        AppRoutingChoice = s.AppRouting switch
        {
            AppRoutingMode.OnlySelected => "include",
            AppRoutingMode.BypassSelected => "exclude",
            _ => "all",
        };
        AutoStartOn = AutoStart.IsEnabled();
        _startMinimizedOn = s.StartMinimized;
        Raise(nameof(StartMinimizedOn));
        TunStackChoice = string.IsNullOrEmpty(s.TunStack) ? "system" : s.TunStack;
        TunMtuText = s.TunMtu.ToString();
        TunStrictRouteOn = s.TunStrictRoute;
        TunEinatOn = s.TunEndpointIndependentNat;
        ApiSecretText = s.ApiSecret;
        HostsText = string.Join("\n", s.Hosts.Select(kv =>
            kv.Key.Contains(' ') ? $"\"{kv.Key}\" {kv.Value}" : $"{kv.Key} {kv.Value}"));
        OverrideEnabledOn = s.OverrideEnabled;
        OverrideMergeText = s.OverrideMergeYaml;
        OverrideScriptText = s.OverrideScript;
        _languageChoice = string.IsNullOrEmpty(s.Language) ? "auto" : s.Language;
        Raise(nameof(LanguageChoice));
        _hotkeyShow = s.HotkeyShowWindow;
        _hotkeyConnect = s.HotkeyToggleConnect;
        _hotkeyTun = s.HotkeyToggleTun;
        Raise(nameof(HotkeyShowText));
        Raise(nameof(HotkeyConnectText));
        Raise(nameof(HotkeyTunText));
        // 直接落字段再通知：走 CloseChoice 的 setter 会在每次读档时回写一遍盘。
        _closeChoice = s.Close switch { CloseBehavior.Tray => "tray", CloseBehavior.Exit => "exit", _ => "ask" };
        Raise(nameof(CloseChoice));
        Raise(nameof(CloseMode));
        _themeChoice = s.DarkTheme switch { true => "dark", false => "light", null => "auto" };
        Raise(nameof(ThemeChoice));
        Ipv6On = s.Ipv6Enabled;
        DnsOverrideOn = s.DnsOverrideEnabled;
        DnsServersText = s.DnsServers.Count > 0 ? string.Join("\n", s.DnsServers) : DefaultDnsServers;
        SyncTunStatus();
        SyncGeoSummary();
    }

    private void SyncTunStatus()
    {
        // 读界面上的开关（TunOn），不是设置里的旧值：用户一勾选，状态行就得跟着变。
        // 判据是我们自己的虚拟网卡，不是 Windows 右下角那个图标（它画的是物理链路）。
        TunStatusText = !TunOn ? Lang.T("Msg.TunOff")
            : _manager.TunActive ? Lang.T("Msg.TunActive")
            : _manager.TunPending ? Lang.T("Msg.TunPending")
            : _manager.State == TunnelState.Connected
                ? (_manager.TunAdapterPresent() ? Lang.T("Msg.TunNoRoute") : Lang.T("Msg.TunFailed"))
                : !IsAdmin ? Lang.T("Msg.TunNeedAdmin")
                : Lang.T("Msg.TunArmed");
    }

    private void SyncGeoSummary()
    {
        var parts = new List<string>();
        foreach (var a in _manager.GeoAssets.Statuses)
        {
            if (a.Key == GeoAssetStore.AdRulesKey && !_manager.GeoAssets.AdRulesWanted) continue;
            parts.Add($"{a.Title}：{a.Detail}");
        }
        GeoSummaryText = parts.Count == 0 ? "分流库：还没开始下载" : string.Join("\n", parts);
    }

    // ── 出口信息卡（仪表盘）──────────────────────────────────────────────
    // 这张卡的存在理由就是用户报的那件事：「我选的节点和我查到的 IP 不对应」。

    private EgressSnapshot _egress = EgressSnapshot.Empty;
    private bool _egressBusy;
    private string _egressStamp = "";
    private int _egressGeneration;

    public bool EgressBusy { get => _egressBusy; private set => Set(ref _egressBusy, value); }
    public string EgressIpText => _egress.HasEgress ? _egress.EgressIp : (_egressBusy ? Lang.T("Tip.EgressBusy") : "—");
    public string EgressLocationText => _egress.HasEgress ? _egress.LocationText : "—";
    public string EgressCarrierText => _egress.HasEgress ? _egress.CarrierText : "—";
    public string LocalIpText => _egress.HasLocal ? _egress.LocalIp : "—";
    public bool HasEgressInfo => _egress.HasEgress;

    /// <summary>右下角那句提醒：出口=本机说明压根没走代理；查询失败就引用接口给的原因。</summary>
    public string EgressNote
    {
        get
        {
            if (_egress.Error != null) return Lang.F("Msg.EgressQueryFail", _egress.Error);
            if (_egress.SameAsLocal) return Lang.T("Msg.EgressSameAsLocal");
            if (!_egress.HasEgress) return IsConnected ? "" : Lang.T("Msg.EgressNeedConnect");
            return _egress.At == DateTime.MinValue ? "" : " " + Lang.F("Msg.EgressUpdated", _egress.At.ToString("HH:mm"));
        }
    }

    public bool ShowEgressWarn => _egress.SameAsLocal || _egress.Error != null;

    private void RaiseEgress()
    {
        foreach (var n in new[]
                 {
                     nameof(EgressIpText), nameof(EgressLocationText), nameof(EgressCarrierText),
                     nameof(LocalIpText), nameof(HasEgressInfo), nameof(EgressNote), nameof(ShowEgressWarn),
                 })
            Raise(n);
    }

    /// <summary>测试缝隙：换一下「出口身份」并排队一次出口查询（模拟用户连着点节点）。</summary>
    internal void PokeEgressForTests(string selectedNodeId)
    {
        _manager.Settings.SelectedNodeId = selectedNodeId;
        RefreshEgressSoon();
    }

    private async Task QueryEgressAsync()
    {
        if (EgressBusy) return;
        if (!_manager.EgressQueryable)
        {
            _egress = EgressSnapshot.Empty with { Connected = IsConnected };
            RaiseEgress();
            return;
        }
        EgressBusy = true;
        RaiseEgress();
        try
        {
            // 本机 IP 只在第一次（或用户手动刷新）时直连问一次，别每轮都多打一个请求
            _egress = await _manager.QueryEgressAsync(withLocal: !_egress.HasLocal);
            // 查询路上断开了连接：这次结果已经过期，别把「连接时查到的出口」留在卡上冒充现状
            if (!_manager.EgressQueryable)
                _egress = EgressSnapshot.Empty with { Connected = IsConnected };
        }
        catch (Exception e)
        {
            _egress = _egress with { Error = e.Message };
        }
        EgressBusy = false;
        RaiseEgress();
    }

    /// <summary>
    /// 出口该变了就重查一次：连接上、换节点、切模式都算；连珠炮式的重建合并成一次。
    /// 只数代数，不持有可被释放的对象：过期的那次自己走人。
    /// </summary>
    internal void RefreshEgressSoon()
    {
        var stamp = $"{(_manager.State == TunnelState.Connected ? "on" : "off")}"
            + $"|{_manager.Settings.ProxyMode}|{_manager.Settings.SelectedNodeId}";
        if (stamp == _egressStamp) return;
        _egressStamp = stamp;
        var generation = Interlocked.Increment(ref _egressGeneration);
        _ = Task.Run(async () =>
        {
            await Task.Delay(800);
            if (generation != Volatile.Read(ref _egressGeneration)) return;   // 后面又点过了，让最新那次去查
            Application.Current?.Dispatcher.InvokeAsync(() =>
            {
                if (generation != Volatile.Read(ref _egressGeneration)) return;
                _ = QueryEgressAsync();
            });
        });
    }

    private void OnManagerChanged()
    {
        // 内核事件来自后台线程，一秒能来好几次：这里抛一个异常就是一格一帧的弹窗风暴，
        // 所以整段兜底 —— 刷新失败落到状态栏，绝不让它逃出去。
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            try
            {
                RebuildLists();
                IsConnected = _manager.IsConnected;
                IsCoreAlive = _manager.CoreAlive;
                IsConnecting = _manager.State == TunnelState.Connecting;
                Raise(nameof(RingStateText));
                if (_manager.LastError != null) DetailText = _manager.LastError;
                else if (_manager.LastDrop is { HasDrop: true } d) DetailText = d.Summary();
                ProxyMode = _manager.Settings.ProxyMode;
                SyncTunStatus();
                SyncGeoSummary();
                foreach (var item in Nodes) item.Refresh();
                Raise(nameof(SmartAvailable));
                Raise(nameof(SmartActive));
                Raise(nameof(SmartSubtitle));
                Raise(nameof(SelectedEgressText));
                Raise(nameof(PortsSummaryText));
                if (_manager.LastOverrideNote is { Length: > 0 } ov) DetailText = Lang.F("Tools.Override.Warn", ov);
                _ = FetchCoreVersionAsync();
                foreach (var c in new[] { TestAllCommand, ToggleConnectCommand, TestAllCommand }) c.Refresh();
                // 断开的那一刻就把旧出口从卡上撤下来，别等 800ms 防抖。
                if (!IsConnected && _egress.HasEgress) { _egress = EgressSnapshot.Empty; RaiseEgress(); }
                // 出口换了就该重新查一次出口 IP（连接、换节点、切模式都会走到这里，800ms 合并）
                RefreshEgressSoon();
            }
            catch (Exception e)
            {
                DetailText = Lang.F("Msg.UiCrash", e.GetType().Name, e.Message);
            }
        });
    }

    private bool _rebuilding;

    // ── 列表重建 ─────────────────────────────────────────────────────────

    /// <summary>
    /// 节点实例全项目只有一批（挂在总表 Nodes 上），代理页网格与选中态引用同一批
    /// —— 测速结果刷新一次，看得到的每一处都跟着变。
    ///
    /// 关键：**重建必须保留上次的显示顺序和选中的分组页签**。内核事件一秒能来好几次，
    /// 每次都 Clear + 按原序重加，界面上就是「刚排好的延迟顺序又弹回去了」。
    /// </summary>
    private void RebuildLists()
    {
        var selectedName = SelectedNode?.Model.Name;
        var previousOrder = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < Nodes.Count; i++) previousOrder.TryAdd(Nodes[i].Model.Id, i);
        var byIdCards = Subscriptions.ToDictionary(c => c.Model.Id, c => c);

        _rebuilding = true;
        try
        {
            Nodes.Clear();
            foreach (var n in _manager.Nodes)
            {
                var item = new NodeItem(n)
                {
                    IsSelectedNow = n.Id == _manager.Settings.SelectedNodeId,
                };
                Nodes.Add(item);
            }
            ReorderBy(Nodes, previousOrder);

            // 合并页：订阅卡**原地同步**——实例能复用就复用（按钮不闪、更新中的旋转动画不重启），
            // 只有新增/删除的订阅才真正建/删卡。展开态与可见顺序照旧保留。
            var keepExpanded = new Dictionary<string, bool>(StringComparer.Ordinal);
            var keepVisibleOrder = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal);
            foreach (var card in Subscriptions)
            {
                keepExpanded[card.Model.Id] = card.IsExpanded;
                var order = new Dictionary<string, int>(StringComparer.Ordinal);
                for (var i = 0; i < card.VisibleNodes.Count; i++) order.TryAdd(card.VisibleNodes[i].Model.Id, i);
                keepVisibleOrder[card.Model.Id] = order;
            }

            var wanted = new List<SubscriptionItem>();
            foreach (var s in _manager.Subscriptions)
            {
                if (!byIdCards.TryGetValue(s.Id, out var card))
                    card = new SubscriptionItem(s) { AutoUpdateChanged = OnAutoUpdateChanged };
                wanted.Add(card);
            }
            foreach (var gone in Subscriptions.Except(wanted).ToList()) Subscriptions.Remove(gone);
            for (var i = 0; i < wanted.Count; i++)
            {
                var card = wanted[i];
                var at = Subscriptions.IndexOf(card);
                if (at < 0) Subscriptions.Insert(i, card);
                else if (at != i) Subscriptions.Move(at, i);
            }
            foreach (var s in _manager.Subscriptions)
            {
                var card = Subscriptions.First(c => c.Model.Id == s.Id);
                if (keepExpanded.TryGetValue(s.Id, out var expanded)) card.IsExpanded = expanded;
                SyncCardNodes(card, s.Id, keepVisibleOrder.TryGetValue(s.Id, out var prev) ? prev : null);
                card.ApplyCardFilter(_nodeSearchText, _sortChoice);
            }

            RebuildQuickEgress();

            var match = Nodes.FirstOrDefault(x => x.Model.Name == selectedName)
                        ?? Nodes.FirstOrDefault(n => n.Model.Id == _manager.Settings.SelectedNodeId)
                        ?? Nodes.FirstOrDefault();
            if (!ReferenceEquals(SelectedNode, match)) SelectedNode = match;
        }
        finally { _rebuilding = false; }
        Raise(nameof(SubscriptionCountText));
        Raise(nameof(RequestsCountText));
        Raise(nameof(Nodes));
    }

    /// <summary>把一张订阅卡的节点集合同步成最新名单：能 Move 就 Move，不整表重建（节点网格不闪）。</summary>
    private void SyncCardNodes(SubscriptionItem card, string subId, Dictionary<string, int>? order)
    {
        var want = Nodes_of(subId);
        if (order != null)
            want = want.OrderBy(n => order.TryGetValue(n.Model.Id, out var at) ? at : int.MaxValue).ToList();
        for (var i = 0; i < want.Count; i++)
        {
            var at = card.Nodes.IndexOf(want[i]);
            if (at < 0) card.Nodes.Insert(i, want[i]);
            else if (at != i) card.Nodes.Move(at, i);
        }
        for (var i = card.Nodes.Count - 1; i >= 0; i--)
            if (!want.Contains(card.Nodes[i])) card.Nodes.RemoveAt(i);
    }

    private System.Collections.Generic.List<NodeItem> Nodes_of(string subId)
        => Nodes.Where(n => n.Model.SubscriptionId == subId).ToList();

    /// <summary>按上次的显示位置就地重排（用 Move，不重建集合）；新出现的节点保持原有相对顺序往后放。</summary>
    private static void ReorderBy(
        System.Collections.ObjectModel.ObservableCollection<NodeItem> list,
        Dictionary<string, int> previousOrder)
    {
        if (previousOrder.Count == 0) return;
        var want = list.OrderBy(x => previousOrder.TryGetValue(x.Model.Id, out var at) ? at : int.MaxValue)
            .ThenBy(x => list.IndexOf(x)).ToList();
        for (var i = 0; i < want.Count; i++)
        {
            var at = list.IndexOf(want[i]);
            if (at >= 0 && at != i) list.Move(at, i);
        }
    }

    /// <summary>点节点卡上的延迟数字：只测这一个，用来验证「这家不行还是这个不行」。</summary>
    public void TestOne(NodeItem item) => _ = TestOneCoreAsync(item);

    private async Task TestOneCoreAsync(NodeItem item)
    {
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? Lang.T("Msg.CoreDeadTest");
            return;
        }
        item.Model.State = DelayState.Testing;
        item.Refresh();
        var r = await _manager.TestNodeAsync(item.Model.Name);
        item.Refresh();
        // 延迟结果直接落在卡上（数字 / 超时 / 不通），不再重复播报；节点凭空消失才需要解释
        if (r == null) DetailText = Lang.T("Msg.NodeGone");
    }

    private static async Task ClearFlashSoonAsync(SubscriptionItem card)
    {
        try { await Task.Delay(1400).ConfigureAwait(true); } catch { }
        card.UpdateFlash = false;
    }

    public async Task UpdateSubscriptionAsync(SubscriptionItem item)
    {
        // 卡片实例可能在轮询重建时换过：按 Id 找当前挂在界面上的那张来转圈
        var card = Subscriptions.FirstOrDefault(c => c.Model.Id == item.Model.Id) ?? item;
        card.IsUpdating = true;
        try
        {
            var ok = await _manager.RefreshSubscriptionAsync(item.Model.Id);
            card.IsUpdating = false;
            if (!ok)
            {
                // 失败:停止旋转,错误已在状态条;按钮可立即再点
                DetailText = _manager.LastError ?? Lang.T("Msg.UpdateFailed");
                return;
            }
            // 成功:绿勾回弹反馈,1.4s 后自动收掉
            card.UpdateFlash = true;
            _ = ClearFlashSoonAsync(card);
        }
        catch { card.IsUpdating = false; throw; }
        RebuildLists();
        Raise(nameof(SubscriptionCountText));
    }

    public void RemoveSubscription(SubscriptionItem item)
    {
        _manager.RemoveSubscription(item.Model.Id);
        RebuildLists();
        Raise(nameof(SubscriptionCountText));
    }

    private void OnAutoUpdateChanged(SubscriptionItem item, string choice)
    {
        if (!int.TryParse(choice, out var minutes)) return;
        _manager.UpdateSubscriptionAutoUpdate(item.Model.Id, minutes);
        DetailText = minutes > 0
            ? Lang.F("Msg.AutoUpdateSet", item.Name, DescribeInterval(minutes))
            : Lang.F("Msg.AutoUpdateOff", item.Name);
    }

    internal static string DescribeInterval(int minutes) => minutes switch
    {
        30 => Lang.T("Interval.Min30"),
        60 => Lang.T("Interval.Hour"),
        360 => Lang.T("Interval.Hour6"),
        720 => Lang.T("Interval.Hour12"),
        1440 => Lang.T("Interval.Day"),
        _ => Lang.F("Interval.MinFormat", minutes),
    };

    // ── 订阅自动更新 ─────────────────────────────────────────────────────

    private readonly System.Windows.Threading.DispatcherTimer _autoUpdateTimer;
    private bool _autoUpdating;

    private async Task RunDueAutoUpdatesAsync()
    {
        if (_autoUpdating || _manager.Subscriptions.Count == 0) return;
        var due = _manager.DueForAutoUpdate(DateTimeOffset.Now);
        if (due.Count == 0) return;
        _autoUpdating = true;
        try
        {
            foreach (var s in due)
            {
                var ok = await _manager.RefreshSubscriptionAsync(s.Id);
                if (!ok) { DetailText = Lang.F("Msg.AutoUpdateFail", s.Name, _manager.LastError); break; }
            }
            RebuildLists();
        }
        finally { _autoUpdating = false; }
    }

    // ── 仪表盘动作 ───────────────────────────────────────────────────────

    private async Task ToggleConnectAsync()
    {
        if (_manager.IsConnected) { await _manager.DisconnectAsync(); return; }
        await ConnectNowAsync();
    }

    private async Task<bool> ConnectNowAsync()
    {
        var ok = await _manager.ConnectAsync();
        if (!ok) { DetailText = _manager.LastError ?? Lang.T("Msg.ConnectFailed"); return false; }
        // 单开关语义:连接 = 内核接管 + 系统代理一并写上;断开路径上的 TryDisableProxy 负责放手。
        if (!_manager.EnsureSystemProxy())
            DetailText = Lang.F("Msg.SysProxyBlocked", _manager.Settings.SystemProxyPort());
        else
            DetailText = Lang.T("Msg.Connected");
        return true;
    }

    private async Task TestAllAsync()
    {
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? Lang.T("Msg.CoreDeadTest");
            return;
        }
        var total = _manager.Nodes.Count;
        var ok = await _manager.TestAllAsync(_ =>
        {
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                foreach (var item in Nodes) item.Refresh();
                SortVisibleByLatency();
            });
        });
        if (ok == 0)
            DetailText = Lang.F("Msg.TestNone", total + " ");
        foreach (var item in Nodes) item.Refresh();
    }

    private async Task TestNodesAsync(List<NodeItem> targets, string what)
    {
        if (targets.Count == 0) { DetailText = Lang.T("Msg.PageEmpty"); return; }
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? Lang.T("Msg.CoreDeadTest");
            return;
        }
        foreach (var t in targets)
        {
            t.Model.State = DelayState.Testing;
            t.Refresh();
        }
        // 测速过程不播报：卡会自己变 ⚡、变色、按延迟上浮，看得见的不用再说一遍
        SortVisibleByLatency();
        var results = await _manager.Api.DelayManyAsync(
            targets.Select(t => t.Model.Name).ToList(), _manager.Settings.TestUrl,
            onEach: r => Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                ApplyResult(r);
                SortVisibleByLatency();
            }));
        SortVisibleByLatency();
        if (results.Count(r => r.Ok) == 0)
            DetailText = Lang.F("Msg.TestNone", what);
    }

    private static int SortRank(NodeItem item) => item.Model.State switch
    {
        DelayState.Ok => item.Model.LastLatency,
        DelayState.Testing => 1_000_000,       // 正在测的跟在已出结果的后面
        _ => 2_000_000,                        // 未测 / 超时 / 失败垫底
    };

    /// <summary>测完按延迟把每张订阅卡的可见列表就地重排（Move，不重建，滚动位置不丢）。</summary>
    private void SortVisibleByLatency()
    {
        foreach (var card in Subscriptions)
        {
            var want = card.VisibleNodes.OrderBy(SortRank)
                .ThenBy(n => n.Model.Name, StringComparer.OrdinalIgnoreCase).ToList();
            for (var i = 0; i < want.Count; i++)
            {
                var at = card.VisibleNodes.IndexOf(want[i]);
                if (at >= 0 && at != i) card.VisibleNodes.Move(at, i);
            }
        }
    }

    /// <summary>点订阅卡上的测速：只测这张卡当前显示的节点（搜索过滤后的一屏）。</summary>
    public void TestSubscription(SubscriptionItem? card)
    {
        if (card == null || card.IsUpdating) return;
        var targets = card.VisibleNodes.ToList();
        if (targets.Count == 0) { DetailText = Lang.T("Msg.PageEmpty"); return; }
        _ = TestNodesAsync(targets, $"「{card.Name}」");
    }

    /// <summary>单条测速结果写回节点模型。</summary>
    private void ApplyResult(DelayResult r)
    {
        var node = _manager.Nodes.FirstOrDefault(n => n.Name == r.Name);
        if (node == null) return;
        node.LastLatency = r.Ok ? r.DelayMs : -1;
        node.State = r.State;
        node.DelayError = r.Error;
        var item = Nodes.FirstOrDefault(x => x.Model.Name == r.Name);
        item?.Refresh();
    }

    public void EditSubscription(SubscriptionItem item, string newName, string newUrl)
    {
        if (item == null) return;
        _manager.UpdateSubscriptionMeta(item.Model.Id, newName, newUrl);
        RebuildLists();
    }

    public async Task ImportFileAsync(string path)
    {
        try
        {
            var ok = await _manager.ImportFileAsync(path);
            if (!ok) DetailText = _manager.LastError ?? Lang.F("Msg.ImportFailed", "");
        }
        catch (Exception e)
        {
            DetailText = Lang.F("Msg.ImportFailed", e.GetType().Name + " " + e.Message);
        }
        finally
        {
            RebuildLists();
            Raise(nameof(SubscriptionCountText));
        }
    }

    // ── 订阅导入 ─────────────────────────────────────────────────────────

    public Task ImportAsync(string input)
    {
        SubscriptionInput = input ?? "";
        return ImportAsync();
    }

    private async Task ImportAsync()
    {
        var input = SubscriptionInput.Trim();
        if (input.Length == 0) { DetailText = Lang.T("Msg.ImportEmpty"); return; }
        try
        {
            var ok = await _manager.AddSubscriptionAsync(input);
            DetailText = !ok
                ? (_manager.LastError ?? Lang.T("Msg.ImportFailedPlain"))
                : _manager.SaveWarning is { Length: > 0 } w ? Lang.F("Msg.SaveWarn", w) : "";
            if (ok) SubscriptionInput = "";
        }
        catch (Exception e)
        {
            // 导入的任何错误都必须落在状态栏里：让它逃出去就是一串弹窗
            DetailText = Lang.F("Msg.ImportFailed", e.GetType().Name + " " + e.Message);
        }
        finally
        {
            RebuildLists();
        }
    }

    // ── 设置页 ───────────────────────────────────────────────────────────

    private async Task ApplySettingsAsync()
    {
        if (!TrySaveSettings()) return;
        SyncAutoStart();
        await ApplyChangesAsync("设置");
    }

    /// <summary>
    /// 仪表盘那颗开关的语义 = 别的客户端的总开关：**拨开就接管，拨回就放手**。
    /// </summary>
    public async Task ApplySwitchAsync()
    {
        if (!TrySaveSettings()) return;
        if (TunOn && !_manager.IsConnected) { await ConnectNowAsync(); return; }
        if (_manager.CoreAlive) await ApplyChangesAsync("开关");
    }

    /// <summary>校验界面上的输入并写进设置 + 落盘。返回 false = 有不合法的东西，原因已经写在状态栏。</summary>
    private bool TrySaveSettings()
    {
        var s = _manager.Settings;
        if (!TryReadPort(MixedPortText, out var mixed)) { DetailText = Lang.T("Msg.PortMixed"); return false; }
        if (!TryReadPort(HttpPortText, out var http)) { DetailText = Lang.T("Msg.PortHttp"); return false; }
        if (!TryReadPort(SocksPortText, out var socks)) { DetailText = Lang.T("Msg.PortSocks"); return false; }
        if (!TryReadPort(ApiPortText, out var api)) { DetailText = Lang.T("Msg.PortApi"); return false; }
        s.MixedPort = mixed;
        s.HttpPort = http;
        s.SocksPort = socks;
        s.ApiPort = api;
        s.AllowLan = AllowLan;
        // 单开关总闸:系统代理恒随连接走,不再提供独立关闭项。
        s.SystemProxyEnabled = true;
        s.TunEnabled = TunOn;
        s.TunStack = TunStackChoice is "gvisor" or "mixed" or "system" ? TunStackChoice : "system";
        s.TunMtu = int.TryParse(TunMtuText.Trim(), out var mtu) && mtu is >= 1280 and <= 65535 ? mtu : 1500;
        if (s.TunMtu.ToString() != TunMtuText.Trim()) TunMtuText = s.TunMtu.ToString();
        s.TunStrictRoute = TunStrictRouteOn;
        s.TunEndpointIndependentNat = TunEinatOn;
        s.ApiSecret = ApiSecretText.Trim();
        var url = TestUrlText.Trim();
        if (url.Length == 0 || (!url.StartsWith("http://") && !url.StartsWith("https://")))
        {
            DetailText = Lang.T("Msg.TestUrlInvalid");
            return false;
        }
        s.TestUrl = url;
        s.CoreLogLevel = LogLevelChoice is "debug" or "info" ? LogLevelChoice : "info";
        s.SniffingEnabled = SnifferOn;
        s.UseSmartGroup = SmartOn;
        s.RulesEnabled = RulesOn;
        s.AdRulesEnabled = AdRulesOn;
        s.Ipv6Enabled = Ipv6On;
        s.DnsOverrideEnabled = DnsOverrideOn;
        if (DnsOverrideOn)
        {
            var dnsLines = DnsServersText.Split('\n').Select(x => x.Trim())
                .Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();
            var problems = new List<string>();
            for (var i = 0; i < dnsLines.Count; i++)
            {
                var why = ClashConfigGenerator.ValidateDnsServer(dnsLines[i]);
                if (why.Length > 0) problems.Add($"第 {i + 1} 行没收下（{why}）");
            }
            var kept = ClashConfigGenerator.NormalizeDnsServers(dnsLines);
            DnsFeedback = problems.Count > 0 ? string.Join("；", problems.Take(4)) : "";
            if (kept.Count == 0)
            {
                DetailText = Lang.T("Msg.DnsEmpty");
                return false;
            }
            s.DnsServers.Clear();
            foreach (var d in kept) s.DnsServers.Add(d);
        }
        s.Close = ToCloseBehavior(CloseChoice);
        _manager.SaveSettings();
        return true;
    }

    /// <summary>开机自启只在真的变了时写注册表：每次点开关都去碰 Run 项，容易被安全软件盯上。</summary>
    private void SyncAutoStart()
    {
        var want = AutoStartOn;
        if (want == AutoStart.IsEnabled()) return;
        var exe = Environment.ProcessPath;
        if (exe != null && !AutoStart.Set(want, exe))
            DetailText = Lang.T("Msg.AutoStartBlocked");
        else AutoStartOn = AutoStart.IsEnabled();
    }

    private static bool TryReadPort(string text, out int port)
        => int.TryParse(text.Trim(), out port) && port is >= 0 and <= 65535;

    /// <summary>校验 + 写进设置（不动内核）。不合法的行只反馈在卡上，不会拦下其他保存。</summary>
    private bool TrySaveRules()
    {
        var s = _manager.Settings;
        var lines = CustomRulesText.Split('\n')
            .Select(x => x.Trim()).Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();
        var accepted = new List<string>();
        var problems = new List<string>();
        for (var i = 0; i < lines.Count; i++)
        {
            var why = ClashConfigGenerator.ValidateCustomRule(lines[i]);
            if (why.Length > 0) problems.Add($"第 {i + 1} 行没收下（{why}）");
            else accepted.Add(lines[i]);
        }
        s.CustomRules.Clear();
        s.CustomRules.AddRange(accepted);
        s.ForceProxySites.Clear();
        s.ForceProxySites.AddRange(SplitDomains(ForceProxyText));
        s.ForceDirectSites.Clear();
        s.ForceDirectSites.AddRange(SplitDomains(ForceDirectText));
        s.AppRouting = AppRoutingChoice switch
        {
            "include" => AppRoutingMode.OnlySelected,
            "exclude" => AppRoutingMode.BypassSelected,
            _ => AppRoutingMode.All,
        };
        s.AppProcesses.Clear();
        // 不按空格切：有的 exe 文件名本身带空格（如 Some App.exe），一切就碎了
        foreach (var p in AppProcesses.Split(new[] { ',', '\n', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var name = p.Trim();
            if (name.Length > 0 && !s.AppProcesses.Contains(name)) s.AppProcesses.Add(name);
        }
        RuleFeedback = problems.Count > 0 ? string.Join("；", problems.Take(4)) : "";
        return true;
    }

    /// <summary>
    /// 设置页右上角那颗「保存设置」：改完任意参数点一次就全存下并让内核生效。
    /// </summary>
    private async Task SaveAllAsync()
    {
        if (!TrySaveSettings()) return;
        TrySaveRules();
        SyncAutoStart();
        await ApplyChangesAsync("设置");
    }

    private async Task RefreshGeoAsync()
    {
        var landed = await _manager.RefreshGeoAsync();
        if (!landed) DetailText = _manager.LastError ?? Lang.T("Msg.GeoNothing");
        SyncGeoSummary();
    }

    private static List<string> SplitDomains(string text) => text
        .Split(new[] { '\n', '\r', ',', ';', '、', ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
        .Select(x => x.Trim().TrimEnd('.')).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    private async Task ApplyChangesAsync(string what)
    {
        var ok = await _manager.ApplyChangesAsync();
        if (!ok)
            DetailText = _manager.LastError ?? _manager.PendingConfigNote ?? Lang.F("Msg.ApplyFailed", what);
        SyncTunStatus();
        SyncGeoSummary();
    }

    private void RestartElevated()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) { DetailText = Lang.T("Msg.ElevateNoPath"); return; }
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "--replace-instance",
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = Path.GetDirectoryName(exe) ?? "",
            });
            if (Application.Current is App app) app.ExitApplication();
        }
        catch (Exception e)
        {
            DetailText = Lang.F("Msg.ElevateFail", e.Message);
        }
    }

    // ── 请求页 ───────────────────────────────────────────────────────────

    private System.Windows.Threading.DispatcherTimer? _poll;
    private bool _polling;
    private long _lastUp, _lastDown;
    private DateTime _lastPollAt = DateTime.MinValue;

    internal bool IsPollingConnections => _poll != null;

    /// <summary>窗口切页时调用：仪表盘（速率图）与请求页（表格）需要轮询，别的页不摊这份开销。</summary>
    public const string PageTools = "工具";

    public void SetActiveTab(string? header)
    {
        ActivePage = header ?? PageDashboard;
        ShowSaveButton = header == PageSettings;
        var poll = header == PageDashboard || header == PageRequests || header == PageTools;
        if (header == PageTools) PollCoreLog();
        if (!poll) { StopConnectionsPolling(); return; }
        StartConnectionsPolling();
    }

    private bool _showSaveButton;

    /// <summary>右上角那颗悬浮「保存设置」只在设置页出现：它挂在滚动区外面，往下滑也不会被盖住。</summary>
    public bool ShowSaveButton { get => _showSaveButton; private set => Set(ref _showSaveButton, value); }

    // 设置页四节的折叠态放在视图模型里，不放控件上：TabControl 切页会把上一页的视觉树丢掉，
    // 绑在控件上的话切回来就弹开了（订阅卡踩过同一个坑）。
    private bool _generalExpanded;
    public bool GeneralExpanded { get => _generalExpanded; set => Set(ref _generalExpanded, value); }

    private bool _portsExpanded;
    public bool PortsExpanded { get => _portsExpanded; set => Set(ref _portsExpanded, value); }

    private bool _rulesExpanded;
    public bool RulesExpanded { get => _rulesExpanded; set => Set(ref _rulesExpanded, value); }

    private bool _kernelExpanded;
    public bool KernelExpanded { get => _kernelExpanded; set => Set(ref _kernelExpanded, value); }

    private string _connectionSearchText = "";

    /// <summary>请求页搜索：按目标 / 进程 / 链 / 规则过滤（只过滤显示，不动底层列表）。</summary>
    public string ConnectionSearchText
    {
        get => _connectionSearchText;
        set { if (!Set(ref _connectionSearchText, value ?? "")) return; ConnectionsView.Refresh(); }
    }

    private bool MatchesConnectionSearch(ConnectionItem c)
    {
        var q = _connectionSearchText.Trim();
        if (q.Length == 0) return true;
        return c.Target.Contains(q, StringComparison.OrdinalIgnoreCase)
               || c.Process.Contains(q, StringComparison.OrdinalIgnoreCase)
               || c.Chain.Contains(q, StringComparison.OrdinalIgnoreCase)
               || c.Rule.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    private bool _updatesPaused;

    /// <summary>暂停列表刷新（对齐 FlClash 的请求页暂停）：表不动了，顶栏速率照常走。</summary>
    public bool UpdatesPaused { get => _updatesPaused; set { if (Set(ref _updatesPaused, value)) Raise(nameof(PauseLabel)); } }

    public string PauseLabel => UpdatesPaused ? "继续刷新" : "暂停刷新";

    private void StartConnectionsPolling()
    {
        if (_poll != null) return;
        _poll = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _poll.Tick += (_, _) => PollTick();
        _poll.Start();
        PollTick();
    }

    private void StopConnectionsPolling()
    {
        if (_poll == null) return;
        _poll.Stop();
        _poll = null;
        _lastPollAt = DateTime.MinValue;
    }

    private void PollTick()
    {
        if (_polling) return;
        if (ActivePage == PageTools) PollCoreLog();
        if (!_manager.CoreAlive)
        {
            Connections.Clear();
            TrafficText = "↑ 0 B/s ↓ 0 B/s";
            UpSpeedText = "0 B/s";
            DownSpeedText = "0 B/s";
            Raise(nameof(RequestsCountText));
            return;
        }
        _polling = true;
        Task.Run(async () =>
        {
            var snap = await _manager.Api.SnapshotAsync().ConfigureAwait(false);
            _polling = false;
            Application.Current?.Dispatcher.BeginInvoke(() => ApplySnapshot(snap));
        });
    }

    internal static (double Up, double Down) Rates(long prevUp, long prevDown, long up, long down, double seconds)
    {
        if (seconds <= 0) return (0, 0);
        // 负差值 == 内核重启过、累计值归零：这一刻的速率是 0，不是天文数字。
        return (Math.Max(0, up - prevUp) / seconds, Math.Max(0, down - prevDown) / seconds);
    }

    internal void ApplySnapshot(Snapshot snap)
    {
        var now = DateTime.Now;
        var seconds = _lastPollAt == DateTime.MinValue ? 0 : Math.Max(0.25, (now - _lastPollAt).TotalSeconds);
        var (up, down) = Rates(_lastUp, _lastDown, snap.UploadTotal, snap.DownloadTotal, seconds);
        _lastUp = snap.UploadTotal;
        _lastDown = snap.DownloadTotal;
        _lastPollAt = now;

        UpSpeedText = ConnectionItem.FmtSpeed(up);
        DownSpeedText = ConnectionItem.FmtSpeed(down);
        SpeedSampled?.Invoke(up, down);

        if (_updatesPaused) return;   // 暂停 = 表格冻在原地；速率与图照常

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in snap.Connections)
        {
            if (c.Id.Length == 0) continue;
            seen.Add(c.Id);
            var row = Connections.FirstOrDefault(x => x.Id == c.Id);
            if (row == null) { row = new ConnectionItem(c.Id); Connections.Add(row); }
            row.Apply(c, now, seconds);
        }
        for (var i = Connections.Count - 1; i >= 0; i--)
            if (!seen.Contains(Connections[i].Id)) Connections.RemoveAt(i);

        // 排序只在新连接进来时才做：O(n²) 的 Move 循环每一 tick 都跑的话，
        // 几十条连接就是每两秒几十次集合事件（列表整个闪一遍）。
        var orderChanged = false;
        for (var i = 1; i < Connections.Count; i++)
            if (Connections[i - 1].StartAt < Connections[i].StartAt) { orderChanged = true; break; }
        if (orderChanged)
        {
            var want = Connections.OrderByDescending(x => x.StartAt).ToList();
            for (var i = 0; i < want.Count; i++)
            {
                var at = Connections.IndexOf(want[i]);
                if (at >= 0 && at != i) Connections.Move(at, i);
            }
        }

        var total = Lang.T("Req.TrafficTotal");
        TrafficText = $"↑ {UpSpeedText} ↓ {DownSpeedText}"
            + $" · {total} {ConnectionItem.FmtBytes(snap.UploadTotal)}"
            + $" / {ConnectionItem.FmtBytes(snap.DownloadTotal)}";
        Raise(nameof(RequestsCountText));
    }

    public void CloseConnection(ConnectionItem? item)
    {
        if (item == null) return;
        _ = CloseOneAsync(item);
    }

    private async Task CloseOneAsync(ConnectionItem item)
    {
        await _manager.Api.CloseConnectionAsync(item.Id);
    }

    private async Task CloseAllConnsAsync()
    {
        if (!_manager.CoreAlive) { DetailText = Lang.T("Msg.CoreNotRunning"); return; }
        var ok = await _manager.Api.CloseAllConnectionsAsync();
        if (!ok) DetailText = Lang.T("Msg.CloseAllRejected");
    }

    // ── 生命周期 ─────────────────────────────────────────────────────────

    public string CloseMode => _manager.Settings.Close switch
    {
        CloseBehavior.Tray => "tray",
        CloseBehavior.Exit => "exit",
        _ => "ask",
    };

    public void RememberCloseBehavior(string choice)
    {
        _manager.Settings.Close = choice switch
        {
            "tray" => CloseBehavior.Tray,
            "exit" => CloseBehavior.Exit,
            _ => CloseBehavior.Ask,
        };
        _manager.SaveSettings();
    }

    /// <summary>窗口代码后置要直接读写设置（窗口记忆 / 快捷键注册）。</summary>
    public TunBox.Core.Models.AppSettings ManagerSettings => _manager.Settings;

    /// <summary>静默落盘：不给状态条添乱（窗口关闭时的一连串保存）。</summary>
    public void SaveSettingsQuiet() => _manager.SaveSettings();

    // ── 测试接缝 ───────────────────────────────────────────────────────────
    internal void SortForTests() => SortVisibleByLatency();
    internal void RebuildForTests() => RebuildLists();

    public async Task ShutdownAsync()
    {
        if (_manager.IsConnected) await _manager.DisconnectAsync();
        _manager.Dispose();
    }

    public void Dispose()
    {
        StopConnectionsPolling();
        _autoUpdateTimer.Stop();
        _manager.Dispose();
    }
}
