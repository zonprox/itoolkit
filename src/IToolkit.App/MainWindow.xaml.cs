namespace IToolkit.App;

using System;
using System.Windows;
using System.Windows.Input;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        DataContext = _viewModel;
        SourceInitialized += OnSourceInitialized;
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.TelemetryHeader.StopPolling();
        base.OnClosed(e);
        Application.Current?.Shutdown(0);
        Environment.Exit(0);
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        // Apply native Windows 11 Mica material and dark mode titlebar
        MicaHelper.ApplyMica(this, isDark: true);
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        }
        else if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void Minimize_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void Maximize_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
