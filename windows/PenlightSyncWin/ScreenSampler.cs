using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>
/// Samples the primary screen (or a normalized region of it) and returns its average color. GDI StretchBlt with
/// HALFTONE shrinks the screen straight into a 96×54-budget bitmap, so no full-resolution copy is made and the
/// sampler is cheap enough to run about 30 times per second.
/// </summary>
internal sealed class ScreenSampler : IDisposable
{
    private const int SampleWidth = 96;
    private const int SampleHeight = 54;
    private const int Halftone = 4;
    private const int SourceCopy = 0x00CC0020;
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
        // Keep the 96×54 budget but match the captured shape so nothing is stretched.
        var aspect = (double)bounds.Width / bounds.Height;
        var width = aspect >= (double)SampleWidth / SampleHeight ? SampleWidth : Math.Max(8, (int)Math.Round(SampleHeight * aspect));
        var height = aspect >= (double)SampleWidth / SampleHeight ? Math.Max(8, (int)Math.Round(SampleWidth / aspect)) : SampleHeight;
        if (_small == null || _small.Width != width || _small.Height != height)
        {
            _small?.Dispose();
            // 32bppRgb: GDI leaves no alpha; LockBits below reads it back as opaque ARGB.
            _small = new Bitmap(width, height, PixelFormat.Format32bppRgb);
        }

        var screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero) throw new Win32Exception();
        try
        {
            using var graphics = Graphics.FromImage(_small);
            var target = graphics.GetHdc();
            try
            {
                SetStretchBltMode(target, Halftone);
                SetBrushOrgEx(target, 0, 0, IntPtr.Zero);
                if (!StretchBlt(target, 0, 0, width, height, screenDc, bounds.X, bounds.Y, bounds.Width, bounds.Height, SourceCopy))
                    throw new Win32Exception();
            }
            finally
            {
                graphics.ReleaseHdc(target);
            }
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, screenDc);
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

    public void Dispose() => _small?.Dispose();

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern int SetStretchBltMode(IntPtr dc, int mode);

    [DllImport("gdi32.dll")]
    private static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr previous);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool StretchBlt(IntPtr target, int targetX, int targetY, int targetWidth, int targetHeight,
        IntPtr source, int sourceX, int sourceY, int sourceWidth, int sourceHeight, int operation);
}
