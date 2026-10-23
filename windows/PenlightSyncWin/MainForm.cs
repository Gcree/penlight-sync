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
    private readonly ListView _lampList = new()
    {
        View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
        HeaderStyle = ColumnHeaderStyle.Nonclickable, Height = 96, Dock = DockStyle.Top,
    };
    private readonly Button _scanButton = new() { Text = "掃描手燈", AutoSize = true };
    private readonly TrackBar _fadeTrack = new() { Minimum = 0, Maximum = 20, TickFrequency = 5, SmallChange = 1, LargeChange = 5, Width = 220, AutoSize = false, Height = 32 };
    private readonly Label _fadeValue = new() { AutoSize = false, Width = 60, Height = 28, TextAlign = ContentAlignment.MiddleRight };
    private readonly CheckBox _breathingCheck = new() { Text = "呼吸律動（畫面顏色穩定時，亮度緩慢起伏）", AutoSize = true };
    private readonly Button _startButton = new() { Text = "▶ 開始連動", Height = 40, Dock = DockStyle.Top };
    private readonly Label _error = new() { AutoSize = true, MaximumSize = new Size(380, 0), ForeColor = Color.Firebrick };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 8.5f) };
    private bool _updatingList;

    public MainForm()
    {
        Text = "Ado 手燈連動";
        Font = new Font("Microsoft JhengHei UI", 10f);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        ClientSize = new Size(420, 720);
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

        var lampBox = new GroupBox { Text = "手燈", Dock = DockStyle.Top, Height = 160, Padding = new Padding(8) };
        var scanRow = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(0, 6, 0, 0) };
        scanRow.Controls.Add(_scanButton);
        lampBox.Controls.Add(_lampList);
        lampBox.Controls.Add(scanRow);

        var effectsBox = new GroupBox { Text = "燈光效果", Dock = DockStyle.Top, Height = 100, Padding = new Padding(8) };
        var fadeRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = false };
        fadeRow.Controls.Add(new Label { Text = "漸變時間", AutoSize = false, Width = 70, Height = 28, TextAlign = ContentAlignment.MiddleLeft });
        fadeRow.Controls.Add(_fadeTrack);
        fadeRow.Controls.Add(_fadeValue);
        var breathingRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        breathingRow.Controls.Add(_breathingCheck);
        effectsBox.Controls.Add(breathingRow);
        effectsBox.Controls.Add(fadeRow);

        var errorRow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 8, 0, 0) };
        errorRow.Controls.Add(_error);

        var logLabel = new Label { Text = "執行記錄", Dock = DockStyle.Top, Height = 26, TextAlign = ContentAlignment.BottomLeft, ForeColor = SystemColors.GrayText };
        var footer = new Label
        {
            Text = "取色範圍是整個主螢幕；只送出改變的顏色，不儲存或上傳畫面。",
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
        root.Controls.Add(lampBox);
        root.Controls.Add(statusRow);
        root.Controls.Add(swatches);
        root.Controls.Add(footer);
        Controls.Add(root);

        _controller = new PenlightController();
        _controller.Changed += Render;
        _fadeTrack.Value = (int)Math.Round(_controller.FadeTime * 10);
        _breathingCheck.Checked = _controller.Breathing;
        _fadeTrack.ValueChanged += (_, _) =>
        {
            _controller.FadeTime = _fadeTrack.Value / 10.0;
            Render();
        };
        _breathingCheck.CheckedChanged += (_, _) => _controller.Breathing = _breathingCheck.Checked;
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
        _fadeValue.Text = _controller.FadeTime == 0 ? "立即" : $"{_controller.FadeTime:0.0} 秒";
        _statusDot.BackColor = _controller.Phase switch
        {
            Phase.Syncing => Color.SeaGreen,
            Phase.Connecting or Phase.Stopping => Color.Orange,
            _ => _controller.ErrorMessage == null ? Color.Silver : Color.Firebrick,
        };
        _error.Text = _controller.ErrorMessage ?? "";
        _error.Visible = _controller.ErrorMessage != null;

        _updatingList = true;
        _lampList.BeginUpdate();
        _lampList.Items.Clear();
        foreach (var lamp in _controller.Lamps)
        {
            var signal = lamp.Rssi is { } rssi ? $"{rssi} dBm" : lamp.Remembered ? "上次使用" : "";
            var item = new ListViewItem(new[] { PenlightProtocol.TargetName, lamp.AddressText, signal }) { Tag = lamp.Address };
            item.Selected = lamp.Address == _controller.SelectedAddress;
            _lampList.Items.Add(item);
        }
        _lampList.EndUpdate();
        _updatingList = false;

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
