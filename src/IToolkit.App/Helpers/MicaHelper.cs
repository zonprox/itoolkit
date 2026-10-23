namespace IToolkit.App.Helpers;

public static class MicaHelper
{
    public static bool ApplyMica(System.Windows.Window window, bool isDark = true) =>
        IToolkit.App.Native.MicaHelper.ApplyMica(window, isDark);
}
