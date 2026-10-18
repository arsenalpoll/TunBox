import io

p = 'src/TunBox.App/MainViewModel.cs'
s = io.open(p, encoding='utf-8').read()

# ── 1) SubscriptionItem: 节点列表 + 展开态 + 过滤（合并页核心） ──
old = '''    private string _autoUpdateChoice;

    /// <summary>自动更新档位（分钟字符串；"0" = 手动）。改动立刻落盘，选完就是保存。</summary>'''
new = '''    private bool _isUpdating;

    /// <summary>这条订阅正在更新：更新按钮的图标转起来，用户才知道点了有没有用。</summary>
    public bool IsUpdating { get => _isUpdating; internal set => Set(ref _isUpdating, value); }

    /// <summary>这条订阅的全部节点行（与总表 Nodes 同一批实例：测速结果自动跟着变）。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> Nodes { get; } = new();

    /// <summary>搜索过滤 + 排序后实际显示的节点。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> VisibleNodes { get; } = new();

    private bool _isExpanded = true;

    /// <summary>展开 = 显示节点列表。折叠态要活过每一次列表重建（内核事件一秒好几次）。</summary>
    public bool IsExpanded { get => _isExpanded; set => Set(ref _isExpanded, value); }

    public string NodeCountText => Lang.F("Proxy.CountAll", VisibleNodes.Count, Nodes.Count, "");

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
    }

    private string _autoUpdateChoice;

    /// <summary>自动更新档位（分钟字符串；"0" = 手动）。改动立刻落盘，选完就是保存。</summary>'''
assert old in s, "subitem anchor"
s = s.replace(old, new, 1)

# ── 2) 删除 GroupTab 类（合并后不再有扁平分组页签） ──
start = s.index('/// <summary>\n/// 代理页左侧的一个分组页签')
end = s.index('/// <summary>请求表的一行。按 Id 复用实例')
s = s[:start] + s[end:]

# ── 3) 删除代理页分组机制（页签/选中/过滤/测速本组） ──
start = s.index('    // ── 代理页：分组页签 + 节点网格 ──')
end = s.index('    // ── 全局反馈条 ──')
s = s[:start] + s[end:]

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("vm part1 ok")
