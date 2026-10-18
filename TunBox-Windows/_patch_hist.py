import io

# ── 1) ControllerClient:/proxies 的 history 回填(对齐 Verge 的显示口径)──
p = 'src/TunBox.Core/Api/ControllerClient.cs'
s = io.open(p, encoding='utf-8').read()
old = '''    /// <summary>当前生效的分流规则数量(GET /rules 的数组长度);内核未就绪返回 0。</summary>'''
new = '''    /// <summary>
    /// 各代理最近一次测延迟(GET /proxies 的 history 末条,mihomo 口径)。
    /// Verge 显示的就是这份内核缓存的热连接结果;冷启动的 /delay 实测会多出
    /// QUIC/TLS 握手,数字天然偏高 —— 所以回填用它,和 Verge 看到的一样。
    /// </summary>
    public async Task<Dictionary<string, int>> ProxiesHistoryAsync(CancellationToken ct = default)
    {
        var outDict = new Dictionary<string, int>(StringComparer.Ordinal);
        try
        {
            var n = (await GetJsonAsync("/proxies", ct).ConfigureAwait(false))?["proxies"]?.AsObject();
            if (n == null) return outDict;
            foreach (var kv in n)
            {
                if (kv.Value?["history"] is not JsonArray hist || hist.Count == 0) continue;
                foreach (var h in hist)
                {
                    var delay = h?["delay"]?.GetValue<int>() ?? 0;
                    if (delay > 0) outDict[kv.Key] = delay;   // 末条有效值
                }
            }
        }
        catch { /* 内核未就绪:返回空表 */ }
        return outDict;
    }

    /// <summary>当前生效的分流规则数量(GET /rules 的数组长度);内核未就绪返回 0。</summary>'''
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("api ok")

# ── 2) VM:内核就绪后回填 history(只填未测过的,不覆盖刚测的结果)──
p = 'src/TunBox.App/MainViewModel.cs'
s = io.open(p, encoding='utf-8').read()
old = '''        _coreStartedAt ??= DateTime.Now;
        if (CoreVersionText.Length == 0)
        {
            try { CoreVersionText = await _manager.Api.VersionAsync() ?? ""; } catch { /* 下一拍再试 */ }
        }
        if (_rulesCount == 0)
        {
            try
            {
                var count = await _manager.Api.RulesCountAsync();
                if (count > 0) { _rulesCount = count; Raise(nameof(RulesCountText)); }
            }
            catch { /* 下一拍再试 */ }
        }
        Raise(nameof(CoreUptimeText));'''
new = '''        _coreStartedAt ??= DateTime.Now;
        if (CoreVersionText.Length == 0)
        {
            try { CoreVersionText = await _manager.Api.VersionAsync() ?? ""; } catch { /* 下一拍再试 */ }
        }
        if (_rulesCount == 0)
        {
            try
            {
                var count = await _manager.Api.RulesCountAsync();
                if (count > 0) { _rulesCount = count; Raise(nameof(RulesCountText)); }
            }
            catch { /* 下一拍再试 */ }
        }
        // 回填内核缓存的延迟 history(Verge 同口径):只填「未测过」的节点,刚测完的 fresh 结果不动
        if (Nodes.Any(n => n.Model.State == DelayState.Untested))
        {
            try
            {
                var hist = await _manager.Api.ProxiesHistoryAsync();
                var changed = false;
                foreach (var item in Nodes)
                {
                    if (item.Model.State != DelayState.Untested) continue;
                    if (!hist.TryGetValue(item.Model.Name, out var delay) || delay <= 0) continue;
                    item.Model.LastLatency = delay;
                    item.Model.State = DelayState.Ok;
                    item.Refresh();
                    changed = true;
                }
                if (changed) SortVisibleByLatency();
            }
            catch { /* 下一拍再试 */ }
        }
        Raise(nameof(CoreUptimeText));'''
assert old in s, "vm hist"
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("vm ok")
