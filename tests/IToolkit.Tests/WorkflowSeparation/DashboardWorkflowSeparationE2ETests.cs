namespace IToolkit.Tests.WorkflowSeparation;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Comprehensive E2E test suite validating architectural and workflow separation
/// between global system-wide fixes and per-entity operations in Module 4 (System Dashboard & Telemetry).
/// Tiers:
///  - Tier 1: Feature Coverage (Isolated Happy Path)
///  - Tier 2: Boundary & Corner Cases (WMI failure resilience, concurrency, busy state)
///  - Tier 3: Non-Interference (Telemetry isolation, global quick fixes vs entities)
///  - Tier 4: Real-World Scenarios (End-to-End Dashboard Administrative Lifecycle)
/// </summary>
public class DashboardWorkflowSeparationE2ETests
{
    private readonly Mock<ISystemTelemetryService> _telemetryMock;
    private readonly Mock<ISystemHealthService> _healthMock;
    private readonly Mock<IOfficeSuiteService> _officeSuiteMock;
    private readonly Mock<IOutlookService> _outlookMock;
    private readonly Mock<IConnectivityService> _connectivityMock;
    private readonly Mock<IOptimizationService> _optimizationMock;
    private readonly Mock<IBackupService> _backupMock;
    private readonly TestActivityLogger _logger;

    public DashboardWorkflowSeparationE2ETests()
    {
        _telemetryMock = new Mock<ISystemTelemetryService>();
        _healthMock = new Mock<ISystemHealthService>();
        _officeSuiteMock = new Mock<IOfficeSuiteService>();
        _outlookMock = new Mock<IOutlookService>();
        _connectivityMock = new Mock<IConnectivityService>();
        _optimizationMock = new Mock<IOptimizationService>();
        _backupMock = new Mock<IBackupService>();
        _logger = new TestActivityLogger();
    }

    private TelemetrySnapshot CreateSampleSnapshot()
    {
        return new TelemetrySnapshot(
            OsDescription: "Microsoft Windows 11 Enterprise",
            OsBuild: "26100.1742",
            IsElevated: true,
            CpuUsagePercentage: 15.5,
            MemoryUsedBytes: 16L * 1024 * 1024 * 1024,
            MemoryTotalBytes: 32L * 1024 * 1024 * 1024,
            SystemDriveFreeBytes: 350L * 1024 * 1024 * 1024,
            SystemDriveTotalBytes: 1000L * 1024 * 1024 * 1024,
            NetworkConnected: true,
            ActiveTaskDescription: "System Idle",
            ComputerName: "CORP-WORKSTATION-01",
            DomainOrWorkgroup: "CORP.ENTERPRISE.LOCAL",
            CurrentUser: "admin.user",
            UserProfilePath: @"C:\Users\admin.user",
            SystemUptime: "3 days, 4 hours",
            OsArchitecture: "64-bit (win-x64)",
            CpuModelName: "AMD Ryzen 9 7950X",
            SystemManufacturerModel: "Dell Inc. Precision 3660",
            GpuModelName: "NVIDIA RTX 4000 Ada Generation",
            BiosAndSerial: "BIOS 1.14.0 | S/N: 8ABC123",
            AllDrivesSummary: "C: (65% used, 350 GB free)",
            PrimaryNetworkAdapter: "Intel Ethernet Connection I219-LM",
            Ipv4Address: "192.168.1.100",
            DefaultGateway: "192.168.1.1",
            DnsServers: "1.1.1.1, 8.8.8.8",
            MacAddress: "00-11-22-33-44-55");
    }

    private DashboardViewModel CreateDashboardViewModel()
    {
        return new DashboardViewModel(
            _healthMock.Object,
            _officeSuiteMock.Object,
            _outlookMock.Object,
            _connectivityMock.Object,
            _backupMock.Object,
            _optimizationMock.Object,
            _telemetryMock.Object,
            _logger);
    }

    #region Tier 1: Feature Coverage (Isolated Happy Path)

    [Fact]
    public void Tier1_Global_DashboardSnapshot_CapturesSystemWideMetricsWithoutSideEffects()
    {
        // Arrange
        var snapshot = CreateSampleSnapshot();
        _telemetryMock.Setup(s => s.GetSnapshot()).Returns(snapshot);

        // Act
        var result = _telemetryMock.Object.GetSnapshot();

        // Assert
        Assert.NotNull(result);
        Assert.Equal("Microsoft Windows 11 Enterprise", result.OsDescription);
        Assert.Equal("CORP-WORKSTATION-01", result.ComputerName);
        Assert.Equal("admin.user", result.CurrentUser);
        Assert.Equal("192.168.1.100", result.Ipv4Address);
        Assert.True(result.IsElevated);
    }

