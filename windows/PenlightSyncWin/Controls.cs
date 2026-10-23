using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace PenlightSync.Win;

// Owner-drawn controls for the themed window. Each paints from Theme on every repaint, so a light/dark switch only needs Invalidate().

internal static class Shapes
{
    public static GraphicsPath Rounded(RectangleF bounds, float radius)
    {
        var path = new GraphicsPath();
        var d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        if (d <= 0)
        {
            path.AddRectangle(bounds);
            return path;
        }
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void Prepare(Graphics graphics, Color background)
    {
        graphics.Clear(background);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
    }
}

/// <summary>Rounded card surface; children should use Theme.Card as their background.</summary>
internal sealed class CardPanel : Panel
{
    public CardPanel()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        Padding = new Padding(16);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Background);
        using var path = Shapes.Rounded(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), LogicalToDeviceUnits(14));
        using var fill = new SolidBrush(Theme.Card);
        using var pen = new Pen(Theme.Border);
        e.Graphics.FillPath(fill, path);
        e.Graphics.DrawPath(pen, path);
    }
}

internal enum ButtonKind { Primary, Secondary, Danger, Chip }

/// <summary>Rounded button; keeps Button's keyboard, AcceptButton and accessibility behavior.</summary>
internal sealed class PillButton : Button
{
    private ButtonKind _kind;
    private bool _selected;
    private bool _hover;
    private bool _pressed;

    public PillButton(string text, ButtonKind kind = ButtonKind.Secondary)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Text = text;
        _kind = kind;
        Cursor = Cursors.Hand;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Height = 32;
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public ButtonKind Kind
    {
        get => _kind;
        set
        {
            if (_kind == value) return;
            _kind = value;
            Invalidate();
        }
    }

    /// <summary>For chips: the selected chip is filled.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Selected
    {
        get => _selected;
        set
        {
            if (_selected == value) return;
            _selected = value;
            AccessibleDescription = value ? "已選取" : null;
            Invalidate();
        }
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = _pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { _pressed = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var filled = _kind == ButtonKind.Primary || (_kind == ButtonKind.Chip && _selected);
        Color back, fore;
        Color? border = null;
        if (filled)
        {
            back = Theme.AccentFill;
            fore = Color.White;
        }
        else if (_kind == ButtonKind.Danger)
        {
            back = Theme.Mix(Theme.Danger, Theme.Card, 0.14);
            fore = Theme.Danger;
        }
        else
        {
            back = Theme.Field;
            fore = Theme.Text;
            border = Theme.Border;
        }
        if (!Enabled)
        {
            back = Theme.Mix(back, Theme.Card, 0.45);
            fore = Theme.Mix(fore, back, 0.5);
        }
        else if (_pressed) back = Theme.Mix(Color.Black, back, 0.12);
        else if (_hover) back = Theme.Mix(Theme.Dark ? Color.White : Color.Black, back, 0.06);

        var radius = _kind == ButtonKind.Chip ? (Height - 1) / 2f : LogicalToDeviceUnits(9);
        var bounds = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (var path = Shapes.Rounded(bounds, radius))
        using (var fill = new SolidBrush(back))
        {
            e.Graphics.FillPath(fill, path);
            if (border is { } line)
            {
                using var pen = new Pen(line);
                e.Graphics.DrawPath(pen, path);
            }
        }
        if (Focused && ShowFocusCues)
        {
            using var focus = Shapes.Rounded(RectangleF.Inflate(bounds, -2, -2), Math.Max(1, radius - 2));
            using var pen = new Pen(Theme.Accent, LogicalToDeviceUnits(2));
            e.Graphics.DrawPath(pen, focus);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fore,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
    }
}

/// <summary>On/off switch; still a CheckBox for keyboard and screen readers.</summary>
internal sealed class ToggleSwitch : CheckBox
{
    public ToggleSwitch(string accessibleName)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        AccessibleName = accessibleName;
        Text = "";
        AutoSize = false;
        Size = new Size(40, 22);
        Cursor = Cursors.Hand;
    }

    protected override void OnCheckedChanged(EventArgs e)
    {
        Invalidate();
        base.OnCheckedChanged(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var track = new RectangleF(1, 1, Width - 3, Height - 3);
        var on = Theme.Accent;
        var off = Theme.Dark ? Theme.Border : Theme.Mix(Color.Black, Theme.Card, 0.18);
        var back = Checked ? on : off;
        if (!Enabled) back = Theme.Mix(back, Theme.Card, 0.45);
        using (var path = Shapes.Rounded(track, track.Height / 2))
        using (var fill = new SolidBrush(back))
            e.Graphics.FillPath(fill, path);
        var knob = track.Height - LogicalToDeviceUnits(4);
        var x = Checked ? track.Right - knob - LogicalToDeviceUnits(2) : track.X + LogicalToDeviceUnits(2);
        using (var knobBrush = new SolidBrush(Color.White))
            e.Graphics.FillEllipse(knobBrush, x, track.Y + (track.Height - knob) / 2, knob, knob);
        if (Focused && ShowFocusCues)
        {
            using var pen = new Pen(Theme.Accent, LogicalToDeviceUnits(2));
            using var ring = Shapes.Rounded(RectangleF.Inflate(track, 0.5f, 0.5f), track.Height / 2);
            e.Graphics.DrawPath(pen, ring);
        }
    }
}

/// <summary>Horizontal slider without tick marks. Raises <see cref="ValueChanged"/> only for user input, so code can set Value freely.</summary>
internal sealed class ParamSlider : Control
{
    private double _value;
    private bool _dragging;

    public ParamSlider(string accessibleName, double minimum, double maximum, double step, Func<double, string> format)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
            | ControlStyles.Selectable | ControlStyles.ResizeRedraw, true);
        AccessibleName = accessibleName;
        AccessibleRole = AccessibleRole.Slider;
        Minimum = minimum;
        Maximum = maximum;
        Step = step;
        Format = format;
        TabStop = true;
        Height = 28;
        Cursor = Cursors.Hand;
    }

