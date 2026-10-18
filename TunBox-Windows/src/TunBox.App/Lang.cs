using System.Windows;

namespace TunBox.App;

/// <summary>
/// 多语言（对齐 FlClash 的语言设置）：zh / en 两份资源字典，键以 "L." 开头。
/// XAML 里用 DynamicResource 引用（改语言即时生效），代码里用 Lang.T(key) 取文案。
/// 字典合并进 Application 级资源；测试宿主没有走 App.OnStartup，所以窗口/对话框
/// 构造时都会调 EnsureApplied 兜底。
/// </summary>
public static class Lang
{
    public const string KeyPrefix = "L.";

    /// <summary>当前生效语言（"zh"/"en"，运行期只读展示用）。</summary>
    public static string Current { get; private set; } = "zh";

    /// <summary>把语言归一化：偏好空 = 跟随系统（zh 系默认中文，其余英文），未知值回退跟随系统。</summary>
    public static string Resolve(string? preference)
    {
        if (preference == "zh" || preference == "en") return preference;
        var sys = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return sys == "zh" ? "zh" : "en";
    }

    private static ResourceDictionary? Load(string lang)
    {
        try
        {
            var src = new Uri($"/TunBox;component/Assets/Lang/{lang}.xaml", UriKind.Relative);
            return new ResourceDictionary { Source = src };
        }
        catch { return null; }
    }

    private static ResourceDictionary? _applied;

    /// <summary>把语言字典合并进目标（幂等：先摘旧的再挂新的）。App 与每个窗口都要挂。</summary>
    public static void Apply(ResourceDictionary resources, string resolvedLang)
    {
        var dict = Load(resolvedLang) ?? Load("zh");
        if (dict == null) return;
        if (!ReferenceEquals(resources.MergedDictionaries, null))
        {
            for (var i = resources.MergedDictionaries.Count - 1; i >= 0; i--)
                if (ReferenceEquals(resources.MergedDictionaries[i], _applied))
                    resources.MergedDictionaries.RemoveAt(i);
        }
        resources.MergedDictionaries.Add(dict);
        _applied = dict;
        Current = resolvedLang;
    }

    /// <summary>窗口/对话框构造时调用：语言没应用过（测试宿主）就先应用到 Application 级。</summary>
    public static void EnsureApplied(string resolvedLang)
    {
        var app = Application.Current;
        if (app == null) return;
        if (app.Resources.Contains(KeyPrefix + "Nav.Dashboard") &&
            Current == resolvedLang) return;
        Apply(app.Resources, resolvedLang);
    }

    /// <summary>代码里取文案：取不到键时回退键名，缺翻译也不会显示空白。</summary>
    public static string T(string key)
        => Application.Current?.TryFindResource(KeyPrefix + key) as string ?? key;

    /// <summary>带参数的文案：字典里放 {0}/{1} 占位符。</summary>
    public static string F(string key, params object?[] args)
        => string.Format(T(key), args);
}
