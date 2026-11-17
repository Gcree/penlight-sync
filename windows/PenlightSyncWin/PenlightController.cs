using PenlightSync.Core;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Storage.Streams;

namespace PenlightSync.Win;

/// <summary>Reconnecting: the link dropped while syncing and the controller is retrying on its own.</summary>
internal enum Phase { Idle, Connecting, Syncing, Reconnecting, Stopping }

internal sealed class LampInfo
{
    public required ulong Address { get; init; }
    public short? Rssi { get; set; }
    public bool Remembered { get; set; }
    public string AddressText => FormatAddress(Address);

    public static string FormatAddress(ulong address) =>
        string.Join(":", Enumerable.Range(0, 6).Select(i => ((address >> (8 * (5 - i))) & 0xFF).ToString("X2")));
}

/// <summary>
/// Windows counterpart of the macOS PenlightController: same target-name check, write-with-response,
/// LightEngine effects rendering (only changed colors are written), optional beat sync, 8-second watchdogs,
/// and automatic reconnection for up to <see cref="ReconnectWindow"/> when the lamp drops the link.
/// All public state is read and changed on the UI thread; <see cref="Changed"/> fires there too.
/// </summary>
internal sealed class PenlightController : IDisposable
{
    /// <summary>About 30 screen samples per second.</summary>
    private static readonly TimeSpan SampleInterval = TimeSpan.FromMilliseconds(33);
    /// <summary>Output frame rate; each frame writes only if the color changed and the previous write was acknowledged.</summary>
    private static readonly TimeSpan RenderInterval = TimeSpan.FromMilliseconds(15);
    /// <summary>Swatch updates are limited to about 15 per second so the window stays light.</summary>
    private static readonly TimeSpan ColorNotifyInterval = TimeSpan.FromMilliseconds(66);
    private static readonly TimeSpan LatencyReportInterval = TimeSpan.FromSeconds(5);
    /// <summary>Fade time used while low-latency mode is on (unless the slider is already shorter).</summary>
    private const double LowLatencyFade = 0.15;
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan ScanDuration = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ReconnectWindow = TimeSpan.FromSeconds(30);

    private readonly SynchronizationContext _ui;
    private readonly SettingsStore _settingsStore;
    private readonly AppSettings _settings;
    private readonly object _syncLock = new();
    private LightEngine _engine;
    private readonly LatencyMeter _captureLatency = new();
    private readonly LatencyMeter _bluetoothLatency = new();
    private DateTime _lastLatencyReport;
    private int _latencyReports;
    private bool _colorsChanged;
    private DateTime _lastColorNotify;
    private IDisposable? _connectionRequest;
    private SystemAudioMonitor? _audio;
    private readonly string _logPath;
    private readonly List<LampInfo> _lamps = new();
    private readonly List<string> _log = new();
    private BluetoothLEAdvertisementWatcher? _watcher;
    private CancellationTokenSource? _scanCts;
    private CancellationTokenSource? _syncCts;
    private Task? _syncTask;
    private TaskCompletionSource<bool> _screenModeSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private BluetoothLEDevice? _device;
    private GattDeviceService? _service;
    private GattCharacteristic? _characteristic;

    private Rgb? _screenColor;
    private Rgb? _lampColor;
    private string _siteSongId = "";
    private string _siteSongTitle = "";
    private SitePlayingState _sitePlayingState = SitePlayingState.Waiting;
    private bool _musicDetected;
    private int? _bpm;
    private BeatStyle? _activeBeatStyle;
    private LText _statusText = new(l => L10n.StatusBtChecking(l));
    private LText? _errorText;
    private LText? _latencyText;
    private readonly SiteLinkWin _siteLink = new();
    private readonly SiteLightEvaluator _siteEvaluator = new();
    private readonly SiteStageDirector _siteDirector = new();

    public PenlightController()
    {
        _ui = SynchronizationContext.Current ?? throw new InvalidOperationException("Create the controller on the UI thread.");
        var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PenlightSync");
        _settingsStore = new SettingsStore(dataDir);
        _logPath = Path.Combine(dataDir, "latest.log");
        _settings = _settingsStore.Load();
        if (_settings.SelectedAddress is { } saved)
        {
            _lamps.Add(new LampInfo { Address = saved, Remembered = true });
        }
        L10n.SetPreference(_settings.Language, notify: false);
        _engine = MakeEngine();

        _siteLink.OnStateUpdate = (state, dt) =>
        {
            _ui.Post(_ =>
            {
                lock (_syncLock)
                {
                    _siteEvaluator.UpdateState(state, dt);
                    _siteSongId = state.Song;
                    _siteSongTitle = state.Title;
                    _sitePlayingState = state.Playing ? SitePlayingState.Playing : SitePlayingState.Paused;
                }
                Notify();
            }, null);
        };
        _siteLink.OnStop = () =>
        {
            _ui.Post(_ =>
            {
                lock (_syncLock)
                {
                    _siteEvaluator.Reset();
                    _siteDirector.Reset();
                    _siteSongId = "";
                    _siteSongTitle = "";
                    _sitePlayingState = SitePlayingState.Waiting;
                }
                Notify();
            }, null);
        };
        if (_settings.ColorSource == ColorSource.Site)
        {
            StartSiteLink();
        }
    }

