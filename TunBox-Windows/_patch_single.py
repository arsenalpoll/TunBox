import io

# ── 1) VM:删除独立系统代理开关(单开关语义:连接即接管,断开即放手) ──
p = 'src/TunBox.App/MainViewModel.cs'
s = io.open(p, encoding='utf-8').read()

old = '''    private bool _systemProxyOn = true;

    /// <summary>
    /// 系统代理开关（对齐 FlClash 的仪表盘「系统代理」）：开 = 连接后写 WinINet，
    /// 关 = 立刻放手。改动当场落盘，不用再点「保存设置」。
    /// </summary>
    public bool SystemProxyOn
    {
        get => _systemProxyOn;
        set
        {
            if (!Set(ref _systemProxyOn, value)) return;
            _manager.Settings.SystemProxyEnabled = value;
            _manager.SaveSettings();
            ApplySystemProxyNow();
        }
    }

    public string SystemProxyStatusText => !_systemProxyOn ? Lang.T("Msg.SysProxyOff")
        : _manager.IsConnected ? Lang.T("Msg.SysProxyTaking") : Lang.T("Msg.SysProxyArmed");

    private void ApplySystemProxyNow()
    {
        try
        {
            if (!_systemProxyOn)
            {
                SystemProxy.Disable();
            }
            else if (_manager.IsConnected && _manager.Settings.SystemProxyPort() > 0)
            {
                if (!_manager.EnsureSystemProxy())
                    DetailText = Lang.F("Msg.SysProxyManual", _manager.Settings.SystemProxyPort());
            }
        }
        catch (Exception e)
        {
            DetailText = Lang.F("Msg.SysProxyToggleFail", e.Message);
        }
        Raise(nameof(SystemProxyStatusText));
    }

    private string _closeChoice = "ask";'''
new = '''    // 系统代理不再有独立开关（用户钦定：只保留一个「代理连接」开关）。
    // 语义 = 单开关总闸：连接即接管系统代理，断开即放手（TryDisableProxy 已在断开路径上）。

    private string _closeChoice = "ask";'''
assert old in s, "sysproxy prop"
s = s.replace(old, new, 1)

# ConnectNowAsync:无条件接管系统代理
old = '''        // 「连接」必须真的生效：系统代理写不进注册表要当场说出来。
        if (_manager.Settings.SystemProxyEnabled && !_manager.EnsureSystemProxy())
            DetailText = Lang.F("Msg.SysProxyBlocked", _manager.Settings.SystemProxyPort());
        else
            DetailText = Lang.T("Msg.Connected");
        return true;'''
new = '''        // 单开关语义:连接 = 内核接管 + 系统代理一并写上;断开路径上的 TryDisableProxy 负责放手。
        if (!_manager.EnsureSystemProxy())
            DetailText = Lang.F("Msg.SysProxyBlocked", _manager.Settings.SystemProxyPort());
        else
            DetailText = Lang.T("Msg.Connected");
        return true;'''
assert old in s, "connectnow"
s = s.replace(old, new, 1)

# TrySaveSettings:恢复强制开启(总闸语义)
old = '''        // 系统代理由它自己的开关（SystemProxyOn）负责写设置，这里不再越权覆盖。'''
new = '''        // 单开关总闸:系统代理恒随连接走,不再提供独立关闭项。
        s.SystemProxyEnabled = true;'''
assert old in s, "trysave"
s = s.replace(old, new, 1)

# SyncFromSettings / RefreshLocalizedOptions / OnManagerChanged 里的旧通知
old = '''        _systemProxyOn = s.SystemProxyEnabled;
        Raise(nameof(SystemProxyOn));
        Raise(nameof(SystemProxyStatusText));
'''
assert old in s, "sync raise"
s = s.replace(old, '', 1)
old = '''        Raise(nameof(SystemProxyStatusText));
        Raise(nameof(PortsSummaryText));'''
new = '''        Raise(nameof(PortsSummaryText));'''
assert old in s, "localized"
s = s.replace(old, new, 1)
old = '''                Raise(nameof(SystemProxyStatusText));
                Raise(nameof(PortsSummaryText));'''
if old in s:
    s = s.replace(old, '                Raise(nameof(PortsSummaryText));', 1)

