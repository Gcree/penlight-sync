using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>Captures the primary screen, scales it to 96×54 like the macOS sampler, and returns its average color.</summary>
internal sealed class ScreenSampler : IDisposable
{
    private const int SampleWidth = 96;
    private const int SampleHeight = 54;
    private Bitmap? _full;
    private readonly Bitmap _small = new(SampleWidth, SampleHeight, PixelFormat.Format32bppArgb);

    public Rgb Sample()
    {
        var bounds = Screen.PrimaryScreen?.Bounds ?? throw new InvalidOperationException("找不到主螢幕。");
        if (_full == null || _full.Width != bounds.Width || _full.Height != bounds.Height)
        {
            _full?.Dispose();
            _full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        }
        using (var graphics = Graphics.FromImage(_full))
        {
            graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
        }
        using (var graphics = Graphics.FromImage(_small))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
            graphics.DrawImage(_full, new Rectangle(0, 0, SampleWidth, SampleHeight));
        }

        var data = _small.LockBits(new Rectangle(0, 0, SampleWidth, SampleHeight), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var stride = Math.Abs(data.Stride);
            var pixels = new byte[stride * SampleHeight];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            // Format32bppArgb is stored as B, G, R, A in memory.
            return AverageColor.Find(pixels, SampleWidth, SampleHeight, stride, bgra: true)
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
        _small.Dispose();
    }
}