    private void StartSiteLink()
    {
        _siteLink.Start();
        if (_siteLink.PortInUse)
        {
            if (Phase == Phase.Syncing) _statusText = SyncingStatusText;
            Log(l => L10n.LogPortInUse(l));
        }
    }

    private void StopSiteLink()
    {
        _siteLink.Stop();
    }

    public void SwitchColorSource()
    {
        ColorSource source;
        bool beatSync;
        lock (_syncLock)
        {
            source = _settings.ColorSource;
            beatSync = _settings.BeatSync;
        }
        Log(l => L10n.LogSourceSwitched(source, l));
        if (source == ColorSource.Site)
        {
            StartSiteLink();
            if (Phase == Phase.Syncing)
            {
                StopAudio();
                _siteLink.SetLampStatus("linked");
                _statusText = SyncingStatusText;
            }
        }
        else
        {
            StopSiteLink();
            SignalScreenMode();
            if (Phase == Phase.Syncing)
            {
                lock (_syncLock)
                {
                    _siteEvaluator.Reset();
                    _siteDirector.Reset();
                    _siteSongId = "";
                    _siteSongTitle = "";
                    _sitePlayingState = SitePlayingState.Waiting;
                }
                if (beatSync) StartAudio();
                _statusText = SyncingStatusText;
            }
        }
    }