    public double Minimum { get; }
    public double Maximum { get; }
    public double Step { get; }
    public Func<double, string> Format { get; }
    public event EventHandler? ValueChanged;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public double Value
    {
        get => _value;
        set
        {
            var snapped = Snap(value);
            if (Math.Abs(snapped - _value) < 1e-9) return;
            _value = snapped;
            AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
            Invalidate();
        }
    }

    private double Snap(double value) => Math.Clamp(Math.Round(value / Step) * Step, Minimum, Maximum);

    private void SetByUser(double value)
    {
        var before = _value;
        Value = value;
        if (Math.Abs(before - _value) > 1e-9) ValueChanged?.Invoke(this, EventArgs.Empty);
    }

    private float ThumbSize => LogicalToDeviceUnits(16);

    private double ValueAt(int x)
    {
        var left = ThumbSize / 2;
        var width = Math.Max(1, Width - ThumbSize);
        return Minimum + (Maximum - Minimum) * Math.Clamp((x - left) / width, 0, 1);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || !Enabled) return;
        Focus();
        _dragging = true;
        Capture = true;
        SetByUser(ValueAt(e.X));
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_dragging) SetByUser(ValueAt(e.X));
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        _dragging = false;
        Capture = false;
    }

    protected override bool IsInputKey(Keys keyData) =>
        (keyData & Keys.KeyCode) is Keys.Left or Keys.Right or Keys.Up or Keys.Down || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        var change = e.KeyCode switch
        {
            Keys.Left or Keys.Down => -Step,
            Keys.Right or Keys.Up => Step,
            Keys.PageDown => -Step * 5,
            Keys.PageUp => Step * 5,
            _ => 0,
        };
        if (e.KeyCode == Keys.Home) SetByUser(Minimum);
        else if (e.KeyCode == Keys.End) SetByUser(Maximum);
        else if (change != 0) SetByUser(_value + change);
        else return;
        e.Handled = true;
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var thumb = ThumbSize;
        var trackHeight = LogicalToDeviceUnits(4);
        var track = new RectangleF(thumb / 2, (Height - trackHeight) / 2f, Width - thumb, trackHeight);
        var fraction = (float)((_value - Minimum) / (Maximum - Minimum));
        var accent = Enabled ? Theme.Accent : Theme.Mix(Theme.Accent, Theme.Card, 0.4);
        using (var path = Shapes.Rounded(track, trackHeight / 2f))
        using (var rest = new SolidBrush(Theme.Dark ? Theme.Border : Theme.Mix(Color.Black, Theme.Card, 0.12)))
            e.Graphics.FillPath(rest, path);
        if (fraction > 0)
        {
            using var filled = Shapes.Rounded(new RectangleF(track.X, track.Y, track.Width * fraction, track.Height), trackHeight / 2f);
            using var brush = new SolidBrush(accent);
            e.Graphics.FillPath(brush, filled);
        }
        var center = track.X + track.Width * fraction;
        var knob = new RectangleF(center - thumb / 2, (Height - thumb) / 2f, thumb, thumb);
        using (var knobBrush = new SolidBrush(Color.White))
        using (var edge = new Pen(Enabled ? accent : Theme.Border, LogicalToDeviceUnits(2)))
        {
            e.Graphics.FillEllipse(knobBrush, knob);
            e.Graphics.DrawEllipse(edge, RectangleF.Inflate(knob, -1, -1));
        }
        if (Focused && ShowFocusCues)
        {
            using var ring = new Pen(Theme.Mix(Theme.Accent, Theme.Card, 0.45), LogicalToDeviceUnits(3));
            e.Graphics.DrawEllipse(ring, RectangleF.Inflate(knob, 2, 2));
        }
    }

    protected override AccessibleObject CreateAccessibilityInstance() => new SliderAccessibleObject(this);

    private sealed class SliderAccessibleObject(ParamSlider owner) : ControlAccessibleObject(owner)
    {
        public override string? Value
        {
            get => owner.Format(owner.Value);
            set { }
        }
    }
}

