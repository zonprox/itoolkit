namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.SystemHealth;
using Moq;
using Xunit;

public class SystemHealthViewModelTests
{
    private readonly Mock<ISystemHealthService> _healthServiceMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    public SystemHealthViewModelTests()
    {
        _healthServiceMock = new Mock<ISystemHealthService>();
        _loggerMock = new Mock<IActivityLogger>();
    }

    [Fact]
    public async Task RunSfcScanCommand_ExecutesAndUpdatesStatus()
    {
        _healthServiceMock
            .Setup(s => s.RunSfcScan())
            .Returns(SfcScanResult.Repaired("Found and fixed corruptions"));

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.RunSfcScanCommand.ExecuteAsync(null);

        Assert.Contains("SFC: Violations Repaired", vm.LastSfcStatus);
        Assert.False(vm.IsBusy);
        _healthServiceMock.Verify(s => s.RunSfcScan(), Times.Once);
    }

    [Fact]
    public async Task RunDismRestoreHealthCommand_HandlesRebootRequirement()
    {
        _healthServiceMock
            .Setup(s => s.RunDismRestoreHealth(It.IsAny<string?>(), It.IsAny<bool>()))
            .Returns(DismScanResult.Successful("Restore completed successfully", rebootRequired: true));

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.RunDismRestoreHealthCommand.ExecuteAsync(null);

        Assert.Contains("DISM: Health Restored Successfully", vm.LastDismStatus);
        Assert.True(vm.RebootRequired);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task ResetWindowsUpdateCommand_ExecutesAndLogsDetails()
    {
        var resetResult = new WindowsUpdateResetResult(
            Success: true,
            StoppedServices: new[] { "wuauserv", "bits" },
            RenamedDirectories: new[] { "SoftwareDistribution", "Catroot2" },
            ReRegisteredDllCount: 24,
            RestartedServices: new[] { "wuauserv", "bits" },
            Message: "Reset completed"
        );

        _healthServiceMock
            .Setup(s => s.ResetWindowsUpdateComponents())
            .Returns(resetResult);

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.ResetWindowsUpdateCommand.ExecuteAsync(null);

        Assert.Contains("24 DLLs registered", vm.LastWindowsUpdateStatus);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RepairWmiCommand_ReportsConsistencyState()
    {
        _healthServiceMock
            .Setup(s => s.RepairWmiRepository())
            .Returns(new WmiRepairResult(Success: true, IsConsistent: false, Salvaged: true, Reset: false, Output: "WMI repo salvaged"));

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.RepairWmiCommand.ExecuteAsync(null);

        Assert.Contains("Salvaged", vm.LastWmiStatus);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RunUnifiedDiskCleanupCommand_CalculatesReclaimedMegabytes()
    {
        var cleanupResult = new StorageCleanupResult(
            Success: true,
            BytesReclaimed: 524_288_000, // 500 MB
            FilesDeleted: 142,
            FilesSkipped: 3,
            CleanedTargets: new[] { "Temp", "Logs" },
            Errors: Array.Empty<string>()
        );

        _healthServiceMock
            .Setup(s => s.RunUnifiedDiskCleanup(It.IsAny<int>()))
            .Returns(cleanupResult);

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.RunUnifiedDiskCleanupCommand.ExecuteAsync(null);

        Assert.Contains("Reclaimed 500.0 MB", vm.LastCleanupSummary);
        Assert.Contains("across 142 files", vm.LastCleanupSummary);
    }

    [Fact]
    public async Task BlockAndUnblockWindowsUpdatesCommands_ExecuteAndUpdateStatus()
    {
        _healthServiceMock
            .Setup(s => s.BlockWindowsUpdates())
            .Returns(new WindowsUpdateBlockResult(true, true, new[] { "wuauserv", "UsoSvc" }, true, "Blocked"));
        _healthServiceMock
            .Setup(s => s.UnblockWindowsUpdates())
            .Returns(new WindowsUpdateBlockResult(true, false, new[] { "wuauserv", "UsoSvc" }, true, "Unblocked"));

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.BlockWindowsUpdatesCommand.ExecuteAsync(null);
        Assert.Contains("Blocked", vm.LastWindowsUpdateBlockStatus);

        await vm.UnblockWindowsUpdatesCommand.ExecuteAsync(null);
        Assert.Contains("Unblocked", vm.LastWindowsUpdateBlockStatus);
    }

    [Fact]
    public async Task SyncSystemTimeCommand_ExecutesAndUpdatesStatus()
    {
        _healthServiceMock
            .Setup(s => s.SyncSystemTime(null))
            .Returns(new TimeSyncResult(true, SystemHealthService.DefaultNtpServers, true, true, true, "The command completed successfully."));

        var vm = new SystemHealthViewModel(_healthServiceMock.Object, _loggerMock.Object);

        await vm.SyncSystemTimeCommand.ExecuteAsync(null);

        Assert.Contains("Synchronized", vm.LastTimeSyncStatus);
        _healthServiceMock.Verify(s => s.SyncSystemTime(null), Times.Once);
    }
}
