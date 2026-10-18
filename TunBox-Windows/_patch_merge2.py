import io

p = 'src/TunBox.App/MainViewModel.cs'
s = io.open(p, encoding='utf-8').read()
applied = []

def rep(old, new, tag):
    global s
    if old in s:
        s = s.replace(old, new, 1)
        applied.append(tag)
    else:
        print('SKIP(缺失):', tag)

# A) 集合声明
rep('''    public ObservableCollection<GroupTab> ProxyGroupTabs { get; } = new();
    public ObservableCollection<NodeItem> GroupNodes { get; } = new();

''', '', 'A-集合')

# B) 页面常量
rep('    public const string PageProfiles = "配置";\n', '', 'B-PageProfiles')

# C) 排序区整块重写：setter + ApplyCardFilters + 搜索属性
rep('''    private string _sortChoice = "default";

    /// <summary>default = 保留测速后的排序历史；delay/name = 强制排序。</summary>
    public string SortChoice
    {
        get => _sortChoice;
        set
        {
            if (!Set(ref _sortChoice, value ?? "default")) return;
            ApplyProxyFilter();
        }
    }

    private IEnumerable<NodeItem> OrderVisible(IEnumerable<NodeItem> nodes) => _sortChoice switch
    {
        "name" => nodes.OrderBy(n => n.Model.Name, StringComparer.OrdinalIgnoreCase),
        "delay" => nodes.OrderBy(SortRank).ThenBy(n => n.Model.Name, StringComparer.OrdinalIgnoreCase),
        _ => nodes,
    };
''',
'''    private string _sortChoice = "default";

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
''', 'C-排序区')

# D) GroupTestCommand 三处
rep('    public AsyncRelayCommand GroupTestCommand { get; }\n', '', 'D1-声明')
rep('        GroupTestCommand = new AsyncRelayCommand(_ => TestGroupAsync());\n', '', 'D2-接线')
rep('                                  CloseAllConnectionsCommand, GroupTestCommand })',
    '                                  CloseAllConnectionsCommand })', 'D3-挂接')

# E) RebuildLists 订阅段
rep('''            Subscriptions.Clear();
            foreach (var s in _manager.Subscriptions)
            {
                var card = new SubscriptionItem(s) { AutoUpdateChanged = OnAutoUpdateChanged };
                Subscriptions.Add(card);
            }

            RebuildProxyTabs();
            ApplyProxyFilter();
            RebuildQuickEgress();''',
'''            // 合并页：订阅卡按 Id 保留展开态，装上自己的节点，套用搜索与排序
            var keepExpanded = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (var card in Subscriptions) keepExpanded[card.Model.Id] = card.IsExpanded;

            Subscriptions.Clear();
            foreach (var s in _manager.Subscriptions)
            {
                var card = new SubscriptionItem(s) { AutoUpdateChanged = OnAutoUpdateChanged };
                // 折叠态要活过重建：用户收起来的卡，切页回来不能又弹开
                if (keepExpanded.TryGetValue(s.Id, out var expanded)) card.IsExpanded = expanded;
                foreach (var n in Nodes.Where(n => n.Model.SubscriptionId == s.Id)) card.Nodes.Add(n);
                card.ApplyCardFilter(_nodeSearchText, _sortChoice);
                Subscriptions.Add(card);
            }

            RebuildQuickEgress();''', 'E-RebuildLists')

# F) SortVisibleByLatency 定义补回（原定义在误删区域里）
rep('''    /// <summary>单条测速结果写回节点模型。</summary>
    private void ApplyResult(DelayResult r)''',
'''    /// <summary>测完按每张订阅卡排：卡里的可见列表就地 Move，滚动位置不丢。</summary>
    private void SortVisibleByLatency()
    {
        foreach (var card in Subscriptions) card.ApplyCardFilter(_nodeSearchText, _sortChoice);
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
    private void ApplyResult(DelayResult r)''', 'F-排序与卡测速')

# G) RefreshLocalizedOptions 增加卡片重算（键名缓存场景）
rep('''    internal void RefreshLocalizedOptions()
    {
        SyncTunStatus();
        RebuildQuickEgress();''',
'''    internal void RefreshLocalizedOptions()
    {
        SyncTunStatus();
        RebuildQuickEgress();
        ApplyCardFilters();''', 'G-本地化刷新')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('applied:', applied)
