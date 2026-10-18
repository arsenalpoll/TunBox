import io

p = 'tests/TunBox.Core.Tests/UiTests.cs'
s = io.open(p, encoding='utf-8').read()

# 1) Pages → 5 页（配置并入代理）
old = 'private static readonly string[] Pages = { "仪表盘", "代理", "请求", "配置", "工具", "设置" };'
new = 'private static readonly string[] Pages = { "仪表盘", "代理", "请求", "工具", "设置" };'
assert old in s, "pages"
s = s.replace(old, new, 1)

# 2) owners 去掉 GroupTab
old = '''        var owners = new[] { typeof(MainViewModel), typeof(NodeItem), typeof(GroupTab),
                              typeof(SubscriptionItem), typeof(ConnectionItem),
                              typeof(MainViewModel.NetCheckRow) };'''
new = '''        var owners = new[] { typeof(MainViewModel), typeof(NodeItem),
                              typeof(SubscriptionItem), typeof(ConnectionItem),
                              typeof(MainViewModel.NetCheckRow) };'''
assert old in s, "owners"
s = s.replace(old, new, 1)

# 3) 删除 GroupTab 相关两个测试（类已不存在）
start = s.index('    /// <summary>分组页签是筛选器，不是测速按钮；smart 伪分组与「全部节点」固定存在。</summary>')
end = s.index('    /// <summary>测速排序必须作用在**当前网格**上')
s = s[:start] + s[end:]

# 4) 点击分组测试 → 订阅卡展开/搜索/排序测试
old_start = s.index('    /// <summary>点分组页签只剩该组节点')
old_end = s.index('    /// <summary>\n    /// 测速排序必须作用在**当前网格**上')
new_card_test = '''    /// <summary>合并页契约：一个订阅一张卡，展开显示节点；折叠态活过重建；搜索跨卡过滤。</summary>
    [Fact]
    public void Subscription_cards_expand_and_filter_across_the_page()
    {
        var home = TempHome("cards");
        var (tabCount, cardNodeTotal, visibleAfterSearch, expandedAfterRebuild) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\\n"
                + "  - {name: HK 01, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: HK 02, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: US 01, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var card = vm.Subscriptions.First();
            var total = card.Nodes.Count;
            // 搜索跨卡过滤：只剩 US 01
            vm.NodeSearchText = "US";
            var visible = card.VisibleNodes.Select(n => n.Name).ToList();
            vm.NodeSearchText = "";
            // 折叠态活过重建
            card.IsExpanded = false;
            vm.RebuildForTests();
            return (vm.ProxyGroupTabs is { } _ ? 0 : 0, total, visible,
                vm.Subscriptions.First().IsExpanded);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(3, cardNodeTotal);
        Assert.Equal(new[] { "US 01" }, visibleAfterSearch);
        Assert.False(expandedAfterRebuild);
    }

'''
s = s[:old_start] + new_card_test + s[old_end:]

# 5) 排序测试 → 卡片 VisibleNodes
old = '''    [Fact]
    public void Sort_choice_orders_the_proxy_grid()
    {
        var home = TempHome("sortchoice");
        var (byName, byDelay) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\\n"
                + "  - {name: Ccc, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: Aaa, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: Bbb, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name switch { "Aaa" => 500, "Bbb" => 100, _ => 300 });
            vm.SortChoice = "name";
            var names = vm.GroupNodes.Select(n => n.Name).ToList();
            vm.SortChoice = "delay";
            var delays = vm.GroupNodes.Select(n => n.Name).ToList();
            return (names, delays);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(new[] { "Aaa", "Bbb", "Ccc" }, byName);
        Assert.Equal(new[] { "Bbb", "Ccc", "Aaa" }, byDelay);
    }'''
new = '''    [Fact]
    public void Sort_choice_orders_each_subscription_card()
    {
        var home = TempHome("sortchoice");
        var (byName, byDelay) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\\n"
                + "  - {name: Ccc, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: Aaa, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\\n"
                + "  - {name: Bbb, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\\n");
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
    }'''
assert old in s, "sort"
s = s.replace(old, new, 1)

# 6) 测速排序测试 → 卡片
old = '''            var b = vm.GroupNodes.Select(n => n.Name).ToList();
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name.StartsWith("A") ? 900 : n.Model.Name.StartsWith("B") ? 30 : 300);
            vm.SortForTests();
            var a = vm.GroupNodes.Select(n => n.Name).ToList();
            vm.RebuildForTests();
            return (b, a, vm.GroupNodes.Select(n => n.Name).ToList());'''
new = '''            var b = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name.StartsWith("A") ? 900 : n.Model.Name.StartsWith("B") ? 30 : 300);
            vm.SortForTests();
            var a = vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList();
            vm.RebuildForTests();
            return (b, a, vm.Subscriptions.First().VisibleNodes.Select(n => n.Name).ToList());'''
assert old in s, "latencysort"
s = s.replace(old, new, 1)

# 7) 配置页引用 → 代理页（自动更新下拉测试）
old = '''                    var tab = FindTab(window, "配置");
                    if (tab == null) return "找不到配置页";'''
new = '''                    var tab = FindTab(window, "代理");
                    if (tab == null) return "找不到代理页";'''
assert old in s, "autoupd"
s = s.replace(old, new, 1)

# 8) 代理页契约：分组页签 → 卡片测速按钮
old = '''        Assert.Contains("Click=\\"OnGroupTabClick\\"", xaml);
        Assert.DoesNotContain("OnGroupChipClick", xaml);'''
new = '''        Assert.Contains("Click=\\"OnTestSubClick\\"", xaml);
        Assert.Contains("Click=\\"OnNodeRowClick\\"", xaml);
        Assert.DoesNotContain("OnGroupChipClick", xaml);
        Assert.DoesNotContain("OnGroupTabClick", xaml);'''
assert old in s, "contract"
s = s.replace(old, new, 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("tests updated")
