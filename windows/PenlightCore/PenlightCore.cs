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
    /// <summary>
    /// Video-oriented average of 8-bit premultiplied RGBA (or BGRA when <paramref name="bgra"/> is true) rows.
    /// Trims near-black letterbox/pillarbox edges, skips near-white pixels in the bottom quarter (subtitles),
    /// and weights the center up to twice the corners. Entirely black/white frames fall back to the plain average.
    /// Returns null for malformed or fully transparent buffers.
    /// </summary>
    public static Rgb? Find(byte[] pixels, int width, int height, int bytesPerRow, bool bgra = false)
    {
        if (width <= 0 || height <= 0 || width > int.MaxValue / 4) return null;
        var rowBytes = width * 4;
        if (bytesPerRow < rowBytes || height - 1 > (int.MaxValue - rowBytes) / bytesPerRow) return null;
        var requiredBytes = (height - 1) * bytesPerRow + rowBytes;
        if (pixels.Length < requiredBytes) return null;

        int redOffset = bgra ? 2 : 0, blueOffset = bgra ? 0 : 2;
        (int R, int G, int B)? Pixel(int x, int y)
        {
            var offset = y * bytesPerRow + x * 4;
            int alpha = pixels[offset + 3];
            if (alpha == 0) return null;
            return (Math.Min(255, pixels[offset + redOffset] * 255 / alpha),
                    Math.Min(255, pixels[offset + 1] * 255 / alpha),
                    Math.Min(255, pixels[offset + blueOffset] * 255 / alpha));
        }
        bool IsBar((int R, int G, int B)? p) => p is not { } v || Math.Max(v.R, Math.Max(v.G, v.B)) < 16;

        // Trim letterbox rows and pillarbox columns while they are entirely near-black.
        int top = 0, bottom = height - 1, left = 0, right = width - 1;
        bool RowIsBar(int y) { for (var x = left; x <= right; x++) if (!IsBar(Pixel(x, y))) return false; return true; }
        bool ColumnIsBar(int x) { for (var y = top; y <= bottom; y++) if (!IsBar(Pixel(x, y))) return false; return true; }
        while (top < bottom && RowIsBar(top)) top++;
        while (bottom > top && RowIsBar(bottom)) bottom--;
        while (left < right && ColumnIsBar(left)) left++;
        while (right > left && ColumnIsBar(right)) right--;

        var subtitleTop = bottom - (bottom - top + 1) / 4 + 1;
        double cr = 0, cg = 0, cb = 0, cw = 0, ar = 0, ag = 0, ab = 0, aw = 0;
        for (var y = top; y <= bottom; y++)
        {
            for (var x = left; x <= right; x++)
            {
                if (Pixel(x, y) is not { } p) continue;
                var nx = (x - left + 0.5) / (right - left + 1) * 2 - 1;
                var ny = (y - top + 0.5) / (bottom - top + 1) * 2 - 1;
                var weight = 2 - Math.Min(1, Math.Sqrt(nx * nx + ny * ny) / Math.Sqrt(2));
                ar += p.R * weight; ag += p.G * weight; ab += p.B * weight; aw += weight;
                if (y >= subtitleTop && Math.Min(p.R, Math.Min(p.G, p.B)) > 200) continue;
                cr += p.R * weight; cg += p.G * weight; cb += p.B * weight; cw += weight;
            }
        }
        if (cw <= 0) (cr, cg, cb, cw) = (ar, ag, ab, aw);
        if (cw <= 0) return null;
        byte Channel(double sum) => (byte)Math.Round(sum / cw, MidpointRounding.AwayFromZero);
        return new Rgb(Channel(cr), Channel(cg), Channel(cb));
    }
}