# 快捷键:去掉系统代理槽位(剩余:打开窗口/连接断开/切换TUN)
old = '''    private string _hotkeySysProxy = "";
    public string HotkeySysProxyText
    {
        get => _hotkeySysProxy;
        set { var norm = Hotkeys.Normalize(value); if (Set(ref _hotkeySysProxy, norm)) SaveHotkey(norm, s => s.HotkeyToggleSystemProxy = norm); }
    }

'''
assert old in s, "hotkey prop"
s = s.replace(old, '', 1)
old = '''        _hotkeySysProxy = s.HotkeyToggleSystemProxy;
'''
assert old in s, "hotkey sync"
s = s.replace(old, '', 1)
old = '''        Raise(nameof(HotkeySysProxyText));
'''
assert old in s, "hotkey raise"
s = s.replace(old, '', 1)

# ── 2) 订阅更新三态:Updating 旋转 / Success 完成回弹 ──
old = '''    private bool _isUpdating;

    /// <summary>这条订阅正在更新：更新按钮的图标转起来，用户才知道点了有没有用。</summary>
    public bool IsUpdating { get => _isUpdating; internal set => Set(ref _isUpdating, value); }'''
new = '''    private bool _isUpdating;

    /// <summary>更新中：图标顺时针连续旋转（700ms 一圈）。</summary>
    public bool IsUpdating { get => _isUpdating; internal set => Set(ref _isUpdating, value); }

    private bool _updateFlash;

    /// <summary>完成反馈:图标短暂变绿勾并轻微回弹(~1.4s),失败则直接回原样(错误在状态条)。</summary>
    public bool UpdateFlash { get => _updateFlash; private set => Set(ref _updateFlash, value); }'''
assert old in s, "updatestate"
s = s.replace(old, new, 1)

old = '''        var card = Subscriptions.FirstOrDefault(c => c.Model.Id == item.Model.Id) ?? item;
        card.IsUpdating = true;
        try
        {
            var ok = await _manager.RefreshSubscriptionAsync(item.Model.Id);
            if (!ok) DetailText = _manager.LastError ?? Lang.T("Msg.UpdateFailed");
        }
        finally { card.IsUpdating = false; }'''
new = '''        var card = Subscriptions.FirstOrDefault(c => c.Model.Id == item.Model.Id) ?? item;
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
            // 成功:绿勾轻微回弹的完成反馈,1.4s 后自己消失
            card.UpdateFlash = true;
            _ = ClearFlashSoonAsync(card);
        }
        catch { card.IsUpdating = false; throw; }'''
assert old in s, "update flow"
s = s.replace(old, new, 1)

old = '''    public async Task UpdateSubscriptionAsync(SubscriptionItem item)'''
new = '''    private static async Task ClearFlashSoonAsync(SubscriptionItem card)
    {
        try { await Task.Delay(1400).ConfigureAwait(true); } catch { }
        card.UpdateFlash = false;
    }

    public async Task UpdateSubscriptionAsync(SubscriptionItem item)'''
assert old in s, "clearflash"
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("vm ok")

# ── 3) Hotkeys:去掉系统代理槽位 ──
p = 'src/TunBox.App/Hotkeys.cs'
s = io.open(p, encoding='utf-8').read()
old = '''        Try(hwnd, IdShow, settings.HotkeyShowWindow, failed);
        Try(hwnd, IdConnect, settings.HotkeyToggleConnect, failed);
        Try(hwnd, IdSysProxy, settings.HotkeyToggleSystemProxy, failed);
        Try(hwnd, IdTun, settings.HotkeyToggleTun, failed);'''
new = '''        Try(hwnd, IdShow, settings.HotkeyShowWindow, failed);
        Try(hwnd, IdConnect, settings.HotkeyToggleConnect, failed);
        Try(hwnd, IdTun, settings.HotkeyToggleTun, failed);'''
assert old in s
s = s.replace(old, new, 1)
old = '        foreach (var id in new[] { IdShow, IdConnect, IdSysProxy, IdTun })'
new = '        foreach (var id in new[] { IdShow, IdConnect, IdTun })'
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("hotkeys ok")

# ── 4) MainWindow.xaml.cs:快捷键分发去掉系统代理 ──
p = 'src/TunBox.App/MainWindow.xaml.cs'
s = io.open(p, encoding='utf-8').read()
old = '''            case Hotkeys.IdSysProxy:
                ViewModel.SystemProxyOn = !ViewModel.SystemProxyOn;
                break;
'''
assert old in s
s = s.replace(old, '', 1)
old = '''            case "HotkeySysProxyText": ViewModel.HotkeySysProxyText = value; break;
'''
assert old in s
s = s.replace(old, '', 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("codebehind ok")
