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

/// <summary>Port of ScreenColorSampler.dominantColor in ScreenColor.swift.</summary>
public static class DominantColor
{
    /// Reads 8-bit RGBA (or BGRA when <paramref name="bgra"/> is true) rows. Returns null for malformed or empty buffers.
    public static Rgb? Find(byte[] pixels, int width, int height, int bytesPerRow, bool bgra = false)
    {
        if (width <= 0 || height <= 0 || width > int.MaxValue / 4) return null;
        var rowBytes = width * 4;
        if (bytesPerRow < rowBytes || height - 1 > (int.MaxValue - rowBytes) / bytesPerRow) return null;
        var requiredBytes = (height - 1) * bytesPerRow + rowBytes;
        if (pixels.Length < requiredBytes) return null;

        var counts = new int[4096];
        var scores = new double[4096];
        var redSums = new int[4096];
        var greenSums = new int[4096];
        var blueSums = new int[4096];
        var chromaticPixels = 0;
        int redOffset = bgra ? 2 : 0, blueOffset = bgra ? 0 : 2;

        for (var y = 0; y < height; y++)
        {
            var row = y * bytesPerRow;
            for (var x = 0; x < width; x++)
            {
                var offset = row + x * 4;
                int alpha = pixels[offset + 3];
                if (alpha == 0) continue;
                var red = Math.Min(255, pixels[offset + redOffset] * 255 / alpha);
                var green = Math.Min(255, pixels[offset + 1] * 255 / alpha);
                var blue = Math.Min(255, pixels[offset + blueOffset] * 255 / alpha);
                var maximum = Math.Max(red, Math.Max(green, blue));
                var minimum = Math.Min(red, Math.Min(green, blue));
                var saturation = maximum == 0 ? 0.0 : (double)(maximum - minimum) / maximum;
                var brightness = maximum / 255.0;
                if (saturation > 0.08) chromaticPixels++;

                var bin = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4);
                counts[bin]++;
                redSums[bin] += red;
                greenSums[bin] += green;
                blueSums[bin] += blue;
                // Favor bright, saturated screen colors while keeping grayscale pixels count-weighted.
                scores[bin] += 1.0 + 2.5 * saturation * brightness;
            }
        }

        var best = 0;
        for (var bin = 1; bin < 4096; bin++)
        {
            var current = chromaticPixels == 0 ? counts[bin] : scores[bin];
            var leader = chromaticPixels == 0 ? counts[best] : scores[best];
            if (current > leader) best = bin; // Ties keep the earlier bin, matching Swift's max(by:).
        }
        var count = counts[best];
        if (count == 0) return null;
        return new Rgb(
            (byte)((redSums[best] + count / 2) / count),
            (byte)((greenSums[best] + count / 2) / count),
            (byte)((blueSums[best] + count / 2) / count));
    }
}
