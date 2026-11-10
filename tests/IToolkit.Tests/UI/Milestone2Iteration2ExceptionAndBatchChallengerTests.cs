namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Moq;
using Xunit;

/// <summary>
/// Empirical Challenger Harness for Milestone 2 Iteration 2 (Challenger 2):
/// Rigorous stress-testing of service exception recovery, state cleanliness,
/// and batch upgrade loop error boundaries in AppManagementViewModel.
/// </summary>
public class Milestone2Iteration2ExceptionAndBatchChallengerTests : IDisposable
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    public Milestone2Iteration2ExceptionAndBatchChallengerTests()
    {
        ViewModelBase.ResetOperationEvents();
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private AppManagementViewModel CreateViewModel(bool includeConfirmation = true)
    {
        return new AppManagementViewModel(
            _appInstallerMock.Object,
            includeConfirmation ? _confirmationMock.Object : null,
            _loggerMock.Object);
    }

    // =========================================================================
    // 1. SINGLE-ITEM SERVICE EXCEPTION RECOVERY (INSTALL, UNINSTALL, UPDATE)
    // =========================================================================

    [Theory]
    [InlineData(typeof(IOException), "Disk write failure on temp directory")]
    [InlineData(typeof(TimeoutException), "Winget operation timed out after 300s")]
    [InlineData(typeof(UnauthorizedAccessException), "Administrator elevation required")]
    [InlineData(typeof(HttpRequestException), "Unable to download package manifest from CDN")]
    [InlineData(typeof(InvalidOperationException), "Winget CLI corrupted")]
    [InlineData(typeof(PlatformNotSupportedException), "Architecture mismatch x86 vs x64")]
    public async Task InstallAppAsync_WhenServiceThrowsVariousExceptions_GuaranteesCleanReset(Type exceptionType, string errorMessage)
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("TestApp", "Test.Package.Id", "1.0.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        var ex = (Exception)Activator.CreateInstance(exceptionType, errorMessage)!;
        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Test.Package.Id", It.IsAny<CancellationToken>()))
            .ThrowsAsync(ex);

        bool finishedEventRaised = false;
        bool finishedSuccess = true;
        int finishedExitCode = -1;
        ViewModelBase.OperationFinished += (name, success, exitCode) =>
        {
            finishedEventRaised = true;
            finishedSuccess = success;
            finishedExitCode = exitCode;
        };

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        // Assert item busy state is strictly reset
        Assert.False(pkgVm.IsInstalling, "IsInstalling must be false after exception");
        Assert.NotEqual("Installing...", pkgVm.Status);
        Assert.StartsWith("Failed:", pkgVm.Status);
        Assert.Contains(errorMessage, pkgVm.Status);

        // Assert ViewModel overall state is strictly reset
        Assert.False(vm.IsBusy, "ViewModel.IsBusy must be reset to false");
        Assert.True(vm.IsNotBusy, "ViewModel.IsNotBusy must be true");
        Assert.Equal(0, vm.OperationProgress);
        Assert.Equal("Installation failed.", vm.OperationProgressText);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(errorMessage, vm.StatusMessage);

        // Assert operation event notification
        Assert.True(finishedEventRaised, "OperationFinished event must be raised");
        Assert.False(finishedSuccess, "OperationFinished success must be false");
        Assert.Equal(1, finishedExitCode);
    }

    [Theory]
    [InlineData(typeof(IOException), "File lock on target executable")]
    [InlineData(typeof(TimeoutException), "Uninstallation process hung")]
    [InlineData(typeof(UnauthorizedAccessException), "UAC prompt dismissed")]
    [InlineData(typeof(Win32Exception), "Access is denied (0x5)")]
    public async Task UninstallAppAsync_WhenServiceThrowsVariousExceptions_GuaranteesCleanResetAndPreservesInventory(Type exceptionType, string errorMessage)
    {
        var vm = CreateViewModel();
        var app = new WingetInstalledApp("TargetApp", "Target.App.Id", "2.0.0", null, "winget");
        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        Assert.Single(vm.InstalledApps);
        var appVm = vm.InstalledApps[0];

        var ex = (Exception)Activator.CreateInstance(exceptionType, errorMessage)!;
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Target.App.Id", It.IsAny<CancellationToken>()))
            .ThrowsAsync(ex);

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        // Assert item busy state and status
        Assert.False(appVm.IsUninstalling, "IsUninstalling must be false after exception");
        Assert.NotEqual("Uninstalling...", appVm.Status);
        Assert.StartsWith("Failed:", appVm.Status);
        Assert.Contains(errorMessage, appVm.Status);

        // Target application must NOT be removed from installed list on failure
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Target.App.Id", vm.InstalledApps[0].Id);

        // Assert ViewModel overall state is cleanly reset
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Equal("Uninstallation failed.", vm.OperationProgressText);
        Assert.Contains(errorMessage, vm.StatusMessage);
    }

    [Theory]
    [InlineData(typeof(IOException), "Network stream closed prematurely")]
    [InlineData(typeof(TimeoutException), "Download socket timed out")]
    [InlineData(typeof(InvalidOperationException), "Corrupt package hash")]
    public async Task UpdateAppAsync_WhenServiceThrowsVariousExceptions_GuaranteesCleanResetAndPreservesUpdateItem(Type exceptionType, string errorMessage)
    {
        var vm = CreateViewModel();
        var update = new WingetUpdateItem("UpdateApp", "Update.App.Id", "1.0", "1.1", "winget");
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { update });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Single(vm.AvailableUpdates);
        var updateVm = vm.AvailableUpdates[0];

        var ex = (Exception)Activator.CreateInstance(exceptionType, errorMessage)!;
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Update.App.Id", It.IsAny<CancellationToken>()))
            .ThrowsAsync(ex);

        await vm.UpdateAppCommand.ExecuteAsync(updateVm);

        // Assert item busy state and status
        Assert.False(updateVm.IsUpdating, "IsUpdating must be false after exception");
        Assert.NotEqual("Updating...", updateVm.Status);
        Assert.StartsWith("Failed:", updateVm.Status);
        Assert.Contains(errorMessage, updateVm.Status);

        // Target update must NOT be removed on failure
        Assert.Single(vm.AvailableUpdates);

        // Assert ViewModel overall state is cleanly reset
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Equal("Update failed.", vm.OperationProgressText);
        Assert.Contains(errorMessage, vm.StatusMessage);
    }

    // =========================================================================
    // 2. ADVERSARIAL EDGE CASES IN EXCEPTION HANDLING
    // =========================================================================

    [Fact]
    public async Task InstallAppAsync_WhenExceptionMessageIsNull_DoesNotCrash()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("NullMsgApp", "Null.Msg.App", "1.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Null.Msg.App", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new Exception((string?)null));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        Assert.False(pkgVm.IsInstalling);
        Assert.NotEqual("Installing...", pkgVm.Status);
        Assert.StartsWith("Failed:", pkgVm.Status);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task InstallAppAsync_WhenTargetVmNotInSearchResults_HandlesGracefullyWithoutNullRef()
    {
        var vm = CreateViewModel();
        // SearchResults is empty, but we pass packageId directly
        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Orphan.App", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Install engine failure"));

        await vm.InstallAppAsync("Orphan.App", "Orphan Display Name");

        Assert.False(vm.IsBusy);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Contains("Install engine failure", vm.StatusMessage);
    }

    // =========================================================================
    // 3. BATCH UPGRADE FAULT BOUNDARIES & LOOP CONTINUATION
    // =========================================================================

    [Fact]
    public async Task UpgradeAllApps_WhenFirstItemThrowsException_ContinuesLoopToSubsequentItems()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("Item1_Broken", "broken.item.1", "1.0", "1.1", "winget"),
            new("Item2_Good", "good.item.2", "2.0", "2.1", "winget"),
            new("Item3_Good", "good.item.3", "3.0", "3.1", "winget"),
            new("Item4_Broken", "broken.item.4", "4.0", "4.1", "winget"),
            new("Item5_Good", "good.item.5", "5.0", "5.1", "winget")
        };

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(5, vm.AvailableUpdates.Count);

        // Setup item behaviors:
        // Item 1 throws exception
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("broken.item.1", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new IOException("Disk read error on item 1"));

        // Item 2 succeeds
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("good.item.2", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("good.item.2", "Item2_Good", "winget", true, "Success", true));

        // Item 3 succeeds
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("good.item.3", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("good.item.3", "Item3_Good", "winget", true, "Success", true));

        // Item 4 throws exception
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("broken.item.4", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new TimeoutException("Network timeout on item 4"));

        // Item 5 succeeds
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("good.item.5", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("good.item.5", "Item5_Good", "winget", true, "Success", true));

        // Execute batch upgrade
        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // 1. Verify all 5 items were invoked across the loop
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("broken.item.1", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("good.item.2", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("good.item.3", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("broken.item.4", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("good.item.5", It.IsAny<CancellationToken>()), Times.Once);

        // 2. Verify collection state: 3 succeeded items removed, 2 broken items remain
        Assert.Equal(2, vm.AvailableUpdates.Count);

        var item1 = vm.AvailableUpdates.FirstOrDefault(u => u.Id == "broken.item.1");
        Assert.NotNull(item1);
        Assert.False(item1.IsUpdating, "Item 1 IsUpdating must be false");
        Assert.NotEqual("Updating...", item1.Status);
        Assert.Contains("Disk read error on item 1", item1.Status);

        var item4 = vm.AvailableUpdates.FirstOrDefault(u => u.Id == "broken.item.4");
        Assert.NotNull(item4);
        Assert.False(item4.IsUpdating, "Item 4 IsUpdating must be false");
        Assert.NotEqual("Updating...", item4.Status);
        Assert.Contains("Network timeout on item 4", item4.Status);

        // 3. Verify batch summary and progress
        Assert.Equal(100, vm.OperationProgress);
        Assert.Equal("Batch update completed.", vm.OperationProgressText);
        Assert.Equal("Batch upgrade finished: 3 of 5 package(s) updated.", vm.UpdatesStatusText);

        // 4. Verify overall failure status reflecting the first exception
        Assert.Contains("Upgrade All Applications failed: Disk read error on item 1", vm.StatusMessage);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);

        // 5. Verify batch command remains executable for retry of remaining 2 items
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task UpgradeAllApps_WhenAllItemsThrowExceptions_ProcessesEveryItemAndRecoversState()
    {
        var vm = CreateViewModel();

        var updates = Enumerable.Range(1, 8)
            .Select(i => new WingetUpdateItem($"FaultyApp_{i}", $"faulty.app.{i}", "1.0", "2.0", "winget"))
            .ToList();

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(8, vm.AvailableUpdates.Count);

        for (int i = 1; i <= 8; i++)
        {
            string id = $"faulty.app.{i}";
            _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync(id, It.IsAny<CancellationToken>()))
                .ThrowsAsync(new InvalidOperationException($"Fault in package {i}"));
        }

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // Assert all 8 items were attempted
        for (int i = 1; i <= 8; i++)
        {
            string id = $"faulty.app.{i}";
            _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync(id, It.IsAny<CancellationToken>()), Times.Once);
        }

        // All 8 items must remain in AvailableUpdates
        Assert.Equal(8, vm.AvailableUpdates.Count);
        Assert.All(vm.AvailableUpdates, item =>
        {
            Assert.False(item.IsUpdating);
            Assert.NotEqual("Updating...", item.Status);
            Assert.StartsWith("Failed:", item.Status);
        });

        // Summary and progress
        Assert.Equal("Batch upgrade finished: 0 of 8 package(s) updated.", vm.UpdatesStatusText);
        Assert.Equal(100, vm.OperationProgress);
        Assert.Equal("Batch update completed.", vm.OperationProgressText);

        // Overall status reflects first item's failure
        Assert.Contains("Upgrade All Applications failed: Fault in package 1", vm.StatusMessage);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UpgradeAllApps_WithMixedFailuresAndExceptions_AccuratelyCapturesFirstThrownException()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1_ResultFail", "app.result.fail", "1.0", "1.1", "winget"),
            new("App2_Exception", "app.ex.1", "2.0", "2.1", "winget"),
            new("App3_Success", "app.success", "3.0", "3.1", "winget"),
            new("App4_Exception", "app.ex.2", "4.0", "4.1", "winget")
        };

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        // App 1 returns non-success result (not an exception)
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.result.fail", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.result.fail", "App1_ResultFail", "winget", false, "Hash mismatch error", true));

        // App 2 throws an exception
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.ex.1", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("First real exception on app 2"));

        // App 3 succeeds
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.success", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.success", "App3_Success", "winget", true, "Success", true));

        // App 4 throws another exception
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.ex.2", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new IOException("Second exception on app 4"));

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // Loop processed all 4
        Assert.Equal(3, vm.AvailableUpdates.Count);

        // Check App 1 status
        var app1 = vm.AvailableUpdates.First(u => u.Id == "app.result.fail");
        Assert.Equal("Failed: Hash mismatch error", app1.Status);
        Assert.False(app1.IsUpdating);

        // Check App 2 status
        var app2 = vm.AvailableUpdates.First(u => u.Id == "app.ex.1");
        Assert.Contains("First real exception on app 2", app2.Status);
        Assert.False(app2.IsUpdating);

        // Check App 4 status
        var app4 = vm.AvailableUpdates.First(u => u.Id == "app.ex.2");
        Assert.Contains("Second exception on app 4", app4.Status);
        Assert.False(app4.IsUpdating);

        // Overall status reflects App 2's exception (since App 1 did not throw)
        Assert.Contains("Upgrade All Applications failed: First real exception on app 2", vm.StatusMessage);
        Assert.Equal("Batch upgrade finished: 1 of 4 package(s) updated.", vm.UpdatesStatusText);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UpgradeAllApps_WhenLastItemThrowsException_PreservesPrecedingSuccesses()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1_Good", "app.good.1", "1.0", "1.1", "winget"),
            new("App2_Good", "app.good.2", "2.0", "2.1", "winget"),
            new("App3_TailFail", "app.tail.fail", "3.0", "3.1", "winget")
        };

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.good.1", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.good.1", "App1_Good", "winget", true, "Success", true));
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.good.2", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.good.2", "App2_Good", "winget", true, "Success", true));
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("app.tail.fail", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Tail item failure"));

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // Only tail item remains
        Assert.Single(vm.AvailableUpdates);
        Assert.Equal("app.tail.fail", vm.AvailableUpdates[0].Id);
        Assert.False(vm.AvailableUpdates[0].IsUpdating);
        Assert.Contains("Tail item failure", vm.AvailableUpdates[0].Status);

        Assert.Equal("Batch upgrade finished: 2 of 3 package(s) updated.", vm.UpdatesStatusText);
        Assert.Contains("Tail item failure", vm.StatusMessage);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 4. LARGE-SCALE MONTE CARLO BATCH STRESS HARNESS
    // =========================================================================

    [Fact]
    public async Task UpgradeAllApps_LargeBatchMonteCarloFaultInjection_GuaranteesConsistentState()
    {
        var vm = CreateViewModel();
        const int totalItems = 30;

        var updates = Enumerable.Range(1, totalItems)
            .Select(i => new WingetUpdateItem($"BatchApp_{i:D2}", $"batch.app.{i:D2}", "1.0.0", "2.0.0", "winget"))
            .ToList();

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(totalItems, vm.AvailableUpdates.Count);

        int expectedSuccess = 0;
        int expectedFailResult = 0;
        int expectedException = 0;

        for (int i = 1; i <= totalItems; i++)
        {
            string id = $"batch.app.{i:D2}";
            int mode = i % 3; // 0 = Success, 1 = Fail Result, 2 = Thrown Exception

            switch (mode)
            {
                case 0:
                    expectedSuccess++;
                    _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync(id, It.IsAny<CancellationToken>()))
                        .ReturnsAsync(new AppInstallResult(id, $"BatchApp_{i:D2}", "winget", true, "OK", true));
                    break;
                case 1:
                    expectedFailResult++;
                    _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync(id, It.IsAny<CancellationToken>()))
                        .ReturnsAsync(new AppInstallResult(id, $"BatchApp_{i:D2}", "winget", false, $"Error code {1000 + i}", true));
                    break;
                case 2:
                    expectedException++;
                    _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync(id, It.IsAny<CancellationToken>()))
                        .ThrowsAsync(new IOException($"Simulated I/O crash on {id}"));
                    break;
            }
        }

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // Verification:
        // 1. Expected number of items remaining in AvailableUpdates
        int expectedRemaining = expectedFailResult + expectedException;
        Assert.Equal(expectedRemaining, vm.AvailableUpdates.Count);

        // 2. No remaining item has IsUpdating == true or Status == "Updating..."
        Assert.All(vm.AvailableUpdates, item =>
        {
            Assert.False(item.IsUpdating, $"Item {item.Id} must have IsUpdating == false");
            Assert.NotEqual("Updating...", item.Status);
            Assert.StartsWith("Failed:", item.Status);
        });

        // 3. Batch tally matches exactly
        Assert.Equal($"Batch upgrade finished: {expectedSuccess} of {totalItems} package(s) updated.", vm.UpdatesStatusText);
        Assert.Equal(100, vm.OperationProgress);

        // 4. Busy flag is reset
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
    }
}
