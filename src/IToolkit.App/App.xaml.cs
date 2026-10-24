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

            // Log application startup
            var appLogger = Services.GetRequiredService<IActivityLogger>();
            appLogger.LogInfo("Application", "iToolKit initializing on Windows 64-bit (win-x64)...");

            // Verify Administrator elevation status
            var elevation = Services.GetRequiredService<IElevationService>();
            if (!elevation.IsElevated())
            {
                appLogger.LogWarning("Security", "Running in standard user mode. Some remediation features require elevation.");
            }
            else
            {
                appLogger.LogSuccess("Security", "Elevated as Administrator.");
            }

            // Show Main Window
            var mainWindow = Services.GetRequiredService<MainWindow>();
            MainWindow = mainWindow;
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
