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

/// <summary>Port of BeatStyle in LightEngine.swift: how the lamp marks each music beat.</summary>
public enum BeatStyle
{
    /// <summary>Picks by tempo: blink for fast songs, colors for mid-tempo ones, breathe for slow ones.</summary>
    Auto,
    /// <summary>Dims slightly between beats and pops back to full on each beat.</summary>
    Flash,
    /// <summary>Lit on the beat, dark between beats, like a concert crowd's light sea.</summary>
    Blink,
    /// <summary>Each beat steps through the screen color, a similar color, the screen color again and its opposite color.</summary>
    Colors,
    /// <summary>Brightness rises and falls once every two beats; only chosen by <see cref="Auto"/> for slow songs.</summary>
    Breathe,
}

public static class BeatStyles
{
    /// <summary>The styles offered in the apps.</summary>
    public static readonly IReadOnlyList<BeatStyle> Choices = new[] { BeatStyle.Auto, BeatStyle.Flash, BeatStyle.Blink, BeatStyle.Colors };

    public static string Name(this BeatStyle style) => style switch
    {
        BeatStyle.Auto => "自動",
        BeatStyle.Breathe => "呼吸",
        BeatStyle.Blink => "亮滅",
        BeatStyle.Colors => "換色",
        _ => "加亮",
    };

    public static string Summary(this BeatStyle style) => style switch
    {
        BeatStyle.Auto => "依 BPM 切換：快歌亮滅、中速換色、慢歌跟拍呼吸",
        BeatStyle.Breathe => "跟著拍子緩慢起伏，每兩拍一次",
        BeatStyle.Blink => "拍上亮、拍間暗，像演唱會燈海",
        BeatStyle.Colors => "每拍輪流：原色、相似色、原色、對比色",
        _ => "拍點瞬間變亮，拍間稍暗",
    };
}

