namespace IToolkit.App;

using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
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
    private static readonly IActivityLogger _earlyLogger = new ActivityLogger();
    private bool _isFatalStartupError;

    /// <summary>
    /// Global application service provider.
    /// </summary>
    public static IServiceProvider Services { get; private set; } = null!;

    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private static IActivityLogger ResolveLogger()
    {
        try
        {
            return Services?.GetService<IActivityLogger>() ?? _earlyLogger;
        }
        catch
        {
            return _earlyLogger;
        }
    }

    private static void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception ex)
        {
            ResolveLogger().LogError("Application", "Unhandled domain exception", ex);
        }
        else
        {
            ResolveLogger().LogError("Application", $"Unhandled domain non-exception object: {e.ExceptionObject}");
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs args)
    {
        if (_isFatalStartupError)
        {
            args.Handled = true;
            return;
        }

        var logger = ResolveLogger();
        logger.LogError("Application", "Unhandled UI dispatcher exception", args.Exception);
        logger.LogError("DialogService", "Displayed unhandled exception error dialog.", args.Exception);
        MessageBox.Show(
            $"An unexpected error occurred:\n\n{args.Exception.Message}",
            "iToolKit Error",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        logger.LogInfo("DialogService", "User dismissed unhandled exception error dialog: [iToolKit Error] Result=OK");
        args.Handled = true;

        if (MainWindow == null || !MainWindow.IsVisible)
        {
            Environment.Exit(1);
        }
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs args)
    {
        ResolveLogger().LogError("TaskScheduler", "Unobserved task exception", args.Exception);
        args.SetObserved();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        System.Threading.SynchronizationContext.SetSynchronizationContext(
            new DispatcherSynchronizationContext(Dispatcher));
        ShutdownMode = ShutdownMode.OnMainWindowClose;

        ResolveLogger().LogInfo("Application", "iToolKit starting up.");

        try
        {
            var serviceCollection = new ServiceCollection();
            ConfigureServices(serviceCollection);
            Services = serviceCollection.BuildServiceProvider();

            // Enforce mandatory Administrator elevation at startup
            var elevation = Services.GetRequiredService<IElevationService>();
            var appLogger = ResolveLogger();
            if (!elevation.IsElevated())
            {
                appLogger.LogWarning("Application", "Administrator privileges required. Prompting user to elevate.");
                appLogger.LogError("Security", "Administrator privileges are required to run iToolKit.");
                appLogger.LogWarning("DialogService", "Displayed elevation required dialog prompt.");
                MessageBox.Show(
                    "iToolKit requires Administrator privileges to run.\nPlease launch iToolKit as Administrator.",
                    "iToolKit Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                appLogger.LogInfo("DialogService", "User dismissed elevation required dialog prompt: [iToolKit Error] Result=OK");
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
            _isFatalStartupError = true;
            var logger = ResolveLogger();
            logger.LogError("Application", "Fatal startup exception", ex);
            logger.LogError("DialogService", "Displayed fatal startup error dialog.", ex);
            MessageBox.Show(
                $"Failed to initialize iToolKit:\n\n{ex.Message}",
                "iToolKit Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            logger.LogInfo("DialogService", "User dismissed fatal startup error dialog: [iToolKit Error] Result=OK");
            Environment.Exit(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        ResolveLogger().LogInfo("Application", "iToolKit exiting.");
        try
        {
            Services?.GetService<TelemetryHeaderViewModel>()?.StopPolling();
            Services?.GetService<DashboardViewModel>()?.StopPolling();
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
