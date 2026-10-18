using System.Runtime.InteropServices;
using System.Windows.Input;

namespace TunBox.App;

/// <summary>
/// 全局快捷键（对齐 FlClash 的快捷键设置）：RegisterHotKey 注册到主窗口消息循环。
/// 四个槽位：打开主窗口 / 连接·断开 / 切换系统代理 / 切换 TUN；空串 = 未启用。
/// 组合键写法 "Ctrl+Alt+P"（解析与规范化都在这里，设置页的捕获框直接产出这种格式）。
/// </summary>
public static class Hotkeys
{
    public const int WM_HOTKEY = 0x0312;
    public const int IdShow = 1;
    public const int IdConnect = 2;
    public const int IdSysProxy = 3;
    public const int IdTun = 4;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const uint MOD_ALT = 0x1;
    private const uint MOD_CONTROL = 0x2;
    private const uint MOD_SHIFT = 0x4;
    private const uint MOD_WIN = 0x8;
    private const uint MOD_NOREPEAT = 0x4000;

    /// <summary>解析组合键；返回 null = 写法无效（注册时静默跳过）。</summary>
    public static (uint Modifiers, uint VirtualKey)? Parse(string? spec)
    {
        var text = (spec ?? "").Trim();
        if (text.Length == 0) return null;
        uint mods = 0;
        uint vk = 0;
        foreach (var raw in text.Split('+'))
        {
            var token = raw.Trim();
            if (token.Length == 0) return null;
            switch (token.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= MOD_CONTROL; continue;
                case "alt": mods |= MOD_ALT; continue;
                case "shift": mods |= MOD_SHIFT; continue;
                case "win" or "windows": mods |= MOD_WIN; continue;
            }
            if (vk != 0) return null;                     // 两个非修饰键：无效
            vk = VirtualKeyOf(token);
            if (vk == 0) return null;
        }
        if (vk == 0) return null;
        // 无修饰键的普通键（字母/数字）一注册就吞掉整个系统的这个键，必须拒绝；
        // F1-F12 单键是惯例可接受的例外（多媒体键同款思路）。
        var isFunctionKey = vk is >= 0x70 and <= 0x7B;
        if (mods == 0 && !isFunctionKey) return null;
        return (mods | MOD_NOREPEAT, vk);
    }

    /// <summary>把任意写法规范化成 "Ctrl+Alt+P" 形态（设置页显示用）；无效返回空串。</summary>
    public static string Normalize(string? spec)
    {
        var parsed = Parse(spec);
        if (parsed == null) return "";
        var (mods, vk) = parsed.Value;
        var parts = new List<string>();
        if ((mods & MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((mods & MOD_ALT) != 0) parts.Add("Alt");
        if ((mods & MOD_SHIFT) != 0) parts.Add("Shift");
        if ((mods & MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyNameOf(vk));
        return string.Join("+", parts);
    }

    private static uint VirtualKeyOf(string token) => token.ToUpperInvariant() switch
    {
        "A" or "B" or "C" or "D" or "E" or "F" or "G" or "H" or "I" or "J" or "K" or "L" or "M"
        or "N" or "O" or "P" or "Q" or "R" or "S" or "T" or "U" or "V" or "W" or "X" or "Y" or "Z"
            => (uint)(token.ToUpperInvariant()[0] - 'A' + 0x41),
        "0" or "1" or "2" or "3" or "4" or "5" or "6" or "7" or "8" or "9"
            => (uint)(token[0] - '0' + 0x30),
        "F1" or "F2" or "F3" or "F4" or "F5" or "F6" or "F7" or "F8" or "F9" or "F10" or "F11" or "F12"
            => (uint)(0x70 + int.Parse(token[1..]) - 1),
        "SPACE" or "SPACEBAR" => 0x20,
        "ESC" or "ESCAPE" => 0x1B,
        "ENTER" or "RETURN" => 0x0D,
        "INSERT" or "INS" => 0x2D,
        "DELETE" or "DEL" => 0x2E,
        "HOME" => 0x24,
        "END" => 0x23,
        "PGUP" or "PAGEUP" => 0x21,
        "PGDN" or "PAGEDOWN" => 0x22,
        "UP" => 0x26,
        "DOWN" => 0x28,
        "LEFT" => 0x25,
        "RIGHT" => 0x27,
        _ => 0,
    };

    private static string KeyNameOf(uint vk) => vk switch
    {
        >= 0x41 and <= 0x5A => ((char)('A' + vk - 0x41)).ToString(),
        >= 0x30 and <= 0x39 => ((char)('0' + vk - 0x30)).ToString(),
        >= 0x70 and <= 0x7B => "F" + (vk - 0x70 + 1),
        0x20 => "Space",
        0x1B => "Esc",
        0x0D => "Enter",
        0x2D => "Ins",
        0x2E => "Del",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "PgUp",
        0x22 => "PgDn",
        0x26 => "Up",
        0x28 => "Down",
        0x25 => "Left",
        0x27 => "Right",
        _ => $"0x{vk:X2}",
    };

    /// <summary>
    /// 把设置里的四个快捷键注册到窗口。返回注册失败的键（已规范化的形态），成功的直接生效。
    /// 重复调用安全：先全部注销再注册（设置变更后重挂）。
    /// </summary>
    public static List<string> Apply(IntPtr hwnd, TunBox.Core.Models.AppSettings settings)
    {
        UnregisterAll(hwnd);
        var failed = new List<string>();
        Try(hwnd, IdShow, settings.HotkeyShowWindow, failed);
        Try(hwnd, IdConnect, settings.HotkeyToggleConnect, failed);
        Try(hwnd, IdSysProxy, settings.HotkeyToggleSystemProxy, failed);
        Try(hwnd, IdTun, settings.HotkeyToggleTun, failed);
        return failed;
    }

    public static void UnregisterAll(IntPtr hwnd)
    {
        foreach (var id in new[] { IdShow, IdConnect, IdSysProxy, IdTun })
            try { UnregisterHotKey(hwnd, id); } catch { /* 没注册过也无妨 */ }
    }

    private static void Try(IntPtr hwnd, int id, string spec, List<string> failed)
    {
        var parsed = Parse(spec);
        if (parsed == null) return;
        if (!RegisterHotKey(hwnd, id, parsed.Value.Modifiers, parsed.Value.VirtualKey))
            failed.Add(Normalize(spec));
    }

    /// <summary>把 WPF 按键事件转换成 "Ctrl+Alt+P" 形态；纯修饰键/Tab/方向导航返回 null（让事件继续走）。</summary>
    public static string? FromKeyEvent(Key key, ModifierKeys modifiers)
    {
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
            or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin
            or Key.Tab or Key.System) return null;
        var keyName = key switch
        {
            Key.Space => "Space",
            Key.Escape => "Esc",
            Key.Enter or Key.Return => "Enter",
            Key.Insert => "Ins",
            Key.Delete => "Del",
            Key.Home => "Home",
            Key.End => "End",
            Key.PageUp => "PgUp",
            Key.PageDown => "PgDn",
            Key.Up => "Up",
            Key.Down => "Down",
            Key.Left => "Left",
            Key.Right => "Right",
            _ when key is >= Key.A and <= Key.Z => ((char)('A' + key - Key.A)).ToString(),
            _ when key is >= Key.D0 and <= Key.D9 => ((char)('0' + key - Key.D0)).ToString(),
            _ when key is >= Key.F1 and <= Key.F12 => "F" + (key - Key.F1 + 1),
            _ => null,
        };
        if (keyName == null) return null;
        var parts = new List<string>();
        if (modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(keyName);
        return string.Join("+", parts);
    }
}
