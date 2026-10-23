using PenlightSync.Core;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Storage.Streams;

namespace PenlightSync.Win;

internal enum Phase { Idle, Connecting, Syncing, Stopping }

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
/// Windows counterpart of the macOS PenlightController: same target-name check, write-with-response pacing
/// (at most 4 samples/writes per second, only changed colors) and 8-second watchdogs.
/// All public state is read and changed on the UI thread; <see cref="Changed"/> fires there too.
/// </summary>
internal sealed class PenlightController : IDisposable
{
    private static readonly TimeSpan SampleInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan ScanDuration = TimeSpan.FromSeconds(10);

    private readonly SynchronizationContext _ui;
    private readonly string _settingsPath;
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
        try
        {
            if (File.Exists(_settingsPath) && ulong.TryParse(File.ReadAllText(_settingsPath).Trim(), System.Globalization.NumberStyles.HexNumber, null, out var saved))
            {
                _selectedAddress = saved;
                _lamps.Add(new LampInfo { Address = saved, Remembered = true });
            }
        }
        catch (IOException) { }
    }

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
    public string LogPath => _logPath;
    public bool CanStart => BluetoothReady && Phase == Phase.Idle && _selectedAddress != null;

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
        Status = "連線中…";
        Log($"連線 {PenlightProtocol.TargetName}（{LampInfo.FormatAddress(address)}）。");
        Notify();
        try
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

            if (Phase != Phase.Connecting) return; // Stopped while connecting.
            Phase = Phase.Syncing;
            Status = "連動中：跟隨主螢幕主色（每秒最多 4 次）。";
            Log("連動開始。");
            Notify();
            _syncCts = new CancellationTokenSource();
            _syncTask = RunSyncLoopAsync(characteristic, _syncCts.Token);
        }
        catch (TimeoutException)
        {
            await ShutDownAsync("連線逾時。請讓手燈重新進入配對模式後再試。");
        }
        catch (SyncException error)
        {
            await ShutDownAsync(error.Message);
        }
        catch (Exception error)
        {
            await ShutDownAsync($"無法連線：{error.Message}");
        }
    }

    public Task StopAsync() => Phase is Phase.Connecting or Phase.Syncing ? ShutDownAsync(null) : Task.CompletedTask;

    private async Task RunSyncLoopAsync(GattCharacteristic characteristic, CancellationToken token)
    {
        using var sampler = new ScreenSampler();
        try
        {
            while (!token.IsCancellationRequested)
            {
                var started = DateTime.UtcNow;
                Rgb color;
                try
                {
                    color = await Task.Run(sampler.Sample, token).WaitAsync(OperationTimeout, token);
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
                if (color != LampColor)
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
                        throw new SyncException("藍牙寫入超過 8 秒沒有回應，已停止連動。請確認手燈仍在附近。");
                    }
                    if (result.Status != GattCommunicationStatus.Success)
                        throw new SyncException($"藍牙寫入失敗（{result.Status}）。");
                    LampColor = color;
                }
                Notify();
                var remaining = SampleInterval - (DateTime.UtcNow - started);
                if (remaining > TimeSpan.Zero) await Task.Delay(remaining, token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
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

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus != BluetoothConnectionStatus.Disconnected) return;
        _ui.Post(_ =>
        {
            if (sender != _device || Phase != Phase.Syncing) return;
            _ = ShutDownAsync("手燈連線中斷。請讓手燈重新進入配對模式後再按「開始連動」。");
        }, null);
    }

    /// <summary><paramref name="reason"/> null means the user pressed Stop.</summary>
    private async Task ShutDownAsync(string? reason)
    {
        if (Phase is Phase.Idle or Phase.Stopping) return;
        Phase = Phase.Stopping;
        Status = "停止中…";
        Notify();
        _syncCts?.Cancel();
        if (_syncTask is { } task && !task.IsCompleted)
        {
            // Bound the wait for an outstanding sample or write acknowledgement.
            await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(3)));
        }
        _syncCts?.Dispose();
        _syncCts = null;
        _syncTask = null;
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
        ReleaseDevice();
    }

    private sealed class SyncException(string message) : Exception(message);
}