/// <summary>
/// Port of LightEngine.swift: grades each sample (vibrance, color temperature, brightness floor, overall brightness), fades toward it (faster after a
/// scene cut), adds an optional breath while the color is steady, and optional beat sync that dims between
/// beats and pops on each beat only while beats keep arriving. With a known tempo, fades speed up for fast songs
/// (and slow down for slow ones) and each flash lasts about a third of a beat. The beat style can instead blink the
/// lamp off between beats, step the hue on each beat, breathe with the beat, or pick one of these by tempo.
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
    public const double DefaultBeatDepth = 0.45;
    public double BeatDepth { get; set; } = DefaultBeatDepth;
    public const double BeatDecay = 0.18;
    public const double BeatHold = 2;
    public const double BeatRamp = 0.5;
    /// <summary>Blinking keeps the lamp lit for this share of a beat, then goes dark until the next one.</summary>
    public const double BlinkDuty = 0.5;
    public const double BlinkOnTime = 0.25;
    /// <summary>Hue offsets in degrees for successive beats in the color style: screen color, similar, screen color, opposite.</summary>
    private static readonly double[] BeatHues = { 0, 30, 0, 180 };
    /// <summary>
    /// Auto style: blink from <see cref="AutoFastTempo"/> BPM up, breathe below <see cref="AutoSlowTempo"/>, colors in between.
    /// A song must cross a line by <see cref="AutoMargin"/> BPM to leave its current style, so tempo jitter cannot flip it.
    /// </summary>
    public const double AutoFastTempo = 130;
    public const double AutoSlowTempo = 90;
    public const double AutoMargin = 4;
    /// <summary>The tempo breath dims to 50% halfway between every second beat.</summary>
    public const double BeatBreathDepth = 0.5;
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
    private int _beatCount;
    private BeatStyle _autoStyle = BeatStyle.Flash;

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
    /// <summary>-1 (cool) … 0 (as sampled) … 1 (warm).</summary>
    public double Warmth { get; set; }
    /// <summary>Overall output level (0–1), applied after the brightness floor.</summary>
    public double Brightness { get; set; } = 1;
    public bool SceneCuts { get; set; } = true;
    public bool BeatSync { get; set; }
    public BeatStyle BeatStyle { get; set; } = BeatStyle.Flash;

    /// <summary>True while beat sync is actively shaping the light.</summary>
    public bool MusicDetected => BeatSync && _beatActivity > 0.5;

    /// <summary>The music's tempo while beat sync is active and a tempo is known.</summary>
    public double? Bpm => MusicDetected ? _tempo : null;

    /// <summary>The style shaping the light right now (what Auto picked), while beat sync is active.</summary>
    public BeatStyle? ActiveBeatStyle => MusicDetected ? ResolvedStyle : null;

    private BeatStyle ResolvedStyle => BeatStyle == BeatStyle.Auto ? _autoStyle : BeatStyle;

    /// <summary>The style Auto uses at <paramref name="tempo"/>, staying with <paramref name="current"/> until the tempo clearly leaves its range.</summary>
    public static BeatStyle AutoStyleFor(double tempo, BeatStyle current)
    {
        var fastLine = AutoFastTempo + (current == BeatStyle.Blink ? -AutoMargin : current == BeatStyle.Colors ? AutoMargin : 0);
        var slowLine = AutoSlowTempo + (current == BeatStyle.Breathe ? AutoMargin : current == BeatStyle.Colors ? -AutoMargin : 0);
        return tempo >= fastLine ? BeatStyle.Blink : tempo < slowLine ? BeatStyle.Breathe : BeatStyle.Colors;
    }

    public void SetTarget(Rgb rgb)
    {
        var next = Grade(rgb, Vibrance, MinBrightness, Warmth, Brightness);
        if (_target == null) _current = (double[])next.Clone(); // The first sample shows immediately instead of fading in from black.
        else if (SceneCuts && Distance(next, _current) > CutDistance) _cutInProgress = true;
        _target = next;
    }

    /// <summary>Registers a detected beat with strength 0–1 and, when known, the music's tempo in BPM.</summary>
    public void Beat(double strength, double? bpm = null)
    {
        _pulse = Math.Max(_pulse, Math.Clamp(strength, 0, 1));
        // After a pause the color steps start over from the screen color.
        _beatCount = _sinceBeat < BeatHold ? _beatCount + 1 : 0;
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
        if (_tempo is { } styleTempo) _autoStyle = AutoStyleFor(styleTempo, _autoStyle);
        var beatScale = ResolvedStyle switch
        {
            BeatStyle.Blink => _sinceBeat < (_tempo is { } blinkTempo ? BlinkDuty * 60 / blinkTempo : BlinkOnTime) ? 1 : 1 - _beatActivity,
            BeatStyle.Colors => 1, // The hue step itself marks the beat.
            // Brightest on every second beat, dimmest halfway to the next one.
            BeatStyle.Breathe => 1 - BeatBreathDepth * _beatActivity * (0.5 - 0.5 * Math.Cos(2 * Math.PI * Math.Min(1,
                (_beatCount % 2 + Math.Min(1, _sinceBeat / (_tempo is { } breathTempo ? 60 / breathTempo : 0.75))) / 2))),
            // The frame right after a beat shows it at full strength; the flash decays from the next frame on.
            // Auto falls back to flash until a tempo is known.
            _ => 1 - BeatDepth * _beatActivity * (1 - _pulse),
        };
        var hueShift = ResolvedStyle == BeatStyle.Colors && BeatSync && _sinceBeat < BeatHold ? BeatHues[_beatCount % BeatHues.Length] : 0;
        var decay = _tempo is { } beatTempo ? Math.Clamp(0.35 * 60 / beatTempo, 0.1, 0.3) : BeatDecay;
        _pulse *= Math.Exp(-dt / decay);

        // Music takes over from breathing while it plays.
        var wanted = Breathing && distance < SteadyDistance ? 1 - _beatActivity : 0.0;
        _breathLevel += (wanted - _breathLevel) * (1 - Math.Exp(-dt / BreathRamp));
        _phase = (_phase + dt / BreathPeriod) % 1;
        var breathScale = 1 - BreathDepth * _breathLevel * (0.5 - 0.5 * Math.Cos(2 * Math.PI * _phase));

        var scale = beatScale * breathScale;
        var shown = RotateHue(_current, hueShift);
        byte Channel(int i) => (byte)Math.Clamp(Math.Round(shown[i] * scale, MidpointRounding.AwayFromZero), 0, 255);
        return new Rgb(Channel(0), Channel(1), Channel(2));
    }

    /// <summary>
    /// Boosts saturation along a curve that lifts dull colors most, keeps hue and brightness,
    /// shifts toward warm or cool, raises brightness to at least <paramref name="minBrightness"/>, then scales by
    /// <paramref name="brightness"/>.
    /// </summary>
    public static double[] Grade(Rgb rgb, double vibrance, double minBrightness, double warmth = 0, double brightness = 1)
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
        // Temperature only ever dims the opposite channels, so it cannot clip.
        var warm = Math.Clamp(warmth, -1, 1);
        if (warm > 0)
        {
            channels[1] *= 1 - 0.15 * warm;
            channels[2] *= 1 - 0.6 * warm;
        }
        else if (warm < 0)
        {
            channels[0] *= 1 + 0.6 * warm;
            channels[1] *= 1 + 0.15 * warm;
        }
        var floor = 255 * Math.Clamp(minBrightness, 0, 1);
        if (maximum < floor)
            channels = maximum > 0 ? channels.Select(c => c * floor / maximum).ToArray() : new[] { floor, floor, floor };
        var level = Math.Clamp(brightness, 0, 1);
        return channels.Select(c => c * level).ToArray();
    }

    /// <summary>Turns the hue by <paramref name="degrees"/>, keeping saturation and brightness; grays stay as they are.</summary>
    public static double[] RotateHue(double[] rgb, double degrees)
    {
        var maximum = rgb.Max();
        var minimum = rgb.Min();
        var chroma = maximum - minimum;
        if (chroma <= 0 || degrees % 360 == 0) return rgb;
        double r = rgb[0], g = rgb[1], b = rgb[2];
        var hue = maximum == r ? (g - b) / chroma : maximum == g ? (b - r) / chroma + 2 : (r - g) / chroma + 4;
        hue = ((hue * 60 + degrees) % 360 + 360) % 360 / 60;
        var x = chroma * (1 - Math.Abs(hue % 2 - 1));
        double[] sector = (int)hue switch
        {
            0 => new[] { chroma, x, 0 },
            1 => new[] { x, chroma, 0 },
            2 => new[] { 0, chroma, x },
            3 => new[] { 0, x, chroma },
            4 => new[] { x, 0, chroma },
            _ => new[] { chroma, 0, x },
        };
        return sector.Select(c => c + minimum).ToArray();
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

/// <summary>Port of ColorPreset in LightEngine.swift: one-click combinations of the color settings.</summary>
public sealed record ColorPreset(string Name, double Vibrance, double MinBrightness, double Brightness, double Warmth)
{
    public static readonly IReadOnlyList<ColorPreset> All = new[]
    {
        new ColorPreset("自然", 0.2, 0, 1, 0),
        new ColorPreset("標準", 0.4, 0, 1, 0),
        new ColorPreset("鮮豔", 0.75, 0.1, 1, 0),
        new ColorPreset("演唱會", 0.9, 0.2, 1, -0.1),
        new ColorPreset("電影院", 0.3, 0.05, 0.7, 0.15),
    };

    /// <summary>The defaults a fresh install starts with.</summary>
    public static ColorPreset Standard => All[1];

    public bool Matches(double vibrance, double minBrightness, double brightness, double warmth) =>
        Math.Abs(Vibrance - vibrance) < 0.001 && Math.Abs(MinBrightness - minBrightness) < 0.001
        && Math.Abs(Brightness - brightness) < 0.001 && Math.Abs(Warmth - warmth) < 0.001;
}

/// <summary>Port of ReleaseVersion in PenlightApp/UpdateChecker.swift: release tags such as "v1.4.0", compared part by part.</summary>
public static class ReleaseVersion
{
    /// <summary>Numeric parts of "v1.4.0" / "1.4"; null when the text is not a version.</summary>
    public static int[]? Parts(string text)
    {
        var body = text.Trim();
        if (body.StartsWith('v') || body.StartsWith('V')) body = body[1..];
        // Ignore a pre-release or build suffix such as "-beta" or "+abc".
        var end = body.IndexOfAny(new[] { '-', '+' });
        if (end >= 0) body = body[..end];
        var parts = body.Split('.');
        var numbers = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            if (!int.TryParse(parts[i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out numbers[i])) return null;
        }
        return numbers;
    }

    public static bool IsNewer(string candidate, string current)
    {
        if (Parts(candidate) is not { } a || Parts(current) is not { } b) return false;
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}

public enum ColorSource
{
    Screen,
    Site
}

public sealed record SiteBeat(double Bpm, double Offset, bool BarKnown);

public sealed record SiteState(
    int V,
    string Type,
    int Seq,
    string Song,
    string Title,
    bool Playing,
    double T,
    double Rate,
    string[] Colors,
    bool? ColorsSet = null,
    SiteBeat? Beat = null,
    double? Climax = null,
    string? Cue = null);

public readonly record struct SiteLightFrame(
    Rgb TargetColor,
    bool ShouldBeat,
    double BeatStrength,
    double BeatBpm,
    bool IsBarStart,
    bool IsClimax,
    bool IsWaiting,
    double BrightnessMultiplier,
    double MovieTime,
    int ColorIndex,
    int BeatInBar = 0,
    bool IsPreDownbeat = false);

public static class SiteLinkParser
{
    public const int MaxMessageSize = 4096;

    public static bool IsAllowedOrigin(string origin)
    {
        if (string.IsNullOrWhiteSpace(origin)) return false;
        if (origin.Equals("https://gcree.github.io", StringComparison.OrdinalIgnoreCase)) return true;
        if (origin.Equals("https://ado.kuti.cc", StringComparison.OrdinalIgnoreCase)) return true;
        if (Uri.TryCreate(origin, UriKind.Absolute, out var uri))
        {
            if ((uri.Scheme == "http" || uri.Scheme == "https") &&
                (uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || uri.Host == "127.0.0.1"))
            {
                return true;
            }
        }
        return false;
    }

    public static Rgb? HexToRgb(string hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return null;
        var s = hex.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length != 6) return null;
        if (uint.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var val))
        {
            var r = (byte)((val >> 16) & 0xFF);
            var g = (byte)((val >> 8) & 0xFF);
            var b = (byte)(val & 0xFF);
            return new Rgb(r, g, b);
        }
        return null;
    }

    public static bool IsStopMessage(string jsonText)
    {
        if (jsonText.Length > MaxMessageSize) return false;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(jsonText);
            var root = doc.RootElement;
            return root.ValueKind == System.Text.Json.JsonValueKind.Object
                && root.TryGetProperty("v", out var v) && v.GetInt32() == 1
                && root.TryGetProperty("type", out var type) && type.GetString() == "stop";
        }
        catch { return false; }
    }

    public static SiteState? ParseState(string jsonText)
    {
        if (jsonText.Length > MaxMessageSize) return null;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(jsonText);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) return null;

            if (!root.TryGetProperty("v", out var vProp) || vProp.GetInt32() != 1) return null;
            if (!root.TryGetProperty("type", out var typeProp) || typeProp.GetString() != "state") return null;
            if (!root.TryGetProperty("seq", out var seqProp)) return null;
            if (!root.TryGetProperty("song", out var songProp)) return null;
            if (!root.TryGetProperty("title", out var titleProp)) return null;
            if (!root.TryGetProperty("playing", out var playingProp)) return null;
            if (!root.TryGetProperty("t", out var tProp)) return null;
            if (!root.TryGetProperty("rate", out var rateProp)) return null;
            if (!root.TryGetProperty("colors", out var colorsProp) || colorsProp.ValueKind != System.Text.Json.JsonValueKind.Array) return null;

            var colorsList = new List<string>();
            foreach (var c in colorsProp.EnumerateArray())
            {
                if (c.ValueKind == System.Text.Json.JsonValueKind.String && c.GetString() is { } str)
                    colorsList.Add(str);
            }

            bool? colorsSet = null;
            if (root.TryGetProperty("colorsSet", out var csProp) && (csProp.ValueKind == System.Text.Json.JsonValueKind.True || csProp.ValueKind == System.Text.Json.JsonValueKind.False))
                colorsSet = csProp.GetBoolean();

            SiteBeat? beat = null;
            if (root.TryGetProperty("beat", out var bProp) && bProp.ValueKind == System.Text.Json.JsonValueKind.Object)
            {
                if (bProp.TryGetProperty("bpm", out var bpmProp) &&
                    bProp.TryGetProperty("offset", out var offProp) &&
                    bProp.TryGetProperty("barKnown", out var bkProp))
                {
                    beat = new SiteBeat(bpmProp.GetDouble(), offProp.GetDouble(), bkProp.GetBoolean());
                }
            }

            double? climax = null;
            if (root.TryGetProperty("climax", out var cxProp) && cxProp.ValueKind == System.Text.Json.JsonValueKind.Number)
                climax = cxProp.GetDouble();

            string? cue = null;
            if (root.TryGetProperty("cue", out var cueProp) && cueProp.ValueKind == System.Text.Json.JsonValueKind.String)
                cue = cueProp.GetString();

            return new SiteState(
                vProp.GetInt32(),
                typeProp.GetString()!,
                seqProp.GetInt32(),
                songProp.GetString()!,
                titleProp.GetString()!,
                playingProp.GetBoolean(),
                tProp.GetDouble(),
                rateProp.GetDouble(),
                colorsList.ToArray(),
                colorsSet,
                beat,
                climax,
                cue
            );
        }
        catch
        {
            return null;
        }
    }
}

