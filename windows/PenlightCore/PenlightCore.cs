using System.Security.Cryptography;

namespace PenlightSync.Core;

public readonly record struct Rgb(byte Red, byte Green, byte Blue)
{
    public override string ToString() => $"#{Red:X2}{Green:X2}{Blue:X2}";
}

/// <summary>
/// Port of PenlightProtocol.swift. Protocol/frame facts are based on Polyfish0/abo-light-stick-app
/// (GPL-3.0), LightStickCommandBuilder.kt at c11638d25ecf83a6d1eeef6334b42898a6b03ae8.
/// </summary>
public static class PenlightProtocol
{
    public const string TargetName = "Ado Light Stick";
    public static readonly Guid ControlUuid = new("00000000-0000-1000-8000-00805f9b34fb");

    private static readonly byte[] Key =
    {
        0x21, 0x74, 0x51, 0x64, 0x73, 0xA1, 0xF5, 0x35,
        0x10, 0x04, 0xA1, 0x3E, 0x6B, 0x71, 0x6A, 0xB9,
    };

    public static byte[] Encode(Rgb rgb)
    {
        byte[] plaintext =
        {
            0x82, 0x01, rgb.Red, rgb.Green, rgb.Blue,
            0x00, 0x00, 0x00, 0x00, 0x00,
            0xFD, 0x47, 0x52, 0x41, 0x56, 0x45,
        };
        using var aes = Aes.Create();
        aes.Key = Key;
        var ciphertext = aes.EncryptEcb(plaintext, PaddingMode.None);
        if (ciphertext.Length != 16) throw new CryptographicException("Unexpected RGB command length.");
        return ciphertext;
    }
}

/// <summary>Port of ScreenColorSampler.averageColor in ScreenColor.swift.</summary>
public static class AverageColor
{
    /// Average of 8-bit premultiplied RGBA (or BGRA when <paramref name="bgra"/> is true) rows.
    /// Transparent pixels are skipped. Returns null for malformed or fully transparent buffers.
    public static Rgb? Find(byte[] pixels, int width, int height, int bytesPerRow, bool bgra = false)
    {
        if (width <= 0 || height <= 0 || width > int.MaxValue / 4) return null;
        var rowBytes = width * 4;
        if (bytesPerRow < rowBytes || height - 1 > (int.MaxValue - rowBytes) / bytesPerRow) return null;
        var requiredBytes = (height - 1) * bytesPerRow + rowBytes;
        if (pixels.Length < requiredBytes) return null;

        int redOffset = bgra ? 2 : 0, blueOffset = bgra ? 0 : 2;
        long redSum = 0, greenSum = 0, blueSum = 0, count = 0;
        for (var y = 0; y < height; y++)
        {
            var row = y * bytesPerRow;
            for (var x = 0; x < width; x++)
            {
                var offset = row + x * 4;
                int alpha = pixels[offset + 3];
                if (alpha == 0) continue;
                redSum += Math.Min(255, pixels[offset + redOffset] * 255 / alpha);
                greenSum += Math.Min(255, pixels[offset + 1] * 255 / alpha);
                blueSum += Math.Min(255, pixels[offset + blueOffset] * 255 / alpha);
                count++;
            }
        }
        if (count == 0) return null;
        return new Rgb(
            (byte)((redSum + count / 2) / count),
            (byte)((greenSum + count / 2) / count),
            (byte)((blueSum + count / 2) / count));
    }
}

/// <summary>
/// Port of LightEngine.swift: an exponential fade toward the latest screen sample, plus an optional slow
/// brightness "breath" that only appears while the color is steady, so it never fights the video's own changes.
/// </summary>
public sealed class LightEngine
{
    public const double BreathPeriod = 4;
    /// <summary>Brightness dips to 70% at the bottom of each breath.</summary>
    public const double BreathDepth = 0.3;
    /// <summary>RGB distance below which the faded color counts as steady enough to breathe.</summary>
    public const double SteadyDistance = 24;
    /// <summary>How quickly breathing fades in or out after the color settles or changes.</summary>
    public const double BreathRamp = 0.8;

    private double[]? _target;
    private readonly double[] _current = new double[3];
    private double _breathLevel;
    private double _phase;

    public LightEngine(double fadeTime, bool breathing)
    {
        FadeTime = fadeTime;
        Breathing = breathing;
    }

    /// <summary>Seconds to cover ~95% of the way to a new color; 0 switches instantly.</summary>
    public double FadeTime { get; set; }
    public bool Breathing { get; set; }

    public void SetTarget(Rgb rgb)
    {
        double[] next = { rgb.Red, rgb.Green, rgb.Blue };
        if (_target == null) next.CopyTo(_current, 0); // The first sample shows immediately instead of fading in from black.
        _target = next;
    }

    /// <summary>Advances the effect by <paramref name="dt"/> seconds. Returns null until the first sample arrives.</summary>
    public Rgb? Step(double dt)
    {
        if (_target == null) return null;
        dt = Math.Max(0, dt);
        var k = FadeTime <= 0 ? 1 : 1 - Math.Exp(-3 * dt / FadeTime);
        double distanceSquared = 0;
        for (var i = 0; i < 3; i++)
        {
            _current[i] += (_target[i] - _current[i]) * k;
            distanceSquared += (_target[i] - _current[i]) * (_target[i] - _current[i]);
        }

        var wanted = Breathing && Math.Sqrt(distanceSquared) < SteadyDistance ? 1.0 : 0.0;
        _breathLevel += (wanted - _breathLevel) * (1 - Math.Exp(-dt / BreathRamp));
        _phase = (_phase + dt / BreathPeriod) % 1;
        var scale = 1 - BreathDepth * _breathLevel * (0.5 - 0.5 * Math.Cos(2 * Math.PI * _phase));

        byte Channel(int i) => (byte)Math.Clamp(Math.Round(_current[i] * scale, MidpointRounding.AwayFromZero), 0, 255);
        return new Rgb(Channel(0), Channel(1), Channel(2));
    }
}
