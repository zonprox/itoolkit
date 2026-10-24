namespace IToolkit.Tests.Integration;

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using Xunit;

public class DashboardEndToEndTests
{
    private static IServiceProvider CreateTestServiceProvider(
        MockProcessRunner processRunner,
        MockFileSystemService fileSystem,
        MockRegistryService registry,
        MockNetworkService network,
        MockWmiService wmi,
        MockOutlookComService? outlookCom = null,
        IActivityLogger? customLogger = null)
    {
        var services = new ServiceCollection();

        // Logger
        var logger = customLogger ?? new TestActivityLogger();
        services.AddSingleton<IActivityLogger>(logger);

        // Test Doubles / Platform Abstractions
        services.AddSingleton<IProcessRunner>(processRunner);
        services.AddSingleton<IFileSystemService>(fileSystem);
        services.AddSingleton<IRegistryService>(registry);
        services.AddSingleton<INetworkService>(network);
        services.AddSingleton<IWmiService>(wmi);
        if (outlookCom != null)
        {
            services.AddSingleton<IOutlookComService>(outlookCom);
        }

        // Mock Telemetry & Elevation
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var sampleSnapshot = new TelemetrySnapshot(
            "Windows 11 Pro 64-bit",
            "22631.4317",
            true,
            15.0,
            8L * 1024 * 1024 * 1024,
            16L * 1024 * 1024 * 1024,
            150L * 1024 * 1024 * 1024,
            500L * 1024 * 1024 * 1024,
            true,
            "Ready");
        telemetryMock.Setup(t => t.GetSnapshot()).Returns(sampleSnapshot);
        telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>())).ReturnsAsync(sampleSnapshot);
        services.AddSingleton<ISystemTelemetryService>(telemetryMock.Object);

        var elevationMock = new Mock<IElevationService>();
        elevationMock.Setup(e => e.IsElevated()).Returns(true);
        services.AddSingleton<IElevationService>(elevationMock.Object);

        // Safety Engines
        services.AddSingleton<AtomicRegistryEngine>();
        services.AddSingleton<AtomicRegistryService>();
        services.AddSingleton<ProcessLockGuard>();
        services.AddSingleton<ResourceGuard>();

        // 5 Operational Pillar Domain Services
        services.AddSingleton<ISystemHealthService, SystemHealthService>();
        services.AddSingleton<IOfficeSuiteService, OfficeSuiteService>();
        services.AddSingleton<IOutlookService, OutlookService>();
        services.AddSingleton<IConnectivityService, ConnectivityService>();
        services.AddSingleton<IPrinterService, PrinterService>();
        services.AddSingleton<IIdentityService, IdentityService>();
        services.AddSingleton<IBackupService, BackupService>();
        services.AddSingleton<IAppInstallerService, AppInstallerService>();
        services.AddSingleton<IOptimizationService, OptimizationService>();

        // ViewModels
        services.AddSingleton<TelemetryHeaderViewModel>();
        services.AddSingleton<ActivityConsoleViewModel>();
        services.AddSingleton<DashboardViewModel>();
        services.AddSingleton<SystemHealthViewModel>();
        services.AddSingleton<OfficeOutlookViewModel>();
        services.AddSingleton<ConnectivityViewModel>();
        services.AddSingleton<IdentityBackupViewModel>();
        services.AddSingleton<SoftwareOptimizationViewModel>();
        services.AddSingleton<MainViewModel>();

        return services.BuildServiceProvider();
    }

    [Fact]
    public void DependencyInjection_ContainerConfiguration_ResolvesAllViewModelsAndSingletons()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();
        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);

        // Act
        var mainVm = provider.GetRequiredService<MainViewModel>();
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();
        var telemetryVm = provider.GetRequiredService<TelemetryHeaderViewModel>();
        telemetryVm.StopPolling();

        var healthVm = provider.GetRequiredService<SystemHealthViewModel>();
        var officeVm = provider.GetRequiredService<OfficeOutlookViewModel>();
        var connVm = provider.GetRequiredService<ConnectivityViewModel>();
        var identityVm = provider.GetRequiredService<IdentityBackupViewModel>();
        var optVm = provider.GetRequiredService<SoftwareOptimizationViewModel>();

        // Assert
        Assert.NotNull(mainVm);
        Assert.NotNull(dashboardVm);
        Assert.NotNull(consoleVm);
        Assert.NotNull(telemetryVm);
        Assert.NotNull(healthVm);
        Assert.NotNull(officeVm);
        Assert.NotNull(connVm);
        Assert.NotNull(identityVm);
        Assert.NotNull(optVm);

        // Verify MainViewModel navigation properties point to singleton instances
        Assert.Same(dashboardVm, mainVm.DashboardViewModel);
        Assert.Same(healthVm, mainVm.SystemHealthViewModel);
        Assert.Same(officeVm, mainVm.OfficeOutlookViewModel);
        Assert.Same(connVm, mainVm.ConnectivityViewModel);
        Assert.Same(identityVm, mainVm.IdentityBackupViewModel);
        Assert.Same(optVm, mainVm.SoftwareOptimizationViewModel);
        Assert.Same(consoleVm, mainVm.ActivityConsole);
        Assert.Same(telemetryVm, mainVm.TelemetryHeader);
    }

    [Fact]
    public void App_ConfigureServices_ProductionCompositionRoot_ResolvesWithoutCircularDependenciesAndDisposesCleanly()
    {
        // Arrange
        var services = new ServiceCollection();
        IToolkit.App.ServiceRegistration.ConfigureServices(services);

        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        // Act
        var elevationService = provider.GetRequiredService<IElevationService>();
        var elevationGuard = provider.GetRequiredService<ElevationGuard>();
        var telemetryService = provider.GetRequiredService<ISystemTelemetryService>();
        var mainVm = provider.GetRequiredService<MainViewModel>();

        // Assert
        Assert.NotNull(elevationService);
        Assert.Same(elevationGuard, elevationService);
        Assert.NotNull(telemetryService);
        Assert.NotNull(mainVm);
        Assert.Same(provider.GetRequiredService<SystemHealthService>(), provider.GetRequiredService<ISystemHealthService>());
        Assert.Same(provider.GetRequiredService<OfficeSuiteService>(), provider.GetRequiredService<IOfficeSuiteService>());
        Assert.Same(provider.GetRequiredService<OutlookService>(), provider.GetRequiredService<IOutlookService>());
        Assert.Same(provider.GetRequiredService<ConnectivityService>(), provider.GetRequiredService<IConnectivityService>());
        Assert.Same(provider.GetRequiredService<PrinterService>(), provider.GetRequiredService<IPrinterService>());
        Assert.Same(provider.GetRequiredService<IdentityService>(), provider.GetRequiredService<IIdentityService>());
        Assert.Same(provider.GetRequiredService<BackupService>(), provider.GetRequiredService<IBackupService>());
        Assert.Same(provider.GetRequiredService<AppInstallerService>(), provider.GetRequiredService<IAppInstallerService>());
        Assert.Same(provider.GetRequiredService<OptimizationService>(), provider.GetRequiredService<IOptimizationService>());
    }

    [Fact]
    public void MainViewModel_NavigationOrchestration_SwitchesCurrentPageAcrossAllPillars()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();
        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);

        var mainVm = provider.GetRequiredService<MainViewModel>();
        mainVm.TelemetryHeader.StopPolling();

        // Initial state is Dashboard
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);
        Assert.Same(mainVm.DashboardViewModel, mainVm.CurrentPageViewModel);

        // Act & Assert each navigation
        string[] pillars = { "SystemHealth", "OfficeOutlook", "Connectivity", "IdentityBackup", "SoftwareOptimization", "Dashboard" };
        foreach (var pillar in pillars)
        {
            mainVm.NavigateCommand.Execute(pillar);
            Assert.Equal(pillar, mainVm.CurrentPillarName);
        }

        // Toggle nav rail
        bool initialRail = mainVm.IsNavRailExpanded;
        mainVm.ToggleNavRailCommand.Execute(null);
        Assert.NotEqual(initialRail, mainVm.IsNavRailExpanded);
    }

    [Fact]
    public async Task DashboardViewModel_QuickSystemRepair_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        pr.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth",
            new ProcessExecutionResult(0, "DISM success.", string.Empty, false));
        pr.SetCommandResult("sfc.exe /scannow",
            new ProcessExecutionResult(0, "Windows Resource Protection did not find any integrity violations.", string.Empty, false));

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        int initialLogCount = consoleVm.TotalCount;

        // Act
        await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal("System image and files healthy", dashboardVm.SystemHealthStatus);
        Assert.True(consoleVm.TotalCount > initialLogCount, "Activity console should capture logged events.");
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Quick System Repair"));
        Assert.Equal(0, consoleVm.ErrorCount);
    }

    [Fact]
    public async Task DashboardViewModel_QuickMailRepair_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        // Seed RoamCache with autocomplete and stale cache
        string roamDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Outlook", "RoamCache");
        fs.CreateDirectory(roamDir);
        fs.WriteAllText(Path.Combine(roamDir, "Stream_Autocomplete_0_TEST.dat"), "autocomplete data");
        fs.WriteAllText(Path.Combine(roamDir, "Stream_Rules_0_TEST.dat"), "stale rules cache");

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        // Act
        await dashboardVm.QuickMailRepairCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal("Mailbox cache and outbox clean", dashboardVm.OfficeStatus);
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Quick Outlook Mail Repair"));
        Assert.True(fs.FileExists(Path.Combine(roamDir, "Stream_Autocomplete_0_TEST.dat")), "Autocomplete MUST be preserved.");
        Assert.False(fs.FileExists(Path.Combine(roamDir, "Stream_Rules_0_TEST.dat")), "Stale cache should be cleaned.");
    }

    [Fact]
    public async Task DashboardViewModel_QuickNetworkReset_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        pr.SetCommandResult("ipconfig /flushdns", new ProcessExecutionResult(0, "Flushed.", string.Empty, false));
        pr.SetCommandResult("netsh winsock reset", new ProcessExecutionResult(0, "Reset.", string.Empty, false));
        pr.SetCommandResult("netsh int ip reset", new ProcessExecutionResult(0, "Reset.", string.Empty, false));

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        // Act
        await dashboardVm.QuickNetworkResetCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal("Network stack reset and ready", dashboardVm.NetworkStatus);
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Quick Network Reset"));
    }

    [Fact]
    public async Task DashboardViewModel_QuickDiskCleanup_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        pr.SetCommandResult("dism.exe /Online /Cleanup-Image /StartComponentCleanup", new ProcessExecutionResult(0, "Cleaned.", string.Empty, false));

        // Seed temp file (2MB stale)
        string tempFile = @"C:\Windows\Temp\stale_data.tmp";
        fs.CreateDirectory(@"C:\Windows\Temp");
        fs.WriteAllBytes(tempFile, new byte[2 * 1024 * 1024]);
        fs.SetLastWriteTime(tempFile, DateTime.UtcNow.AddHours(-36));

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        // Act
        await dashboardVm.QuickDiskCleanupCommand.ExecuteAsync(null);

        // Assert
        Assert.Contains("Reclaimed", dashboardVm.SystemHealthStatus);
        Assert.Contains("MB temp and cache space", dashboardVm.SystemHealthStatus);
        Assert.False(fs.FileExists(tempFile));
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Quick Unified Disk Cleanup"));
    }

    [Fact]
    public async Task DashboardViewModel_QuickSoftwareUpgrade_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        pr.SetCommandResult("winget.exe upgrade --all --silent --accept-package-agreements --accept-source-agreements",
            new ProcessExecutionResult(0, "All packages upgraded.", string.Empty, false));

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        // Act
        await dashboardVm.QuickSoftwareUpgradeCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal("All Winget packages up-to-date", dashboardVm.SoftwareStatus);
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Upgrade Software Packages"));
    }

    [Fact]
    public async Task DashboardViewModel_QuickProfileBackup_OrchestratesThroughDI_StreamsLogsToActivityConsole()
    {
        // Arrange
        var pr = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var wmi = new MockWmiService();

        string currentUser = Environment.UserName;
        string userSid = "S-1-5-21-000-111-222-1001";
        string userHome = $@"C:\Users\{currentUser}";

        reg.CreateKey($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}");
        reg.SetValue($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}", "ProfileImagePath", userHome, RegistryValueKind.String);
        fs.CreateDirectory(userHome);

        pr.SetCommandResult($"robocopy.exe \"{userHome}\" \"D:\\UserBackups\\{currentUser}\"",
            new ProcessExecutionResult(1, "1 file copied.", string.Empty, false));

        var provider = CreateTestServiceProvider(pr, fs, reg, net, wmi);
        var dashboardVm = provider.GetRequiredService<DashboardViewModel>();
        var consoleVm = provider.GetRequiredService<ActivityConsoleViewModel>();

        // Act
        await dashboardVm.QuickProfileBackupCommand.ExecuteAsync(null);

        // Assert
        Assert.Contains("Profile backed up to", dashboardVm.BackupStatus);
        Assert.Contains(consoleVm.FilteredEntries, e => e.Message.Contains("Quick Profile Backup"));
    }

    [Fact]
    public void ActivityConsoleViewModel_LiveLogStreaming_FilterAndSearchUnderLoad()
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        // Act - Stream 100 log entries of varying severity
        for (int i = 0; i < 60; i++) logger.LogInfo("ServiceHealth", $"Informational trace event {i}");
        for (int i = 0; i < 25; i++) logger.LogWarning("NetworkGuard", $"Transient packet drop warning {i}");
        for (int i = 0; i < 15; i++) logger.LogError("PrinterSpooler", $"Critical RPC timeout error {i}");

        // Assert counts
        Assert.Equal(100, consoleVm.TotalCount);
        Assert.Equal(25, consoleVm.WarningCount);
        Assert.Equal(15, consoleVm.ErrorCount);
        Assert.Equal(100, consoleVm.FilteredEntries.Count);

        // Filter by Error Level
        consoleVm.SelectedLevelFilter = "Error";
        Assert.Equal(15, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Error, e.Level));

        // Filter by Warning Level
        consoleVm.SelectedLevelFilter = "Warning";
        Assert.Equal(25, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Warning, e.Level));

        // Filter by Search Query (component or text)
        consoleVm.SelectedLevelFilter = "All";
        consoleVm.SearchFilter = "PrinterSpooler";
        Assert.Equal(15, consoleVm.FilteredEntries.Count);

        consoleVm.SearchFilter = "packet drop";
        Assert.Equal(25, consoleVm.FilteredEntries.Count);

        // Clear log command
        consoleVm.ClearLogCommand.Execute(null);
        Assert.Equal(0, consoleVm.TotalCount);
        Assert.Equal(0, consoleVm.ErrorCount);
        Assert.Equal(0, consoleVm.WarningCount);
        Assert.Empty(consoleVm.FilteredEntries);
    }

    [Fact]
    public async Task DashboardViewModel_UnderlyingServiceFailure_StreamsErrorToConsole_WithoutCrashingUI()
    {
        // Arrange
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Throws(new InvalidOperationException("Fatal hardware I/O device error during SFC scannow."));

        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();

        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        var dashboardVm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            logger);

        // Act
        await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null);

        // Assert
        Assert.False(dashboardVm.IsBusy, "ViewModel must not remain in busy state on failure.");
        Assert.Contains("failed: Fatal hardware I/O device error", dashboardVm.StatusMessage);
        Assert.True(consoleVm.ErrorCount >= 1);
        Assert.Equal("Errors Encountered", consoleVm.ExecutionStatus);
        Assert.Equal("#EF4444", consoleVm.ExecutionStatusBrush);
        Assert.Contains(consoleVm.FilteredEntries, e => e.Level == LogLevel.Error && e.Message.Contains("Fatal hardware I/O"));
    }

    [Theory]
    [InlineData(true, 0, "Completed", "#22C55E")]
    [InlineData(false, 87, "Failed", "#EF4444")]
    public void ActivityConsole_NotifyOperationFinished_ReplacesLegacyTuiPause_PreservesBannerAndLogs(
        bool success,
        int exitCode,
        string expectedStatus,
        string expectedBrush)
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("SystemHealth", "Starting repair pipeline step 1");
        logger.LogInfo("SystemHealth", "Repair pipeline step 2 finished");

        // Act
        consoleVm.NotifyOperationFinished("Composite System Health Pipeline", success, exitCode);

        // Assert
        Assert.True(consoleVm.ShowCompletionBanner);
        Assert.Equal(expectedStatus, consoleVm.ExecutionStatus);
        Assert.Equal(expectedBrush, consoleVm.ExecutionStatusBrush);
        Assert.Contains("Composite System Health Pipeline", consoleVm.CompletionMessage);
        Assert.Contains(exitCode.ToString(), consoleVm.CompletionMessage);

        // All logs are preserved
        Assert.Equal(2, consoleVm.TotalCount);

        // Dismiss completion command closes banner
        consoleVm.DismissCompletionCommand.Execute(null);
        Assert.False(consoleVm.ShowCompletionBanner);
        Assert.Equal(2, consoleVm.TotalCount);
    }
}
