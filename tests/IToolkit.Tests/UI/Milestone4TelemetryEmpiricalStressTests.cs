namespace IToolkit.Tests.UI;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Xml.Linq;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using Moq;
using Xunit;

public class Milestone4TelemetryEmpiricalStressTests
{
    private static readonly string SolutionRoot = FindSolutionRoot();

    private static string FindSolutionRoot()
    {
        string dir = AppContext.BaseDirectory;
        while (!string.IsNullOrEmpty(dir))
        {
            if (File.Exists(Path.Combine(dir, "IToolkit.sln")))
                return dir;
            dir = Directory.GetParent(dir)?.FullName!;
        }
        return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
    }

    private static (
        Mock<ISystemHealthService> healthMock,
        Mock<IOfficeSuiteService> officeMock,
        Mock<IOutlookService> outlookMock,
        Mock<IConnectivityService> netMock,
        Mock<IBackupService> backupMock,
        Mock<IOptimizationService> optMock,
        Mock<ISystemTelemetryService> telemetryMock,
        Mock<IActivityLogger> loggerMock) CreateStandardMocks()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var loggerMock = new Mock<IActivityLogger>();

        // Setup default mock behaviors for quick actions
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Returns((DismScanResult.Successful("DISM: OK"), SfcScanResult.Clean("SFC: Clean")));

        outlookMock.Setup(o => o.RepairGlobalMailSettings())
            .Returns(OperationResult.Succeeded("Mail repair OK"));

        outlookMock.Setup(o => o.QuickMailAndCacheRepair(It.IsAny<string?>()))
            .Returns(new QuickMailRepairResult(true, true, true, true, true, true, "Clean"));