public sealed class SiteLightEvaluator
{
    public static readonly Rgb DefaultBlue = new(93, 157, 254); // #5D9DFE
    public const double WaitingTimeoutSeconds = 5.0;

    public SiteState? LatestState { get; private set; }
    public DateTime? StateReceivedAt { get; private set; }
    public double? LastMovieTime { get; private set; }
    public Rgb LastTargetColor { get; private set; } = DefaultBlue;
    public int ColorChangeBeatCount { get; private set; }

    public void Reset()
    {
        LatestState = null;
        StateReceivedAt = null;
        LastMovieTime = null;
        LastTargetColor = DefaultBlue;
        ColorChangeBeatCount = 0;
    }

    public bool UpdateState(SiteState state, DateTime? receivedAt = null)
    {
        if (LatestState is { } current && state.Seq <= current.Seq)
        {
            return false;
        }
        LatestState = state;
        StateReceivedAt = receivedAt ?? DateTime.UtcNow;
        return true;
    }

    public static double CalculateMovieTime(SiteState state, DateTime receivedAt, DateTime now)
    {
        if (!state.Playing) return state.T;
        var elapsed = Math.Max(0.0, (now - receivedAt).TotalSeconds);
        return state.T + elapsed * state.Rate;
    }

    public SiteLightFrame Evaluate(DateTime? now = null, BeatStyle userBeatStyle = BeatStyle.Auto)
    {
        var currentTime = now ?? DateTime.UtcNow;
        if (LatestState is not { } state || StateReceivedAt is not { } receivedAt)
        {
            return new SiteLightFrame(
                TargetColor: LastTargetColor,
                ShouldBeat: false,
                BeatStrength: 0,
                BeatBpm: 0,
                IsBarStart: false,
                IsClimax: false,
                IsWaiting: true,
                BrightnessMultiplier: 0.3,
                MovieTime: 0,
                ColorIndex: 0
            );
        }

        var elapsedSinceReceive = (currentTime - receivedAt).TotalSeconds;
        if (elapsedSinceReceive > WaitingTimeoutSeconds)
        {
            return new SiteLightFrame(
                TargetColor: LastTargetColor,
                ShouldBeat: false,
                BeatStrength: 0,
                BeatBpm: 0,
                IsBarStart: false,
                IsClimax: false,
                IsWaiting: true,
                BrightnessMultiplier: 0.3,
                MovieTime: LastMovieTime ?? state.T,
                ColorIndex: 0
            );
        }

        var movieTime = CalculateMovieTime(state, receivedAt, currentTime);

        var parsedColors = new List<Rgb>();
        foreach (var c in state.Colors)
        {
            if (SiteLinkParser.HexToRgb(c) is { } rgb)
                parsedColors.Add(rgb);
        }
        var availableColors = parsedColors.Count > 0 ? parsedColors : new List<Rgb> { DefaultBlue };

        var isClimax = false;
        if (state.Climax is { } climax)
        {
            var climaxDuration = (state.Beat is { } b && b.Bpm > 0) ? 8.0 * (60.0 / b.Bpm) : 4.0;
            if (movieTime >= climax && movieTime < climax + climaxDuration)
            {
                isClimax = true;
            }
        }

        var isListen = state.Cue == "listen";
        var brightnessMultiplier = 1.0;
        if (isListen) brightnessMultiplier = 0.5;
        if (isClimax) brightnessMultiplier = 1.0;

        var shouldBeat = false;
        var beatStrength = 0.6;
        var isBarStart = false;
        var beatBpm = 0.0;
        var beatInBar = 0;

        var isHypeCue = state.Cue == "jump" || state.Cue == "call" || state.Cue == "clap" || isClimax;

        if (state.Playing && !isListen && state.Beat is { } beat && beat.Bpm > 0)
        {
            beatBpm = beat.Bpm;
            var beatInterval = 60.0 / beat.Bpm;
            if (LastMovieTime is { } prevTime)
            {
                var prevBeat = (int)Math.Floor((prevTime - beat.Offset) / beatInterval);
                var currBeat = (int)Math.Floor((movieTime - beat.Offset) / beatInterval);
                var prevHalfBeat = (int)Math.Floor((prevTime - beat.Offset) / (beatInterval / 2.0));
                var currHalfBeat = (int)Math.Floor((movieTime - beat.Offset) / (beatInterval / 2.0));

                var isDrumRoll = isClimax || (isHypeCue && beat.Bpm >= 125);

                if (currBeat > prevBeat)
                {
                    shouldBeat = true;
                    beatInBar = ((currBeat % 4) + 4) % 4;
                    isBarStart = beatInBar == 0;
                    beatStrength = (beat.BarKnown && isBarStart) ? 1.0 : 0.6;
                    if (userBeatStyle == BeatStyle.Colors)
                    {
                        ColorChangeBeatCount++;
                    }
                }
                else if (isDrumRoll && currHalfBeat > prevHalfBeat)
                {
                    shouldBeat = true;
                    beatInBar = ((currBeat % 4) + 4) % 4;
                    isBarStart = false;
                    beatStrength = 0.55;
                    if (userBeatStyle == BeatStyle.Colors)
                    {
                        ColorChangeBeatCount++;
                    }
                }
            }
        }
        LastMovieTime = movieTime;

        int colorIndex;
        if (availableColors.Count <= 1)
        {
            colorIndex = 0;
        }
        else if (userBeatStyle == BeatStyle.Colors)
        {
            colorIndex = ((ColorChangeBeatCount % availableColors.Count) + availableColors.Count) % availableColors.Count;
        }
        else if (state.Beat is { } beatData && beatData.Bpm > 0)
        {
            var beatInterval = 60.0 / beatData.Bpm;
            var exactBeat = (movieTime - beatData.Offset) / beatInterval;
            var beatIdx = (int)Math.Floor(exactBeat);
            var beatFraction = exactBeat - Math.Floor(exactBeat);

            var isDrumRoll = isClimax || (isHypeCue && beatData.Bpm >= 125) || (beatInBar == 3 && beatFraction >= 0.5 && beatData.Bpm >= 115);

            int colorStepIdx;
            if (isDrumRoll)
            {
                // 連續鼓聲：每 0.5 拍（半拍）極速切換！
                colorStepIdx = (int)Math.Floor(exactBeat * 2.0);
            }
            else if (isHypeCue || beatData.Bpm >= 135)
            {
                // 嗨歌／高潮／互動動作／快歌：每 1 拍換一次色！
                colorStepIdx = beatIdx;
            }
            else
            {
                // 一般正常段落：每 2 拍換一次色（1～2 拍換一次）！
                colorStepIdx = (int)Math.Floor((double)beatIdx / 2.0);
            }
            colorIndex = ((colorStepIdx % availableColors.Count) + availableColors.Count) % availableColors.Count;
        }
        else
        {
            var barIdx = (int)Math.Floor(movieTime / 4.0);
            colorIndex = ((barIdx % availableColors.Count) + availableColors.Count) % availableColors.Count;
        }

        var chosenColor = availableColors[colorIndex];
        LastTargetColor = chosenColor;

        var isPreDownbeat = false;
        if (state.Playing && !isListen && state.Beat is { } bKnown && bKnown.Bpm > 0 && bKnown.BarKnown)
        {
            var bInterval = 60.0 / bKnown.Bpm;
            var exBeat = (movieTime - bKnown.Offset) / bInterval;
            var bFrac = exBeat - Math.Floor(exBeat);
            var currBib = (((int)Math.Floor(exBeat) % 4) + 4) % 4;
            if (currBib == 3 && bFrac >= 0.82)
            {
                isPreDownbeat = true;
            }
        }

        return new SiteLightFrame(
            TargetColor: chosenColor,
            ShouldBeat: shouldBeat,
            BeatStrength: beatStrength,
            BeatBpm: beatBpm,
            IsBarStart: isBarStart,
            IsClimax: isClimax,
            IsWaiting: false,
            BrightnessMultiplier: brightnessMultiplier,
            MovieTime: movieTime,
            ColorIndex: colorIndex,
            BeatInBar: beatInBar,
            IsPreDownbeat: isPreDownbeat
        );
    }
}
