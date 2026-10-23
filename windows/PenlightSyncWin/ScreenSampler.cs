using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>
/// Captures the primary screen (or a normalized region of it), scales it to fit 96×54 like the macOS sampler,
/// and returns its average color.
/// </summary>
internal sealed class ScreenSampler : IDisposable
{
    private const int SampleWidth = 96;
    private const int SampleHeight = 54;
    private Bitmap? _full;
    private Bitmap? _small;

    /// <param name="region">Area to sample, normalized 0–1 with a top-left origin; null samples the whole screen.</param>
    public Rgb Sample(RectangleF? region)
    {
        var screen = Screen.PrimaryScreen?.Bounds ?? throw new InvalidOperationException("找不到主螢幕。");
        var bounds = screen;
        if (region is { } r)
        {
            var area = Rectangle.Intersect(screen, Rectangle.Round(new RectangleF(
                screen.X + r.X * screen.Width, screen.Y + r.Y * screen.Height, r.Width * screen.Width, r.Height * screen.Height)));
            if (area.Width > 0 && area.Height > 0) bounds = area;
        }
        if (_full == null || _full.Width != bounds.Width || _full.Height != bounds.Height)
        {
            _full?.Dispose();
            _full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        }
        using (var graphics = Graphics.FromImage(_full))
        {
            graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
        }
        // Keep the 96×54 budget but match the captured shape so nothing is stretched.
        var aspect = (double)bounds.Width / bounds.Height;
        var width = aspect >= (double)SampleWidth / SampleHeight ? SampleWidth : Math.Max(8, (int)Math.Round(SampleHeight * aspect));
        var height = aspect >= (double)SampleWidth / SampleHeight ? Math.Max(8, (int)Math.Round(SampleWidth / aspect)) : SampleHeight;
        if (_small == null || _small.Width != width || _small.Height != height)
        {
            _small?.Dispose();
            _small = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        }
        using (var graphics = Graphics.FromImage(_small))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
            graphics.DrawImage(_full, new Rectangle(0, 0, width, height));
        }

        var data = _small.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var stride = Math.Abs(data.Stride);
            var pixels = new byte[stride * height];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            // Format32bppArgb is stored as B, G, R, A in memory.
            return AverageColor.Find(pixels, width, height, stride, bgra: true)
                ?? throw new InvalidOperationException("無法讀取螢幕畫面。");
        }
        finally
        {
            _small.UnlockBits(data);
        }
    }

    public void Dispose()
    {
        _full?.Dispose();
        _small?.Dispose();
    }
}
