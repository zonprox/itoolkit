namespace IToolkit.App;

using System;
using System.Windows;
using IToolkit.App.ViewModels;
using IToolkit.App.Views;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private ActivityLogWindow? _logWindow;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        DataContext = _viewModel;

        _viewModel.ActivityConsole.RequestOpen += ShowLogWindow;
        _viewModel.ActivityConsole.RequestClose += CloseLogWindow;

        Loaded += async (_, _) => await _viewModel.RunSystemScanAsync();
    }

    private void ShowLogWindow()
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }

        Dispatcher.Invoke(() =>
        {
            if (_logWindow == null || !_logWindow.IsLoaded)
            {
                _logWindow = new ActivityLogWindow
                {
                    Owner = this,
                    DataContext = _viewModel.ActivityConsole
                };
                _logWindow.Closed += (_, _) => _logWindow = null;
            }

            if (!_logWindow.IsVisible)
            {
                _logWindow.Show();
            }

            if (_logWindow.WindowState == WindowState.Minimized)
            {
                _logWindow.WindowState = WindowState.Normal;
            }

            _logWindow.Activate();
        });
    }

    private void CloseLogWindow()
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }

        Dispatcher.Invoke(() =>
        {
            _logWindow?.Close();
            _logWindow = null;
        });
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.ActivityConsole.RequestOpen -= ShowLogWindow;
        _viewModel.ActivityConsole.RequestClose -= CloseLogWindow;

        if (_logWindow != null)
        {
            _logWindow.Close();
            _logWindow = null;
        }

        _viewModel.TelemetryHeader.StopPolling();
        base.OnClosed(e);
        Application.Current?.Shutdown(0);
        Environment.Exit(0);
    }
}