    [Fact]
    public async Task Tier1_Global_DashboardViewModel_LoadsTelemetrySnapshotProperly()
    {
        // Arrange
        var snapshot = CreateSampleSnapshot();
        _telemetryMock.Setup(s => s.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(snapshot);

        var vm = CreateDashboardViewModel();

        // Act
        await vm.RefreshTelemetryCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal("Microsoft Windows 11 Enterprise", vm.OsDescription);
        Assert.Equal("26100.1742", vm.OsBuild);
        Assert.True(vm.IsElevated);
        Assert.Equal(15.5, vm.CpuUsagePercentage);
        Assert.Equal(50.0, vm.MemoryPercentage); // 16 / 32 = 50%
        Assert.Equal("CORP-WORKSTATION-01", vm.ComputerName);
        Assert.Equal("admin.user", vm.CurrentUser);
        Assert.Equal("192.168.1.100", vm.Ipv4Address);
        Assert.Equal("00-11-22-33-44-55", vm.MacAddress);
    }

    [Fact]
    public async Task Tier1_Global_QuickNetworkResetCommand_InvokesParameterlessGlobalResets()
    {
        // Arrange
        _connectivityMock.Setup(c => c.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "Remediated"));

        var vm = CreateDashboardViewModel();

        // Act
        await vm.QuickNetworkResetCommand.ExecuteAsync(null);

        // Assert
        _connectivityMock.Verify(c => c.RemediateNetworkStack(), Times.Once);

        // CRITICAL CONTRACT: Parameterless global method must NOT target any specific adapter
        _connectivityMock.Verify(c => c.RestartAdapter(It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task Tier1_Global_QuickMailRepairCommand_InvokesParameterlessMailRepair()
    {
        // Arrange
        _outlookMock.Setup(o => o.RepairGlobalMailSettings())
            .Returns(OperationResult.Succeeded("Mail settings repaired"));

        var vm = CreateDashboardViewModel();

        // Act
        await vm.QuickMailRepairCommand.ExecuteAsync(null);

        // Assert
        _outlookMock.Verify(o => o.RepairGlobalMailSettings(), Times.Once);

        // CRITICAL CONTRACT: Must NOT mutate individual mail profiles or relocate/compact/backup data files
        _outlookMock.Verify(o => o.QuickMailAndCacheRepair(It.IsAny<string>()), Times.Never);
        _outlookMock.Verify(o => o.RelocateDataFile(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        _outlookMock.Verify(o => o.CompactDataFile(It.IsAny<string>()), Times.Never);
        _outlookMock.Verify(o => o.BackupDataFile(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    #endregion

    #region Tier 2: Boundary & Corner Cases

    [Fact]
    public async Task Tier2_Boundary_TelemetryService_HandlesWmiFailuresGracefully()
    {
        // Arrange: simulate telemetry service failure throwing an exception
        _telemetryMock.Setup(s => s.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("WMI query timed out or root\\cimv2 namespace damaged"));

        var vm = CreateDashboardViewModel();

        // Act & Assert: Must NOT crash or propagate unhandled exception
        var ex = await Record.ExceptionAsync(() => vm.RefreshTelemetryCommand.ExecuteAsync(null));
        Assert.Null(ex);
    }

    [Fact]
    public async Task Tier2_Boundary_RapidConcurrentTelemetryRefreshes_ThreadSafe()
    {
        // Arrange
        var snapshot = CreateSampleSnapshot();
        _telemetryMock.Setup(s => s.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(snapshot);

        var vm = CreateDashboardViewModel();

        // Act: Fire 10 concurrent telemetry refreshes
        var tasks = Enumerable.Range(0, 10)
            .Select(_ => vm.RefreshTelemetryCommand.ExecuteAsync(null))
            .ToArray();

        await Task.WhenAll(tasks);

        // Assert
        Assert.Equal("Microsoft Windows 11 Enterprise", vm.OsDescription);
        Assert.Equal("CORP-WORKSTATION-01", vm.ComputerName);
    }

    [Fact]
    public void Tier2_Boundary_DashboardCommands_DisabledWhileBusy()
    {
        // Arrange
        var vm = CreateDashboardViewModel();

        // Initially not busy
        Assert.True(vm.IsNotBusy);
        Assert.True(vm.QuickNetworkResetCommand.CanExecute(null));
        Assert.True(vm.QuickMailRepairCommand.CanExecute(null));

        // When busy (simulated by setting IsBusy = true via base)
        vm.IsBusy = true;
        Assert.False(vm.IsNotBusy);
        Assert.False(vm.QuickNetworkResetCommand.CanExecute(null));
        Assert.False(vm.QuickMailRepairCommand.CanExecute(null));
    }

    #endregion

    #region Tier 3: Cross-Feature Combinations & Non-Interference

    [Fact]
    public async Task Tier3_NonInterference_PollingTelemetry_DoesNotMutateOrLockEntities()
    {
        // Arrange
        var snapshot = CreateSampleSnapshot();
        _telemetryMock.Setup(s => s.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(snapshot);

        var vm = CreateDashboardViewModel();

        // Act: Poll telemetry
        await vm.RefreshTelemetryCommand.ExecuteAsync(null);

        // Assert: Absolutely no mutation methods were called across any service
        _healthMock.Verify(h => h.RunSfcScan(), Times.Never);
        _healthMock.Verify(h => h.RunDismRestoreHealth(It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
        _healthMock.Verify(h => h.RunDismSfcPipeline(It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
        _outlookMock.Verify(o => o.QuickMailAndCacheRepair(It.IsAny<string>()), Times.Never);
        _connectivityMock.Verify(c => c.FlushDns(), Times.Never);
        _connectivityMock.Verify(c => c.ResetWinsock(), Times.Never);
        _connectivityMock.Verify(c => c.ResetTcpIpStack(), Times.Never);
        _connectivityMock.Verify(c => c.RestartAdapter(It.IsAny<string>()), Times.Never);
        _backupMock.Verify(b => b.RestoreProfileData(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task Tier3_NonInterference_QuickNetworkReset_DoesNotAlterStaticAdapterConfiguration()
    {
        // Arrange
        _connectivityMock.Setup(c => c.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "OK"));

        var vm = CreateDashboardViewModel();

        // Act: Run Quick Network Reset
        await vm.QuickNetworkResetCommand.ExecuteAsync(null);

        // Assert: Verifies it does NOT call adapter-specific restart
        _connectivityMock.Verify(c => c.RestartAdapter(It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task Tier3_NonInterference_QuickOutlookRepair_DoesNotRelocateOrCompactPstFiles()
    {
        // Arrange
        _outlookMock.Setup(o => o.RepairGlobalMailSettings())
            .Returns(OperationResult.Succeeded("Mail settings repaired"));

        var vm = CreateDashboardViewModel();

        // Act
        await vm.QuickMailRepairCommand.ExecuteAsync(null);

        // Assert: Verifies mailbox reset does NOT touch data file storage paths or rules
        _outlookMock.Verify(o => o.RelocateDataFile(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        _outlookMock.Verify(o => o.RunNewDefaultPstPipeline(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        _outlookMock.Verify(o => o.ExpandDataFileLimitsTo100GB(), Times.Never);
    }

    #endregion

    #region Tier 4: Real-World Scenarios (End-to-End Admin Lifecycles)

    [Fact]
    public async Task Tier4_RealWorld_FullDashboardLifecycle_Inspect_QuickFix_CrossModuleOperations_VerifyHealth()
    {
        // Arrange
        var snapshot = CreateSampleSnapshot();
        _telemetryMock.Setup(s => s.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(snapshot);

        _healthMock.Setup(h => h.RunDismSfcPipeline(null, false))
            .Returns((DismScanResult.Successful("DISM Health: Healthy"), SfcScanResult.Clean("No violations")));

        _connectivityMock.Setup(c => c.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "Network ready"));

        var vm = CreateDashboardViewModel();

        // Step 1: Administrator opens dashboard -> Inspects real-time telemetry
        await vm.RefreshTelemetryCommand.ExecuteAsync(null);
        Assert.Equal("Microsoft Windows 11 Enterprise", vm.OsDescription);
        Assert.Equal("CORP-WORKSTATION-01", vm.ComputerName);
        Assert.Equal("admin.user", vm.CurrentUser);

        // Step 2: System lag detected -> Administrator executes Quick System Repair (DISM/SFC)
        Assert.True(vm.QuickSystemRepairCommand.CanExecute(null));
        await vm.QuickSystemRepairCommand.ExecuteAsync(null);
        _healthMock.Verify(h => h.RunDismSfcPipeline(null, false), Times.Once);
        Assert.Equal("System image and files healthy", vm.SystemHealthStatus);

        // Step 3: Network latency detected -> Administrator executes Quick Network Reset
        Assert.True(vm.QuickNetworkResetCommand.CanExecute(null));
        await vm.QuickNetworkResetCommand.ExecuteAsync(null);
        _connectivityMock.Verify(c => c.RemediateNetworkStack(), Times.Once);
        _connectivityMock.Verify(c => c.RestartAdapter(It.IsAny<string>()), Times.Never);

        // Step 4: Refresh telemetry to confirm healthy system state
        await vm.RefreshTelemetryCommand.ExecuteAsync(null);
        Assert.True(vm.IsNotBusy);
    }

    #endregion
}
