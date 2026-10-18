import io

p = 'src/TunBox.App/MainViewModel.cs'
s = io.open(p, encoding='utf-8').read()

def rep(old, new, tag):
    global s
    assert old in s, tag
    s = s.replace(old, new, 1)
    print('ok', tag)

# ── 1) 快捷出口:测速边测边按延迟排序(smart 恒居首) ──
old = '''    /// <summary>测完按延迟把每张订阅卡的可见列表就地重排（Move，不重建，滚动位置不丢）。</summary>
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
    }'''
new = '''    /// <summary>测完按延迟把每张订阅卡的可见列表与快捷出口就地重排（Move，不重建，滚动位置不丢）。
    /// 边测边排:onEach 回调里走的就是这里,下拉顺序实时跟着延迟走。</summary>
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
        var wantQuick = QuickEgressOptions
            .OrderByDescending(q => q.IsSmart)                       // 智能选项恒居首
            .ThenBy(q => q.Node == null ? int.MinValue : SortRank(q.Node))
            .ToList();
        for (var i = 0; i < wantQuick.Count; i++)
        {
            var at = QuickEgressOptions.IndexOf(wantQuick[i]);
            if (at >= 0 && at != i) QuickEgressOptions.Move(at, i);
        }
    }'''
rep(old, new, '快捷排序')

# ── 2) 开机自启:拨上立即写注册表(常用卡外露,不再依赖「保存设置」) ──
old = '''    private bool _autoStartOn;
    public bool AutoStartOn { get => _autoStartOn; set => Set(ref _autoStartOn, value); }'''
new = '''    private bool _autoStartOn;

    /// <summary>拨上立即写注册表(常用卡直接外露,不该让人再去找「保存设置」);写失败自动回拨并说明。</summary>
    public bool AutoStartOn
    {
        get => _autoStartOn;
        set
        {
            if (!Set(ref _autoStartOn, value)) return;
            var exe = Environment.ProcessPath;
            if (exe != null && !AutoStart.Set(value, exe))
            {
                DetailText = Lang.T("Msg.AutoStartBlocked");
                _autoStartOn = AutoStart.IsEnabled();
                Raise(nameof(AutoStartOn));
            }
        }
    }'''
rep(old, new, '自启即时')

# SyncAutoStart 现在只需在保存路径兜底(幂等)
old = '''    /// <summary>开机自启只在真的变了时写注册表：每次点开关都去碰 Run 项，容易被安全软件盯上。</summary>
    private void SyncAutoStart()
    {
        var want = AutoStartOn;
        if (want == AutoStart.IsEnabled()) return;
        var exe = Environment.ProcessPath;
        if (exe != null && !AutoStart.Set(want, exe))
            DetailText = Lang.T("Msg.AutoStartBlocked");
        else AutoStartOn = AutoStart.IsEnabled();
    }'''
new = '''    /// <summary>保存路径上的兜底:开关已经是即时生效的,这里只校正界面与注册表的不一致。</summary>
    private void SyncAutoStart()
    {
        if (AutoStartOn == AutoStart.IsEnabled()) return;
        AutoStartOn = AutoStart.IsEnabled();
    }'''
rep(old, new, 'SyncAutoStart')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("vm done")
