using System.Drawing;
using System.Globalization;
using PenlightSync.Core;

namespace PenlightSync.Win;

internal sealed class AppSettings
{
    public LanguagePreference Language { get; set; } = LanguagePreference.Auto;
    public ColorSource ColorSource { get; set; } = ColorSource.Screen;
    public double FadeTime { get; set; } = 0.6;
    public bool LowLatency { get; set; }
    public bool Breathing { get; set; }
    public double Vibrance { get; set; } = 0.4;
    public double MinBrightness { get; set; }
    public double Warmth { get; set; }
    public double Brightness { get; set; } = 1.0;
    public bool SceneCuts { get; set; } = true;
    public bool BeatSync { get; set; }
    public BeatStyle BeatStyle { get; set; } = BeatStyle.Flash;
    public RectangleF? Region { get; set; }
    public ulong? SelectedAddress { get; set; }
}

/// <summary>Loads and saves user preferences in %LOCALAPPDATA%\PenlightSync.</summary>
internal sealed class SettingsStore
{
    private readonly string _effectsPath;
    private readonly string _selectedLampPath;

    public SettingsStore(string dataDir)
    {
        Directory.CreateDirectory(dataDir);
        _effectsPath = Path.Combine(dataDir, "effects.txt");
        _selectedLampPath = Path.Combine(dataDir, "selected-lamp.txt");
    }

    public AppSettings Load()
    {
        var settings = new AppSettings();
        try
        {
            if (File.Exists(_effectsPath))
            {
                foreach (var line in File.ReadAllLines(_effectsPath))
                {
                    var parts = line.Split('=', 2);
                    if (parts.Length != 2) continue;
                    var hasNumber = double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed);
                    switch (parts[0])
                    {
                        case "language": settings.Language = LanguageResolver.ParsePreference(parts[1]); break;
                        case "source": settings.ColorSource = parts[1] == "site" ? ColorSource.Site : ColorSource.Screen; break;
                        case "fade" when hasNumber: settings.FadeTime = Math.Clamp(parsed, 0, 2); break;
                        case "vibrance" when hasNumber: settings.Vibrance = Math.Clamp(parsed, 0, 1); break;
                        case "minBrightness" when hasNumber: settings.MinBrightness = Math.Clamp(parsed, 0, 0.5); break;
                        case "warmth" when hasNumber: settings.Warmth = Math.Clamp(parsed, -0.5, 0.5); break;
                        case "brightness" when hasNumber: settings.Brightness = Math.Clamp(parsed, 0.1, 1); break;
                        case "breathing": settings.Breathing = parts[1] == "1"; break;
                        case "sceneCuts": settings.SceneCuts = parts[1] == "1"; break;
                        case "beatSync": settings.BeatSync = parts[1] == "1"; break;
                        case "beatStyle":
                            settings.BeatStyle = Enum.TryParse<BeatStyle>(parts[1], out var style) && Enum.IsDefined(style)
                                ? style
                                : BeatStyle.Flash;
                            break;
                        case "lowLatency": settings.LowLatency = parts[1] == "1"; break;
                        case "region":
                            var values = parts[1].Split(',')
                                .Select(v => double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? n : -1)
                                .ToArray();
                            if (values.Length == 4 && values.All(v => v is >= 0 and <= 1) && values[2] > 0 && values[3] > 0)
                                settings.Region = new RectangleF((float)values[0], (float)values[1], (float)values[2], (float)values[3]);
                            break;
                    }
                }
            }

            if (File.Exists(_selectedLampPath) &&
                ulong.TryParse(File.ReadAllText(_selectedLampPath).Trim(), NumberStyles.HexNumber, null, out var saved))
            {
                settings.SelectedAddress = saved;
            }
        }
        catch (IOException) { }
        return settings;
    }

    public void SaveEffects(AppSettings settings)
    {
        static string Number(double value) => value.ToString(CultureInfo.InvariantCulture);
        static string Flag(bool value) => value ? "1" : "0";
        var text = $"language={LanguageResolver.ToConfigString(settings.Language)}\n"
            + $"source={(settings.ColorSource == ColorSource.Site ? "site" : "screen")}\n"
            + $"fade={Number(settings.FadeTime)}\nbreathing={Flag(settings.Breathing)}\nvibrance={Number(settings.Vibrance)}\n"
            + $"minBrightness={Number(settings.MinBrightness)}\nwarmth={Number(settings.Warmth)}\nbrightness={Number(settings.Brightness)}\n"
            + $"sceneCuts={Flag(settings.SceneCuts)}\nbeatSync={Flag(settings.BeatSync)}\nbeatStyle={settings.BeatStyle}\n"
            + $"lowLatency={Flag(settings.LowLatency)}\n";
        if (settings.Region is { } r)
            text += $"region={Number(r.X)},{Number(r.Y)},{Number(r.Width)},{Number(r.Height)}\n";
        try { File.WriteAllText(_effectsPath, text); } catch (IOException) { }
    }

    public void SaveSelectedLamp(ulong? address)
    {
        try { File.WriteAllText(_selectedLampPath, address?.ToString("X12") ?? ""); } catch (IOException) { }
    }
}
