using System.Windows;
using System.Windows.Media;

namespace TunBox.App;

/// <summary>
/// 仪表盘的实时速率面积图（对齐 FlClash 的流量图表）：
/// 上传绿 / 下载蓝两条曲线，固定 120 个采样的窗口，新样本从右侧进来、整条线左移。
/// 纵轴自动缩放——涨得快跟得快，落得慢（0.25 倍以下才收），避免一抖一抖读不了。
/// 直接 OnRender 自绘，不引第三方图表库。
/// </summary>
public sealed class TrafficChart : FrameworkElement
{
    private readonly List<double> _up = new();
    private readonly List<double> _down = new();
    private const int Capacity = 120;
    private const double FloorScale = 64 * 1024;   // 64 KB/s 起步：没流量时曲线贴底，坐标不至于除零
    private double _scale = FloorScale;

    /// <summary>当前窗口里的采样个数（测试用）。</summary>
    public int SampleCount => _down.Count;

    public void Push(double up, double down)
    {
        _up.Add(up);
        _down.Add(down);
        if (_up.Count > Capacity)
        {
            _up.RemoveAt(0);
            _down.RemoveAt(0);
        }
        var peak = 0.0;
        foreach (var v in _up) if (v > peak) peak = v;
        foreach (var v in _down) if (v > peak) peak = v;
        if (peak > _scale) _scale = peak * 1.15;                       // 顶到天上就放宽
        else if (peak < _scale * 0.25) _scale = Math.Max(FloorScale, peak * 1.6);   // 长期低流量再收回
        InvalidateVisual();
    }

    public void Clear()
    {
        _up.Clear();
        _down.Clear();
        _scale = FloorScale;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        var gridPen = new Pen(new SolidColorBrush(Color.FromArgb(0x50, 0x88, 0x90, 0x9C)), 1);
        gridPen.Freeze();
        for (var i = 1; i <= 3; i++)
        {
            var y = h * i / 4;
            dc.DrawLine(gridPen, new Point(0, y), new Point(w, y));
        }

        // 主题色在渲染时取（暗色切换后下一帧就跟上）
        var downColor = ResourceColor("Brand", Color.FromRgb(0x00, 0x7A, 0xFF));
        var upColor = ResourceColor("Running", Color.FromRgb(0x16, 0xA3, 0x4A));
        DrawSeries(dc, _down, downColor, w, h);
        DrawSeries(dc, _up, upColor, w, h);
    }

    private Color ResourceColor(string key, Color fallback)
    {
        if (TryFindResource(key) is SolidColorBrush b) return b.Color;
        return fallback;
    }

    private void DrawSeries(DrawingContext dc, List<double> series, Color color, double w, double h)
    {
        if (series.Count == 0) return;
        var n = series.Count;
        var step = w / (Capacity - 1);            // 固定窗口：满 120 个采样后一格一个点
        var startX = w - (n - 1) * step;

        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(new Point(startX, h), true, true);
            for (var i = 0; i < n; i++)
            {
                var t = Math.Min(1.0, series[i] / _scale);
                var y = h - t * (h - 2) - 1;
                g.LineTo(new Point(startX + i * step, y), true, false);
            }
            g.LineTo(new Point(w, h), true, false);
        }
        geo.Freeze();

        var fill = new SolidColorBrush(Color.FromArgb(0x40, color.R, color.G, color.B));
        fill.Freeze();
        var pen = new Pen(new SolidColorBrush(color), 1.6);
        pen.Freeze();
        dc.DrawGeometry(fill, pen, geo);
    }
}