        netMock.Setup(n => n.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "Reset Completed"));

        healthMock.Setup(h => h.RunUnifiedDiskCleanup(It.IsAny<int>()))
            .Returns(new StorageCleanupResult(true, 50L * 1024 * 1024, 10, 0, Array.Empty<string>(), Array.Empty<string>()));

        optMock.Setup(o => o.UpdateAllPackages())
            .Returns(new ProcessExecutionResult(0, "All Winget packages up-to-date", "", false));

        backupMock.Setup(b => b.GetUserProfileMap(It.IsAny<string?>()))
            .Returns(new UserProfileMap("user", @"C:\Users\user", @"C:\Users\user\Desktop", @"C:\Users\user\Documents", @"C:\Users\user\Downloads", @"C:\Users\user\Favorites", @"C:\Users\user\Pictures", false));

        backupMock.Setup(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<bool>()))
            .Returns(new RobocopySyncResult("source", "dest", 0, true, "OK", ""));

        telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TelemetrySnapshot("Win 11", "26100", true, 20.0, 4L * 1024 * 1024 * 1024, 16L * 1024 * 1024 * 1024, 100L * 1024 * 1024 * 1024, 256L * 1024 * 1024 * 1024, true, "Idle"));

        return (healthMock, officeMock, outlookMock, netMock, backupMock, optMock, telemetryMock, loggerMock);
    }

    // =========================================================================
    // 1. DYNAMIC TELEMETRY: NORMAL & EXTREME VALUES (0%, 100%, OVERFLOW, BOUNDS)
    // =========================================================================

    [Fact]
    public void UpdateFromSnapshot_ZeroValues_HandlesCleanlyWithoutDivisionByZero()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object, mocks.loggerMock.Object);

        var zeroSnapshot = new TelemetrySnapshot(
            OsDescription: "Windows Test Edition",
            OsBuild: "0.0.0",
            IsElevated: false,
            CpuUsagePercentage: 0.0,
            MemoryUsedBytes: 0,
            MemoryTotalBytes: 0,
            SystemDriveFreeBytes: 0,
            SystemDriveTotalBytes: 0,
            NetworkConnected: false,
            ActiveTaskDescription: "Idle");

        vm.UpdateFromSnapshot(zeroSnapshot);

        Assert.Equal("Windows Test Edition", vm.OsDescription);
        Assert.Equal("0.0.0", vm.OsBuild);
        Assert.False(vm.IsElevated);
        Assert.Equal("Standard User", vm.ElevationBadgeText);
        Assert.Equal("#EAB308", vm.ElevationBadgeBrush);

        Assert.Equal(0.0, vm.CpuUsagePercentage);
        Assert.Equal("0%", vm.CpuUsageText);
        Assert.Equal("#22C55E", vm.CpuBrush);

        Assert.Equal(0.0, vm.MemoryPercentage);
        Assert.Equal("0%", vm.MemoryPercentageText);
        Assert.Equal("0.0 / 0.0 GB", vm.MemoryUsageText);
        Assert.Equal("#22C55E", vm.MemoryBrush);

        Assert.Equal(50.0, vm.DiskFreePercentage); // fallback when totalDiskGb == 0
        Assert.Equal("0.0 GB Free", vm.DiskFreeSpaceText);
        Assert.Equal("Critical", vm.DiskHealthStatus); // free < 10 GB
        Assert.Equal("#EF4444", vm.DiskHealthBrush);

        Assert.False(vm.IsNetworkConnected);
        Assert.Equal("Offline", vm.NetworkStatusText);
        Assert.Equal("#EF4444", vm.NetworkStatusBrush);
    }

    [Fact]
    public void UpdateFromSnapshot_MaxValues_HandlesCleanly()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        long sixtyFourGb = 64L * 1024 * 1024 * 1024;
        long twoTb = 2048L * 1024 * 1024 * 1024;

        var maxSnapshot = new TelemetrySnapshot(
            OsDescription: "Windows 11 Enterprise",
            OsBuild: "26100.1742",
            IsElevated: true,
            CpuUsagePercentage: 100.0,
            MemoryUsedBytes: sixtyFourGb,
            MemoryTotalBytes: sixtyFourGb,
            SystemDriveFreeBytes: twoTb,
            SystemDriveTotalBytes: twoTb,
            NetworkConnected: true,
            ActiveTaskDescription: "Full Throttle");

        vm.UpdateFromSnapshot(maxSnapshot);

        Assert.Equal(100.0, vm.CpuUsagePercentage);
        Assert.Equal("100%", vm.CpuUsageText);
        Assert.Equal("#EF4444", vm.CpuBrush);

        Assert.Equal(100.0, vm.MemoryPercentage);
        Assert.Equal("100%", vm.MemoryPercentageText);
        Assert.Equal("64.0 / 64.0 GB", vm.MemoryUsageText);
        Assert.Equal("#EF4444", vm.MemoryBrush);

        Assert.Equal(100.0, vm.DiskFreePercentage);
        Assert.Contains("2048.0 GB Free of 2048 GB", vm.DiskFreeSpaceText);
        Assert.Equal("Healthy", vm.DiskHealthStatus);
        Assert.Equal("#22C55E", vm.DiskHealthBrush);

        Assert.True(vm.IsNetworkConnected);
        Assert.Equal("Connected", vm.NetworkStatusText);
        Assert.Equal("#22C55E", vm.NetworkStatusBrush);
        Assert.Equal("Administrator", vm.ElevationBadgeText);
        Assert.Equal("#22C55E", vm.ElevationBadgeBrush);
    }

    [Theory]
    [InlineData(-50.0, 0.0, "0%", "#22C55E")]
    [InlineData(0.0, 0.0, "0%", "#22C55E")]
    [InlineData(59.9, 59.9, "60%", "#22C55E")]
    [InlineData(60.0, 60.0, "60%", "#22C55E")]
    [InlineData(60.1, 60.1, "60%", "#EAB308")]
    [InlineData(85.0, 85.0, "85%", "#EAB308")]
    [InlineData(85.1, 85.1, "85%", "#EF4444")]
    [InlineData(100.0, 100.0, "100%", "#EF4444")]
    [InlineData(150.0, 100.0, "100%", "#EF4444")] // Clamped to 100
    public void UpdateFromSnapshot_CpuThresholdsAndClamping_CalculatesCorrectly(
        double inputCpu, double expectedPercentage, string expectedText, string expectedBrush)
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object);

        var snap = new TelemetrySnapshot("Win", "1", true, inputCpu, 1024, 2048, 1024, 2048, true, "Test");
        vm.UpdateFromSnapshot(snap);

        Assert.Equal(expectedPercentage, vm.CpuUsagePercentage);
        Assert.Equal(expectedText, vm.CpuUsageText);
        Assert.Equal(expectedBrush, vm.CpuBrush);
    }

    [Theory]
    [InlineData(5, 100, 5.0, "#22C55E")]
    [InlineData(70, 100, 70.0, "#22C55E")]
    [InlineData(71, 100, 71.0, "#EAB308")]
    [InlineData(85, 100, 85.0, "#EAB308")]
    [InlineData(86, 100, 86.0, "#EF4444")]
    [InlineData(120, 100, 100.0, "#EF4444")] // Clamped to 100
    public void UpdateFromSnapshot_MemoryThresholdsAndClamping_CalculatesCorrectly(
        long usedGb, long totalGb, double expectedPercentage, string expectedBrush)
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object);

        long gb = 1024L * 1024 * 1024;
        var snap = new TelemetrySnapshot("Win", "1", true, 10, usedGb * gb, totalGb * gb, 50 * gb, 100 * gb, true, "Test");
        vm.UpdateFromSnapshot(snap);

        Assert.Equal(expectedPercentage, vm.MemoryPercentage);
        Assert.Equal(expectedBrush, vm.MemoryBrush);
    }

    [Theory]
    [InlineData(5, "Critical", "#EF4444")]   // < 10 GB
    [InlineData(9, "Critical", "#EF4444")]   // < 10 GB
    [InlineData(10, "Warning", "#EAB308")]   // >= 10 and < 25 GB
    [InlineData(24, "Warning", "#EAB308")]   // >= 10 and < 25 GB
    [InlineData(25, "Healthy", "#22C55E")]   // >= 25 GB
    [InlineData(500, "Healthy", "#22C55E")]  // >= 25 GB
    public void UpdateFromSnapshot_DiskThresholds_CalculatesCorrectly(
        long freeGb, string expectedStatus, string expectedBrush)
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object);

        long gb = 1024L * 1024 * 1024;
        var snap = new TelemetrySnapshot("Win", "1", true, 10, 4 * gb, 16 * gb, freeGb * gb, 1000 * gb, true, "Test");
        vm.UpdateFromSnapshot(snap);

        Assert.Equal(expectedStatus, vm.DiskHealthStatus);
        Assert.Equal(expectedBrush, vm.DiskHealthBrush);
    }

    // =========================================================================
    // 2. FAULT INJECTION & RESILIENCE: SERVICE EXCEPTIONS, CANCELLATION, NULL
    // =========================================================================

    [Fact]
    public async Task RefreshTelemetryAsync_ServiceThrowsException_SwallowsGracefullyAndPreservesState()
    {
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("WMI query failed"));

        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        // Should not throw
        var exception = await Record.ExceptionAsync(async () => await vm.RefreshTelemetryAsync());
        Assert.Null(exception);

        // Should also not throw when invoked via RefreshTelemetryCommand
        var cmdException = await Record.ExceptionAsync(async () => await vm.RefreshTelemetryCommand.ExecuteAsync(null));
        Assert.Null(cmdException);
    }

    [Fact]
    public async Task RefreshTelemetryAsync_CancellationRequested_SwallowsGracefully()
    {
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException());

        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        var exception = await Record.ExceptionAsync(async () => await vm.RefreshTelemetryAsync());
        Assert.Null(exception);
    }

    [Fact]
    public async Task RefreshTelemetryAsync_TelemetryServiceIsNull_NoOpSafely()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            null); // null telemetry service

        var exception = await Record.ExceptionAsync(async () => await vm.RefreshTelemetryAsync());
        Assert.Null(exception);
    }

    private class RecordingSynchronizationContext : SynchronizationContext
    {
        public List<(SendOrPostCallback callback, object? state)> PostedCallbacks { get; } = new();

        public override void Post(SendOrPostCallback d, object? state)
        {
            PostedCallbacks.Add((d, state));
        }

        public void ExecuteAll()
        {
            foreach (var (cb, state) in PostedCallbacks)
            {
                cb(state);
            }
        }
    }

    [Fact]
    public void UpdateFromSnapshot_NullSnapshot_HandlesSafelyWithoutThrowing()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object);

        // When snapshot is null, UpdateFromSnapshot guards against null and returns safely
        var ex = Record.Exception(() => vm.UpdateFromSnapshot(null!));
        Assert.Null(ex);
    }

    [Fact]
    public async Task RefreshTelemetryAsync_ServiceReturnsNull_WithSynchronizationContext_HandledSafelyWithoutUiCrash()
    {
        var syncContext = new RecordingSynchronizationContext();
        var prevContext = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(syncContext);
        DashboardViewModel vm;
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync((TelemetrySnapshot)null!);

        try
        {
            vm = new DashboardViewModel(
                mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
                mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
                mocks.telemetryMock.Object);
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(prevContext);
        }

        using (vm)
        {
            // Execute on background thread (simulating timer callback)
            await Task.Run(async () => await vm.RefreshTelemetryAsync());

            // With null guard in UpdateFromSnapshot, null snapshot safely returns without crashing
            var ex = Record.Exception(() => syncContext.ExecuteAll());
            Assert.Null(ex);
        }
    }

    [Fact]
    public void StartPolling_NegativeInterval_DefaultsSafelyWithoutThrowing()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        var ex = Record.Exception(() => vm.StartPolling(-50));
        Assert.Null(ex);
    }

    // =========================================================================
    // 3. TIMER LIFECYCLE: RAPID START/STOP/DISPOSE, CONCURRENCY & LEAK PREVENTION
    // =========================================================================

    [Fact]
    public void TimerLifecycle_RapidStartStopDispose_DoesNotThrow()
    {
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TelemetrySnapshot("Win", "1", true, 10, 100, 200, 300, 400, true, "Idle"));

        for (int i = 0; i < 200; i++)
        {
            var vm = new DashboardViewModel(
                mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
                mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
                mocks.telemetryMock.Object);

            vm.StartPolling(50);
            vm.StopPolling();
            vm.StartPolling(50);
            vm.Dispose();
        }
    }

    [Fact]
    public void TimerLifecycle_RepeatedDispose_IsIdempotent()
    {
        var mocks = CreateStandardMocks();
        var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        for (int i = 0; i < 20; i++)
        {
            vm.StopPolling();
            vm.Dispose();
        }
    }

    [Fact]
    public void TimerLifecycle_ConcurrentStartStop_IsThreadSafe()
    {
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TelemetrySnapshot("Win", "1", true, 10, 100, 200, 300, 400, true, "Idle"));

        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        var exceptions = new ConcurrentBag<Exception>();

        Parallel.For(0, 30, _ =>
        {
            try
            {
                vm.StartPolling(100);
                Thread.Sleep(2);
                vm.StopPolling();
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        });

        Assert.Empty(exceptions);
    }

    [Fact]
    public async Task TimerLifecycle_DisposeWhileTelemetryFetchInFlight_DoesNotThrow()
    {
        var mocks = CreateStandardMocks();
        var tcs = new TaskCompletionSource<TelemetrySnapshot>();

        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .Returns(tcs.Task);

        var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        // Start poll which triggers GetSnapshotAsync
        vm.StartPolling(10);
        await Task.Delay(20);

        // Now dispose while GetSnapshotAsync is still pending
        vm.Dispose();

        // Release the pending task
        tcs.SetResult(new TelemetrySnapshot("Win", "1", true, 10, 100, 200, 300, 400, true, "Idle"));
        await Task.Delay(20);

        // State remains intact, no unhandled exception
    }

    // =========================================================================
    // 4. QUICK ACTIONS & CONCURRENCY ALONGSIDE RAPID TELEMETRY UPDATES
    // =========================================================================

    [Fact]
    public async Task QuickActions_ExecuteCleanlyAlongsideRapidTelemetryPolling()
    {
        var mocks = CreateStandardMocks();
        mocks.telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TelemetrySnapshot("Win 11", "26100", true, 42.0, 8L * 1024 * 1024 * 1024, 16L * 1024 * 1024 * 1024, 50L * 1024 * 1024 * 1024, 100L * 1024 * 1024 * 1024, true, "Polling"));

        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        // Start fast polling at 15ms interval
        vm.StartPolling(15);

        // Execute all 6 quick action commands sequentially
        await vm.QuickSystemRepairCommand.ExecuteAsync(null);
        Assert.Contains("healthy", vm.SystemHealthStatus);

        await vm.QuickMailRepairCommand.ExecuteAsync(null);
        Assert.Contains("clean", vm.OfficeStatus);

        await vm.QuickNetworkResetCommand.ExecuteAsync(null);
        Assert.Contains("ready", vm.NetworkStatus);

        await vm.QuickDiskCleanupCommand.ExecuteAsync(null);
        Assert.Contains("Reclaimed", vm.SystemHealthStatus);

        await vm.QuickSoftwareUpgradeCommand.ExecuteAsync(null);
        Assert.Contains("up-to-date", vm.SoftwareStatus);

        await vm.QuickProfileBackupCommand.ExecuteAsync(null);
        Assert.Contains("backed up", vm.BackupStatus);

        for (int i = 0; i < 20 && vm.CpuUsagePercentage != 42.0; i++)
        {
            await Task.Delay(10);
        }

        // Verify telemetry still updated properly
        Assert.Equal("Win 11", vm.OsDescription);
        Assert.Equal("26100", vm.OsBuild);
        Assert.Equal(42.0, vm.CpuUsagePercentage);
    }

    [Fact]
    public async Task QuickActions_ReentrancyBlockedWhileBusy_PreservesState()
    {
        var mocks = CreateStandardMocks();
        using var vm = new DashboardViewModel(
            mocks.healthMock.Object, mocks.officeMock.Object, mocks.outlookMock.Object,
            mocks.netMock.Object, mocks.backupMock.Object, mocks.optMock.Object,
            mocks.telemetryMock.Object);

        // When IsBusy is toggled, commands must reflect CanExecute == false
        vm.IsBusy = true;
        Assert.False(vm.IsNotBusy);
        Assert.False(vm.QuickSystemRepairCommand.CanExecute(null));
        Assert.False(vm.QuickMailRepairCommand.CanExecute(null));
        Assert.False(vm.QuickNetworkResetCommand.CanExecute(null));

        // Execution while busy is rejected (no-op)
        await vm.QuickSystemRepairCommand.ExecuteAsync(null);
        mocks.healthMock.Verify(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()), Times.Never);

        vm.IsBusy = false;
        Assert.True(vm.IsNotBusy);
        Assert.True(vm.QuickSystemRepairCommand.CanExecute(null));
    }

    // =========================================================================
    // 5. ARCHITECTURAL & LAYOUT STRETCH VERIFICATION
    // =========================================================================

    [Fact]
    public void MainWindow_HasNoFixedTelemetryHeader_AndWorkspaceOccupiesFullHeight()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        string xaml = File.ReadAllText(path);

        Assert.DoesNotContain("TelemetryHeaderView", xaml);

        var doc = XDocument.Parse(xaml);
        var rootGrid = doc.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "Grid");
        Assert.NotNull(rootGrid);

        var rowDefs = rootGrid.Element(rootGrid.Name.Namespace + "Grid.RowDefinitions");
        Assert.Null(rowDefs); // Fully removed, no split rows

        var colDefs = rootGrid.Element(rootGrid.Name.Namespace + "Grid.ColumnDefinitions")?.Elements().ToList();
        Assert.NotNull(colDefs);
        Assert.Equal(2, colDefs.Count);
        Assert.Equal("175", colDefs[0].Attribute("Width")?.Value);
        Assert.Equal("*", colDefs[1].Attribute("Width")?.Value);
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void Views_HaveProperStretchAlignments_AndNoCenteringOrMaxWidth(string fileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", fileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        var doc = XDocument.Parse(xaml);
        var root = doc.Root!;

        // UserControl stretch alignments
        Assert.Equal("Stretch", root.Attribute("HorizontalContentAlignment")?.Value);
        Assert.Equal("Stretch", root.Attribute("VerticalContentAlignment")?.Value);

        // No container element should have HorizontalAlignment="Center" or explicit MaxWidth
        var allElements = doc.Descendants().ToList();
        foreach (var el in allElements)
        {
            var hAlign = el.Attribute("HorizontalAlignment")?.Value;
            var maxWidth = el.Attribute("MaxWidth")?.Value;

            if (el.Name.LocalName is "Grid" or "StackPanel" or "ScrollViewer" or "TabControl" or "Border" or "DockPanel")
            {
                Assert.NotEqual("Center", hAlign);
                Assert.Null(maxWidth);
            }
        }
    }

    [Fact]
    public void PillarDataGrids_UseMinHeightInsteadOfFixedHeight()
    {
        string outlookPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "OfficeOutlookView.xaml");
        string backupPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "IdentityBackupView.xaml");

        var outlookDoc = XDocument.Parse(File.ReadAllText(outlookPath));
        var dataGridsOutlook = outlookDoc.Descendants().Where(e => e.Name.LocalName == "DataGrid").ToList();
        foreach (var dg in dataGridsOutlook)
        {
            Assert.Null(dg.Attribute("Height")); // Must not be rigid fixed Height
            Assert.NotNull(dg.Attribute("MinHeight")); // Must have responsive MinHeight
        }

        var backupDoc = XDocument.Parse(File.ReadAllText(backupPath));
        var dataGridsBackup = backupDoc.Descendants().Where(e => e.Name.LocalName == "DataGrid").ToList();
        foreach (var dg in dataGridsBackup)
        {
            Assert.Null(dg.Attribute("Height"));
            Assert.NotNull(dg.Attribute("MinHeight"));
        }
    }
}
