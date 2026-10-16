using System.Windows;

namespace TunBox.App;

/// <summary>
/// 暗色主题开关。做法：窗口和对话框各自合并 Styles.xaml（这是测试契约的一部分，
/// 不能改成 app 级资源），所以暗色覆盖也按同样的方式合并——把 ThemeDark.xaml
/// 追加到同一个 MergedDictionaries 尾部，同名键由后合并者获胜。
/// 必须在 InitializeComponent / XAML 解析之前调用：StaticResource 在加载时取值。
/// </summary>
public static class ThemeManager
{
    /// <summary>当前会话是否处于暗色（只读给诊断与托盘菜单用）。</summary>
    public static bool IsDark { get; private set; }

    /// <summary>
    /// 跟随系统（注册表 AppsUseLightTheme），failOrKey=auto 时；
    /// manualOverride 为 null 表示跟随系统，true/false 表示用户手动锁定。
    /// </summary>
    public static bool SystemPrefersDark()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int v) return v == 0;
        }
        catch { /* 注册表读不到就当浅色 */ }
        return false;
    }

    /// <summary>把暗色 token 合并进一个已含 Styles.xaml 的 ResourceDictionary。幂等：重复合并会先移除旧的。</summary>
    public static void ApplyDark(ResourceDictionary merged)
    {
        RemoveDark(merged);
        var dark = new ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/TunBox.App;component/Assets/ThemeDark.xaml")
        };
        merged.MergedDictionaries.Add(dark);
        IsDark = true;
    }

    /// <summary>移除暗色覆盖（回浅色）。</summary>
    public static void RemoveDark(ResourceDictionary merged)
    {
        for (var i = merged.MergedDictionaries.Count - 1; i >= 0; i--)
        {
            var d = merged.MergedDictionaries[i];
            if (d.Source != null && d.Source.OriginalString.Contains("ThemeDark.xaml"))
                merged.MergedDictionaries.RemoveAt(i);
        }
        IsDark = false;
    }

    /// <summary>决定某个窗口该不该暗色：手动设置 > 系统偏好。</summary>
    public static bool ShouldBeDark(bool? manualOverride)
        => manualOverride ?? SystemPrefersDark();
}