/// <summary>
/// Port of LightEngine.swift: grades each sample (vibrance, brightness floor), fades toward it (faster after a
/// scene cut), adds an optional breath while the color is steady, and optional beat sync that dims between
/// beats and pops on each beat only while beats keep arriving. With a known tempo, fades speed up for fast songs
/// (and slow down for slow ones) and each flash lasts about a third of a beat.
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
    /// <summary>RGB distance of a sample jump that counts as a scene cut.</summary>
    public const double CutDistance = 140;
    public const double CutFadeFactor = 0.2;
    public const double MinimumCutFade = 0.08;
    /// <summary>Between beats the lamp rests at 55% brightness; each beat lifts it back to full.</summary>
    public const double BeatDepth = 0.45;
    public const double BeatDecay = 0.18;
    public const double BeatHold = 2;
    public const double BeatRamp = 0.5;
    /// <summary>Tempo at which the fade time is used as set; faster songs scale it down, slower ones up.</summary>
    public const double ReferenceTempo = 120;
    public const double MinTempoScale = 0.6;
    public const double MaxTempoScale = 1.4;

    private double[]? _target;
    private double[] _current = new double[3];
    private bool _cutInProgress;
    private double _breathLevel;
    private double _phase;
    private double _pulse;
    private double _beatActivity;
    private double _sinceBeat = double.PositiveInfinity;
    private double? _tempo;

    public LightEngine(double fadeTime, bool breathing)
    {
        FadeTime = fadeTime;
        Breathing = breathing;
    }

    /// <summary>Seconds to cover ~95% of the way to a new color; 0 switches instantly.</summary>
    public double FadeTime { get; set; }
    public bool Breathing { get; set; }
    /// <summary>0 leaves colors as sampled; 1 strongly boosts saturation (hue is preserved).</summary>
    public double Vibrance { get; set; }
    /// <summary>Lowest brightness (0–1) the lamp shows; 0 lets dark scenes go fully dark.</summary>
    public double MinBrightness { get; set; }
    public bool SceneCuts { get; set; } = true;
    public bool BeatSync { get; set; }

    /// <summary>True while beat sync is actively shaping the light.</summary>
    public bool MusicDetected => BeatSync && _beatActivity > 0.5;

    /// <summary>The music's tempo while beat sync is active and a tempo is known.</summary>
    public double? Bpm => MusicDetected ? _tempo : null;

    public void SetTarget(Rgb rgb)
    {
        var next = Grade(rgb, Vibrance, MinBrightness);
        if (_target == null) _current = (double[])next.Clone(); // The first sample shows immediately instead of fading in from black.
        else if (SceneCuts && Distance(next, _current) > CutDistance) _cutInProgress = true;
        _target = next;
    }

    /// <summary>Registers a detected beat with strength 0–1 and, when known, the music's tempo in BPM.</summary>
    public void Beat(double strength, double? bpm = null)
    {
        _pulse = Math.Max(_pulse, Math.Clamp(strength, 0, 1));
        _sinceBeat = 0;
        if (bpm is > 0) _tempo = bpm;
    }

    /// <summary>Advances the effect by <paramref name="dt"/> seconds. Returns null until the first sample arrives.</summary>
    public Rgb? Step(double dt)
    {
        if (_target == null) return null;
        dt = Math.Max(0, dt);
        // Blend the tempo's effect in and out with beat activity so it never jumps.
        var tempoScale = _tempo is { } tempo ? 1 + (Math.Clamp(ReferenceTempo / tempo, MinTempoScale, MaxTempoScale) - 1) * _beatActivity : 1;
        var baseFade = FadeTime * tempoScale;
        var activeFade = _cutInProgress ? Math.Max(MinimumCutFade, baseFade * CutFadeFactor) : baseFade;
        var k = FadeTime <= 0 ? 1 : 1 - Math.Exp(-3 * dt / activeFade);
        for (var i = 0; i < 3; i++) _current[i] += (_target[i] - _current[i]) * k;
        var distance = Distance(_current, _target);
        if (distance < SteadyDistance) _cutInProgress = false;

        _sinceBeat += dt;
        if (_sinceBeat >= BeatHold) _tempo = null;
        var beatsArriving = BeatSync && _sinceBeat < BeatHold ? 1.0 : 0.0;
        _beatActivity += (beatsArriving - _beatActivity) * (1 - Math.Exp(-dt / BeatRamp));
        // The frame right after a beat shows it at full strength; the flash decays from the next frame on.
        var beatScale = 1 - BeatDepth * _beatActivity * (1 - _pulse);
        var decay = _tempo is { } beatTempo ? Math.Clamp(0.35 * 60 / beatTempo, 0.1, 0.3) : BeatDecay;
        _pulse *= Math.Exp(-dt / decay);

        // Music takes over from breathing while it plays.
        var wanted = Breathing && distance < SteadyDistance ? 1 - _beatActivity : 0.0;
        _breathLevel += (wanted - _breathLevel) * (1 - Math.Exp(-dt / BreathRamp));
        _phase = (_phase + dt / BreathPeriod) % 1;
        var breathScale = 1 - BreathDepth * _breathLevel * (0.5 - 0.5 * Math.Cos(2 * Math.PI * _phase));

        var scale = beatScale * breathScale;
        byte Channel(int i) => (byte)Math.Clamp(Math.Round(_current[i] * scale, MidpointRounding.AwayFromZero), 0, 255);
        return new Rgb(Channel(0), Channel(1), Channel(2));
    }

    /// <summary>
    /// Boosts saturation along a curve that lifts dull colors most, keeps hue and brightness,
    /// then raises brightness to at least <paramref name="minBrightness"/>.
    /// </summary>
    public static double[] Grade(Rgb rgb, double vibrance, double minBrightness)
    {
        double[] channels = { rgb.Red, rgb.Green, rgb.Blue };
        var maximum = channels.Max();
        var minimum = channels.Min();
        if (maximum > 0 && maximum > minimum && vibrance > 0)
        {
            var saturation = (maximum - minimum) / maximum;
            var boosted = 1 - Math.Pow(1 - saturation, 1 + 3 * Math.Min(1, vibrance));
            channels = channels.Select(c => maximum - (maximum - c) * boosted / saturation).ToArray();
        }
        var floor = 255 * Math.Clamp(minBrightness, 0, 1);
        if (maximum < floor)
            channels = maximum > 0 ? channels.Select(c => c * floor / maximum).ToArray() : new[] { floor, floor, floor };
        return channels;
    }

    private static double Distance(double[] a, double[] b) =>
        Math.Sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

