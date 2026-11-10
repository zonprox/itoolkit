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
/// Empirical challenge test suite for AppManagementViewModel:
/// 1. Uninstallation safety confirmation blocking & user cancellation resilience.
/// 2. Batch upgrade partial failures, sequencing, progress tracking, and state preservation.
/// 3. Service exception fault tolerance, busy state recovery, error logging, and non-crashing behavior.
/// </summary>
public class AppManagementViewModelEmpiricalChallengerTests : IDisposable
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    public AppManagementViewModelEmpiricalChallengerTests()
    {
        ViewModelBase.ResetOperationEvents();
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private AppManagementViewModel CreateViewModel(bool includeConfirmationService = true)
    {
        return new AppManagementViewModel(
            _appInstallerMock.Object,
            includeConfirmationService ? _confirmationMock.Object : null,
            _loggerMock.Object);
    }

    // =========================================================================
    // CHALLENGE AREA 1: UNINSTALLATION SAFETY CONFIRMATION WORKFLOWS
    // =========================================================================

    [Fact]
    public async Task UninstallApp_WhenUserCancelsConfirmation_NeverInvokesUninstallService()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Git", "Git.Git", "2.47.1", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        Assert.Single(vm.InstalledApps);
        var appVm = vm.InstalledApps[0];

        // User explicitly cancels confirmation dialog
        _confirmationMock.Setup(c => c.ConfirmAsync(
            It.Is<string>(title => title.Contains("Uninstall Git")),
            It.Is<string>(msg => msg.Contains("Git.Git")),
            It.IsAny<string>()))
            .ReturnsAsync(false);

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        // Assert service was NEVER called
        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);

        // Assert item was NOT removed from collection
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Git.Git", vm.InstalledApps[0].Id);

        // Assert item status remains Installed and not uninstalling
        Assert.Equal("Installed", appVm.Status);
        Assert.False(appVm.IsUninstalling);

        // Assert operation progress was not advanced
        Assert.Equal(0, vm.OperationProgress);

        // Assert cancellation was recorded in log
        _loggerMock.Verify(l => l.LogInfo(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task UninstallApp_ViaSubViewModelCommand_WhenUserCancels_BlocksUninstallation()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Visual Studio Code", "Microsoft.VisualStudioCode", "1.95.0", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        Assert.Single(vm.InstalledApps);
        var appVm = vm.InstalledApps[0];

        // Simulate user clicking "Cancel" in confirmation dialog
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(false);

        // Trigger via direct button command on sub-item
        await appVm.UninstallCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Installed", appVm.Status);
        Assert.False(appVm.IsUninstalling);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public async Task UninstallApp_WithEmptyOrNullPackageId_DoesNotPromptOrInvokeService(string? packageId)
    {
        var vm = CreateViewModel();

        await vm.UninstallAppAsync(packageId!);

        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task UninstallApp_WhenConfirmationServiceIsNull_ProceedsWithUninstallation()
    {
        // When constructed without confirmation service (null)
        var vm = CreateViewModel(includeConfirmationService: false);

        var app = new WingetInstalledApp("7-Zip", "7zip.7zip", "24.08", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        var appVm = vm.InstalledApps[0];

        _appInstallerMock.Setup(a => a.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "Winget", true, "Uninstalled", true));

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.InstalledApps);
        Assert.Equal(100, vm.OperationProgress);
    }

    [Fact]
    public async Task UninstallApp_WhenConfirmationThrowsException_NeverInvokesUninstallService()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Git", "Git.Git", "2.47.1", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        var appVm = vm.InstalledApps[0];

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ThrowsAsync(new InvalidOperationException("Failed to display confirmation window"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => vm.UninstallAppCommand.ExecuteAsync(appVm));

        // Critical safety assertion: uninstall service is NEVER called if confirmation cannot be completed
        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Single(vm.InstalledApps);
    }

    // =========================================================================
    // CHALLENGE AREA 2: BATCH UPGRADE-ALL WORKFLOW & PARTIAL FAILURES
    // =========================================================================

    [Fact]
    public async Task UpgradeAllApps_WithPartialFailures_ContinuesSequenceAndReportsAccurateTally()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.0", "8.7.1", "winget"),
            new("Git", "Git.Git", "2.46.0", "2.47.1", "winget"),
            new("VLC media player", "VideoLAN.VLC", "3.0.20", "3.0.21", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        // 7zip succeeds
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "Winget", true, "Upgraded", true));

        // Notepad++ fails with hash mismatch (0x8A150014)
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Notepad++.Notepad++", "Notepad++", "Winget", false, "Exit code 0x8A150014: Check hash failed", true));

        // Git succeeds
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Git.Git", "Git", "Winget", true, "Upgraded", true));

        // VLC fails with installer busy (1618)
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("VideoLAN.VLC", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("VideoLAN.VLC", "VLC", "Winget", false, "Exit code 1618: Another installation in progress", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(4, vm.AvailableUpdates.Count);

        // Execute batch upgrade
        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // 1. Verify ALL 4 packages were attempted (batch did not abort upon Notepad++ failure)
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("VideoLAN.VLC", It.IsAny<CancellationToken>()), Times.Once);

        // 2. Verify accurate tally in UpdatesStatusText
        Assert.Contains("2 of 4 package(s) updated", vm.UpdatesStatusText);

        // 3. Verify batch completion progress
        Assert.Equal(100, vm.OperationProgress);
        Assert.Equal("Batch update completed.", vm.OperationProgressText);

        // 4. Verify successful items were removed and failed items remain with error statuses
        Assert.Equal(2, vm.AvailableUpdates.Count);

        var failedNotepad = vm.AvailableUpdates.FirstOrDefault(u => u.Id == "Notepad++.Notepad++");
        Assert.NotNull(failedNotepad);
        Assert.Contains("Check hash failed", failedNotepad.Status);
        Assert.False(failedNotepad.IsUpdating);

        var failedVlc = vm.AvailableUpdates.FirstOrDefault(u => u.Id == "VideoLAN.VLC");
        Assert.NotNull(failedVlc);
        Assert.Contains("Another installation in progress", failedVlc.Status);
        Assert.False(failedVlc.IsUpdating);

        // 5. Verify batch command remains executable so user can retry remaining updates
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task UpgradeAllApps_WhenAllFail_PreservesAllItemsAndReportsZeroSucceeded()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1", "App1.Id", "1.0", "2.0", "winget"),
            new("App2", "App2.Id", "1.0", "2.0", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("App", "App", "Winget", false, "Service unavailable", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("App1.Id", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("App2.Id", It.IsAny<CancellationToken>()), Times.Once);

        Assert.Contains("0 of 2 package(s) updated", vm.UpdatesStatusText);
        Assert.Equal(2, vm.AvailableUpdates.Count);
        Assert.All(vm.AvailableUpdates, item =>
        {
            Assert.Contains("Failed: Service unavailable", item.Status);
            Assert.False(item.IsUpdating);
        });
        Assert.Equal(100, vm.OperationProgress);
    }

    [Fact]
    public async Task UpgradeAllApps_WhenAvailableUpdatesIsEmpty_ExitsEarlyWithoutCallingService()
    {
        var vm = CreateViewModel();
        Assert.Empty(vm.AvailableUpdates);

        await vm.UpgradeAllAppsAsync();

        Assert.Equal("No available updates to install.", vm.UpdatesStatusText);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UpgradeAllApps_InterleavedSuccessAndFailures_CorrectlyCalculatesAndUpdates()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1", "app.1", "1.0", "1.1", "winget"),
            new("App2", "app.2", "2.0", "2.1", "winget"),
            new("App3", "app.3", "3.0", "3.1", "winget"),
            new("App4", "app.4", "4.0", "4.1", "winget"),
            new("App5", "app.5", "5.0", "5.1", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        // Pattern: Success, Fail, Success, Fail, Success
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.1", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.1", "App1", "Winget", true, "OK", true));
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.2", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.2", "App2", "Winget", false, "Fail 2", true));
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.3", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.3", "App3", "Winget", true, "OK", true));
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.4", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.4", "App4", "Winget", false, "Fail 4", true));
        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.5", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app.5", "App5", "Winget", true, "OK", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(5, vm.AvailableUpdates.Count);

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.Equal("Batch upgrade finished: 3 of 5 package(s) updated.", vm.UpdatesStatusText);
        Assert.Equal(2, vm.AvailableUpdates.Count);
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "app.2" && u.Status == "Failed: Fail 2");
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "app.4" && u.Status == "Failed: Fail 4");
        Assert.Equal(100, vm.OperationProgress);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task UpgradeAllApps_OnServiceException_RecoversBusyStateAndReportsFailure()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1", "app.1", "1.0", "1.1", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("app.1", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Fatal winget engine crash"));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Single(vm.AvailableUpdates);

        // Batch execution must not crash the caller
        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.Contains("Upgrade All Applications failed: Fatal winget engine crash", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Fatal winget engine crash"))), Times.Once);
    }

    // =========================================================================
    // CHALLENGE AREA 3: SERVICE EXCEPTION FAULT TOLERANCE & ERROR REPORTING
    // =========================================================================

    [Fact]
    public async Task SearchApps_OnServiceException_HandlesGracefullyWithoutCrashing()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "vscode";

        _appInstallerMock.Setup(a => a.SearchPackagesAsync("vscode", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("Network failure reaching winget CDN"));

        // Must not throw unhandled exception
        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.False(vm.IsSearching);
        Assert.Contains("Search Packages (vscode) failed: Network failure reaching winget CDN", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Network failure"))), Times.Once);
    }

    [Fact]
    public async Task RefreshInstalled_OnServiceException_RecoversBusyStateAndLogsError()
    {
        var vm = CreateViewModel();

        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new TimeoutException("Registry query timed out after 60 seconds"));

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.False(vm.IsLoadingInstalled);
        Assert.Contains("Refresh Installed Applications failed: Registry query timed out after 60 seconds", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Registry query timed out"))), Times.Once);
    }

    [Fact]
    public async Task CheckUpdates_OnServiceException_RecoversBusyStateAndLogsError()
    {
        var vm = CreateViewModel();

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Winget package index database is corrupt"));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.False(vm.IsCheckingUpdates);
        Assert.Contains("Check Available Updates failed: Winget package index database is corrupt", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Winget package index database is corrupt"))), Times.Once);
    }

    [Fact]
    public async Task InstallApp_OnServiceException_ResetsInstallingFlagAndLogsError()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("Google Chrome", "Google.Chrome", "131.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(a => a.InstallWingetPackageAsync("Google.Chrome", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new IOException("Disk quota exceeded while writing installer cache"));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        Assert.False(vm.IsBusy);
        Assert.False(pkgVm.IsInstalling);
        Assert.Contains("Install Google Chrome failed: Disk quota exceeded while writing installer cache", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Disk quota exceeded"))), Times.Once);
    }

    [Fact]
    public async Task UninstallApp_OnServiceException_ResetsUninstallingFlagAndLogsError()
    {
        var vm = CreateViewModel();
        var app = new WingetInstalledApp("Mozilla Firefox", "Mozilla.Firefox", "133.0", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        var appVm = vm.InstalledApps[0];

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(a => a.UninstallWingetPackageAsync("Mozilla.Firefox", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new Win32Exception(5, "Access is denied"));

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        Assert.False(vm.IsBusy);
        Assert.False(appVm.IsUninstalling);
        Assert.Contains("Uninstall Mozilla Firefox failed: Access is denied", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Access is denied"))), Times.Once);
    }

    [Fact]
    public async Task UpdateApp_OnServiceException_ResetsUpdatingFlagAndLogsError()
    {
        var vm = CreateViewModel();
        var update = new WingetUpdateItem("7-Zip", "7zip.7zip", "24.07", "24.08", "winget");
        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { update });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        var updateVm = vm.AvailableUpdates[0];

        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Elevation was refused by UAC"));

        await vm.UpdateAppCommand.ExecuteAsync(updateVm);

        Assert.False(vm.IsBusy);
        Assert.False(updateVm.IsUpdating);
        Assert.Contains("Update 7-Zip failed: Elevation was refused by UAC", vm.StatusMessage);
        _loggerMock.Verify(l => l.LogError(
            nameof(AppManagementViewModel),
            It.Is<string>(msg => msg.Contains("Elevation was refused by UAC"))), Times.Once);
    }

    [Fact]
    public async Task ConcurrencyGuard_WhenBusy_IgnoresConcurrentSearchExecution()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "git";
        vm.IsBusy = true; // Simulating another active operation

        await vm.SearchAppsAsync();

        // Must be rejected by ExecuteAsync concurrency guard
        _appInstallerMock.Verify(a => a.SearchPackagesAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }
}
