using System.Drawing;
using PenlightSync.Core;

namespace PenlightSync.Win;

internal sealed class MainForm : Form
{
    private readonly PenlightController _controller;
    private readonly Panel _screenSwatch = Swatch();
    private readonly Panel _lampSwatch = Swatch();
    private readonly Label _screenHex = Caption();
    private readonly Label _lampHex = Caption();
    private readonly Label _statusDot = new() { AutoSize = false, Size = new Size(12, 12), Margin = new Padding(0, 5, 6, 0) };
    private readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(360, 0) };
    private readonly Label _latency = new() { AutoSize = true, MaximumSize = new Size(380, 0), ForeColor = SystemColors.GrayText, Padding = new Padding(18, 0, 0, 4) };
    private readonly CheckBox _lowLatencyCheck = new() { Text = "低延遲模式（漸變最多 0.15 秒，燈光緊跟畫面）", AutoSize = true };
    private readonly ListView _lampList = new()
    {
        View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
        HeaderStyle = ColumnHeaderStyle.Nonclickable, Height = 96, Dock = DockStyle.Top,
    };
    private readonly Button _scanButton = new() { Text = "掃描手燈", AutoSize = true };
    // Track values are in steps: vibrance and brightness 0.05, fade 0.1 s.
    private readonly TrackBar _vibranceTrack = Track(20);
    private readonly TrackBar _brightnessTrack = Track(10);
    private readonly TrackBar _fadeTrack = Track(20);
    private readonly Label _vibranceValue = TrackValue();
    private readonly Label _brightnessValue = TrackValue();
    private readonly Label _fadeValue = TrackValue();
    private readonly Label _regionLabel = new() { AutoSize = false, Width = 200, Height = 28, TextAlign = ContentAlignment.MiddleLeft, ForeColor = SystemColors.GrayText };
    private readonly Button _regionButton = new() { Text = "框選範圍…", AutoSize = true };
    private readonly Button _wholeScreenButton = new() { Text = "整個螢幕", AutoSize = true };
    private readonly CheckBox _sceneCutsCheck = new() { Text = "換場快切（畫面大幅換色時加快漸變）", AutoSize = true };
    private readonly CheckBox _breathingCheck = new() { Text = "呼吸律動（畫面顏色穩定時，亮度緩慢起伏）", AutoSize = true };
    private readonly CheckBox _beatSyncCheck = new() { Text = "跟音樂節拍閃動（依 BPM 調整快慢）", AutoSize = true };
    private readonly Label _musicLabel = new() { Text = "♪ 偵測到節拍", AutoSize = true, ForeColor = Color.SeaGreen, Margin = new Padding(6, 5, 0, 0) };
    private readonly Button _startButton = new() { Text = "▶ 開始連動", Height = 40, Dock = DockStyle.Top };
    private readonly Label _error = new() { AutoSize = true, MaximumSize = new Size(380, 0), ForeColor = Color.Firebrick };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 8.5f) };
    private bool _updatingList;
    private string _lampListSignature = "";

    public MainForm()
    {
        Text = "Ado 手燈連動";
        Font = new Font("Microsoft JhengHei UI", 10f);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        ClientSize = new Size(420, 960);
        StartPosition = FormStartPosition.CenterScreen;

        _lampList.Columns.Add("手燈", 150);
        _lampList.Columns.Add("位址", 150);
        _lampList.Columns.Add("訊號", 70);

        var swatches = new TableLayoutPanel { ColumnCount = 3, RowCount = 1, Dock = DockStyle.Top, Height = 150 };
        swatches.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        swatches.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
        swatches.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        swatches.Controls.Add(SwatchColumn(_screenSwatch, "螢幕平均色", _screenHex), 0, 0);
        swatches.Controls.Add(new Label { Text = "→", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText }, 1, 0);
        swatches.Controls.Add(SwatchColumn(_lampSwatch, "手燈", _lampHex), 2, 0);

        var statusRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false, Padding = new Padding(0, 8, 0, 8) };
        statusRow.Controls.Add(_statusDot);
        statusRow.Controls.Add(_status);
        var latencyRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        latencyRow.Controls.Add(_latency);

        var lampBox = new GroupBox { Text = "手燈", Dock = DockStyle.Top, Height = 160, Padding = new Padding(8) };
        var scanRow = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(0, 6, 0, 0) };
        scanRow.Controls.Add(_scanButton);
        lampBox.Controls.Add(_lampList);
        lampBox.Controls.Add(scanRow);

        var regionBox = new GroupBox { Text = "取色範圍", Dock = DockStyle.Top, Height = 64, Padding = new Padding(8, 4, 8, 4) };
        var regionRow = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        regionRow.Controls.Add(_regionLabel);
        regionRow.Controls.Add(_wholeScreenButton);
        regionRow.Controls.Add(_regionButton);
        regionBox.Controls.Add(regionRow);

        var effectsBox = new GroupBox { Text = "燈光效果", Dock = DockStyle.Top, Height = 260, Padding = new Padding(8) };
        var beatRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false };
        beatRow.Controls.Add(_beatSyncCheck);
        beatRow.Controls.Add(_musicLabel);
        // Dock order: controls added later dock first, so add bottom-up.
        effectsBox.Controls.Add(beatRow);
        effectsBox.Controls.Add(CheckRow(_breathingCheck));
        effectsBox.Controls.Add(CheckRow(_sceneCutsCheck));
        effectsBox.Controls.Add(TrackRow("漸變時間", _fadeTrack, _fadeValue));
        effectsBox.Controls.Add(TrackRow("最低亮度", _brightnessTrack, _brightnessValue));
        effectsBox.Controls.Add(TrackRow("鮮豔度", _vibranceTrack, _vibranceValue));
        effectsBox.Controls.Add(CheckRow(_lowLatencyCheck));

        var errorRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 8, 0, 0) };
        errorRow.Controls.Add(_error);

        var logLabel = new Label { Text = "執行記錄", Dock = DockStyle.Top, Height = 26, TextAlign = ContentAlignment.BottomLeft, ForeColor = SystemColors.GrayText };
        var footer = new Label
        {
            Text = "取色時自動略過黑邊與字幕；只送出改變的顏色，畫面與聲音都不儲存或上傳。",
            Dock = DockStyle.Bottom, Height = 36, TextAlign = ContentAlignment.MiddleLeft, ForeColor = SystemColors.GrayText,
            Font = new Font(Font.FontFamily, 8.5f),
        };

        var root = new Panel { Dock = DockStyle.Fill, Padding = new Padding(20, 16, 20, 8) };
        // Dock order: controls added later dock first, so add bottom-up.
        root.Controls.Add(_log);
        root.Controls.Add(logLabel);
        root.Controls.Add(errorRow);
        root.Controls.Add(_startButton);
        root.Controls.Add(new Panel { Dock = DockStyle.Top, Height = 12 });
        root.Controls.Add(effectsBox);
        root.Controls.Add(new Panel { Dock = DockStyle.Top, Height = 8 });
        root.Controls.Add(regionBox);
        root.Controls.Add(new Panel { Dock = DockStyle.Top, Height = 8 });
        root.Controls.Add(lampBox);
        root.Controls.Add(latencyRow);
        root.Controls.Add(statusRow);
        root.Controls.Add(swatches);
        root.Controls.Add(footer);
        Controls.Add(root);

        _controller = new PenlightController();
        _controller.Changed += Render;
        _vibranceTrack.Value = (int)Math.Round(_controller.Vibrance * 20);
        _brightnessTrack.Value = (int)Math.Round(_controller.MinBrightness * 20);
        _fadeTrack.Value = (int)Math.Round(_controller.FadeTime * 10);
        _sceneCutsCheck.Checked = _controller.SceneCuts;
        _lowLatencyCheck.Checked = _controller.LowLatency;
        _breathingCheck.Checked = _controller.Breathing;
        _beatSyncCheck.Checked = _controller.BeatSync;
        _vibranceTrack.ValueChanged += (_, _) =>
        {
            _controller.Vibrance = _vibranceTrack.Value / 20.0;
            Render();
        };
        _brightnessTrack.ValueChanged += (_, _) =>
        {
            _controller.MinBrightness = _brightnessTrack.Value / 20.0;
            Render();
        };
        _fadeTrack.ValueChanged += (_, _) =>
        {
            _controller.FadeTime = _fadeTrack.Value / 10.0;
            Render();
        };
        _sceneCutsCheck.CheckedChanged += (_, _) => _controller.SceneCuts = _sceneCutsCheck.Checked;
        _lowLatencyCheck.CheckedChanged += (_, _) =>
        {
            _controller.LowLatency = _lowLatencyCheck.Checked;
            Render();
        };
        _breathingCheck.CheckedChanged += (_, _) => _controller.Breathing = _breathingCheck.Checked;
        _beatSyncCheck.CheckedChanged += (_, _) => _controller.BeatSync = _beatSyncCheck.Checked;
        // Keep the whole window on small or high-DPI screens; the log area absorbs the difference.
        Load += (_, _) =>
        {
            var available = Screen.FromControl(this).WorkingArea.Height;
            if (Height > available) Height = available;
        };
        _regionButton.Click += (_, _) =>
        {
            var screen = Screen.PrimaryScreen?.Bounds ?? Rectangle.Empty;
            if (screen.IsEmpty) return;
            using var selector = new RegionSelectorForm(screen);
            if (selector.ShowDialog(this) == DialogResult.OK && selector.Selection is { } selection) _controller.Region = selection;
        };
        _wholeScreenButton.Click += (_, _) => _controller.Region = null;
        _scanButton.Click += (_, _) =>
        {
            if (_controller.IsScanning) _controller.StopScan(); else _controller.StartScan();
        };
        _startButton.Click += async (_, _) =>
        {
            if (_controller.Phase == Phase.Idle) await _controller.StartAsync(); else await _controller.StopAsync();
        };
        _lampList.SelectedIndexChanged += (_, _) =>
        {
            if (_updatingList || _lampList.SelectedItems.Count == 0) return;
            _controller.SelectedAddress = (ulong)_lampList.SelectedItems[0].Tag!;
        };
        Shown += async (_, _) => await _controller.InitializeAsync();
        FormClosing += (_, _) => _controller.Dispose();
        AcceptButton = _startButton;
        Render();
    }

    private void Render()
    {
        SetSwatch(_screenSwatch, _screenHex, _controller.ScreenColor);
        SetSwatch(_lampSwatch, _lampHex, _controller.LampColor);
        _status.Text = _controller.Status;
        _vibranceValue.Text = $"{_controller.Vibrance * 100:0}%";
        _brightnessValue.Text = _controller.MinBrightness == 0 ? "關" : $"{_controller.MinBrightness * 100:0}%";
        _fadeValue.Text = _controller.FadeTime == 0 ? "立即" : $"{_controller.FadeTime:0.0} 秒";
        _musicLabel.Visible = _controller.MusicDetected;
        _latency.Text = _controller.LatencySummary ?? "";
        _latency.Visible = _controller.LatencySummary != null;
        _fadeTrack.Enabled = !_controller.LowLatency;
        _musicLabel.Text = _controller.Bpm is { } bpm ? $"♪ {bpm} BPM" : "♪ 偵測到節拍";
        _regionLabel.Text = _controller.Region is { } region ? $"框選範圍（寬 {region.Width * 100:0}%、高 {region.Height * 100:0}%）" : "整個主螢幕";
        _wholeScreenButton.Visible = _controller.Region != null;
        _statusDot.BackColor = _controller.Phase switch
        {
            Phase.Syncing => Color.SeaGreen,
            Phase.Connecting or Phase.Reconnecting or Phase.Stopping => Color.Orange,
            _ => _controller.ErrorMessage == null ? Color.Silver : Color.Firebrick,
        };
        _error.Text = _controller.ErrorMessage ?? "";
        _error.Visible = _controller.ErrorMessage != null;

        // Rebuild the list only when it changed: Render runs many times per second while syncing.
        string Signal(LampInfo lamp) => lamp.Rssi is { } rssi ? $"{rssi} dBm" : lamp.Remembered ? "上次使用" : "";
        var signature = string.Join("|", _controller.Lamps.Select(l => $"{l.Address}:{Signal(l)}")) + $"#{_controller.SelectedAddress}";
        if (signature != _lampListSignature)
        {
            _lampListSignature = signature;
            _updatingList = true;
            _lampList.BeginUpdate();
            _lampList.Items.Clear();
            foreach (var lamp in _controller.Lamps)
            {
                var item = new ListViewItem(new[] { PenlightProtocol.TargetName, lamp.AddressText, Signal(lamp) }) { Tag = lamp.Address };
                item.Selected = lamp.Address == _controller.SelectedAddress;
                _lampList.Items.Add(item);
            }
            _lampList.EndUpdate();
            _updatingList = false;
        }

        var idle = _controller.Phase == Phase.Idle;
        _lampList.Enabled = idle;
        _scanButton.Text = _controller.IsScanning ? "停止掃描" : "掃描手燈";
        _scanButton.Enabled = _controller.BluetoothReady && idle;
        _startButton.Text = idle ? "▶ 開始連動" : "■ 停止";
        _startButton.Enabled = idle ? _controller.CanStart : _controller.Phase != Phase.Stopping;

        var log = string.Join(Environment.NewLine, _controller.LogLines);
        if (_log.Text != log)
        {
            _log.Text = log;
            _log.SelectionStart = _log.TextLength;
            _log.ScrollToCaret();
        }
    }

    private static void SetSwatch(Panel swatch, Label hex, Rgb? color)
    {
        swatch.BackColor = color is { } c ? Color.FromArgb(c.Red, c.Green, c.Blue) : SystemColors.ControlLight;
        hex.Text = color?.ToString() ?? "—";
    }

    private static TrackBar Track(int maximum) =>
        new() { Minimum = 0, Maximum = maximum, TickFrequency = 5, SmallChange = 1, LargeChange = 5, Width = 220, AutoSize = false, Height = 32 };

    private static Label TrackValue() => new() { AutoSize = false, Width = 60, Height = 28, TextAlign = ContentAlignment.MiddleRight };

    private static Control TrackRow(string title, TrackBar track, Label value)
    {
        var row = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false };
        row.Controls.Add(new Label { Text = title, AutoSize = false, Width = 70, Height = 28, TextAlign = ContentAlignment.MiddleLeft });
        row.Controls.Add(track);
        row.Controls.Add(value);
        return row;
    }

    private static Control CheckRow(CheckBox check)
    {
        var row = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        row.Controls.Add(check);
        return row;
    }

    private static Panel Swatch() => new() { Size = new Size(150, 90), BorderStyle = BorderStyle.FixedSingle, Anchor = AnchorStyles.Top };

    private static Label Caption() => new() { AutoSize = false, Dock = DockStyle.Top, Height = 20, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText };

    private static Control SwatchColumn(Panel swatch, string title, Label hex)
    {
        var column = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        column.RowStyles.Add(new RowStyle(SizeType.Absolute, 96));
        column.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        column.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        swatch.Anchor = AnchorStyles.None;
        column.Controls.Add(swatch, 0, 0);
        column.Controls.Add(new Label { Text = title, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Microsoft JhengHei UI", 10f, FontStyle.Bold) }, 0, 1);
        column.Controls.Add(hex, 0, 2);
        return column;
    }
}
