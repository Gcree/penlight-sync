using System.Diagnostics;
using System.Drawing;
using Microsoft.Win32;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>
/// Same layout as the Mac app: a live card (status, screen → lamp colors, lamp picker, start/stop) above a tabbed
/// settings card (Color / Motion / Capture Area / General). Colors follow the Windows light/dark app setting.
/// </summary>
internal sealed class MainForm : Form
{
    private const string FontName = "Microsoft JhengHei UI";

    private enum UpdateNoteKind { None, Checking, NewVersion, UpToDate, Failed }

    private readonly PenlightController _controller;
    private readonly UpdateChecker _updates = new();
    private readonly HashSet<Label> _secondaryLabels = new();
    private readonly List<SliderRow> _sliderRows = new();
    private readonly List<Action> _languageUpdaters = new();

    private readonly StatusPill _statusPill = new() { Anchor = AnchorStyles.Left };
    private readonly Label _latency;
    private readonly Label _status;
    private readonly ColorTile _screenTile = new(glows: false) { Dock = DockStyle.Top };
    private readonly ColorTile _lampTile = new(glows: true) { Dock = DockStyle.Top };
    private readonly Label _screenTitle;
    private readonly Label _screenSubtitle;
    private readonly Label _screenHex;
    private readonly Label _lampTitle;
    private readonly Label _lampHex;
    private readonly PillButton _lampButton = new("", ButtonKind.Secondary) { Dock = DockStyle.Fill };
    private readonly PillButton _scanButton = new("") { Dock = DockStyle.Fill };
    private readonly PillButton _startButton = new("", ButtonKind.Primary) { Dock = DockStyle.Top, Height = 42 };
    private readonly ContextMenuStrip _lampMenu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    private readonly ContextMenuStrip _languageMenu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    private readonly Panel _errorWrap = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 12, 0, 0), Visible = false };
    private readonly Label _error;

    private readonly SegmentedControl _tabs;
    private readonly SegmentedControl _sourcePicker;
    private readonly PillButton _openSiteButton = new("", ButtonKind.Chip) { Height = 30, Visible = false };
    private readonly List<Panel> _pages = new();
    private readonly List<PillButton> _presetChips = new();
    private readonly ParamSlider _fade;
    private readonly ToggleSwitch _lowLatency;
    private readonly ToggleSwitch _sceneCuts;
    private readonly ToggleSwitch _breathing;
    private readonly Label _beatStatus;
    private readonly List<PillButton> _beatStyleChips = new();
    private readonly Label _beatStyleSummary;
    private readonly RegionPreview _regionPreview = new() { Dock = DockStyle.Top };
    private readonly Label _regionLabel;
    private readonly PillButton _regionButton = new("") { Width = 145 };
    private readonly PillButton _wholeScreenButton = new("") { Width = 130 };
    private readonly PillButton _regionSiteButton = new("", ButtonKind.Chip) { Height = 28, Margin = new Padding(0, 4, 0, 0) };
    private readonly Panel _siteRegionNotice = new() { Dock = DockStyle.Top, Padding = new Padding(12, 10, 12, 10) };
    private readonly Panel _screenRegionPanel = new() { Dock = DockStyle.Top };
    private Panel _regionPage = null!;
    private readonly PillButton _languageButton = new("", ButtonKind.Secondary) { Dock = DockStyle.Fill };
    private readonly ToggleSwitch _checkOnLaunch;
    private readonly Label _updateNote;
    private UpdateNoteKind _updateNoteKind = UpdateNoteKind.None;
    private string? _updateNoteArg;
    private readonly PillButton _checkUpdatesButton = new("") { Dock = DockStyle.Fill };
    private readonly PillButton _logButton = new("") { Dock = DockStyle.Fill };
    private readonly TextBox _log = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Top, Height = 140,
        BorderStyle = BorderStyle.None, Visible = false, Font = new Font(FontFamily.GenericMonospace, 8.5f),
    };
    private readonly PillButton _resetButton = new("", ButtonKind.Danger) { Dock = DockStyle.Fill };
    private readonly Panel _generalPage;

    private sealed record SliderRow(ParamSlider Slider, Label Value, PillButton Reset, double Default, Func<double> Read);

    public MainForm()
    {
        _controller = new PenlightController();

        Text = L10n.AppTitle();
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font(FontName, 10f);
        // Sizes below are in 96-DPI units; the form scales them to the monitor's DPI.
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        ClientSize = new Size(480, 865);
        StartPosition = FormStartPosition.CenterScreen;
        _lampMenu.Renderer = new ThemedMenuRenderer();
        _lampMenu.Font = Font;
        _languageMenu.Renderer = new ThemedMenuRenderer();
        _languageMenu.Font = Font;

        _tabs = new SegmentedControl(L10n.TabNames()) { Dock = DockStyle.Top };
        _sourcePicker = new SegmentedControl(L10n.ColorSourceNames()) { Dock = DockStyle.Top };
        _fade = new ParamSlider(L10n.FadeTimeLabel(), 0, 2, 0.1, v => L10n.FadeTimeValue(v)) { Dock = DockStyle.Fill };
        _lowLatency = new ToggleSwitch(L10n.LowLatencyTitle());
        _sceneCuts = new ToggleSwitch(L10n.SceneCutsTitle());
        _breathing = new ToggleSwitch(L10n.BreathingTitle());
        _checkOnLaunch = new ToggleSwitch(L10n.CheckUpdatesTitle());

        _languageUpdaters.Add(() =>
        {
            Text = L10n.AppTitle();
            _lampButton.AccessibleName = L10n.SelectLampAccessibility();
            _tabs.AccessibleName = L10n.SettingsTabsAccessibility();
            _tabs.SetItems(L10n.TabNames());
            _sourcePicker.AccessibleName = L10n.ColorSourceHeading();
            _sourcePicker.SetItems(L10n.ColorSourceNames());
            _fade.AccessibleName = L10n.FadeTimeLabel();
            _lowLatency.AccessibleName = L10n.LowLatencyTitle();
            _sceneCuts.AccessibleName = L10n.SceneCutsTitle();
            _breathing.AccessibleName = L10n.BreathingTitle();
            _checkOnLaunch.AccessibleName = L10n.CheckUpdatesTitle();
            _languageButton.Text = $"{L10n.LanguageOptionName(_controller.LanguagePreference)}  ▾";
            _languageButton.AccessibleName = L10n.LanguageTitle();
            _regionButton.Text = L10n.SelectRegionButton();
            _wholeScreenButton.Text = L10n.WholeScreenButton();
            _checkUpdatesButton.Text = L10n.CheckNowButton();
            _logButton.Text = L10n.LogToggleButton(_log.Visible);
            _resetButton.Text = L10n.ResetButton();
            RefreshUpdateNote();
        });

        _latency = MakeLabel("", secondary: true, size: 8.5f);
        _latency.TextAlign = ContentAlignment.MiddleRight;
        _status = MakeLabel("", secondary: true);
        _status.Dock = DockStyle.Top;
        _status.Height = 46;
        _status.TextAlign = ContentAlignment.TopLeft;
        _screenTitle = MakeLabel(L10n.ScreenTile(), bold: true);
        _screenSubtitle = MakeLabel("", secondary: true, size: 8.5f);
        _screenHex = MakeLabel("—", secondary: true, size: 8.5f);
        _lampTitle = MakeLabel(L10n.LampTile(), bold: true);
        _lampHex = MakeLabel("—", secondary: true, size: 8.5f);
        _error = new Label { AutoSize = true, MaximumSize = new Size(420, 0), Margin = Padding.Empty };
        _beatStatus = MakeLabel("", secondary: true, size: 8.5f);
        _beatStatus.TextAlign = ContentAlignment.MiddleRight;
        _beatStyleSummary = MakeLabel("", secondary: true, size: 8.5f);
        _beatStyleSummary.Dock = DockStyle.Top;
        _beatStyleSummary.Height = 28;
        _beatStyleSummary.TextAlign = ContentAlignment.TopLeft;
        _regionLabel = MakeLabel("", secondary: false);
        _regionLabel.Dock = DockStyle.Top;
        _regionLabel.Height = 26;
        _updateNote = MakeLabel("", secondary: true, size: 8.5f);

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

        var footer = MakeLabel(L10n.FooterNotice(), secondary: true, size: 8.5f);
        footer.Dock = DockStyle.Bottom;
        footer.Height = 30;
        footer.TextAlign = ContentAlignment.MiddleCenter;
        _languageUpdaters.Add(() => footer.Text = L10n.FooterNotice());

        var root = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 16, 16, 4) };
        root.Controls.Add(settingsCard);
        root.Controls.Add(Gap(12));
        root.Controls.Add(_errorWrap);
        root.Controls.Add(liveCard);
        root.Controls.Add(footer);
        Controls.Add(root);

        ApplyLanguage();
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
        tiles.Controls.Add(LampTileColumn(_lampTile, _lampTitle, _lampHex), 2, 0);

        var lampRow = Columns(38, (_lampButton, 0), (_scanButton, 108));
        _scanButton.Margin = new Padding(8, 2, 0, 2);
        _lampButton.Margin = new Padding(0, 2, 0, 2);

        var card = new CardPanel { Dock = DockStyle.Top, Height = 342 };
        AddRows(card, header, _status, tiles, Gap(4), lampRow, Gap(10), _startButton);
        return card;
    }

    private static Control ScreenTileColumn(ColorTile tile, Label title, Label subtitle, Label hex)
    {
        var caption = Columns(24, (title, 0), (hex, 70));
        hex.TextAlign = ContentAlignment.MiddleRight;
        subtitle.TextAlign = ContentAlignment.TopLeft;
        subtitle.Height = 18;
        var column = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        AddRows(column, tile, Gap(4), caption, subtitle);
        return column;
    }

    private Control LampTileColumn(ColorTile tile, Label title, Label hex)
    {
        var caption = Columns(24, (title, 0), (hex, 70));
        hex.TextAlign = ContentAlignment.MiddleRight;
        var spacer = new Panel { Dock = DockStyle.Top, Height = 18 };
        _languageUpdaters.Add(() =>
        {
            var name = L10n.LampTile();
            title.Text = name;
            tile.AccessibleName = name;
        });
        var column = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        AddRows(column, tile, Gap(4), caption, spacer);
        return column;
    }

    private Panel BuildColorPage()
    {
        var sourceHeading = MakeLabel(L10n.ColorSourceHeading(), secondary: true, size: 8.5f);
        sourceHeading.Dock = DockStyle.Top;
        sourceHeading.Height = 22;
        _languageUpdaters.Add(() => sourceHeading.Text = L10n.ColorSourceHeading());

        var chips = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38, WrapContents = false, Padding = Padding.Empty };
        foreach (var preset in ColorPreset.All)
        {
            var captured = preset;
            var chip = new PillButton(L10n.PresetName(captured.Id), ButtonKind.Chip)
            {
                Height = 30,
                Margin = new Padding(0, 2, 6, 2),
                Tag = captured.Id,
            };
            chip.Width = TextRenderer.MeasureText(chip.Text, Font).Width + 24;
            chip.Click += (_, _) =>
            {
                _controller.Apply(captured);
                Render();
            };
            _languageUpdaters.Add(() =>
            {
                chip.Text = L10n.PresetName(captured.Id);
                chip.Width = TextRenderer.MeasureText(chip.Text, Font).Width + 24;
            });
            _presetChips.Add(chip);
            chips.Controls.Add(chip);
        }

        var heading = MakeLabel(L10n.StylePresetsHeading(), secondary: true, size: 8.5f);
        heading.Dock = DockStyle.Top;
        heading.Height = 22;
        _languageUpdaters.Add(() => heading.Text = L10n.StylePresetsHeading());

        var hint = MakeLabel(L10n.ColorSliderHint(), secondary: true, size: 8.5f);
        hint.Dock = DockStyle.Top;
        hint.Height = 32;
        _languageUpdaters.Add(() => hint.Text = L10n.ColorSliderHint());

        _openSiteButton.Click += (_, _) => _controller.OpenAdoGuideSite();

        return Page(sourceHeading, _sourcePicker, Gap(6), _openSiteButton, Gap(8), Separator(), Gap(4), heading, chips, Gap(6),
            Slider(() => L10n.VibranceLabel(), new ParamSlider(L10n.VibranceLabel(), 0, 1, 0.05, Percent), ColorPreset.Standard.Vibrance,
                () => _controller.Vibrance, v => _controller.Vibrance = v),
            Slider(() => L10n.MinBrightnessLabel(), new ParamSlider(L10n.MinBrightnessLabel(), 0, 0.5, 0.05, v => v < 0.001 ? L10n.OffLabel() : Percent(v)), ColorPreset.Standard.MinBrightness,
                () => _controller.MinBrightness, v => _controller.MinBrightness = v),
            Slider(() => L10n.BrightnessLabel(), new ParamSlider(L10n.BrightnessLabel(), 0.1, 1, 0.05, Percent), ColorPreset.Standard.Brightness,
                () => _controller.Brightness, v => _controller.Brightness = v),
            Slider(() => L10n.WarmthLabel(), new ParamSlider(L10n.WarmthLabel(), -0.5, 0.5, 0.05, v => L10n.WarmthValue(v)), ColorPreset.Standard.Warmth,
                () => _controller.Warmth, v => _controller.Warmth = v),
            Gap(6), hint);
    }

    private Panel BuildMotionPage()
    {
        var chips = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38, WrapContents = false, Padding = Padding.Empty };
        foreach (var style in BeatStyles.Choices.Cast<BeatStyle?>().Prepend(null))
        {
            var captured = style;
            var text = captured is { } s ? L10n.BeatStyleName(s) : L10n.OffLabel();
            var chip = new PillButton(text, ButtonKind.Chip) { Height = 30, Margin = new Padding(0, 2, 6, 2), Tag = captured };
            chip.Width = TextRenderer.MeasureText(chip.Text, Font).Width + 24;
            chip.Click += (_, _) =>
            {
                if (captured is { } chosen) _controller.BeatStyle = chosen;
                _controller.BeatSync = captured != null;
                Render();
            };
            _languageUpdaters.Add(() =>
            {
                chip.Text = captured is { } s2 ? L10n.BeatStyleName(s2) : L10n.OffLabel();
                chip.Width = TextRenderer.MeasureText(chip.Text, Font).Width + 24;
            });
            _beatStyleChips.Add(chip);
            chips.Controls.Add(chip);
        }

        var beatTitle = MakeLabel(L10n.BeatSyncTitle());
        _languageUpdaters.Add(() => beatTitle.Text = L10n.BeatSyncTitle());

        return Page(
            LabeledRow(() => L10n.LowLatencyTitle(), () => L10n.LowLatencySubtitle(), _lowLatency, 48),
            Slider(() => L10n.FadeTimeLabel(), _fade, 0.6, () => _controller.FadeTime, v => _controller.FadeTime = v),
            Separator(),
            LabeledRow(() => L10n.SceneCutsTitle(), () => L10n.SceneCutsSubtitle(), _sceneCuts, 48),
            LabeledRow(() => L10n.BreathingTitle(), () => L10n.BreathingSubtitle(), _breathing, 48),
            Separator(),
            Columns(30, (beatTitle, 0), (_beatStatus, 210)),
            chips, _beatStyleSummary);
    }

    private Panel BuildRegionPage()
    {
        var noticeBox = new TintPanel { Dock = DockStyle.Top, Height = 104, Padding = new Padding(12, 10, 12, 10) };
        var noticeLabel = MakeLabel(L10n.RegionSiteNotice(), secondary: true);
        noticeLabel.Dock = DockStyle.Top;
        noticeLabel.Height = 44;
        _languageUpdaters.Add(() => noticeLabel.Text = L10n.RegionSiteNotice());

        var siteButtonRow = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 34, WrapContents = false, Padding = Padding.Empty, Margin = Padding.Empty };
        _regionSiteButton.Margin = new Padding(0, 2, 0, 2);
        _regionSiteButton.Click += (_, _) => _controller.OpenAdoGuideSite();
        siteButtonRow.Controls.Add(_regionSiteButton);

        AddRows(noticeBox, noticeLabel, Gap(4), siteButtonRow);

        _siteRegionNotice.Controls.Add(noticeBox);
        _siteRegionNotice.Height = 124;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, WrapContents = false };
        _regionButton.Margin = new Padding(0, 4, 8, 4);
        _wholeScreenButton.Margin = new Padding(0, 4, 0, 4);
        buttons.Controls.Add(_regionButton);
        buttons.Controls.Add(_wholeScreenButton);
        var hint = MakeLabel(L10n.RegionHint(), secondary: true, size: 8.5f);
        hint.Dock = DockStyle.Top;
        hint.Height = 54;
        hint.TextAlign = ContentAlignment.TopLeft;
        _languageUpdaters.Add(() => hint.Text = L10n.RegionHint());

        AddRows(_screenRegionPanel, _regionPreview, Gap(8), _regionLabel, buttons, Gap(4), hint);
        _screenRegionPanel.Height = _regionPreview.Height + 8 + _regionLabel.Height + buttons.Height + 4 + hint.Height;

        _regionPage = Page(_siteRegionNotice, _screenRegionPanel);
        return _regionPage;
    }

    private Panel BuildGeneralPage()
    {
        var languageRow = LabeledRow(() => L10n.LanguageTitle(), () => L10n.LanguageSubtitle(), _languageButton, 165);
        var updateRow = LabeledRow(() => L10n.CheckUpdatesTitle(), () => L10n.CurrentVersionSubtitle(_updates.CurrentVersion), _checkOnLaunch, 48);
        var logRow = LabeledRow(() => L10n.LogTitle(), () => L10n.LogSubtitle(), _logButton, 132);
        var resetRow = LabeledRow(() => L10n.ResetTitle(), () => L10n.ResetSubtitle(), _resetButton, 122);
        return Page(
            languageRow,
            Separator(),
            updateRow,
            Columns(38, (_updateNote, 0), (_checkUpdatesButton, 118)),
            Separator(),
            logRow, _log,
            Separator(),
            resetRow);
    }

    private Control Slider(Func<string> getTitle, ParamSlider slider, double defaultValue, Func<double> read, Action<double> write)
    {
        slider.Dock = DockStyle.Fill;
        slider.Margin = new Padding(4, 3, 4, 3);
        var titleLabel = MakeLabel(getTitle());
        var value = MakeLabel("", size: 9.5f);
        value.TextAlign = ContentAlignment.MiddleRight;
        var reset = new PillButton("↺") { Dock = DockStyle.Fill, Margin = new Padding(4, 4, 0, 4), AccessibleName = L10n.ResetSliderAccessibility(getTitle()) };
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
        _languageUpdaters.Add(() =>
        {
            var title = getTitle();
            titleLabel.Text = title;
            slider.AccessibleName = title;
            reset.AccessibleName = L10n.ResetSliderAccessibility(title);
        });
        _sliderRows.Add(new SliderRow(slider, value, reset, defaultValue, read));
        return Columns(36, (titleLabel, 112), (slider, 0), (value, 70), (reset, 32));
    }

    /// <summary>Title with a smaller subtitle on the left and a control on the right.</summary>
    private Control LabeledRow(Func<string> getTitle, Func<string> getSubtitle, Control trailing, int trailingWidth)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Top, Height = 52, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, trailingWidth));
        row.RowStyles.Add(new RowStyle(SizeType.Percent, 52));
        row.RowStyles.Add(new RowStyle(SizeType.Percent, 48));
        var titleLabel = MakeLabel(getTitle());
        titleLabel.TextAlign = ContentAlignment.BottomLeft;
        var subtitleLabel = MakeLabel(getSubtitle(), secondary: true, size: 8.5f);
        subtitleLabel.TextAlign = ContentAlignment.TopLeft;
        _languageUpdaters.Add(() =>
        {
            titleLabel.Text = getTitle();
            subtitleLabel.Text = getSubtitle();
        });
        row.Controls.Add(titleLabel, 0, 0);
        row.Controls.Add(subtitleLabel, 0, 1);
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

    // MARK: - Events

    private void WireEvents()
    {
        _controller.Changed += Render;
        L10n.LanguageChanged += OnLanguageChanged;
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
            _logButton.Text = L10n.LogToggleButton(_log.Visible);
            _generalPage.Height += _log.Visible ? _log.Height : -_log.Height;
            Render();
        };
        _resetButton.Click += (_, _) =>
        {
            var reset = new TaskDialogButton(L10n.ResetButton());
            var page = new TaskDialogPage
            {
                Caption = Text,
                Heading = L10n.ResetConfirmHeading(),
                Text = L10n.ResetConfirmText(),
                Icon = TaskDialogIcon.Warning,
                Buttons = { reset, TaskDialogButton.Cancel },
                DefaultButton = TaskDialogButton.Cancel,
            };
            if (TaskDialog.ShowDialog(this, page) != reset) return;
            _controller.ResetEffects();
            Render();
        };
        _languageButton.Click += (_, _) =>
        {
            _languageMenu.Items.Clear();
            foreach (var pref in new[] { LanguagePreference.Auto, LanguagePreference.ZhHant, LanguagePreference.En, LanguagePreference.Ja })
            {
                var captured = pref;
                var item = new ToolStripMenuItem(L10n.LanguageOptionName(captured))
                {
                    Checked = captured == _controller.LanguagePreference,
                };
                item.Click += (_, _) =>
                {
                    _controller.LanguagePreference = captured;
                };
                _languageMenu.Items.Add(item);
            }
            _languageMenu.Show(_languageButton, new Point(0, _languageButton.Height));
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
        FormClosed += (_, _) =>
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            L10n.LanguageChanged -= OnLanguageChanged;
        };
        AcceptButton = _startButton;
    }

    private void OnLanguageChanged()
    {
        if (!IsHandleCreated) return;
        BeginInvoke((Action)(() =>
        {
            ApplyLanguage();
            Render();
        }));
    }

    private void ApplyLanguage()
    {
        foreach (var update in _languageUpdaters) update();
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
            _screenTitle.Text = L10n.SiteColorTileTitle();
            _screenTile.AccessibleName = L10n.SiteColorAccessibleName();
            _screenSubtitle.Text = L10n.SiteSongCaption(_controller.SiteSongTitle, _controller.SitePlayingState);
        }
        else
        {
            _screenTitle.Text = L10n.ScreenTile();
            _screenTile.AccessibleName = L10n.ScreenTile();
            _screenSubtitle.Text = "";
        }
        _screenTile.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _screenTitle.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _screenSubtitle.Cursor = isSite ? Cursors.Hand : Cursors.Default;
        _sourcePicker.SelectedIndex = isSite ? 1 : 0;
        _openSiteButton.Visible = isSite;
        var openSiteText = L10n.OpenSiteButton(_controller.SiteSongTitle);
        _openSiteButton.Text = openSiteText;
        _openSiteButton.Width = TextRenderer.MeasureText(openSiteText, Font).Width + 28;
        _regionSiteButton.Text = openSiteText;
        _regionSiteButton.Width = TextRenderer.MeasureText(openSiteText, Font).Width + 28;

        var failed = _controller.ErrorMessage != null;
        var (pill, tone) = L10n.StatusPill(_controller.Phase, failed);
        _statusPill.Show(pill, tone);
        _status.Text = _controller.Status;
        _latency.Text = _controller.LatencySummary ?? "";

        var idle = _controller.Phase == Phase.Idle;
        var selected = _controller.Lamps.FirstOrDefault(l => l.Address == _controller.SelectedAddress);
        _lampButton.Text = _controller.Lamps.Count == 0 ? L10n.NoLampFoundHint()
            : selected != null ? $"{LampLabel(selected)}  ▾" : L10n.SelectLampPrompt();
        _lampButton.Enabled = idle && _controller.Lamps.Count > 0;
        _scanButton.Text = L10n.ScanButton(_controller.IsScanning);
        _scanButton.Enabled = _controller.BluetoothReady && idle;
        _startButton.Kind = idle ? ButtonKind.Primary : ButtonKind.Danger;
        _startButton.Text = idle ? L10n.StartSyncButton() : L10n.StopSyncButton();
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
        foreach (var chip in _presetChips)
            chip.Selected = chip.Tag is ColorPresetId id && active?.Id == id;
        _fade.Enabled = !_controller.LowLatency;
        _lowLatency.Checked = _controller.LowLatency;
        _sceneCuts.Checked = _controller.SceneCuts;
        _breathing.Checked = _controller.Breathing;
        _checkOnLaunch.Checked = _updates.CheckOnLaunch;

        if (isSite)
        {
            _beatStatus.Text = _controller.Bpm is { } siteBpm && siteBpm > 0
                ? L10n.MusicStatusSiteBpm(siteBpm)
                : L10n.MusicStatusSiteWaiting();
            _beatStatus.ForeColor = _controller.Bpm is > 0 ? Theme.Success : Theme.SecondaryText;
        }
        else
        {
            _beatStatus.Text = !_controller.BeatSync ? ""
                : !_controller.MusicDetected ? L10n.MusicStatusWaitingMusic()
                : L10n.MusicStatusDetected(_controller.Bpm, _controller.ActiveBeatStyle, _controller.BeatStyle == BeatStyle.Auto);
            _beatStatus.ForeColor = _controller.MusicDetected ? Theme.Success : Theme.SecondaryText;
        }
        foreach (var chip in _beatStyleChips)
            chip.Selected = chip.Tag is BeatStyle style ? _controller.BeatSync && style == _controller.BeatStyle : !_controller.BeatSync;
        _beatStyleSummary.Text = isSite ? L10n.BeatSummarySite()
            : _controller.BeatSync ? L10n.BeatStyleSummary(_controller.BeatStyle) : L10n.BeatSummaryOff();

        _regionPreview.Area = _controller.Region;
        _regionLabel.Text = _controller.Region is { } region
            ? L10n.RegionCustomDesc(region.Width * 100, region.Height * 100)
            : L10n.RegionWholeScreenDesc();
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
        var detail = lamp.Rssi is { } rssi ? $"{rssi} dBm" : lamp.Remembered ? L10n.LampLastUsed() : "";
        return $"{PenlightProtocol.TargetName} · {lamp.AddressText}" + (detail.Length > 0 ? $" · {detail}" : "");
    }

    // MARK: - Updates

    private void SetUpdateNote(UpdateNoteKind kind, string? arg = null)
    {
        _updateNoteKind = kind;
        _updateNoteArg = arg;
        RefreshUpdateNote();
    }

    private void RefreshUpdateNote()
    {
        _updateNote.Text = _updateNoteKind switch
        {
            UpdateNoteKind.Checking => L10n.UpdateChecking(),
            UpdateNoteKind.NewVersion when _updateNoteArg != null => L10n.UpdateNewVersion(_updateNoteArg),
            UpdateNoteKind.UpToDate => L10n.UpdateLatest(_updates.CurrentVersion),
            UpdateNoteKind.Failed => L10n.UpdateFailed(),
            _ => L10n.UpdateDefaultNote(),
        };
    }

    /// <summary>A launch check stays silent unless there is a version the user has not skipped; a manual check always reports.</summary>
    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (!_checkUpdatesButton.Enabled) return;
        _checkUpdatesButton.Enabled = false;
        if (manual) SetUpdateNote(UpdateNoteKind.Checking);
        try
        {
            var newer = await _updates.FindNewerAsync();
            if (newer == null)
            {
                if (manual) SetUpdateNote(UpdateNoteKind.UpToDate);
                return;
            }
            SetUpdateNote(UpdateNoteKind.NewVersion, newer);
            if (manual || !_updates.IsSkipped(newer)) OfferUpdate(newer);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            if (manual) SetUpdateNote(UpdateNoteKind.Failed);
        }
        finally
        {
            _checkUpdatesButton.Enabled = true;
        }
    }

    private void OfferUpdate(string version)
    {
        var download = new TaskDialogButton(L10n.UpdateDownloadButton());
        var skip = new TaskDialogButton(L10n.UpdateSkipButton());
        var later = new TaskDialogButton(L10n.UpdateLaterButton());
        var page = new TaskDialogPage
        {
            Caption = Text,
            Heading = L10n.UpdateAlertTitle(version),
            Text = L10n.UpdateAlertMessageWin(_updates.CurrentVersion),
            Icon = TaskDialogIcon.Information,
            Buttons = { download, skip, later },
            DefaultButton = download,
        };
        var clicked = TaskDialog.ShowDialog(this, page);
        if (clicked == download) Process.Start(new ProcessStartInfo(UpdateChecker.DownloadPage) { UseShellExecute = true });
        else if (clicked == skip) _updates.Skip(version);
    }
}
