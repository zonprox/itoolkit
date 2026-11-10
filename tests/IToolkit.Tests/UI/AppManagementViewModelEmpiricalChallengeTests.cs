namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Moq;
using Xunit;

public class AppManagementViewModelEmpiricalChallengeTests : IDisposable
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    public AppManagementViewModelEmpiricalChallengeTests()
    {
        ViewModelBase.ResetOperationEvents();
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private AppManagementViewModel CreateViewModel()
    {
        return new AppManagementViewModel(
            _appInstallerMock.Object,
            _confirmationMock.Object,
            _loggerMock.Object);
    }

    // =========================================================================
    // 1. CONCURRENCY & RAPID CLICKS TESTS
    // =========================================================================

    [Fact]
    public async Task SearchAppsCommand_RapidParallelClicks_OnlyInvokesServiceOnce()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "python";

        var tcs = new TaskCompletionSource<IReadOnlyList<WingetPackage>>();
        _appInstallerMock.Setup(s => s.SearchPackagesAsync("python", It.IsAny<CancellationToken>()))
            .Returns(tcs.Task);

        // Fire 20 parallel executions simultaneously
        var tasks = Enumerable.Range(0, 20)
            .Select(_ => vm.SearchAppsCommand.ExecuteAsync(null))
            .ToArray();

        // Release the mock service
        tcs.SetResult(new List<WingetPackage>
        {
            new("Python 3.12", "Python.Python.3.12", "3.12.0", null, "winget")
        });

        await Task.WhenAll(tasks);

        // Assert service was called strictly once
        _appInstallerMock.Verify(s => s.SearchPackagesAsync("python", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Single(vm.SearchResults);
        Assert.False(vm.IsSearching);
        Assert.False(vm.IsBusy);

        // Subsequent search after completion must execute cleanly
        _appInstallerMock.Setup(s => s.SearchPackagesAsync("python", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetPackage>
            {
                new("Python 3.13", "Python.Python.3.13", "3.13.0", null, "winget")
            });

        await vm.SearchAppsCommand.ExecuteAsync(null);
        _appInstallerMock.Verify(s => s.SearchPackagesAsync("python", It.IsAny<CancellationToken>()), Times.Exactly(2));
        Assert.Single(vm.SearchResults);
        Assert.Equal("Python 3.13", vm.SearchResults[0].Name);
    }

    [Fact]
    public async Task InstallAppCommand_RapidParallelClicks_OnlyInvokesServiceOnce()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("Git", "Git.Git", "2.47.1", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        var tcs = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .Returns(tcs.Task);

        // Fire 20 parallel install clicks on the same package
        var tasks = Enumerable.Range(0, 20)
            .Select(_ => vm.InstallAppCommand.ExecuteAsync(pkgVm))
            .ToArray();

        Assert.True(pkgVm.IsInstalling);
        Assert.Equal("Installing...", pkgVm.Status);

        tcs.SetResult(new AppInstallResult("Git.Git", "Git", "winget", true, "Success", true));
        await Task.WhenAll(tasks);

        _appInstallerMock.Verify(s => s.InstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()), Times.Once);
        Assert.False(pkgVm.IsInstalling);
        Assert.Equal("Installed", pkgVm.Status);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UpgradeAllAppsCommand_RapidParallelClicks_OnlyInvokesBatchOnce()
    {
        var vm = CreateViewModel();
        var update1 = new WingetUpdateItem("7-Zip", "7zip.7zip", "24.07", "24.08", "winget");
        var update2 = new WingetUpdateItem("Git", "Git.Git", "2.47.0", "2.47.1", "winget");

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { update1, update2 });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        var tcs1 = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .Returns(tcs1.Task);
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Git.Git", "Git", "winget", true, "Upgraded", true));

        // Fire 15 parallel clicks on Upgrade All
        var tasks = Enumerable.Range(0, 15)
            .Select(_ => vm.UpgradeAllAppsCommand.ExecuteAsync(null))
            .ToArray();

        tcs1.SetResult(new AppInstallResult("7zip.7zip", "7-Zip", "winget", true, "Upgraded", true));
        await Task.WhenAll(tasks);

        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.AvailableUpdates);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 2. CANEXECUTE GUARDS TESTS
    // =========================================================================

    [Fact]
    public async Task CanExecuteGuards_DisabledWhileOperationIsBusy()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("7-Zip", "7zip.7zip", "24.08", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        var app = new WingetInstalledApp("7-Zip", "7zip.7zip", "24.08", null, "winget");
        var appVm = new InstalledAppViewModel(app);
        vm.InstalledApps.Add(appVm);

        var upd = new WingetUpdateItem("7-Zip", "7zip.7zip", "24.07", "24.08", "winget");
        var updVm = new AppUpdateViewModel(upd);
        vm.AvailableUpdates.Add(updVm);

        // Initially not busy
        Assert.True(vm.IsNotBusy);
        Assert.True(vm.SearchAppsCommand.CanExecute(null));
        Assert.True(vm.RefreshInstalledCommand.CanExecute(null));
        Assert.True(vm.CheckUpdatesCommand.CanExecute(null));
        Assert.True(vm.InstallAppCommand.CanExecute(pkgVm));
        Assert.True(vm.UninstallAppCommand.CanExecute(appVm));
        Assert.True(vm.UpdateAppCommand.CanExecute(updVm));
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));

        var tcs = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .Returns(tcs.Task);

        var installTask = vm.InstallAppCommand.ExecuteAsync(pkgVm);

        // While operation is in flight, IsBusy is true
        Assert.True(vm.IsBusy);
        Assert.False(vm.IsNotBusy);
        Assert.False(vm.SearchAppsCommand.CanExecute(null));
        Assert.False(vm.RefreshInstalledCommand.CanExecute(null));
        Assert.False(vm.CheckUpdatesCommand.CanExecute(null));
        Assert.False(vm.InstallAppCommand.CanExecute(pkgVm));
        Assert.False(vm.UninstallAppCommand.CanExecute(appVm));
        Assert.False(vm.UpdateAppCommand.CanExecute(updVm));
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));

        // Complete operation
        tcs.SetResult(new AppInstallResult("7zip.7zip", "7-Zip", "winget", true, "Success", true));
        await installTask;

        // Returns to ready
        Assert.True(vm.IsNotBusy);
        Assert.False(vm.IsBusy);
        Assert.True(vm.SearchAppsCommand.CanExecute(null));
        Assert.True(vm.RefreshInstalledCommand.CanExecute(null));
        Assert.True(vm.CheckUpdatesCommand.CanExecute(null));
    }

    // =========================================================================
    // 3. CANCELLATION & EXCEPTION RESILIENCE TESTS
    // =========================================================================

    [Fact]
    public async Task SearchAppsCommand_WhenOperationCanceledExceptionThrown_RecoversCleanly()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "curl";

        _appInstallerMock.Setup(s => s.SearchPackagesAsync("curl", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Operation was cancelled by user."));

        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.False(vm.IsSearching);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);

        // Verify ViewModel is still functional for a subsequent search
        _appInstallerMock.Setup(s => s.SearchPackagesAsync("curl", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetPackage> { new("cURL", "curl.curl", "8.10.0", null, "winget") });

        await vm.SearchAppsCommand.ExecuteAsync(null);
        Assert.Single(vm.SearchResults);
    }

    [Fact]
    public async Task RefreshInstalledCommand_WhenServiceThrows_RecoversCleanly()
    {
        var vm = CreateViewModel();

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Winget CLI failed with exit code 0x8A15000F"));

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.False(vm.IsLoadingInstalled);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // 4. RAPID FILTER TYPING STRESS TESTS
    // =========================================================================

    [Fact]
    public async Task InstalledFilterQuery_RapidTypingAndEdgeCases_DoesNotThrow()
    {
        var vm = CreateViewModel();

        // Populate with 500 installed apps
        var mockApps = Enumerable.Range(1, 500)
            .Select(i => new WingetInstalledApp($"Application {i:D4}", $"Publisher.App{i:D4}", $"1.{i}.0", null, "winget"))
            .ToList();

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(mockApps);

        await vm.RefreshInstalledAsync();
        Assert.Equal(500, vm.InstalledApps.Count);

        // Sequence of rapid keystrokes with edge cases
        string[] rapidKeystrokes =
        [
            "",
            "   ",
            "A",
            "App",
            "App0",
            "App00",
            "App001",
            "App0010",
            "NonExistentPackageXYZ",
            "",
            "publisher",
            "PUBLISHER.APP005",
            // Special characters that could break regex or indexing
            "[",
            "]",
            "(",
            ")",
            "*",
            "?",
            "+",
            "{",
            "}",
            "^",
            "$",
            "\\",
            "|",
            "Application 01",
            new string('X', 5000), // Very long string
            ""
        ];

        foreach (var query in rapidKeystrokes)
        {
            vm.InstalledFilterQuery = query;
            Assert.True(vm.InstalledApps.Count <= 500);
        }

        // Final empty query must restore all 500 items
        Assert.Equal(500, vm.InstalledApps.Count);
        Assert.Contains("Loaded 500 installed", vm.InstalledStatusText);
    }

    // =========================================================================
    // 5. BATCH UPGRADE RESILIENCE (PARTIAL FAILURE CONTINUATION)
    // =========================================================================

    [Fact]
    public async Task UpgradeAllAppsCommand_WhenOneItemFails_ContinuesUpdatingRemainingItems()
    {
        var vm = CreateViewModel();

        var item1 = new WingetUpdateItem("App1", "Vendor.App1", "1.0", "2.0", "winget");
        var item2 = new WingetUpdateItem("App2", "Vendor.App2", "1.0", "2.0", "winget");
        var item3 = new WingetUpdateItem("App3", "Vendor.App3", "1.0", "2.0", "winget");

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { item1, item2, item3 });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(3, vm.AvailableUpdates.Count);

        // Item 1 succeeds, Item 2 fails, Item 3 succeeds
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Vendor.App1", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.App1", "App1", "winget", true, "Success", true));
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Vendor.App2", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.App2", "App2", "winget", false, "Checksum verification failed", true));
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Vendor.App3", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.App3", "App3", "winget", true, "Success", true));

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // Item 1 and Item 3 removed, Item 2 remains with failure status
        Assert.Single(vm.AvailableUpdates);
        var remaining = vm.AvailableUpdates[0];
        Assert.Equal("Vendor.App2", remaining.Id);
        Assert.Contains("Failed: Checksum verification failed", remaining.Status);
        Assert.False(remaining.IsUpdating);

        Assert.Contains("2 of 3 package(s) updated", vm.UpdatesStatusText);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 6. ADVERSARIAL EDGE CASES & INTEGRITY TESTS
    // =========================================================================

    [Fact]
    public async Task UninstallAppAsync_WhenAppIsFilteredOut_UnderlyingInventoryIntegrity()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Git", "Git.Git", "2.47.1", null, "winget"),
            new("Google Chrome", "Google.Chrome", "131.0", null, "winget"),
            new("Mozilla Firefox", "Mozilla.Firefox", "133.0", null, "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);

        await vm.RefreshInstalledAsync();
        Assert.Equal(3, vm.InstalledApps.Count);

        // Apply filter so Google Chrome is hidden from the UI view
        vm.InstalledFilterQuery = "Git";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Git.Git", vm.InstalledApps[0].Id);

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Google.Chrome", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Google.Chrome", "Google Chrome", "winget", true, "Uninstalled", true));

        // Programmatic or indirect uninstall of Google Chrome by package ID while filtered
        await vm.UninstallAppAsync("Google.Chrome", "Google Chrome");

        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync("Google.Chrome", It.IsAny<CancellationToken>()), Times.Once);

        // Now clear filter: what apps are visible?
        vm.InstalledFilterQuery = string.Empty;

        // Check if Chrome was removed or if it stayed in _allInstalledApps
        bool chromeStillPresent = vm.InstalledApps.Any(a => a.Id == "Google.Chrome");
        Assert.False(chromeStillPresent, "Uninstalled package must be removed from the underlying inventory even if currently filtered in the UI");
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task InstallAppAsync_WhenServiceThrowsUnexpectedException_ResetsIsInstallingAndIsBusy()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("BrokenApp", "broken.app", "1.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("broken.app", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new System.IO.IOException("Disk I/O error during winget extraction"));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        Assert.False(pkgVm.IsInstalling);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
        Assert.NotEqual("Installing...", pkgVm.Status);
    }

    [Fact]
    public async Task UpgradeAllAppsCommand_WhenServiceThrowsUnexpectedException_ResetsIsUpdatingAndRecovers()
    {
        var vm = CreateViewModel();

        var item1 = new WingetUpdateItem("BrokenApp", "broken.app", "1.0", "2.0", "winget");
        var item2 = new WingetUpdateItem("GoodApp", "good.app", "1.0", "2.0", "winget");

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { item1, item2 });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        var app1Vm = vm.AvailableUpdates[0];

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("broken.app", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new System.IO.IOException("Connection reset by peer"));

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.False(app1Vm.IsUpdating, "IsUpdating should be reset to false even if exception is thrown");
        Assert.NotEqual("Updating...", app1Vm.Status);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UninstallAppAsync_WithoutConfirmationService_ExecutesDirectly()
    {
        // ViewModel created without ISafetyConfirmationService (null confirmation service)
        var vm = new AppManagementViewModel(_appInstallerMock.Object, confirmationService: null, _loggerMock.Object);

        var app = new WingetInstalledApp("App1", "Vendor.App1", "1.0", null, "winget");
        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        var appVm = vm.InstalledApps[0];

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Vendor.App1", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.App1", "App1", "winget", true, "Uninstalled", true));

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync("Vendor.App1", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.InstalledApps);
        Assert.False(vm.IsBusy);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public async Task ActionMethods_WithNullOrWhitespaceIds_GracefullyExitWithoutCallingService(string? packageId)
    {
        var vm = CreateViewModel();

        await vm.InstallAppAsync(packageId!);
        await vm.UninstallAppAsync(packageId!);
        await vm.UpdateAppAsync(packageId!);

        _appInstallerMock.Verify(s => s.InstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task CrossCommandInterleaving_SimultaneousSearchAndRefresh_DoesNotDeadlock()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "test";

        var searchTcs = new TaskCompletionSource<IReadOnlyList<WingetPackage>>();
        _appInstallerMock.Setup(s => s.SearchPackagesAsync("test", It.IsAny<CancellationToken>()))
            .Returns(searchTcs.Task);

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp>());

        // Start search
        var searchTask = vm.SearchAppsCommand.ExecuteAsync(null);

        // While search is running, try to refresh installed
        var refreshTask = vm.RefreshInstalledCommand.ExecuteAsync(null);

        // Finish search
        searchTcs.SetResult(new List<WingetPackage>());
        await Task.WhenAll(searchTask, refreshTask);

        // Refresh was either dropped because IsBusy was true, or executed sequentially
        Assert.False(vm.IsBusy);
        Assert.False(vm.IsSearching);
        Assert.False(vm.IsLoadingInstalled);
    }
}

