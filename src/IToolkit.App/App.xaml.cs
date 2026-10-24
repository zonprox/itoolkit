namespace IToolkit.App;

using System;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;

/// <summary>
/// Interaction logic and DI composition root for App.xaml.
/// </summary>
public partial class App : Application
{
    /// <summary>
    /// Global application service provider.
    /// </summary>
    public static IServiceProvider Services { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        System.Threading.SynchronizationContext.SetSynchronizationContext(
            new System.Windows.Threading.DispatcherSynchronizationContext(Dispatcher));
        ShutdownMode = ShutdownMode.OnMainWindowClose;

        // Configure global unhandled exception handling to fail loud and capture crashes
        AppDomain.CurrentDomain.UnhandledException += (s, args) =>
        {
            if (args.ExceptionObject is Exception ex)
            {
                var logger = Services?.GetService<IActivityLogger>();
                logger?.LogError("Application", $"Unhandled domain exception: {ex.Message}");
            }
        };

        DispatcherUnhandledException += (s, args) =>
        {
            var logger = Services?.GetService<IActivityLogger>();
            logger?.LogError("Application", $"Unhandled UI dispatcher exception: {args.Exception.Message}");
            MessageBox.Show(
                $"An unexpected error occurred:\n\n{args.Exception.Message}",
                "iToolKit Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            args.Handled = true;

            if (MainWindow == null || !MainWindow.IsVisible)
            {
                Environment.Exit(1);
            }
        };

        try
        {
            var serviceCollection = new ServiceCollection();
            ConfigureServices(serviceCollection);
            Services = serviceCollection.BuildServiceProvider();

            // Enforce mandatory Administrator elevation at startup
            var elevation = Services.GetRequiredService<IElevationService>();
            var appLogger = Services.GetRequiredService<IActivityLogger>();
            if (!elevation.IsElevated())
            {
                appLogger.LogError("Security", "Administrator privileges are required to run iToolKit.");
                MessageBox.Show(
                    "iToolKit requires Administrator privileges to run.\nPlease launch iToolKit as Administrator.",
                    "iToolKit Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                Environment.Exit(1);
                return;
            }

            // Resolve Main Window first so ActivityConsoleViewModel receives startup log entries
            var mainWindow = Services.GetRequiredService<MainWindow>();
            MainWindow = mainWindow;

            appLogger.LogInfo("Application", "iToolKit initializing on Windows 64-bit (win-x64)...");
            appLogger.LogSuccess("Security", "Elevated as Administrator.");

            // Show Main Window
            mainWindow.Show();
        }
        catch (Exception ex)
        {
            var logger = Services?.GetService<IActivityLogger>();
            logger?.LogError("Application", $"Fatal startup exception: {ex.Message}");
            MessageBox.Show(
                $"Failed to initialize iToolKit:\n\n{ex.Message}",
                "iToolKit Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Environment.Exit(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            Services?.GetService<TelemetryHeaderViewModel>()?.StopPolling();
            if (Services is IDisposable disposable)
            {
                disposable.Dispose();
            }
        }
        catch
        {
            // Ignore disposal errors during shutdown
        }

        base.OnExit(e);
        Environment.Exit(e.ApplicationExitCode);
    }

    /// <summary>
    /// Configures Dependency Injection container with platform implementations, core services, and ViewModels.
    /// </summary>
    public static void ConfigureServices(IServiceCollection services)
    {
        ServiceRegistration.ConfigureServices(services);
        services.AddSingleton<MainWindow>();
    }
}
