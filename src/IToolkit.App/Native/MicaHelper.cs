namespace IToolkit.App.Native;

using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

/// <summary>
/// Interop helper to apply Windows 11 Mica material and dark mode titlebar styling.
/// </summary>
public static class MicaHelper
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMWA_MICA_EFFECT = 1029;

    private const int DWMSBT_AUTO = 0;
    private const int DWMSBT_NONE = 1;
    private const int DWMSBT_MAINWINDOW = 2; // Mica
    private const int DWMSBT_TRANSIENTWINDOW = 3; // Acrylic
    private const int DWMSBT_TABBEDWINDOW = 4; // Mica Alt

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    /// <summary>
    /// Applies Windows 11 Mica and immersive dark mode attributes to the target window.
    /// Safely falls back on Windows 10 or non-Windows hosts.
    /// </summary>
    public static bool ApplyMica(Window window, bool isDark = true)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            var hwnd = new WindowInteropHelper(window).EnsureHandle();
            if (hwnd == IntPtr.Zero)
            {
                return false;
            }

            // Enable Immersive Dark Mode for window frame
            int darkMode = isDark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));

            var osVersion = Environment.OSVersion.Version;

            // Windows 11 22H2+ (Build 22621+) supports DWMWA_SYSTEMBACKDROP_TYPE
            if (osVersion.Build >= 22621)
            {
                int backdrop = DWMSBT_MAINWINDOW;
                return DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int)) == 0;
            }
            // Windows 11 21H2 (Build 22000) supports DWMWA_MICA_EFFECT
            else if (osVersion.Build >= 22000)
            {
                int mica = 1;
                return DwmSetWindowAttribute(hwnd, DWMWA_MICA_EFFECT, ref mica, sizeof(int)) == 0;
            }

            return false;
        }
        catch
        {
            return false;
        }
    }
}