/// <summary>Row of mutually exclusive tabs drawn as a segmented control.</summary>
internal sealed class SegmentedControl : Control
{
    private readonly string[] _items;
    private int _selected;

    public SegmentedControl(params string[] items)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
            | ControlStyles.Selectable | ControlStyles.ResizeRedraw, true);
        _items = items;
        AccessibleRole = AccessibleRole.PageTabList;
        AccessibleName = "設定分頁";
        TabStop = true;
        Height = 32;
        Cursor = Cursors.Hand;
    }

    public event EventHandler? SelectedIndexChanged;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int SelectedIndex
    {
        get => _selected;
        set
        {
            var index = Math.Clamp(value, 0, _items.Length - 1);
            if (index == _selected) return;
            _selected = index;
            AccessibleDescription = _items[index];
            Invalidate();
            SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();
        SelectedIndex = Math.Clamp(e.X * _items.Length / Math.Max(1, Width), 0, _items.Length - 1);
    }

    protected override bool IsInputKey(Keys keyData) =>
        (keyData & Keys.KeyCode) is Keys.Left or Keys.Right || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Left) SelectedIndex = (_selected + _items.Length - 1) % _items.Length;
        else if (e.KeyCode == Keys.Right) SelectedIndex = (_selected + 1) % _items.Length;
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var outer = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (var path = Shapes.Rounded(outer, LogicalToDeviceUnits(9)))
        using (var fill = new SolidBrush(Theme.Field))
            e.Graphics.FillPath(fill, path);
        var width = (Width - 4f) / _items.Length;
        for (var i = 0; i < _items.Length; i++)
        {
            var cell = new RectangleF(2 + i * width, 2, width, Height - 4);
            var selected = i == _selected;
            if (selected)
            {
                using var path = Shapes.Rounded(cell, LogicalToDeviceUnits(7));
                using var fill = new SolidBrush(Theme.AccentFill);
                e.Graphics.FillPath(fill, path);
                if (Focused && ShowFocusCues)
                {
                    using var pen = new Pen(Theme.Text, LogicalToDeviceUnits(1));
                    using var ring = Shapes.Rounded(RectangleF.Inflate(cell, -2, -2), LogicalToDeviceUnits(5));
                    e.Graphics.DrawPath(pen, ring);
                }
            }
            TextRenderer.DrawText(e.Graphics, _items[i], Font, Rectangle.Round(cell), selected ? Color.White : Theme.SecondaryText,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }
}

/// <summary>Rounded color swatch; the lamp swatch gets a soft halo in its own color.</summary>
internal sealed class ColorTile : Control
{
    private Color? _color;

    public ColorTile(bool glows)
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Glows = glows;
        Height = 84;
    }

    public bool Glows { get; }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color? Swatch
    {
        get => _color;
        set
        {
            if (_color == value) return;
            _color = value;
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var inset = Glows ? LogicalToDeviceUnits(4) : 0;
        var bounds = new RectangleF(inset + 0.5f, inset + 0.5f, Width - 2 * inset - 1.5f, Height - 2 * inset - 1.5f);
        var radius = LogicalToDeviceUnits(12);
        if (Glows && _color is { } halo)
        {
            for (var i = inset; i > 0; i--)
            {
                using var ring = Shapes.Rounded(RectangleF.Inflate(bounds, i, i), radius + i);
                using var pen = new Pen(Color.FromArgb(40 - 30 * i / inset, halo), 2);
                e.Graphics.DrawPath(pen, ring);
            }
        }
        using var path = Shapes.Rounded(bounds, radius);
        using (var fill = new SolidBrush(_color ?? Theme.Field))
            e.Graphics.FillPath(fill, path);
        using var border = new Pen(Theme.Border);
        e.Graphics.DrawPath(border, path);
    }
}