/// <summary>
/// Port of BeatDetector.swift: kick-drum energy onsets in ~23 ms windows of low-passed mono audio,
/// plus a tempo estimate from the spacing of recent beats.
/// </summary>
public sealed class BeatDetector
{
    public const double Cutoff = 150;
    public const double Window = 0.023;
    public const double AverageTime = 1.2;
    public const double Threshold = 1.6;
    public const double MinimumEnergy = 1e-5;
    public const double Refractory = 0.2;
    public const int TempoHistory = 8;
    public const double MinTempo = 70;
    public const double MaxTempo = 180;

    private readonly double _sampleRate;
    private readonly double _alpha;
    private readonly int _windowSize;
    private double _lowPass;
    private double _energy;
    private int _count;
    private double? _average;
    private double _sinceBeat = double.PositiveInfinity;
    private readonly List<double> _intervals = new();

    public BeatDetector(double sampleRate)
    {
        _sampleRate = sampleRate;
        _alpha = 1 - Math.Exp(-2 * Math.PI * Cutoff / sampleRate);
        _windowSize = Math.Max(1, (int)(sampleRate * Window));
    }

    /// <summary>Beats per minute from recent beats, or null until at least four steady intervals were heard.</summary>
    public double? Bpm { get; private set; }

    /// <summary>Feeds mono samples; returns the strength (0–1) of each beat found in them.</summary>
    public List<double> Process(ReadOnlySpan<float> samples)
    {
        var beats = new List<double>();
        var windowDuration = _windowSize / _sampleRate;
        foreach (var sample in samples)
        {
            _lowPass += (sample - _lowPass) * _alpha;
            _energy += _lowPass * _lowPass;
            if (++_count != _windowSize) continue;
            var windowEnergy = _energy / _count;
            _energy = 0;
            _count = 0;
            _sinceBeat += windowDuration;
            if (_average is not { } previous)
            {
                _average = windowEnergy;
                continue;
            }
            var ratio = windowEnergy / Math.Max(previous, 1e-12);
            if (ratio > Threshold && windowEnergy > MinimumEnergy && _sinceBeat >= Refractory)
            {
                beats.Add(Math.Min(1, 0.4 + (ratio - Threshold) / 2.5));
                RecordInterval(_sinceBeat);
                _sinceBeat = 0;
            }
            _average = previous + (windowEnergy - previous) * (1 - Math.Exp(-windowDuration / AverageTime));
        }
        return beats;
    }

    /// <summary>Uses the median interval to reject odd gaps, then averages intervals close to it.</summary>
    private void RecordInterval(double interval)
    {
        if (double.IsInfinity(interval)) return;
        if (interval > 2) // A long pause: start over.
        {
            _intervals.Clear();
            Bpm = null;
            return;
        }
        _intervals.Add(interval);
        if (_intervals.Count > TempoHistory) _intervals.RemoveRange(0, _intervals.Count - TempoHistory);
        if (_intervals.Count < 4) return;
        var median = _intervals.Order().ElementAt(_intervals.Count / 2);
        var steady = _intervals.Where(i => Math.Abs(i - median) <= median * 0.15).ToList();
        if (steady.Count < 3) return;
        var tempo = 60 / steady.Average();
        while (tempo < MinTempo) tempo *= 2;
        while (tempo > MaxTempo) tempo /= 2;
        Bpm = tempo;
    }
}
