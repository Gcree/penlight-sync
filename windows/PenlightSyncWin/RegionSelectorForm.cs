using System.Drawing;

namespace PenlightSync.Win;

/// <summary>
/// Full-screen overlay on the primary screen: drag a rectangle to pick the area to sample, Esc to cancel.
/// <see cref="Selection"/> is normalized to the screen (0–1, top-left origin) after a drag of at least 20 px.
/// </summary>
internal sealed class RegionSelectorForm : Form
{
    private Point? _start;
    private Rectangle _drag;

    public RegionSelectorForm(Rectangle screenBounds)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = screenBounds;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.Black;
        Opacity = 0.55;
        Cursor = Cursors.Cross;
        DoubleBuffered = true;
        KeyPreview = true;
    }

    public RectangleF? Selection { get; private set; }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        _start = e.Location;
        _drag = Rectangle.Empty;
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_start is not { } start) return;
        _drag = Rectangle.Intersect(ClientRectangle, Rectangle.FromLTRB(
            Math.Min(start.X, e.X), Math.Min(start.Y, e.Y), Math.Max(start.X, e.X), Math.Max(start.Y, e.Y)));
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        OnMouseMove(e);
        _start = null;
        if (_drag.Width >= 20 && _drag.Height >= 20)
        {
            Selection = new RectangleF(
                (float)_drag.X / ClientSize.Width, (float)_drag.Y / ClientSize.Height,
                (float)_drag.Width / ClientSize.Width, (float)_drag.Height / ClientSize.Height);
            DialogResult = DialogResult.OK;
        }
        else
        {
            DialogResult = DialogResult.Cancel;
        }
        Close();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode != Keys.Escape) return;
        DialogResult = DialogResult.Cancel;
        Close();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        const string hint = "拖曳框選影片所在的範圍，手燈只跟這塊畫面變色。按 Esc 取消。";
        using var font = new Font("Microsoft JhengHei UI", 18f, FontStyle.Bold);
        var size = TextRenderer.MeasureText(hint, font);
        TextRenderer.DrawText(e.Graphics, hint, font, new Point((ClientSize.Width - size.Width) / 2, 80), Color.White);
        if (_drag.Width <= 0 || _drag.Height <= 0) return;
        using var fill = new SolidBrush(Color.FromArgb(90, 90, 90));
        e.Graphics.FillRectangle(fill, _drag);
        using var outline = new Pen(Color.LimeGreen, 3);
        e.Graphics.DrawRectangle(outline, _drag);
    }
}