/// <summary>Small colored capsule with a dot, e.g. "連動中".</summary>
internal sealed class StatusPill : Control
{
    private Color _tone = Color.Gray;

    public StatusPill()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 24;
        Width = 96;
    }

    public void Show(string text, Color tone)
    {
        if (Text == text && _tone == tone) return;
        Text = text;
        _tone = tone;
        AccessibleName = text;
        Width = TextRenderer.MeasureText(text, Font).Width + LogicalToDeviceUnits(32);
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var bounds = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (var path = Shapes.Rounded(bounds, bounds.Height / 2))
        using (var fill = new SolidBrush(Theme.Mix(_tone, Theme.Card, 0.16)))
            e.Graphics.FillPath(fill, path);
        var dot = LogicalToDeviceUnits(7);
        using (var brush = new SolidBrush(_tone))
            e.Graphics.FillEllipse(brush, LogicalToDeviceUnits(10), (Height - dot) / 2f, dot, dot);
        var textBounds = new Rectangle(LogicalToDeviceUnits(22), 0, Width - LogicalToDeviceUnits(26), Height);
        TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, _tone, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

/// <summary>Outline of the main screen with the capture area highlighted.</summary>
internal sealed class RegionPreview : Control
{
    private RectangleF? _region;

    public RegionPreview()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 130;
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public RectangleF? Area
    {
        get => _region;
        set
        {
            if (_region == value) return;
            _region = value;
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Card);
        var screen = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 16, 10);
        var aspect = screen.Width / (float)Math.Max(1, screen.Height);
        var height = Height - 1f;
        var width = Math.Min(Width - 1f, height * aspect);
        height = width / aspect;
        var outer = new RectangleF((Width - width) / 2, (Height - height) / 2, width, height);
        using (var path = Shapes.Rounded(outer, LogicalToDeviceUnits(8)))
        using (var fill = new SolidBrush(Theme.Field))
        using (var pen = new Pen(Theme.Border))
        {
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
        var inner = RectangleF.Inflate(outer, -LogicalToDeviceUnits(6), -LogicalToDeviceUnits(6));
        var area = _region ?? new RectangleF(0, 0, 1, 1);
        var box = new RectangleF(inner.X + inner.Width * area.X, inner.Y + inner.Height * area.Y, inner.Width * area.Width, inner.Height * area.Height);
        using var highlight = Shapes.Rounded(box, LogicalToDeviceUnits(4));
        using var tint = new SolidBrush(Theme.Mix(Theme.Accent, Theme.Field, 0.22));
        using var edge = new Pen(Theme.Accent, LogicalToDeviceUnits(2));
        e.Graphics.FillPath(tint, highlight);
        e.Graphics.DrawPath(edge, highlight);
    }
}

/// <summary>Menu colors for the lamp picker.</summary>
internal sealed class ThemedMenuRenderer() : ToolStripProfessionalRenderer(new MenuColors())
{
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? Theme.Text : Theme.SecondaryText;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        var box = e.ImageRectangle;
        TextRenderer.DrawText(e.Graphics, "✓", e.Item.Font, box, Theme.Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    private sealed class MenuColors : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => Theme.Card;
        public override Color ImageMarginGradientBegin => Theme.Card;
        public override Color ImageMarginGradientMiddle => Theme.Card;
        public override Color ImageMarginGradientEnd => Theme.Card;
        public override Color MenuBorder => Theme.Border;
        public override Color MenuItemBorder => Theme.Accent;
        public override Color MenuItemSelected => Theme.Field;
        public override Color MenuItemSelectedGradientBegin => Theme.Field;
        public override Color MenuItemSelectedGradientEnd => Theme.Field;
        public override Color CheckBackground => Theme.Card;
        public override Color CheckSelectedBackground => Theme.Field;
        public override Color CheckPressedBackground => Theme.Field;
        public override Color SeparatorDark => Theme.Border;
        public override Color SeparatorLight => Theme.Border;
    }
}

/// <summary>Rounded panel tinted with a role color, e.g. the error message.</summary>
internal sealed class TintPanel : Panel
{
    public TintPanel()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
    }

    /// <summary>The fill, already mixed for the current theme.</summary>
    public static Color DangerFill => Theme.Mix(Theme.Danger, Theme.Background, 0.14);

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        Shapes.Prepare(e.Graphics, Parent?.BackColor ?? Theme.Background);
        using var path = Shapes.Rounded(new RectangleF(0, 0, Width - 1, Height - 1), LogicalToDeviceUnits(12));
        using var fill = new SolidBrush(DangerFill);
        e.Graphics.FillPath(fill, path);
    }
}
