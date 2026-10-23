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
        };

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
        mainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (Services is IDisposable disposable)
        {
            disposable.Dispose();
        }

        base.OnExit(e);
    }

    /// <summary>
    /// Configures Dependency Injection container with platform implementations, core services, and ViewModels.
    /// </summary>
    public static void ConfigureServices(IServiceCollection services)
    {
        // ---------------------------------------------------------
        // 1. Native Platform Abstractions
        // ---------------------------------------------------------
        services.AddSingleton<IActivityLogger, ActivityLogger>();
        services.AddSingleton<IRegistryService, WindowsRegistryService>();
        services.AddSingleton<IProcessRunner, WindowsProcessRunner>();
        services.AddSingleton<IFileSystemService, WindowsFileSystemService>();
        services.AddSingleton<INetworkService, WindowsNetworkService>();
        services.AddSingleton<IWmiService, WindowsWmiService>();
        services.AddSingleton<ISystemTelemetryService, WindowsTelemetryService>();
        services.AddSingleton<IElevationService, ElevationGuard>();

        // ---------------------------------------------------------
        // 2. Core Safety Engines
        // ---------------------------------------------------------
        services.AddSingleton<ElevationGuard>();
        services.AddSingleton<AtomicRegistryEngine>();
        services.AddSingleton<AtomicRegistryService>();
        services.AddSingleton<ProcessLockGuard>();
        services.AddSingleton<ResourceGuard>();

        // ---------------------------------------------------------
        // 3. Operational Domain Services (5 Pillars)
        // ---------------------------------------------------------
        // Pillar 1: System Health & Maintenance
        services.AddSingleton<ISystemHealthService, SystemHealthService>();
        services.AddSingleton<SystemHealthService>();

        // Pillar 2: Office & Outlook Productivity Suite
        services.AddSingleton<IOfficeSuiteService, OfficeSuiteService>();
        services.AddSingleton<OfficeSuiteService>();
        services.AddSingleton<IOutlookService, OutlookService>();
        services.AddSingleton<OutlookService>();

        // Pillar 3: Connectivity & Print Subsystem
        services.AddSingleton<IConnectivityService, ConnectivityService>();
        services.AddSingleton<ConnectivityService>();
        services.AddSingleton<IPrinterService, PrinterService>();
        services.AddSingleton<PrinterService>();

        // Pillar 4: Identity, Access & Data Protection
        services.AddSingleton<IIdentityService, IdentityService>();
        services.AddSingleton<IdentityService>();
        services.AddSingleton<IBackupService, BackupService>();
        services.AddSingleton<BackupService>();

        // Pillar 5: Software Deployment & OS Optimization
        services.AddSingleton<IAppInstallerService, AppInstallerService>();
        services.AddSingleton<AppInstallerService>();
        services.AddSingleton<IOptimizationService, OptimizationService>();
        services.AddSingleton<OptimizationService>();

        // ---------------------------------------------------------
        // 4. ViewModels & Views
        // ---------------------------------------------------------
        services.AddSingleton<TelemetryHeaderViewModel>();
        services.AddSingleton<ActivityConsoleViewModel>();
        services.AddSingleton<DashboardViewModel>();

        services.AddSingleton<SystemHealthViewModel>();
        services.AddSingleton<OfficeOutlookViewModel>();
        services.AddSingleton<ConnectivityViewModel>();
        services.AddSingleton<IdentityBackupViewModel>();
        services.AddSingleton<SoftwareOptimizationViewModel>();

        services.AddSingleton<MainViewModel>();
        services.AddSingleton<MainWindow>();
    }
}