    private void SignalScreenMode()
    {
        var current = Interlocked.Exchange(ref _screenModeSignal, new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously));
        current.TrySetResult(true);
    }

    private double EffectiveFadeTime => _settings.LowLatency ? Math.Min(_settings.FadeTime, LowLatencyFade) : _settings.FadeTime;

    private LightEngine MakeEngine() => new(EffectiveFadeTime, _settings.Breathing)
    {
        Vibrance = _settings.Vibrance,
        MinBrightness = _settings.MinBrightness,
        Warmth = _settings.Warmth,
        Brightness = _settings.Brightness,
        SceneCuts = _settings.SceneCuts,
        BeatSync = _settings.BeatSync,
        BeatStyle = _settings.BeatStyle,
    };

    public event Action? Changed;

    public LanguagePreference LanguagePreference
    {
        get => _settings.Language;
        set
        {
            if (_settings.Language == value) return;
            _settings.Language = value;
            _settingsStore.SaveEffects(_settings);
            L10n.SetPreference(value);
            Notify();
        }
    }

    public ColorSource ColorSource
    {
        get { lock (_syncLock) return _settings.ColorSource; }
        set
        {
            lock (_syncLock)
            {
                if (_settings.ColorSource == value) return;
                _settings.ColorSource = value;
                _settingsStore.SaveEffects(_settings);
            }
            SwitchColorSource();
            Notify();
        }
    }

    public string SiteSongId { get { lock (_syncLock) return _siteSongId; } }
    public string SiteSongTitle { get { lock (_syncLock) return _siteSongTitle; } }
    public SitePlayingState SitePlayingState { get { lock (_syncLock) return _sitePlayingState; } }
    public bool PortInUse => _siteLink.PortInUse;

    public void OpenAdoGuideSite()
    {
        const string baseUri = "https://gcree.github.io/ado-guide/";
        var songId = SiteSongId;
        var url = string.IsNullOrEmpty(songId) ? baseUri : $"{baseUri}#{songId}";
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch { }
    }

    public IReadOnlyList<LampInfo> Lamps => _lamps;
    public IReadOnlyList<string> LogLines => _log;
    public Phase Phase { get; private set; } = Phase.Idle;
    public bool BluetoothReady { get; private set; }
    public bool IsScanning => _watcher != null;
    public Rgb? ScreenColor { get { lock (_syncLock) return _screenColor; } }
    public Rgb? LampColor { get { lock (_syncLock) return _lampColor; } }
    public string Status => _statusText.ResolveCurrent();
    public string? ErrorMessage => _errorText?.ResolveCurrent();
    /// <summary>True while beats in the system audio are shaping the light.</summary>
    public bool MusicDetected { get { lock (_syncLock) return _musicDetected; } }
    /// <summary>The music's tempo (rounded BPM) while beat sync is shaping the light.</summary>
    public int? Bpm { get { lock (_syncLock) return _bpm; } }
    /// <summary>The style shaping the light right now (what Auto picked) while beat sync is shaping the light.</summary>
    public BeatStyle? ActiveBeatStyle { get { lock (_syncLock) return _activeBeatStyle; } }
    /// <summary>Recent average capture and Bluetooth round-trip times while syncing.</summary>
    public string? LatencySummary => _latencyText?.ResolveCurrent();
    public string LogPath => _logPath;
    public bool CanStart => BluetoothReady && Phase == Phase.Idle && _settings.SelectedAddress != null;

    /// <summary>Seconds to cover ~95% of a color change; 0 switches instantly. Applies live while syncing.</summary>
    public double FadeTime
    {
        get { lock (_syncLock) return _settings.FadeTime; }
        set
        {
            lock (_syncLock)
            {
                _settings.FadeTime = Math.Clamp(value, 0, 2);
                _engine.FadeTime = EffectiveFadeTime;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>Caps the fade at 0.15 s so the lamp follows the screen as closely as possible.</summary>
    public bool LowLatency
    {
        get { lock (_syncLock) return _settings.LowLatency; }
        set
        {
            lock (_syncLock)
            {
                _settings.LowLatency = value;
                _engine.FadeTime = EffectiveFadeTime;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    public bool Breathing
    {
        get { lock (_syncLock) return _settings.Breathing; }
        set
        {
            lock (_syncLock)
            {
                _settings.Breathing = value;
                _engine.Breathing = value;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>0 leaves colors as sampled; 1 strongly boosts saturation. Applies from the next sample.</summary>
    public double Vibrance
    {
        get { lock (_syncLock) return _settings.Vibrance; }
        set
        {
            lock (_syncLock)
            {
                _settings.Vibrance = Math.Clamp(value, 0, 1);
                _engine.Vibrance = _settings.Vibrance;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>Lowest lamp brightness (0–0.5); 0 lets dark scenes go fully dark.</summary>
    public double MinBrightness
    {
        get { lock (_syncLock) return _settings.MinBrightness; }
        set
        {
            lock (_syncLock)
            {
                _settings.MinBrightness = Math.Clamp(value, 0, 0.5);
                _engine.MinBrightness = _settings.MinBrightness;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>-0.5 (cool) … 0.5 (warm). Applies from the next sample.</summary>
    public double Warmth
    {
        get { lock (_syncLock) return _settings.Warmth; }
        set
        {
            lock (_syncLock)
            {
                _settings.Warmth = Math.Clamp(value, -0.5, 0.5);
                _engine.Warmth = _settings.Warmth;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>Overall lamp level (0.1–1). Applies from the next sample.</summary>
    public double Brightness
    {
        get { lock (_syncLock) return _settings.Brightness; }
        set
        {
            lock (_syncLock)
            {
                _settings.Brightness = Math.Clamp(value, 0.1, 1);
                _engine.Brightness = _settings.Brightness;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>The preset whose color settings match the current ones, if any.</summary>
    public ColorPreset? ActivePreset
    {
        get
        {
            lock (_syncLock)
            {
                return ColorPreset.All.FirstOrDefault(p => p.Matches(_settings.Vibrance, _settings.MinBrightness, _settings.Brightness, _settings.Warmth));
            }
        }
    }

    public void Apply(ColorPreset preset)
    {
        Vibrance = preset.Vibrance;
        MinBrightness = preset.MinBrightness;
        Brightness = preset.Brightness;
        Warmth = preset.Warmth;
        Notify();
    }

    /// <summary>Puts every light effect back to its default; the lamp choice and capture area stay.</summary>
    public void ResetEffects()
    {
        Apply(ColorPreset.Standard);
        FadeTime = 0.6;
        LowLatency = false;
        SceneCuts = true;
        Breathing = false;
        BeatSync = false;
        BeatStyle = BeatStyle.Flash;
        Notify();
    }

    public bool SceneCuts
    {
        get { lock (_syncLock) return _settings.SceneCuts; }
        set
        {
            lock (_syncLock)
            {
                _settings.SceneCuts = value;
                _engine.SceneCuts = value;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    /// <summary>Area of the primary screen to sample (normalized 0–1, top-left origin); null is the whole screen.</summary>
    public RectangleF? Region
    {
        get { lock (_syncLock) return _settings.Region; }
        set
        {
            lock (_syncLock)
            {
                _settings.Region = value;
                _settingsStore.SaveEffects(_settings);
            }
            if (value is { } r)
            {
                var wPct = r.Width * 100;
                var hPct = r.Height * 100;
                Log(l => L10n.LogRegionCustom(wPct, hPct, l));
            }
            else
            {
                Log(l => L10n.LogRegionWholeScreen(l));
            }
            if (Phase == Phase.Syncing) _statusText = SyncingStatusText;
            Notify();
        }
    }

    private LText SyncingStatusText
    {
        get
        {
            ColorSource source;
            bool hasRegion;
            lock (_syncLock)
            {
                source = _settings.ColorSource;
                hasRegion = _settings.Region != null;
            }
            if (source == ColorSource.Site)
            {
                if (_siteLink.PortInUse)
                {
                    return new LText(l => L10n.StatusSyncingSitePortInUse(l));
                }
                return new LText(l => L10n.StatusSyncingSite(l));
            }
            return new LText(l => L10n.StatusSyncingScreen(hasRegion, l));
        }
    }

    /// <summary>Pulses the lamp on beats in the system audio; starts or stops listening live while syncing.</summary>
    public bool BeatSync
    {
        get { lock (_syncLock) return _settings.BeatSync; }
        set
        {
            lock (_syncLock)
            {
                _settings.BeatSync = value;
                _engine.BeatSync = value;
                _settingsStore.SaveEffects(_settings);
            }
            if (Phase is not (Phase.Syncing or Phase.Reconnecting)) return;
            if (value && ColorSource == ColorSource.Screen) StartAudio(); else StopAudio();
            Notify();
        }
    }

    /// <summary>How the lamp marks each beat; applies right away.</summary>
    public BeatStyle BeatStyle
    {
        get { lock (_syncLock) return _settings.BeatStyle; }
        set
        {
            lock (_syncLock)
            {
                _settings.BeatStyle = value;
                _engine.BeatStyle = value;
                _settingsStore.SaveEffects(_settings);
            }
        }
    }

    private void StartAudio()
    {
        if (_audio != null) return;
        try
        {
            _audio = new SystemAudioMonitor(_ui, (strength, bpm) =>
            {
                lock (_syncLock) _engine.Beat(strength, bpm);
            }, AudioFailed);
            _audio.Start();
            Log(l => L10n.LogAudioStarted(l));
        }
        catch (Exception error)
        {
            AudioFailed(error.Message);
        }
    }

    private void StopAudio()
    {
        _audio?.Dispose();
        _audio = null;
        lock (_syncLock)
        {
            _musicDetected = false;
            _bpm = null;
            _activeBeatStyle = null;
        }
    }

    /// <summary>Audio problems only turn off the beat effect; color sync keeps running.</summary>
    private void AudioFailed(string message)
    {
        StopAudio();
        _errorText = new LText(l => L10n.ErrAudioFailed(message, l));
        Log(l => L10n.LogAudioFailed(message, l));
        Notify();
    }

    public ulong? SelectedAddress
    {
        get => _settings.SelectedAddress;
        set
        {
            if (_settings.SelectedAddress == value || Phase != Phase.Idle) return;
            _settings.SelectedAddress = value;
            _settingsStore.SaveSelectedLamp(value);
            Notify();
        }
    }

    public async Task InitializeAsync()
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter == null || !adapter.IsLowEnergySupported)
            {
                _statusText = new LText(l => L10n.StatusBtNoBle(l));
            }
            else
            {
                var radio = await adapter.GetRadioAsync();
                if (radio != null && radio.State != RadioState.On)
                {
                    _statusText = new LText(l => L10n.StatusBtOffWin(l));
                }
                else
                {
                    BluetoothReady = true;
                    _statusText = new LText(l => L10n.StatusBtReady(l));
                }
            }
        }
        catch (Exception error)
        {
            var msg = error.Message;
            _statusText = new LText(l => L10n.StatusBtError(msg, l));
        }
        Notify();
    }

    // MARK: Scan

    public void StartScan()
    {
        if (!BluetoothReady || Phase != Phase.Idle || _watcher != null) return;
        _errorText = null;
        _lamps.RemoveAll(lamp => !lamp.Remembered && lamp.Address != SelectedAddress);
        foreach (var lamp in _lamps) lamp.Rssi = null;
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.Received += OnAdvertisement;
        watcher.Stopped += (_, args) => _ui.Post(_ =>
        {
            if (_watcher != watcher) return;
            if (args.Error != BluetoothError.Success)
            {
                var err = args.Error.ToString();
                _errorText = new LText(l => L10n.ErrScanStopped(err, l));
            }
            StopScan(finished: true);
        }, null);
        _watcher = watcher;
        watcher.Start();
        _statusText = new LText(l => L10n.StatusScanning(l));
        Log(l => L10n.LogScanStart(PenlightProtocol.TargetName, l));
        _scanCts = new CancellationTokenSource();
        var token = _scanCts.Token;
        _ = Task.Delay(ScanDuration, token).ContinueWith(_ => StopScan(finished: true),
            token, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.FromCurrentSynchronizationContext());
        Notify();
    }

    public void StopScan(bool finished = false)
    {
        _scanCts?.Cancel();
        _scanCts = null;
        var watcher = _watcher;
        if (watcher == null) return;
        _watcher = null;
        watcher.Received -= OnAdvertisement;
        try { watcher.Stop(); } catch (Exception) { }
        if (finished && Phase == Phase.Idle)
        {
            var found = _lamps.Count(lamp => lamp.Rssi != null);
            _statusText = found == 0
                ? new LText(l => L10n.StatusScanNone(l))
                : new LText(l => L10n.StatusScanFound(found, l));
        }
        Notify();
    }

    private void OnAdvertisement(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        if (!string.Equals(args.Advertisement.LocalName, PenlightProtocol.TargetName, StringComparison.OrdinalIgnoreCase)) return;
        var address = args.BluetoothAddress;
        var rssi = args.RawSignalStrengthInDBm;
        _ui.Post(_ =>
        {
            if (_watcher != sender) return;
            var lamp = _lamps.FirstOrDefault(l => l.Address == address);
            if (lamp == null)
            {
                _lamps.Add(new LampInfo { Address = address, Rssi = rssi });
                var addrText = LampInfo.FormatAddress(address);
                Log(l => L10n.LogLampFound(addrText, l));
            }
            else
            {
                lamp.Rssi = rssi;
            }
            if (SelectedAddress == null || _lamps.All(l => l.Address != SelectedAddress)) SelectedAddress = address;
            Notify();
        }, null);
    }

    // MARK: Connect and sync

    public async Task StartAsync()
    {
        if (!CanStart || SelectedAddress is not { } address) return;
        _errorText = null;
        StopScan();
        if (ColorSource == ColorSource.Site)
        {
            StartSiteLink();
        }
        Phase = Phase.Connecting;
        _siteLink.SetLampStatus("connecting");
        lock (_syncLock)
        {
            _screenColor = null;
            _lampColor = null;
            _engine = MakeEngine();
            _siteDirector.Reset();
            _musicDetected = false;
            _bpm = null;
            _activeBeatStyle = null;
        }
        _statusText = new LText(l => L10n.StatusConnecting(l));
        var addrText = LampInfo.FormatAddress(address);
        Log(l => L10n.LogConnecting(PenlightProtocol.TargetName, addrText, l));
        Notify();
        try
        {
            var characteristic = await ConnectAsync(address);
            if (Phase != Phase.Connecting) return; // Stopped while connecting.
            Phase = Phase.Syncing;
            _siteLink.SetLampStatus("linked");
            _statusText = SyncingStatusText;
            Log(l => L10n.LogSyncStarted(l));
            if (ColorSource == ColorSource.Screen && BeatSync) StartAudio();
            Notify();
            BeginSync(characteristic);
        }
        catch (Exception error)
        {
            await ShutDownAsync(ConnectFailure(error));
        }
    }

    private static LText ConnectFailure(Exception error) => error switch
    {
        TimeoutException => new LText(l => L10n.ErrConnectTimeout(l)),
        SyncException syncError => syncError.LocalizedMessage,
        _ => new LText(l => L10n.ErrFailedToConnect(error.Message, l)),
    };

    /// <summary>Opens the lamp and returns its control characteristic; the device is kept in <see cref="_device"/>.</summary>
    private async Task<GattCharacteristic> ConnectAsync(ulong address)
    {
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address).AsTask().WaitAsync(ConnectTimeout)
            ?? throw new SyncException(new LText(l => L10n.ErrSelectedLampNotFound(l)));
        _device = device;
        if (!string.IsNullOrEmpty(device.Name) && device.Name != PenlightProtocol.TargetName)
            throw new SyncException(new LText(l => L10n.ErrWrongDeviceName(PenlightProtocol.TargetName, l)));
        device.ConnectionStatusChanged += OnConnectionStatusChanged;

        var services = await device.GetGattServicesForUuidAsync(PenlightProtocol.ControlUuid, BluetoothCacheMode.Uncached)
            .AsTask().WaitAsync(ConnectTimeout);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
        {
            var statusName = services.Status.ToString();
            throw new SyncException(new LText(l => L10n.ErrServiceDiscoveryFailed(statusName, l)));
        }
        _service = services.Services[0];
        Log(l => L10n.LogConnectedDiscovering(l));

        var characteristics = await _service.GetCharacteristicsForUuidAsync(PenlightProtocol.ControlUuid, BluetoothCacheMode.Uncached)
            .AsTask().WaitAsync(ConnectTimeout);
        var characteristic = characteristics.Status == GattCommunicationStatus.Success
            ? characteristics.Characteristics.FirstOrDefault()
            : null;
        if (characteristic == null || !characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write))
            throw new SyncException(new LText(l => L10n.ErrCharNoWrite(l)));
        _characteristic = characteristic;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) RequestFastConnection(device);
        return characteristic;
    }

    /// <summary>
    /// Windows 11 lets apps ask for a shorter BLE connection interval, which shortens each write round trip.
    /// The request lasts until it is disposed (in <see cref="ReleaseDevice"/>); the lamp may still decline.
    /// </summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows10.0.22000.0")]
    private void RequestFastConnection(BluetoothLEDevice device)
    {
        try
        {
            var request = device.RequestPreferredConnectionParameters(BluetoothLEPreferredConnectionParameters.ThroughputOptimized);
            if (request.Status == BluetoothLEPreferredConnectionParametersRequestStatus.Success)
            {
                _connectionRequest = request;
                var interval = device.GetConnectionParameters().ConnectionInterval * 1.25;
                Log(l => L10n.LogFastConnAccepted(interval, l));
            }
            else
            {
                var statusName = request.Status.ToString();
                request.Dispose();
                Log(l => L10n.LogFastConnRejected(statusName, l));
            }
        }
        catch (Exception error)
        {
            var msg = error.Message;
            Log(l => L10n.LogFastConnFailed(msg, l));
        }
    }

    private void BeginSync(GattCharacteristic characteristic)
    {
        lock (_syncLock)
        {
            _captureLatency.Drain();
            _bluetoothLatency.Drain();
        }
        _lastLatencyReport = DateTime.UtcNow;
        _latencyReports = 0;
        _syncCts = new CancellationTokenSource();
        var token = _syncCts.Token;
        _syncTask = Task.WhenAll(RunLoopAsync(SampleLoopAsync(token), token), RunLoopAsync(RenderLoopAsync(characteristic, token), token));
    }

    /// <summary>
    /// Stops the loops, drops the link and retries the connection until <see cref="ReconnectWindow"/> runs out.
    /// The engine (current color and effects) and beat listening carry over.
    /// </summary>
    private async Task ReconnectAsync(LText reason)
    {
        if (Phase != Phase.Syncing || SelectedAddress is not { } address) return;
        Phase = Phase.Reconnecting;
        _siteLink.SetLampStatus("connecting");
        lock (_syncLock) { _lampColor = null; } // Rewrite the current color as soon as the link is back.
        var windowSeconds = (int)ReconnectWindow.TotalSeconds;
        _statusText = new LText(l => L10n.StatusReconnecting(reason.Resolve(l), windowSeconds, l));
        Log(l => L10n.LogReconnecting(reason.Resolve(l), l));
        Notify();
        await StopLoopsAsync();
        ReleaseDevice();

        var deadline = DateTime.UtcNow + ReconnectWindow;
        while (Phase == Phase.Reconnecting && DateTime.UtcNow < deadline)
        {
            try
            {
                var characteristic = await ConnectAsync(address);
                if (Phase != Phase.Reconnecting)
                {
                    if (Phase == Phase.Idle) ReleaseDevice(); // Stopped meanwhile.
                    return;
                }
                Phase = Phase.Syncing;
                _siteLink.SetLampStatus("linked");
                _statusText = SyncingStatusText;
                Log(l => L10n.LogReconnected(l));
                Notify();
                BeginSync(characteristic);
                return;
            }
            catch (Exception error)
            {
                if (Phase == Phase.Idle) ReleaseDevice();
                if (Phase != Phase.Reconnecting) return;
                ReleaseDevice();
                var failure = ConnectFailure(error);
                Log(l => L10n.LogReconnectFailed(failure.Resolve(l), l));
                await Task.Delay(TimeSpan.FromSeconds(1));
            }
        }
        if (Phase == Phase.Reconnecting)
            await ShutDownAsync(new LText(l => L10n.ErrReconnectTimedOut(reason.Resolve(l), windowSeconds, l)));
    }

    /// <summary>Cancels the sample and render loops, waiting a bounded time for an outstanding sample or write.</summary>
    private async Task StopLoopsAsync()
    {
        _syncCts?.Cancel();
        if (_syncTask is { } task && !task.IsCompleted) await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(3)));
        _syncCts?.Dispose();
        _syncCts = null;
        _syncTask = null;
    }

    public Task StopAsync() => Phase is Phase.Connecting or Phase.Syncing or Phase.Reconnecting ? ShutDownAsync(null) : Task.CompletedTask;

    /// <summary>Turns a loop failure into a shutdown or reconnect on the UI thread; cancellation is a normal stop.</summary>
    private async Task RunLoopAsync(Task loop, CancellationToken token)
    {
        try
        {
            await loop;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (LinkException error)
        {
            _ui.Post(_ => _ = ReconnectAsync(error.LocalizedMessage), null);
        }
        catch (SyncException error)
        {
            _ui.Post(_ => _ = ShutDownAsync(error.LocalizedMessage), null);
        }
        catch (Exception error)
        {
            var msg = error.Message;
            _ui.Post(_ => _ = ShutDownAsync(new LText(l => L10n.ErrSyncLoop(msg, l))), null);
        }
    }

    private async Task SampleLoopAsync(CancellationToken token)
    {
        ScreenSampler? sampler = null;
        try
        {
            while (!token.IsCancellationRequested)
            {
                if (ColorSource != ColorSource.Screen)
                {
                    sampler?.Dispose();
                    sampler = null;
                    var signal = Volatile.Read(ref _screenModeSignal).Task;
                    await signal.WaitAsync(token);
                    continue;
                }
                sampler ??= new ScreenSampler();
                var started = DateTime.UtcNow;
                Rgb color;
                try
                {
                    var region = Region;
                    var activeSampler = sampler;
                    var watch = System.Diagnostics.Stopwatch.StartNew();
                    color = await Task.Run(() => activeSampler.Sample(region), token).WaitAsync(OperationTimeout, token);
                    lock (_syncLock) { _captureLatency.Add(watch.Elapsed.TotalMilliseconds); }
                }
                catch (TimeoutException)
                {
                    throw new SyncException(new LText(l => L10n.ErrScreenTimeout(l)));
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    var msg = error.Message;
                    throw new SyncException(new LText(l => L10n.ErrScreenFailed(msg, l)));
                }
                lock (_syncLock)
                {
                    if (color != _screenColor)
                    {
                        _screenColor = color;
                        _colorsChanged = true;
                    }
                    _engine.SetTarget(color);
                }
                var remaining = SampleInterval - (DateTime.UtcNow - started);
                if (remaining > TimeSpan.Zero) await Task.Delay(remaining, token);
            }
        }
        finally
        {
            sampler?.Dispose();
        }
    }

    /// <summary>Advances the fade/breath effect and writes each frame that differs from the lamp's acknowledged color.</summary>
    private async Task RenderLoopAsync(GattCharacteristic characteristic, CancellationToken token)
    {
        var loopWatch = System.Diagnostics.Stopwatch.StartNew();
        var last = DateTime.UtcNow;
        while (!token.IsCancellationRequested)
        {
            var now = DateTime.UtcNow;
            var dt = (now - last).TotalSeconds;
            last = now;

            Rgb? frame;
            Rgb? acknowledgedLamp;
            bool musicChanged;
            bool notifyColors = false;
            lock (_syncLock)
            {
                if (_settings.ColorSource == ColorSource.Site)
                {
                    var stage = _siteDirector.Step(
                        uptimeSeconds: loopWatch.Elapsed.TotalSeconds,
                        now: now,
                        baseBrightness: _settings.Brightness,
                        effectiveFadeTime: EffectiveFadeTime,
                        lowLatency: _settings.LowLatency,
                        userBeatStyle: _settings.BeatStyle,
                        evaluator: _siteEvaluator
                    );
                    _siteSongTitle = stage.SongTitle;
                    _sitePlayingState = stage.PlayingState;
                    _engine.Brightness = stage.EffectiveBrightness;
                    _engine.FadeTime = stage.EffectiveFadeTime;
                    _engine.BeatDepth = stage.BeatDepth;
                    _engine.BeatStyle = stage.BeatStyle;
                    _engine.BeatSync = stage.BeatSync;
                    _engine.Breathing = stage.Breathing;
                    if (stage.BeatStrength is { } strength)
                    {
                        _engine.Beat(strength, stage.BeatBpm);
                    }
                    if (stage.EffectiveColor != _screenColor)
                    {
                        _screenColor = stage.EffectiveColor;
                        _colorsChanged = true;
                    }
                    _engine.SetTarget(stage.EffectiveColor);
                }
                else
                {
                    _engine.Brightness = _settings.Brightness;
                    _engine.FadeTime = EffectiveFadeTime;
                    _engine.BeatDepth = LightEngine.DefaultBeatDepth;
                    _engine.BeatStyle = _settings.BeatStyle;
                    _engine.BeatSync = _settings.BeatSync;
                    _engine.Breathing = _settings.Breathing;
                }

                frame = _engine.Step(dt);
                var bpm = _engine.Bpm is { } tempo ? (int)Math.Round(tempo) : (int?)null;
                musicChanged = _engine.MusicDetected != _musicDetected || bpm != _bpm || _engine.ActiveBeatStyle != _activeBeatStyle;
                if (musicChanged)
                {
                    _musicDetected = _engine.MusicDetected;
                    _bpm = bpm;
                    _activeBeatStyle = _engine.ActiveBeatStyle;
                }
                acknowledgedLamp = _lampColor;
            }
            if (musicChanged) Notify();

            if (frame is { } color && color != acknowledgedLamp)
            {
                var writer = new DataWriter();
                writer.WriteBytes(PenlightProtocol.Encode(color));
                GattWriteResult result;
                var watch = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    result = await characteristic.WriteValueWithResultAsync(writer.DetachBuffer(), GattWriteOption.WriteWithResponse)
                        .AsTask().WaitAsync(OperationTimeout, token);
                }
                catch (TimeoutException)
                {
                    throw new LinkException(new LText(l => L10n.ReasonWriteTimeout(l)));
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    var msg = error.Message;
                    throw new LinkException(new LText(l => L10n.ReasonWriteFailed(msg, l)));
                }
                if (result.Status != GattCommunicationStatus.Success)
                {
                    var statusText = result.Status.ToString();
                    throw new LinkException(new LText(l => L10n.ReasonWriteFailed(statusText, l)));
                }
                lock (_syncLock)
                {
                    _bluetoothLatency.Add(watch.Elapsed.TotalMilliseconds);
                    _lampColor = color;
                    _colorsChanged = true;
                }
            }
            lock (_syncLock)
            {
                if (_colorsChanged && DateTime.UtcNow - _lastColorNotify >= ColorNotifyInterval)
                {
                    _colorsChanged = false;
                    _lastColorNotify = DateTime.UtcNow;
                    notifyColors = true;
                }
            }
            if (notifyColors) Notify();
            if (DateTime.UtcNow - _lastLatencyReport >= LatencyReportInterval)
            {
                _lastLatencyReport = DateTime.UtcNow;
                ReportLatency();
            }
            var remaining = RenderInterval - (DateTime.UtcNow - now);
            if (remaining > TimeSpan.Zero) await Task.Delay(remaining, token);
        }
    }

    /// <summary>Shows recent averages in the window and writes them to the log about every 30 seconds.</summary>
    private void ReportLatency()
    {
        (double Average, double Maximum)? capture;
        (double Average, double Maximum)? bluetooth;
        lock (_syncLock)
        {
            capture = _captureLatency.Drain();
            bluetooth = _bluetoothLatency.Drain();
        }
        if (capture == null && bluetooth == null) return;
        var interval = (int)LatencyReportInterval.TotalSeconds;
        var summary = new LText(l => L10n.LatencySummary(interval, capture, bluetooth, l));
        var shouldLog = _latencyReports++ % 6 == 0;
        _ui.Post(_ =>
        {
            _latencyText = summary;
            if (shouldLog) Log(summary.Resolve);
            Changed?.Invoke();
        }, null);
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus != BluetoothConnectionStatus.Disconnected) return;
        _ui.Post(_ =>
        {
            if (sender != _device || Phase != Phase.Syncing) return;
            _ = ReconnectAsync(new LText(l => L10n.ReasonDisconnected(l)));
        }, null);
    }

    /// <summary><paramref name="reason"/> null means the user pressed Stop.</summary>
    private async Task ShutDownAsync(LText? reason)
    {
        if (Phase is Phase.Idle or Phase.Stopping) return;
        Phase = Phase.Stopping;
        _statusText = new LText(l => L10n.StatusStopping(l));
        Notify();
        StopAudio();
        await StopLoopsAsync();
        ReleaseDevice();
        Phase = Phase.Idle;
        _latencyText = null;
        _siteLink.SetLampStatus("idle");
        if (_settings.ColorSource != ColorSource.Site)
        {
            StopSiteLink();
        }
        if (reason != null)
        {
            _errorText = reason;
            _statusText = new LText(l => L10n.StatusStoppedError(l));
            Log(l => L10n.LogErrorPrefix(reason.Resolve(l), l));
        }
        else
        {
            _statusText = new LText(l => L10n.StatusStoppedUser(l));
            Log(l => L10n.LogStoppedByUser(l));
        }
        Notify();
    }

    private void ReleaseDevice()
    {
        // Windows closes the BLE link once every GATT object for the device is released.
        _connectionRequest?.Dispose();
        _connectionRequest = null;
        _characteristic = null;
        _service?.Dispose();
        _service = null;
        if (_device != null)
        {
            _device.ConnectionStatusChanged -= OnConnectionStatusChanged;
            _device.Dispose();
            _device = null;
        }
    }

    private void Log(Func<AppLanguage, string> makeLine) => Log(makeLine(L10n.CurrentLanguage));

    private void Log(string line)
    {
        if (SynchronizationContext.Current != _ui)
        {
            _ui.Post(_ => Log(line), null);
            return;
        }
        var entry = $"{DateTime.Now:HH:mm:ss} {line}";
        _log.Add(entry);
        if (_log.Count > 200) _log.RemoveRange(0, _log.Count - 200);
        try { File.AppendAllText(_logPath, $"{DateTime.Now:yyyy-MM-dd} {entry}{Environment.NewLine}"); } catch (IOException) { }
    }

    private void Notify()
    {
        if (SynchronizationContext.Current == _ui)
        {
            Changed?.Invoke();
        }
        else
        {
            _ui.Post(_ => Changed?.Invoke(), null);
        }
    }

    public void Dispose()
    {
        StopScan();
        _syncCts?.Cancel();
        StopAudio();
        ReleaseDevice();
        _siteLink.Dispose();
    }

    private class SyncException(LText localizedMessage) : Exception(localizedMessage.ResolveCurrent())
    {
        public LText LocalizedMessage { get; } = localizedMessage;
    }

    /// <summary>A Bluetooth link failure while syncing; handled by reconnecting instead of stopping.</summary>
    private sealed class LinkException(LText localizedMessage) : SyncException(localizedMessage);
}

/// <summary>Collects millisecond measurements between reports.</summary>
internal sealed class LatencyMeter
{
    private double _total;
    private int _count;
    private double _maximum;

    public void Add(double milliseconds)
    {
        _total += milliseconds;
        _count++;
        _maximum = Math.Max(_maximum, milliseconds);
    }

    /// <summary>Returns the average and maximum since the last call (null if nothing was measured) and starts over.</summary>
    public (double Average, double Maximum)? Drain()
    {
        (double, double)? result = _count > 0 ? (_total / _count, _maximum) : null;
        (_total, _count, _maximum) = (0, 0, 0);
        return result;
    }
}
