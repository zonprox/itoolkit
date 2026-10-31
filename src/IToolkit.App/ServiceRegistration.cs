namespace IToolkit.App;

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

#if WINDOWS || NET10_0_WINDOWS
using IToolkit.App.Services;
#else
using IToolkit.Tests.TestDoubles;
#endif

/// <summary>
/// Production Dependency Injection registration for platform abstractions, safety guards, pillar services, and ViewModels.
/// </summary>
public static class ServiceRegistration
{
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
        services.AddSingleton<IOutlookComService, WindowsOutlookComService>();
#if WINDOWS || NET10_0_WINDOWS
        services.AddSingleton<WpfDialogService>();
        services.AddSingleton<IDialogService>(sp => sp.GetRequiredService<WpfDialogService>());
        services.AddSingleton<ISafetyConfirmationService>(sp => sp.GetRequiredService<WpfDialogService>());
#else
        services.AddSingleton<MockDialogService>();
        services.AddSingleton<IDialogService>(sp => sp.GetRequiredService<MockDialogService>());
        services.AddSingleton<ISafetyConfirmationService>(sp => sp.GetRequiredService<MockDialogService>());
#endif

        // ---------------------------------------------------------
        // 2. Core Safety Engines
        // ---------------------------------------------------------
        services.AddSingleton<ElevationGuard>(_ => new ElevationGuard());
        services.AddSingleton<IElevationService>(sp => sp.GetRequiredService<ElevationGuard>());
        services.AddSingleton<AtomicRegistryService>();
        services.AddSingleton<ProcessLockGuard>();
        services.AddSingleton<ResourceGuard>();

        // ---------------------------------------------------------
        // 3. Operational Domain Services (5 Pillars)
        // ---------------------------------------------------------
        // Pillar 1: System Health & Maintenance
        services.AddSingleton<SystemHealthService>();
        services.AddSingleton<ISystemHealthService>(sp => sp.GetRequiredService<SystemHealthService>());

        // Pillar 2: Office & Outlook Productivity Suite
        services.AddSingleton<OfficeSuiteService>();
        services.AddSingleton<IOfficeSuiteService>(sp => sp.GetRequiredService<OfficeSuiteService>());
        services.AddSingleton<OutlookService>();
        services.AddSingleton<IOutlookService>(sp => sp.GetRequiredService<OutlookService>());

        // Pillar 3: Connectivity & Print Subsystem
        services.AddSingleton<ConnectivityService>();
        services.AddSingleton<IConnectivityService>(sp => sp.GetRequiredService<ConnectivityService>());
        services.AddSingleton<PrinterService>();
        services.AddSingleton<IPrinterService>(sp => sp.GetRequiredService<PrinterService>());

        // Pillar 4: Identity, Access & Data Protection
        services.AddSingleton<IdentityService>();
        services.AddSingleton<IIdentityService>(sp => sp.GetRequiredService<IdentityService>());
        services.AddSingleton<BackupService>();
        services.AddSingleton<IBackupService>(sp => sp.GetRequiredService<BackupService>());

        // Pillar 5: Software Deployment & OS Optimization
        services.AddSingleton<AppInstallerService>();
        services.AddSingleton<IAppInstallerService>(sp => sp.GetRequiredService<AppInstallerService>());
        services.AddSingleton<OptimizationService>();
        services.AddSingleton<IOptimizationService>(sp => sp.GetRequiredService<OptimizationService>());

        // ---------------------------------------------------------
        // 4. ViewModels
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
    }
}
