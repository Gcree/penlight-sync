using System.Drawing;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace PenlightSync.Win;

/// <summary>Colors that follow the Windows app light/dark setting; same palette as the Mac app (the dark set matches the icon).</summary>
internal static class Theme
{
    public static bool Dark { get; private set; } = ReadDark();

    public static Color Background => Dark ? Hex(0x0E1224) : Hex(0xF3F4FA);
    public static Color Card => Dark ? Hex(0x161B33) : Hex(0xFFFFFF);
    public static Color Field => Dark ? Hex(0x0F1430) : Hex(0xEEF0F8);
    public static Color Border => Dark ? Hex(0x262D52) : Hex(0xDFE2EF);
    public static Color Text => Dark ? Hex(0xE8EAF6) : Hex(0x1B1E33);
    public static Color SecondaryText => Dark ? Hex(0x9AA3C7) : Hex(0x5B6080);
    /// <summary>Slider fills, toggles and selection outlines.</summary>
    public static Color Accent => Dark ? Hex(0x7C83FF) : Hex(0x4F55E0);
    /// <summary>Filled buttons and chips; white text on it stays above 4.5:1.</summary>
    public static Color AccentFill => Dark ? Hex(0x5B61F0) : Hex(0x4F55E0);
    public static Color Success => Dark ? Hex(0x5EE09A) : Hex(0x1E7F4A);
    public static Color Warning => Dark ? Hex(0xF5B94C) : Hex(0x9A5B00);
    public static Color Danger => Dark ? Hex(0xFF8FA3) : Hex(0xC62F45);

    /// <summary>Re-reads the Windows setting; true when it changed.</summary>
    public static bool Refresh()
    {
        var dark = ReadDark();
        if (dark == Dark) return false;
        Dark = dark;
        return true;
    }

    /// <summary><paramref name="color"/> laid over <paramref name="surface"/> at <paramref name="amount"/> (0–1).</summary>
    public static Color Mix(Color color, Color surface, double amount)
    {
        int Channel(int a, int b) => (int)Math.Round(b + (a - b) * amount);
        return Color.FromArgb(Channel(color.R, surface.R), Channel(color.G, surface.G), Channel(color.B, surface.B));
    }

    /// <summary>Dark title bar to match (Windows 10 20H1 and later; ignored elsewhere).</summary>
    public static void ApplyTitleBar(Form form)
    {
        if (!form.IsHandleCreated) return;
        var value = Dark ? 1 : 0;
        if (DwmSetWindowAttribute(form.Handle, 20, ref value, sizeof(int)) != 0)
            DwmSetWindowAttribute(form.Handle, 19, ref value, sizeof(int));
    }

    /// <summary>Dark scroll bars for a native control such as a multiline TextBox.</summary>
    public static void ApplyScrollBars(Control control)
    {
        if (control.IsHandleCreated) SetWindowTheme(control.Handle, Dark ? "DarkMode_Explorer" : "Explorer", null);
    }

    private static bool ReadDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    private static Color Hex(int rgb) => Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string? appName, string? idList);
}
