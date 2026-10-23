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
    private static readonly TimeSpan SampleInterval = TimeSpan.FromMilliseconds(200);
    /// <summary>Output frame rate; each frame writes only if the color changed and the previous write was acknowledged.</summary>
    private static readonly TimeSpan RenderInterval = TimeSpan.FromMilliseconds(50);
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan ScanDuration = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ReconnectWindow = TimeSpan.FromSeconds(30);

    private readonly SynchronizationContext _ui;
    private readonly string _settingsPath;
    private readonly string _effectsPath;
    private LightEngine _engine;
    private double _fadeTime = 0.6;
    private bool _breathing;
    private double _vibrance = 0.4;
    private double _minBrightness;
    private bool _sceneCuts = true;
    private bool _beatSync;
    private RectangleF? _region;
    private SystemAudioMonitor? _audio;
    private readonly string _logPath;
    private readonly List<LampInfo> _lamps = new();
    private readonly List<string> _log = new();
    private BluetoothLEAdvertisementWatcher? _watcher;
    private CancellationTokenSource? _scanCts;
    private CancellationTokenSource? _syncCts;
    private Task? _syncTask;
    private BluetoothLEDevice? _device;
    private GattDeviceService? _service;
    private GattCharacteristic? _characteristic;
    private ulong? _selectedAddress;

    public PenlightController()
    {
        _ui = SynchronizationContext.Current ?? throw new InvalidOperationException("Create the controller on the UI thread.");
        var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PenlightSync");
        Directory.CreateDirectory(dataDir);
        _settingsPath = Path.Combine(dataDir, "selected-lamp.txt");
        _logPath = Path.Combine(dataDir, "latest.log");
        _effectsPath = Path.Combine(dataDir, "effects.txt");
        try
        {
            if (File.Exists(_effectsPath))
            {
                foreach (var line in File.ReadAllLines(_effectsPath))
                {
                    var parts = line.Split('=', 2);
                    if (parts.Length != 2) continue;
                    var number = double.TryParse(parts[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed);
                    switch (parts[0])
                    {
                        case "fade" when number: _fadeTime = Math.Clamp(parsed, 0, 2); break;
                        case "vibrance" when number: _vibrance = Math.Clamp(parsed, 0, 1); break;
                        case "minBrightness" when number: _minBrightness = Math.Clamp(parsed, 0, 0.5); break;
                        case "breathing": _breathing = parts[1] == "1"; break;
                        case "sceneCuts": _sceneCuts = parts[1] == "1"; break;
                        case "beatSync": _beatSync = parts[1] == "1"; break;
                        case "region":
                            var values = parts[1].Split(',').Select(v => double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : -1).ToArray();
                            if (values.Length == 4 && values.All(v => v is >= 0 and <= 1) && values[2] > 0 && values[3] > 0)
                                _region = new RectangleF((float)values[0], (float)values[1], (float)values[2], (float)values[3]);
                            break;
                    }
                }
            }
            if (File.Exists(_settingsPath) && ulong.TryParse(File.ReadAllText(_settingsPath).Trim(), System.Globalization.NumberStyles.HexNumber, null, out var saved))
            {
                _selectedAddress = saved;
                _lamps.Add(new LampInfo { Address = saved, Remembered = true });
            }
        }
        catch (IOException) { }
        _engine = MakeEngine();
    }

    private LightEngine MakeEngine() => new(_fadeTime, _breathing)
    {
        Vibrance = _vibrance, MinBrightness = _minBrightness, SceneCuts = _sceneCuts, BeatSync = _beatSync,
    };

    public event Action? Changed;

    public IReadOnlyList<LampInfo> Lamps => _lamps;
    public IReadOnlyList<string> LogLines => _log;
    public Phase Phase { get; private set; } = Phase.Idle;
    public bool BluetoothReady { get; private set; }
    public bool IsScanning => _watcher != null;
    public Rgb? ScreenColor { get; private set; }
    public Rgb? LampColor { get; private set; }
    public string Status { get; private set; } = "正在檢查藍牙…";
    public string? ErrorMessage { get; private set; }
    /// <summary>True while beats in the system audio are shaping the light.</summary>
    public bool MusicDetected { get; private set; }
    /// <summary>The music's tempo (rounded BPM) while beat sync is shaping the light.</summary>
    public int? Bpm { get; private set; }
    public string LogPath => _logPath;
    public bool CanStart => BluetoothReady && Phase == Phase.Idle && _selectedAddress != null;

    /// <summary>Seconds to cover ~95% of a color change; 0 switches instantly. Applies live while syncing.</summary>
    public double FadeTime
    {
        get => _fadeTime;
        set
        {
            _fadeTime = Math.Clamp(value, 0, 2);
            _engine.FadeTime = _fadeTime;
            SaveEffects();
        }
    }

    public bool Breathing
    {
        get => _breathing;
        set
        {
            _breathing = value;
            _engine.Breathing = value;
            SaveEffects();
        }
    }

    /// <summary>0 leaves colors as sampled; 1 strongly boosts saturation. Applies from the next sample.</summary>
    public double Vibrance
    {
        get => _vibrance;
        set
        {
            _vibrance = Math.Clamp(value, 0, 1);
            _engine.Vibrance = _vibrance;
            SaveEffects();
        }
    }

    /// <summary>Lowest lamp brightness (0–0.5); 0 lets dark scenes go fully dark.</summary>
    public double MinBrightness
    {
        get => _minBrightness;
        set
        {
            _minBrightness = Math.Clamp(value, 0, 0.5);
            _engine.MinBrightness = _minBrightness;
            SaveEffects();
        }
    }

    public bool SceneCuts
    {
        get => _sceneCuts;
        set
        {
            _sceneCuts = value;
            _engine.SceneCuts = value;
            SaveEffects();
        }
    }

    /// <summary>Area of the primary screen to sample (normalized 0–1, top-left origin); null is the whole screen.</summary>
    public RectangleF? Region
    {
        get => _region;
        set
        {
            _region = value;
            SaveEffects();
            Log(value is { } r ? $"取色範圍改為框選區域（寬 {r.Width * 100:0}%、高 {r.Height * 100:0}%）。" : "取色範圍改回整個主螢幕。");
            if (Phase == Phase.Syncing) Status = SyncingStatus;
            Notify();
        }
    }

    private string SyncingStatus => _region == null ? "連動中：跟隨主螢幕平均色。" : "連動中：跟隨框選範圍的平均色。";

    /// <summary>Pulses the lamp on beats in the system audio; starts or stops listening live while syncing.</summary>
    public bool BeatSync
    {
        get => _beatSync;
        set
        {
            _beatSync = value;
            _engine.BeatSync = value;
            SaveEffects();
            if (Phase is not (Phase.Syncing or Phase.Reconnecting)) return;
            if (value) StartAudio(); else StopAudio();
            Notify();
        }
    }

    private void SaveEffects()
    {
        string Number(double value) => value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        string Flag(bool value) => value ? "1" : "0";
        var text = $"fade={Number(_fadeTime)}\nbreathing={Flag(_breathing)}\nvibrance={Number(_vibrance)}\n"
            + $"minBrightness={Number(_minBrightness)}\nsceneCuts={Flag(_sceneCuts)}\nbeatSync={Flag(_beatSync)}\n";
        if (_region is { } r) text += $"region={Number(r.X)},{Number(r.Y)},{Number(r.Width)},{Number(r.Height)}\n";
        try { File.WriteAllText(_effectsPath, text); } catch (IOException) { }
    }

    private void StartAudio()
    {
        if (_audio != null) return;
        try
        {
            _audio = new SystemAudioMonitor(_ui, (strength, bpm) => _engine.Beat(strength, bpm), AudioFailed);
            _audio.Start();
            Log("開始聆聽系統聲音（節拍）。");
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
        MusicDetected = false;
        Bpm = null;
    }

    /// <summary>Audio problems only turn off the beat effect; color sync keeps running.</summary>
    private void AudioFailed(string message)
    {
        StopAudio();
        ErrorMessage = $"無法聆聽系統聲音，節拍閃動已暫停：{message}";
        Log($"音訊錯誤：{message}");
        Notify();
    }

    public ulong? SelectedAddress
    {
        get => _selectedAddress;
        set
        {
            if (_selectedAddress == value || Phase != Phase.Idle) return;
            _selectedAddress = value;
            try { File.WriteAllText(_settingsPath, value?.ToString("X12") ?? ""); } catch (IOException) { }
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
                Status = "這台電腦沒有可用的低功耗藍牙（BLE）。";
            }
            else
            {
                var radio = await adapter.GetRadioAsync();
                if (radio != null && radio.State != RadioState.On)
                {
                    Status = "藍牙已關閉。請在 Windows 設定開啟藍牙後重新開啟本程式。";
                }
                else
                {
                    BluetoothReady = true;
                    Status = "藍牙就緒。按「掃描手燈」尋找手燈。";
                }
            }
        }
        catch (Exception error)
        {
            Status = $"無法使用藍牙：{error.Message}";
        }
        Notify();
    }

    // MARK: Scan

    public void StartScan()
    {
        if (!BluetoothReady || Phase != Phase.Idle || _watcher != null) return;
        ErrorMessage = null;
        _lamps.RemoveAll(lamp => !lamp.Remembered && lamp.Address != _selectedAddress);
        foreach (var lamp in _lamps) lamp.Rssi = null;
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.Received += OnAdvertisement;
        watcher.Stopped += (_, args) => _ui.Post(_ =>
        {
            if (_watcher != watcher) return;
            if (args.Error != BluetoothError.Success) ErrorMessage = $"掃描停止：{args.Error}";
            StopScan(finished: true);
        }, null);
        _watcher = watcher;
        watcher.Start();
        Status = "掃描中：請讓手燈進入配對模式（長按背面按鈕至藍燈閃爍）。";
        Log($"開始掃描 {PenlightProtocol.TargetName}。");
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
            Status = found == 0
                ? "沒有找到手燈。確認手燈在配對模式，且手機 App 已關閉。"
                : $"找到 {found} 支手燈，選擇後按「開始連動」。";
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
                Log($"找到手燈 {LampInfo.FormatAddress(address)}。");
            }
            else
            {
                lamp.Rssi = rssi;
            }
            if (_selectedAddress == null || _lamps.All(l => l.Address != _selectedAddress)) SelectedAddress = address;
            Notify();
        }, null);
    }

    // MARK: Connect and sync

    public async Task StartAsync()
    {
        if (!CanStart || _selectedAddress is not { } address) return;
        ErrorMessage = null;
        StopScan();
        Phase = Phase.Connecting;
        ScreenColor = null;
        LampColor = null;
        _engine = MakeEngine();
        MusicDetected = false;
        Status = "連線中…";
        Log($"連線 {PenlightProtocol.TargetName}（{LampInfo.FormatAddress(address)}）。");
        Notify();
        try
        {
            var characteristic = await ConnectAsync(address);
            if (Phase != Phase.Connecting) return; // Stopped while connecting.
            Phase = Phase.Syncing;
            Status = SyncingStatus;
            Log("連動開始。");
            if (_beatSync) StartAudio();
            Notify();
            BeginSync(characteristic);
        }
        catch (Exception error)
        {
            await ShutDownAsync(ConnectFailure(error));
        }
    }

    private static string ConnectFailure(Exception error) => error switch
    {
        TimeoutException => "連線逾時。請讓手燈重新進入配對模式後再試。",
        SyncException => error.Message,
        _ => $"無法連線：{error.Message}",
    };

    /// <summary>Opens the lamp and returns its control characteristic; the device is kept in <see cref="_device"/>.</summary>
    private async Task<GattCharacteristic> ConnectAsync(ulong address)
    {
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address).AsTask().WaitAsync(ConnectTimeout)
            ?? throw new SyncException("找不到選擇的手燈。請讓手燈進入配對模式後重新掃描。");
        _device = device;
        if (!string.IsNullOrEmpty(device.Name) && device.Name != PenlightProtocol.TargetName)
            throw new SyncException($"選擇的裝置名稱不是 {PenlightProtocol.TargetName}，已拒絕連線。");
        device.ConnectionStatusChanged += OnConnectionStatusChanged;

        var services = await device.GetGattServicesForUuidAsync(PenlightProtocol.ControlUuid, BluetoothCacheMode.Uncached)
            .AsTask().WaitAsync(ConnectTimeout);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            throw new SyncException($"連線失敗或手燈沒有控制服務 0000（{services.Status}）。請讓手燈重新進入配對模式後再試。");
        _service = services.Services[0];
        Log("已連線，探索控制特徵 0000。");

        var characteristics = await _service.GetCharacteristicsForUuidAsync(PenlightProtocol.ControlUuid, BluetoothCacheMode.Uncached)
            .AsTask().WaitAsync(ConnectTimeout);
        var characteristic = characteristics.Status == GattCommunicationStatus.Success
            ? characteristics.Characteristics.FirstOrDefault()
            : null;
        if (characteristic == null || !characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write))
            throw new SyncException("手燈的控制特徵 0000 不支援有回應寫入。");
        _characteristic = characteristic;
        return characteristic;
    }

    private void BeginSync(GattCharacteristic characteristic)
    {
        _syncCts = new CancellationTokenSource();
        var token = _syncCts.Token;
        _syncTask = Task.WhenAll(RunLoopAsync(SampleLoopAsync(token), token), RunLoopAsync(RenderLoopAsync(characteristic, token), token));
    }

    /// <summary>
    /// Stops the loops, drops the link and retries the connection until <see cref="ReconnectWindow"/> runs out.
    /// The engine (current color and effects) and beat listening carry over.
    /// </summary>
    private async Task ReconnectAsync(string reason)
    {
        if (Phase != Phase.Syncing || _selectedAddress is not { } address) return;
        Phase = Phase.Reconnecting;
        LampColor = null; // Rewrite the current color as soon as the link is back.
        Status = $"{reason}，正在自動重新連線（最多 {ReconnectWindow.TotalSeconds:0} 秒）…若一直連不上，請長按手燈背面按鈕進入配對模式。";
        Log($"{reason}，自動重新連線中。");
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
                Status = SyncingStatus;
                Log("已自動重新連線，繼續連動。");
                Notify();
                BeginSync(characteristic);
                return;
            }
            catch (Exception error)
            {
                if (Phase == Phase.Idle) ReleaseDevice();
                if (Phase != Phase.Reconnecting) return;
                ReleaseDevice();
                Log($"重新連線失敗：{ConnectFailure(error)}");
                await Task.Delay(TimeSpan.FromSeconds(1));
            }
        }
        if (Phase == Phase.Reconnecting)
            await ShutDownAsync($"{reason}，{ReconnectWindow.TotalSeconds:0} 秒內無法重新連上手燈。請讓手燈重新進入配對模式後再按「開始連動」。");
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

    /// <summary>Turns a loop failure into a shutdown with its message; cancellation is a normal stop.</summary>
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
            _ = ReconnectAsync(error.Message);
        }
        catch (SyncException error)
        {
            _ = ShutDownAsync(error.Message);
        }
        catch (Exception error)
        {
            _ = ShutDownAsync($"連動錯誤：{error.Message}");
        }
    }

    private async Task SampleLoopAsync(CancellationToken token)
    {
        using var sampler = new ScreenSampler();
        while (!token.IsCancellationRequested)
        {
            var started = DateTime.UtcNow;
            Rgb color;
            try
            {
                var region = _region;
                color = await Task.Run(() => sampler.Sample(region), token).WaitAsync(OperationTimeout, token);
            }
            catch (TimeoutException)
            {
                throw new SyncException("螢幕取樣超過 8 秒沒有完成，已停止連動。");
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                throw new SyncException($"螢幕取樣失敗：{error.Message}");
            }
            ScreenColor = color;
            _engine.SetTarget(color);
            Notify();
            var remaining = SampleInterval - (DateTime.UtcNow - started);
            if (remaining > TimeSpan.Zero) await Task.Delay(remaining, token);
        }
    }

    /// <summary>Advances the fade/breath effect and writes each frame that differs from the lamp's acknowledged color.</summary>
    private async Task RenderLoopAsync(GattCharacteristic characteristic, CancellationToken token)
    {
        var last = DateTime.UtcNow;
        while (!token.IsCancellationRequested)
        {
            var now = DateTime.UtcNow;
            var frame = _engine.Step((now - last).TotalSeconds);
            last = now;
            var bpm = _engine.Bpm is { } tempo ? (int)Math.Round(tempo) : (int?)null;
            if (_engine.MusicDetected != MusicDetected || bpm != Bpm)
            {
                MusicDetected = _engine.MusicDetected;
                Bpm = bpm;
                Notify();
            }
            if (frame is { } color && color != LampColor)
            {
                var writer = new DataWriter();
                writer.WriteBytes(PenlightProtocol.Encode(color));
                GattWriteResult result;
                try
                {
                    result = await characteristic.WriteValueWithResultAsync(writer.DetachBuffer(), GattWriteOption.WriteWithResponse)
                        .AsTask().WaitAsync(OperationTimeout, token);
                }
                catch (TimeoutException)
                {
                    throw new LinkException("藍牙寫入超過 8 秒沒有回應");
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    throw new LinkException($"藍牙寫入失敗（{error.Message}）");
                }
                if (result.Status != GattCommunicationStatus.Success)
                    throw new LinkException($"藍牙寫入失敗（{result.Status}）");
                LampColor = color;
                Notify();
            }
            var remaining = RenderInterval - (DateTime.UtcNow - now);
            if (remaining > TimeSpan.Zero) await Task.Delay(remaining, token);
        }
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus != BluetoothConnectionStatus.Disconnected) return;
        _ui.Post(_ =>
        {
            if (sender != _device || Phase != Phase.Syncing) return;
            _ = ReconnectAsync("手燈連線中斷");
        }, null);
    }

    /// <summary><paramref name="reason"/> null means the user pressed Stop.</summary>
    private async Task ShutDownAsync(string? reason)
    {
        if (Phase is Phase.Idle or Phase.Stopping) return;
        Phase = Phase.Stopping;
        Status = "停止中…";
        Notify();
        StopAudio();
        await StopLoopsAsync();
        ReleaseDevice();
        Phase = Phase.Idle;
        if (reason != null)
        {
            ErrorMessage = reason;
            Status = "連動已因錯誤停止。";
            Log($"錯誤：{reason}");
        }
        else
        {
            Status = "已停止連動。";
            Log("使用者停止連動。");
        }
        Notify();
    }

    private void ReleaseDevice()
    {
        // Windows closes the BLE link once every GATT object for the device is released.
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

    private void Log(string line)
    {
        var entry = $"{DateTime.Now:HH:mm:ss} {line}";
        _log.Add(entry);
        if (_log.Count > 200) _log.RemoveRange(0, _log.Count - 200);
        try { File.AppendAllText(_logPath, $"{DateTime.Now:yyyy-MM-dd} {entry}{Environment.NewLine}"); } catch (IOException) { }
    }

    private void Notify() => Changed?.Invoke();

    public void Dispose()
    {
        StopScan();
        _syncCts?.Cancel();
        StopAudio();
        ReleaseDevice();
    }

    private class SyncException(string message) : Exception(message);

    /// <summary>A Bluetooth link failure while syncing; handled by reconnecting instead of stopping.</summary>
    private sealed class LinkException(string message) : SyncException(message);
}
