namespace IToolkit.App;

using System;
using System.Windows;
using IToolkit.App.ViewModels;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        DataContext = _viewModel;
        Loaded += async (_, _) => await _viewModel.RunSystemScanAsync();
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.TelemetryHeader.StopPolling();
        base.OnClosed(e);
        Application.Current?.Shutdown(0);
        Environment.Exit(0);
    }
}
