using System.Net.Http.Headers;
using System.Text.Json;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>Port of UpdateChecker.swift: asks GitHub for the latest release tag. Only the version number is read; nothing is sent.</summary>
internal sealed class UpdateChecker
{
    public const string DownloadPage = "https://github.com/Gcree/penlight-sync/releases/latest";
    private const string LatestReleaseApi = "https://api.github.com/repos/Gcree/penlight-sync/releases/latest";
    private static readonly HttpClient Http = CreateClient();
    private readonly string _settingsPath;
    private bool _checkOnLaunch = true;
    private string? _skippedVersion;

    public UpdateChecker()
    {
        var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PenlightSync");
        Directory.CreateDirectory(dataDir);
        _settingsPath = Path.Combine(dataDir, "updates.txt");
        try
        {
            if (!File.Exists(_settingsPath)) return;
            foreach (var line in File.ReadAllLines(_settingsPath))
            {
                var parts = line.Split('=', 2);
                if (parts.Length != 2) continue;
                if (parts[0] == "checkOnLaunch") _checkOnLaunch = parts[1] == "1";
                else if (parts[0] == "skipped" && parts[1].Length > 0) _skippedVersion = parts[1];
            }
        }
        catch (IOException) { }
    }

    public string CurrentVersion { get; } = typeof(UpdateChecker).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0";

    public bool CheckOnLaunch
    {
        get => _checkOnLaunch;
        set
        {
            _checkOnLaunch = value;
            Save();
        }
    }

    public bool IsSkipped(string version) => version == _skippedVersion;

    public void Skip(string version)
    {
        _skippedVersion = version;
        Save();
    }

    /// <summary>The latest release tag when it is newer than this app, otherwise null. Throws when GitHub cannot be reached.</summary>
    public async Task<string?> FindNewerAsync()
    {
        using var response = await Http.GetAsync(LatestReleaseApi);
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var tag = json.RootElement.TryGetProperty("tag_name", out var value) ? value.GetString() : null;
        if (tag == null) throw new HttpRequestException("The release has no tag.");
        return ReleaseVersion.IsNewer(tag, CurrentVersion) ? tag : null;
    }

    private void Save()
    {
        try { File.WriteAllLines(_settingsPath, new[] { $"checkOnLaunch={(_checkOnLaunch ? 1 : 0)}", $"skipped={_skippedVersion}" }); } catch (IOException) { }
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        // GitHub's API rejects requests without a User-Agent.
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("PenlightSync", "1"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }
}
