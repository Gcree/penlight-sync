using System.Diagnostics;
using System.Drawing;
using Microsoft.Win32;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>
/// Same layout as the Mac app: a live card (status, screen → lamp colors, lamp picker, start/stop) above a tabbed
/// settings card (色彩／動態／取色範圍／一般). Colors follow the Windows light/dark app setting.
/// </summary>
internal sealed class MainForm : Form
{
    private const string FontName = "Microsoft JhengHei UI";

    private readonly PenlightController _controller;
    private readonly UpdateChecker _updates = new();
    private readonly HashSet<Label> _secondaryLabels = new();
    private readonly List<SliderRow> _sliderRows = new();

    private readonly StatusPill _statusPill = new() { Anchor = AnchorStyles.Left };
    private readonly Label _latency;
    private readonly Label _status;
    private readonly ColorTile _screenTile = new(glows: false) { Dock = DockStyle.Top };
    private readonly ColorTile _lampTile = new(glows: true) { Dock = DockStyle.Top };
    private readonly Label _screenTitle;
    private readonly Label _screenSubtitle;
    private readonly Label _screenHex;
    private readonly Label _lampHex;
    private readonly PillButton _lampButton = new("", ButtonKind.Secondary) { Dock = DockStyle.Fill, AccessibleName = "選擇手燈" };
    private readonly PillButton _scanButton = new("掃描") { Dock = DockStyle.Fill };
    private readonly PillButton _startButton = new("開始連動", ButtonKind.Primary) { Dock = DockStyle.Top, Height = 42 };
    private readonly ContextMenuStrip _lampMenu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    private readonly Panel _errorWrap = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 12, 0, 0), Visible = false };
    private readonly Label _error;

    private readonly SegmentedControl _tabs = new("色彩", "動態", "取色範圍", "一般") { Dock = DockStyle.Top };
    private readonly SegmentedControl _sourcePicker = new("螢幕", "網站（Ado 應援預習）") { Dock = DockStyle.Top };
    private readonly PillButton _openSiteButton = new("開啟 Ado 應援預習網站 ↗", ButtonKind.Chip) { Height = 30, Visible = false };
    private readonly List<Panel> _pages = new();
    private readonly List<PillButton> _presetChips = new();
    private readonly ParamSlider _fade = new("漸變時間", 0, 2, 0.1, v => v < 0.05 ? "立即" : $"{v:0.0} 秒") { Dock = DockStyle.Fill };
    private readonly ToggleSwitch _lowLatency = new("低延遲模式");
    private readonly ToggleSwitch _sceneCuts = new("換場快切");
    private readonly ToggleSwitch _breathing = new("呼吸律動");
    private readonly Label _beatStatus;
    private readonly List<PillButton> _beatStyleChips = new();
    private readonly Label _beatStyleSummary;
    private readonly RegionPreview _regionPreview = new() { Dock = DockStyle.Top };
    private readonly Label _regionLabel;
    private readonly PillButton _regionButton = new("框選範圍…") { Width = 120 };
    private readonly PillButton _wholeScreenButton = new("整個螢幕") { Width = 110 };
    private readonly Panel _siteRegionNotice = new() { Dock = DockStyle.Top, Padding = new Padding(12, 10, 12, 10) };
    private readonly Panel _screenRegionPanel = new() { Dock = DockStyle.Top };
    private Panel _regionPage = null!;
    private readonly ToggleSwitch _checkOnLaunch = new("啟動時檢查更新");
    private readonly Label _updateNote;
    private readonly PillButton _checkUpdatesButton = new("立即檢查") { Dock = DockStyle.Fill };
    private readonly PillButton _logButton = new("顯示記錄 ▾") { Dock = DockStyle.Fill };
    private readonly TextBox _log = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Top, Height = 150,
        BorderStyle = BorderStyle.None, Visible = false, Font = new Font(FontFamily.GenericMonospace, 8.5f),
    };
    private readonly PillButton _resetButton = new("全部重設", ButtonKind.Danger) { Dock = DockStyle.Fill };
    private readonly Panel _generalPage;

    private sealed record SliderRow(ParamSlider Slider, Label Value, PillButton Reset, double Default, Func<double> Read);

    public MainForm()
    {
        Text = "Ado 手燈連動";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font(FontName, 10f);
        // Sizes below are in 96-DPI units; the form scales them to the monitor's DPI.
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        ClientSize = new Size(440, 800);
        StartPosition = FormStartPosition.CenterScreen;
        _lampMenu.Renderer = new ThemedMenuRenderer();
        _lampMenu.Font = Font;

        _controller = new PenlightController();

        _latency = MakeLabel("", secondary: true, size: 8.5f);
        _latency.TextAlign = ContentAlignment.MiddleRight;
        _status = MakeLabel("", secondary: true);
        _status.Dock = DockStyle.Top;
        _status.Height = 42;
        _status.TextAlign = ContentAlignment.TopLeft;
        _screenTitle = MakeLabel("螢幕", bold: true);
        _screenSubtitle = MakeLabel("", secondary: true, size: 8.5f);
        _screenHex = MakeLabel("—", secondary: true, size: 8.5f);
        _lampHex = MakeLabel("—", secondary: true, size: 8.5f);
        _error = new Label { AutoSize = true, MaximumSize = new Size(380, 0), Margin = Padding.Empty };
        _beatStatus = MakeLabel("", secondary: true, size: 8.5f);
        _beatStatus.TextAlign = ContentAlignment.MiddleRight;
        _beatStyleSummary = MakeLabel("", secondary: true, size: 8.5f);
        _beatStyleSummary.Dock = DockStyle.Top;
        _beatStyleSummary.Height = 24;
        _beatStyleSummary.TextAlign = ContentAlignment.TopLeft;
        _regionLabel = MakeLabel("", secondary: false);
        _regionLabel.Dock = DockStyle.Top;
        _regionLabel.Height = 26;
        _updateNote = MakeLabel("只讀取 GitHub 上的版本號，不傳送任何資料。", secondary: true, size: 8.5f);

        var liveCard = BuildLiveCard();
        var errorBox = new TintPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(12, 10, 12, 10) };
        errorBox.Controls.Add(_error);
        _errorWrap.Controls.Add(errorBox);

        var colorPage = BuildColorPage();
        var motionPage = BuildMotionPage();
        var regionPage = BuildRegionPage();
        _generalPage = BuildGeneralPage();
        _pages.AddRange(new[] { colorPage, motionPage, regionPage, _generalPage });

        var pageHost = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        for (var i = _pages.Count - 1; i >= 0; i--)
        {
            _pages[i].Visible = i == 0;
            pageHost.Controls.Add(_pages[i]);
        }
        var settingsCard = new CardPanel { Dock = DockStyle.Fill };
        // Docking: controls added later dock first, so the fill area goes in first and the top rows bottom-up.
        settingsCard.Controls.Add(pageHost);
        settingsCard.Controls.Add(Gap(12));
        settingsCard.Controls.Add(_tabs);

        var footer = MakeLabel("自動略過黑邊與字幕；畫面與聲音都不儲存或上傳。", secondary: true, size: 8.5f);
        footer.Dock = DockStyle.Bottom;
        footer.Height = 30;
        footer.TextAlign = ContentAlignment.MiddleCenter;

        var root = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 16, 16, 4) };
        root.Controls.Add(settingsCard);
        root.Controls.Add(Gap(12));
        root.Controls.Add(_errorWrap);
        root.Controls.Add(liveCard);
        root.Controls.Add(footer);
        Controls.Add(root);

        ApplyTheme();
        Render();
        WireEvents();
    }

    // MARK: - Layout

    private Control BuildLiveCard()
    {
        var header = Columns(30, (_statusPill, -1), (_latency, 0));
        _statusPill.Font = new Font(FontName, 8.5f, FontStyle.Bold);

        var tiles = new TableLayoutPanel { Dock = DockStyle.Top, Height = 138, ColumnCount = 3, RowCount = 1 };
        tiles.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        tiles.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 28));
        tiles.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        var arrow = MakeLabel("→", secondary: true, size: 12f);
        arrow.TextAlign = ContentAlignment.MiddleCenter;
        arrow.AccessibleRole = AccessibleRole.None;
        tiles.Controls.Add(ScreenTileColumn(_screenTile, _screenTitle, _screenSubtitle, _screenHex), 0, 0);
        tiles.Controls.Add(arrow, 1, 0);
        tiles.Controls.Add(LampTileColumn(_lampTile, "手燈", _lampHex), 2, 0);

        var lampRow = Columns(38, (_lampButton, 0), (_scanButton, 96));
        _scanButton.Margin = new Padding(8, 2, 0, 2);
        _lampButton.Margin = new Padding(0, 2, 0, 2);

        var card = new CardPanel { Dock = DockStyle.Top, Height = 338 };
        AddRows(card, header, _status, tiles, Gap(4), lampRow, Gap(10), _startButton);
        return card;
    }

    private Control ScreenTileColumn(ColorTile tile, Label title, Label subtitle, Label hex)
    {
        var caption = Columns(24, (title, 0), (hex, 70));
        hex.TextAlign = ContentAlignment.MiddleRight;
        subtitle.TextAlign = ContentAlignment.TopLeft;
        subtitle.Height = 18;
        tile.AccessibleName = "螢幕";
        var column = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        AddRows(column, tile, Gap(4), caption, subtitle);
        return column;
    }

    private Control LampTileColumn(ColorTile tile, string title, Label hex)
    {
        var caption = Columns(24, (MakeLabel(title, bold: true), 0), (hex, 70));
        hex.TextAlign = ContentAlignment.MiddleRight;
        var spacer = new Panel { Dock = DockStyle.Top, Height = 18 };
        tile.AccessibleName = title;
        var column = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        AddRows(column, tile, Gap(4), caption, spacer);
        return column;
    }

    private Panel BuildColorPage()
    {
        var sourceHeading = MakeLabel("取色來源", secondary: true, size: 8.5f);
        sourceHeading.Dock = DockStyle.Top;
        sourceHeading.Height = 22;

        var chips = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38, WrapContents = false, Padding = Padding.Empty };
        foreach (var preset in ColorPreset.All)
        {
            var chip = new PillButton(preset.Name, ButtonKind.Chip) { Height = 30, Margin = new Padding(0, 2, 6, 2) };
            chip.Width = TextRenderer.MeasureText(preset.Name, Font).Width + 28;
            chip.Click += (_, _) =>
            {
                _controller.Apply(preset);
                Render();
            };
            _presetChips.Add(chip);
            chips.Controls.Add(chip);
        }
        var heading = MakeLabel("風格預設", secondary: true, size: 8.5f);
        heading.Dock = DockStyle.Top;
        heading.Height = 22;
        var hint = MakeLabel("調整會立刻套用到手燈；點一下滑桿後可用方向鍵微調。", secondary: true, size: 8.5f);
        hint.Dock = DockStyle.Top;
        hint.Height = 26;

        _openSiteButton.Click += (_, _) => _controller.OpenAdoGuideSite();

        return Page(sourceHeading, _sourcePicker, Gap(6), _openSiteButton, Gap(8), Separator(), Gap(4), heading, chips, Gap(6),
            Slider("鮮豔度", new ParamSlider("鮮豔度", 0, 1, 0.05, Percent), ColorPreset.Standard.Vibrance,
                () => _controller.Vibrance, v => _controller.Vibrance = v),
            Slider("最低亮度", new ParamSlider("最低亮度", 0, 0.5, 0.05, v => v < 0.001 ? "關" : Percent(v)), ColorPreset.Standard.MinBrightness,
                () => _controller.MinBrightness, v => _controller.MinBrightness = v),
            Slider("整體亮度", new ParamSlider("整體亮度", 0.1, 1, 0.05, Percent), ColorPreset.Standard.Brightness,
                () => _controller.Brightness, v => _controller.Brightness = v),
            Slider("色溫", new ParamSlider("色溫", -0.5, 0.5, 0.05, WarmthText), ColorPreset.Standard.Warmth,
                () => _controller.Warmth, v => _controller.Warmth = v),
            Gap(6), hint);
    }

    private Panel BuildMotionPage()
    {
        // One row of chips: "關" turns beat sync off (Tag null), each style turns it on with that style.
        var chips = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38, WrapContents = false, Padding = Padding.Empty };
        foreach (var style in BeatStyles.Choices.Cast<BeatStyle?>().Prepend(null))
        {
            var chip = new PillButton(style?.Name() ?? "關", ButtonKind.Chip) { Height = 30, Margin = new Padding(0, 2, 6, 2), Tag = style };
            chip.Width = TextRenderer.MeasureText(chip.Text, Font).Width + 28;
            chip.Click += (_, _) =>
            {
                if (style is { } chosen) _controller.BeatStyle = chosen;
                _controller.BeatSync = style != null;
                Render();
            };
            _beatStyleChips.Add(chip);
            chips.Controls.Add(chip);
        }

        return Page(
            LabeledRow("低延遲模式", MakeLabel("漸變最多 0.15 秒，燈光緊跟畫面", secondary: true, size: 8.5f), _lowLatency, 48),
            Slider("漸變時間", _fade, 0.6, () => _controller.FadeTime, v => _controller.FadeTime = v),
            Separator(),
            LabeledRow("換場快切", MakeLabel("畫面大幅換色時加快漸變", secondary: true, size: 8.5f), _sceneCuts, 48),
            LabeledRow("呼吸律動", MakeLabel("沒有音樂時，顏色穩定就緩慢起伏", secondary: true, size: 8.5f), _breathing, 48),
            Separator(),
            Columns(30, (MakeLabel("跟音樂節拍"), 0), (_beatStatus, 200)),
            chips, _beatStyleSummary);
    }

    private Panel BuildRegionPage()
    {
        var noticeBox = new TintPanel { Dock = DockStyle.Top, Padding = new Padding(12, 10, 12, 10) };
        var noticeLabel = MakeLabel("網站模式不需要框選。顏色與拍點直接來自 Ado 應援預習網站。", secondary: true);
        noticeLabel.Dock = DockStyle.Top;
        noticeLabel.Height = 36;
        noticeBox.Controls.Add(noticeLabel);

        var regionSiteButton = new PillButton("開啟 Ado 應援預習網站 ↗", ButtonKind.Chip) { Height = 28, Margin = new Padding(0, 4, 0, 0) };
        regionSiteButton.Click += (_, _) => _controller.OpenAdoGuideSite();
        noticeBox.Controls.Add(regionSiteButton);

        _siteRegionNotice.Controls.Add(noticeBox);
        _siteRegionNotice.Height = 88;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, WrapContents = false };
        _regionButton.Margin = new Padding(0, 4, 8, 4);
        _wholeScreenButton.Margin = new Padding(0, 4, 0, 4);
        buttons.Controls.Add(_regionButton);
        buttons.Controls.Add(_wholeScreenButton);
        var hint = MakeLabel("影片沒有全螢幕時，框選影片所在區域可讓顏色更準。範圍固定在螢幕上的位置，移動影片視窗後請重新框選。",
            secondary: true, size: 8.5f);
        hint.Dock = DockStyle.Top;
        hint.Height = 46;
        hint.TextAlign = ContentAlignment.TopLeft;

        AddRows(_screenRegionPanel, _regionPreview, Gap(8), _regionLabel, buttons, Gap(4), hint);
        _screenRegionPanel.Height = _regionPreview.Height + 8 + _regionLabel.Height + buttons.Height + 4 + hint.Height;

        _regionPage = Page(_siteRegionNotice, _screenRegionPanel);
        return _regionPage;
    }

    private Panel BuildGeneralPage()
    {
        var logRow = LabeledRow("執行記錄", MakeLabel("連線、錯誤與延遲紀錄", secondary: true, size: 8.5f), _logButton, 120);
        var resetRow = LabeledRow("恢復預設效果", MakeLabel("色彩與動態全部恢復預設，手燈與範圍不變", secondary: true, size: 8.5f), _resetButton, 104);
        return Page(
            LabeledRow("啟動時檢查更新", MakeLabel($"目前版本 v{_updates.CurrentVersion}", secondary: true, size: 8.5f), _checkOnLaunch, 48),
            Columns(38, (_updateNote, 0), (_checkUpdatesButton, 100)),
            Separator(),
            logRow, _log,
            Separator(),
            resetRow);
    }

    private Control Slider(string title, ParamSlider slider, double defaultValue, Func<double> read, Action<double> write)
    {
        slider.Dock = DockStyle.Fill;
        slider.Margin = new Padding(4, 3, 4, 3);
        var value = MakeLabel("", size: 9.5f);
        value.TextAlign = ContentAlignment.MiddleRight;
        var reset = new PillButton("↺") { Dock = DockStyle.Fill, Margin = new Padding(4, 4, 0, 4), AccessibleName = $"將{title}恢復預設值" };
        slider.ValueChanged += (_, _) =>
        {
            write(slider.Value);
            Render();
        };
        reset.Click += (_, _) =>
        {
            write(defaultValue);
            Render();
        };
        _sliderRows.Add(new SliderRow(slider, value, reset, defaultValue, read));
        return Columns(36, (MakeLabel(title), 76), (slider, 0), (value, 58), (reset, 32));
    }

    /// <summary>Title with a smaller subtitle on the left and a control on the right.</summary>
    private Control LabeledRow(string title, Label subtitle, Control trailing, int trailingWidth)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Top, Height = 50, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, trailingWidth));
        row.RowStyles.Add(new RowStyle(SizeType.Percent, 54));
        row.RowStyles.Add(new RowStyle(SizeType.Percent, 46));
        var titleLabel = MakeLabel(title);
        titleLabel.TextAlign = ContentAlignment.BottomLeft;
        subtitle.TextAlign = ContentAlignment.TopLeft;
        row.Controls.Add(titleLabel, 0, 0);
        row.Controls.Add(subtitle, 0, 1);
        trailing.Anchor = trailing is ToggleSwitch ? AnchorStyles.Right : AnchorStyles.Left | AnchorStyles.Right;
        if (trailing is PillButton) trailing.Margin = new Padding(0, 9, 0, 9);
        row.Controls.Add(trailing, 1, 0);
        row.SetRowSpan(trailing, 2);
        return row;
    }

    /// <summary>One-row table; width 0 takes the remaining space, -1 sizes to the control.</summary>
    private static TableLayoutPanel Columns(int height, params (Control Control, int Width)[] cells)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Top, Height = height, ColumnCount = cells.Length, RowCount = 1, Margin = Padding.Empty };
        for (var i = 0; i < cells.Length; i++)
        {
            var (control, width) = cells[i];
            row.ColumnStyles.Add(width switch
            {
                0 => new ColumnStyle(SizeType.Percent, 100),
                -1 => new ColumnStyle(SizeType.AutoSize),
                _ => new ColumnStyle(SizeType.Absolute, width),
            });
            if (control.Dock == DockStyle.None && control.Anchor == (AnchorStyles.Top | AnchorStyles.Left)) control.Dock = DockStyle.Fill;
            row.Controls.Add(control, i, 0);
        }
        return row;
    }

    /// <summary>A settings page: rows stacked top to bottom, sized to fit them.</summary>
    private static Panel Page(params Control[] rows)
    {
        var page = new Panel { Dock = DockStyle.Top, Height = rows.Where(r => r.Visible || r is TextBox).Sum(r => r is TextBox { Visible: false } ? 0 : r.Height) };
        AddRows(page, rows);
        return page;
    }

    private static void AddRows(Control parent, params Control[] rows)
    {
        // Docking: controls added later dock first, so add bottom-up.
        for (var i = rows.Length - 1; i >= 0; i--)
        {
            if (rows[i].Dock == DockStyle.None) rows[i].Dock = DockStyle.Top;
            parent.Controls.Add(rows[i]);
        }
    }

    private static Panel Gap(int height) => new() { Dock = DockStyle.Top, Height = height };

    private static Control Separator()
    {
        var wrap = new Panel { Dock = DockStyle.Top, Height = 13, Padding = new Padding(0, 6, 0, 6) };
        wrap.Controls.Add(new Panel { Dock = DockStyle.Fill, Tag = "line" });
        return wrap;
    }

    private Label MakeLabel(string text, bool secondary = false, float size = 10f, bool bold = false)
    {
        var label = new Label
        {
            Text = text, AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = Padding.Empty,
            Font = new Font(FontName, size, bold ? FontStyle.Bold : FontStyle.Regular), AutoEllipsis = true,
        };
        if (secondary) _secondaryLabels.Add(label);
        return label;
    }

    private static string Percent(double value) => $"{Math.Round(value * 100):0}%";

    private static string WarmthText(double value)
    {
        var amount = (int)Math.Round(Math.Abs(value) * 100);
        return amount == 0 ? "中性" : value > 0 ? $"暖 {amount}" : $"冷 {amount}";
    }

    // MARK: - Events

    private void WireEvents()
    {
        _controller.Changed += Render;
        _sourcePicker.SelectedIndexChanged += (_, _) =>
        {
            _controller.ColorSource = _sourcePicker.SelectedIndex == 1 ? ColorSource.Site : ColorSource.Screen;
            Render();
        };
        _tabs.SelectedIndexChanged += (_, _) =>
        {
            for (var i = 0; i < _pages.Count; i++) _pages[i].Visible = i == _tabs.SelectedIndex;
        };
        _lowLatency.CheckedChanged += (_, _) =>
        {
            _controller.LowLatency = _lowLatency.Checked;
            Render();
        };
        _sceneCuts.CheckedChanged += (_, _) => _controller.SceneCuts = _sceneCuts.Checked;
        _breathing.CheckedChanged += (_, _) => _controller.Breathing = _breathing.Checked;
        _checkOnLaunch.CheckedChanged += (_, _) => _updates.CheckOnLaunch = _checkOnLaunch.Checked;
        _checkUpdatesButton.Click += async (_, _) => await CheckForUpdatesAsync(manual: true);
        _logButton.Click += (_, _) =>
        {
            _log.Visible = !_log.Visible;
            _logButton.Text = _log.Visible ? "隱藏記錄 ▴" : "顯示記錄 ▾";
            _generalPage.Height += _log.Visible ? _log.Height : -_log.Height;
            Render();
        };
        _resetButton.Click += (_, _) =>
        {
            var reset = new TaskDialogButton("全部重設");
            var page = new TaskDialogPage
            {
                Caption = Text,
                Heading = "要把色彩與動態設定全部恢復預設嗎？",
                Text = "手燈與取色範圍不會改變。",
                Icon = TaskDialogIcon.Warning,
                Buttons = { reset, TaskDialogButton.Cancel },
                DefaultButton = TaskDialogButton.Cancel,
            };
            if (TaskDialog.ShowDialog(this, page) != reset) return;
            _controller.ResetEffects();
            Render();
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
        _lampButton.Click += (_, _) =>
        {
            _lampMenu.Items.Clear();
            foreach (var lamp in _controller.Lamps)
            {
                var address = lamp.Address;
                var item = new ToolStripMenuItem(LampLabel(lamp)) { Checked = address == _controller.SelectedAddress };
                item.Click += (_, _) =>
                {
                    _controller.SelectedAddress = address;
                    Render();
                };
                _lampMenu.Items.Add(item);
            }
            _lampMenu.Show(_lampButton, new Point(0, _lampButton.Height));
        };
        Action openSiteIfSiteMode = () =>
        {
            if (_controller.ColorSource == ColorSource.Site) _controller.OpenAdoGuideSite();
        };
        _screenTile.Click += (_, _) => openSiteIfSiteMode();
        _screenTitle.Click += (_, _) => openSiteIfSiteMode();
        _screenSubtitle.Click += (_, _) => openSiteIfSiteMode();
        HandleCreated += (_, _) => Theme.ApplyTitleBar(this);
        _log.HandleCreated += (_, _) => Theme.ApplyScrollBars(_log);
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        // Keep the whole window on small or high-DPI screens; the settings area scrolls instead.
        Load += (_, _) =>
        {
            var available = Screen.FromControl(this).WorkingArea.Height;
            if (Height > available) Height = available;
        };
        Shown += async (_, _) => await _controller.InitializeAsync();
        Shown += async (_, _) =>
        {
            if (_updates.CheckOnLaunch) await CheckForUpdatesAsync(manual: false);
        };
        FormClosing += (_, _) => _controller.Dispose();
        FormClosed += (_, _) => SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        AcceptButton = _startButton;
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (!IsHandleCreated) return;
        BeginInvoke((Action)(() =>
        {
            if (!Theme.Refresh()) return;
            ApplyTheme();
            Render();
        }));
    }

    // MARK: - Theme and state

    private void ApplyTheme()
    {
        BackColor = Theme.Background;
        Recolor(this, Theme.Background);
        _log.BackColor = Theme.Field;
        _log.ForeColor = Theme.Text;
        Theme.ApplyTitleBar(this);
        Theme.ApplyScrollBars(_log);
        Invalidate(true);
    }

    private void Recolor(Control parent, Color surface)
    {
        foreach (Control child in parent.Controls)
        {
            var inner = child switch
            {
                CardPanel => Theme.Card,
                TintPanel => TintPanel.DangerFill,
                _ => surface,
            };
            if (child is not TextBox) child.BackColor = child is CardPanel or TintPanel ? surface : inner;
            if (child is Panel { Tag: "line" }) child.BackColor = Theme.Border;
            if (child is Label label) label.ForeColor = label == _error ? Theme.Danger : _secondaryLabels.Contains(label) ? Theme.SecondaryText : Theme.Text;
            Recolor(child, inner);
        }
    }

    private void Render()
    {
        _screenTile.Swatch = ToColor(_controller.ScreenColor);
        _lampTile.Swatch = ToColor(_controller.LampColor);
        _screenHex.Text = _controller.ScreenColor?.ToString() ?? "—";
        _lampHex.Text = _controller.LampColor?.ToString() ?? "—";

        var isSite = _controller.ColorSource == ColorSource.Site;
        if (isSite)
        {
            _screenTitle.Text = "網站顏色 ↗";
            _screenTile.AccessibleName = "網站顏色";
            _screenSubtitle.Text = string.IsNullOrEmpty(_controller.SiteSongTitle)
                ? _controller.SitePlayingState
                : $"〈{_controller.SiteSongTitle}〉{_controller.SitePlayingState}";
        }
        else
        {
            _screenTitle.Text = "螢幕";
            _screenTile.AccessibleName = "螢幕";
            _screenSubtitle.Text = "";
        }
        _screenTile.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _screenTitle.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _screenSubtitle.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _sourcePicker.SelectedIndex = isSite ? 1 : 0;
        _openSiteButton.Visible = isSite;
        _openSiteButton.Text = string.IsNullOrEmpty(_controller.SiteSongTitle)
            ? "開啟 Ado 應援預習網站 ↗"
            : $"在網站開啟〈{_controller.SiteSongTitle}〉 ↗";
        _openSiteButton.Width = TextRenderer.MeasureText(_openSiteButton.Text, Font).Width + 28;

        var failed = _controller.ErrorMessage != null;
        var (pill, tone) = _controller.Phase switch
        {
            Phase.Connecting => ("連線中", Theme.Warning),
            Phase.Syncing => ("連動中", Theme.Success),
            Phase.Reconnecting => ("重新連線中", Theme.Warning),
            Phase.Stopping => ("停止中", Theme.Warning),
            _ => failed ? ("已停止", Theme.Danger) : ("待機", Theme.SecondaryText),
        };
        _statusPill.Show(pill, tone);
        _status.Text = _controller.Status;
        _latency.Text = _controller.LatencySummary ?? "";

        var idle = _controller.Phase == Phase.Idle;
        var selected = _controller.Lamps.FirstOrDefault(l => l.Address == _controller.SelectedAddress);
        _lampButton.Text = _controller.Lamps.Count == 0 ? "尚未找到手燈，請按「掃描」"
            : selected != null ? $"{LampLabel(selected)}  ▾" : "選擇手燈  ▾";
        _lampButton.Enabled = idle && _controller.Lamps.Count > 0;
        _scanButton.Text = _controller.IsScanning ? "停止掃描" : "↻ 掃描";
        _scanButton.Enabled = _controller.BluetoothReady && idle;
        _startButton.Kind = idle ? ButtonKind.Primary : ButtonKind.Danger;
        _startButton.Text = idle ? "▶  開始連動" : "■  停止連動";
        _startButton.Enabled = idle ? _controller.CanStart : _controller.Phase != Phase.Stopping;

        _error.Text = _controller.ErrorMessage ?? "";
        _errorWrap.Visible = failed;

        foreach (var row in _sliderRows)
        {
            row.Slider.Value = row.Read();
            row.Value.Text = row.Slider.Format(row.Slider.Value);
            row.Reset.Visible = Math.Abs(row.Slider.Value - row.Default) >= row.Slider.Step / 2;
        }
        var active = _controller.ActivePreset;
        foreach (var chip in _presetChips) chip.Selected = active?.Name == chip.Text;
        _fade.Enabled = !_controller.LowLatency;
        _lowLatency.Checked = _controller.LowLatency;
        _sceneCuts.Checked = _controller.SceneCuts;
        _breathing.Checked = _controller.Breathing;
        _checkOnLaunch.Checked = _updates.CheckOnLaunch;

        if (isSite)
        {
            _beatStatus.Text = _controller.Bpm is { } siteBpm && siteBpm > 0
                ? $"{siteBpm} BPM（網站節拍）"
                : "等待網站節拍…";
            _beatStatus.ForeColor = _controller.Bpm is > 0 ? Theme.Success : Theme.SecondaryText;
        }
        else
        {
            _beatStatus.Text = !_controller.BeatSync ? ""
                : !_controller.MusicDetected ? "等待音樂…"
                : (_controller.Bpm is { } bpm ? $"偵測到 {bpm} BPM" : "偵測到節拍")
                    + (_controller.BeatStyle == BeatStyle.Auto && _controller.ActiveBeatStyle is { } picked ? $"・{picked.Name()}" : "");
            _beatStatus.ForeColor = _controller.MusicDetected ? Theme.Success : Theme.SecondaryText;
        }
        foreach (var chip in _beatStyleChips)
            chip.Selected = chip.Tag is BeatStyle style ? _controller.BeatSync && style == _controller.BeatStyle : !_controller.BeatSync;
        _beatStyleSummary.Text = isSite ? "由網站自動同步歌曲拍點與高潮閃爍"
            : _controller.BeatSync ? _controller.BeatStyle.Summary() : "只跟畫面顏色，不聽音樂";

        _regionPreview.Area = _controller.Region;
        _regionLabel.Text = _controller.Region is { } region ? $"目前：框選範圍（寬 {region.Width * 100:0}%、高 {region.Height * 100:0}%）" : "目前：整個主螢幕";
        _wholeScreenButton.Visible = _controller.Region != null;

        _siteRegionNotice.Visible = isSite;
        _screenRegionPanel.Visible = !isSite;
        _regionPage.Height = isSite ? _siteRegionNotice.Height : _screenRegionPanel.Height;

        if (_log.Visible)
        {
            var log = string.Join(Environment.NewLine, _controller.LogLines);
            if (_log.Text != log)
            {
                _log.Text = log;
                _log.SelectionStart = _log.TextLength;
                _log.ScrollToCaret();
            }
        }
    }

    private static Color? ToColor(Rgb? rgb) => rgb is { } c ? Color.FromArgb(c.Red, c.Green, c.Blue) : null;

    private static string LampLabel(LampInfo lamp)
    {
        var detail = lamp.Rssi is { } rssi ? $"{rssi} dBm" : lamp.Remembered ? "上次使用" : "";
        return $"{PenlightProtocol.TargetName} · {lamp.AddressText}" + (detail.Length > 0 ? $" · {detail}" : "");
    }

    // MARK: - Updates

    /// <summary>A launch check stays silent unless there is a version the user has not skipped; a manual check always reports.</summary>
    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (!_checkUpdatesButton.Enabled) return;
        _checkUpdatesButton.Enabled = false;
        if (manual) _updateNote.Text = "正在檢查…";
        try
        {
            var newer = await _updates.FindNewerAsync();
            if (newer == null)
            {
                if (manual) _updateNote.Text = $"已是最新版（v{_updates.CurrentVersion}）";
                return;
            }
            _updateNote.Text = $"有新版本 {newer}";
            if (manual || !_updates.IsSkipped(newer)) OfferUpdate(newer);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            if (manual) _updateNote.Text = "無法檢查更新，請確認網路連線。";
        }
        finally
        {
            _checkUpdatesButton.Enabled = true;
        }
    }

    private void OfferUpdate(string version)
    {
        var download = new TaskDialogButton("前往下載");
        var skip = new TaskDialogButton("略過這個版本");
        var later = new TaskDialogButton("稍後");
        var page = new TaskDialogPage
        {
            Caption = Text,
            Heading = $"有新版本 {version}",
            Text = $"目前是 v{_updates.CurrentVersion}。下載新版後解壓縮，取代舊的 PenlightSync.exe 即可。",
            Icon = TaskDialogIcon.Information,
            Buttons = { download, skip, later },
            DefaultButton = download,
        };
        var clicked = TaskDialog.ShowDialog(this, page);
        if (clicked == download) Process.Start(new ProcessStartInfo(UpdateChecker.DownloadPage) { UseShellExecute = true });
        else if (clicked == skip) _updates.Skip(version);
    }
}
