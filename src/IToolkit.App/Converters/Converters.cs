namespace IToolkit.App.Converters;

using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using IToolkit.Core.Models;

public class LogLevelToBrushConverter : IValueConverter
{
    public static readonly LogLevelToBrushConverter Instance = new();

    private static readonly SolidColorBrush InfoBg = CreateFrozenBrush("#0C4A6E");
    private static readonly SolidColorBrush InfoFg = CreateFrozenBrush("#38BDF8");

    private static readonly SolidColorBrush SuccessBg = CreateFrozenBrush("#064E3B");
    private static readonly SolidColorBrush SuccessFg = CreateFrozenBrush("#4ADE80");

    private static readonly SolidColorBrush WarningBg = CreateFrozenBrush("#78350F");
    private static readonly SolidColorBrush WarningFg = CreateFrozenBrush("#FBBF24");

    private static readonly SolidColorBrush ErrorBg = CreateFrozenBrush("#7F1D1D");
    private static readonly SolidColorBrush ErrorFg = CreateFrozenBrush("#F87171");

    private static readonly SolidColorBrush DebugBg = CreateFrozenBrush("#1E293B");
    private static readonly SolidColorBrush DebugFg = CreateFrozenBrush("#94A3B8");

    private static SolidColorBrush CreateFrozenBrush(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not LogLevel level) return InfoFg;
        bool isBackground = string.Equals(parameter as string, "Background", StringComparison.OrdinalIgnoreCase);

        return level switch
        {
            LogLevel.Info => isBackground ? InfoBg : InfoFg,
            LogLevel.Success => isBackground ? SuccessBg : SuccessFg,
            LogLevel.Warning => isBackground ? WarningBg : WarningFg,
            LogLevel.Error => isBackground ? ErrorBg : ErrorFg,
            LogLevel.Debug => isBackground ? DebugBg : DebugFg,
            _ => isBackground ? DebugBg : InfoFg
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

public class BooleanToVisibilityConverter : IValueConverter
{
    public static readonly BooleanToVisibilityConverter Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        bool b = value is bool flag && flag;
        if (string.Equals(parameter as string, "Inverse", StringComparison.OrdinalIgnoreCase))
        {
            b = !b;
        }
        return b ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return value is Visibility v && v == Visibility.Visible;
    }
}
