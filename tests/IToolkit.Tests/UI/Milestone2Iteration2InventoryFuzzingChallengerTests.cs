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

/// <summary>
/// Empirical Challenger Harness for Milestone 2 Iteration 2:
/// Rigorous stress-testing of inventory synchronization, filtered uninstallation,
/// cross-collection AvailableUpdates purging, and concurrency resilience.
/// </summary>
public class Milestone2Iteration2InventoryFuzzingChallengerTests : IDisposable
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    public Milestone2Iteration2InventoryFuzzingChallengerTests()
    {
        ViewModelBase.ResetOperationEvents();
        // Default confirmation: always approve uninstalls in stress tests
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
    // 1. FUZZING & RAPID FILTER MUTATION DURING UNINSTALLATION
    // =========================================================================

    [Fact]
    public async Task Fuzzing_RapidFilterUpdates_InterleavedWithUninstall_GuaranteesCompletePurge()
    {
        var vm = CreateViewModel();

        // 1. Populate inventory with 200 applications
        var allApps = Enumerable.Range(1, 200)
            .Select(i => new WingetInstalledApp(
                $"Application_{i:D3}",
                $"Publisher{i % 10}.App{i:D3}",
                $"1.{i}.0",
                i % 5 == 0 ? $"1.{i + 1}.0" : null,
                "winget"))
            .ToList();

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(allApps);

        await vm.RefreshInstalledAsync();
        Assert.Equal(200, vm.InstalledApps.Count);

        // 2. Select 25 apps distributed across the inventory to uninstall
        var appsToUninstall = allApps.Where((_, idx) => idx % 8 == 0).Take(25).ToList();
        var uninstalledIds = new HashSet<string>(appsToUninstall.Select(a => a.Id), StringComparer.OrdinalIgnoreCase);

        string[] fuzzFilters =
        [
            "", "   ", "App", "0", "01", "02", "Publisher1", "XYZ999", "app_00", "Application",
            "[", "]", "(", ")", "+", "-", "*", ".", "200", "150", "99"
        ];

        var rand = new Random(42);

        // Interleave filter mutations before, during service execution, and after
        foreach (var app in appsToUninstall)
        {
            _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync(app.Id, It.IsAny<CancellationToken>()))
                .Returns(async () =>
                {
                    // Mutate filter while service uninstallation is in flight
                    vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];
                    await Task.Yield();
                    vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];
                    return new AppInstallResult(app.Id, app.Name, "winget", true, "Uninstalled", true);
                });
        }

        // 3. Uninstall all 25 target apps sequentially while filter is mutating
        foreach (var target in appsToUninstall)
        {
            // Rapidly switch filters right before uninstallation
            vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];
            vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];

            await vm.UninstallAppAsync(target.Id, target.Name);

            // Rapidly switch filters right after uninstallation
            vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];
            vm.InstalledFilterQuery = fuzzFilters[rand.Next(fuzzFilters.Length)];
        }

        // 4. Reset filter to empty to expose full underlying inventory
        vm.InstalledFilterQuery = string.Empty;

        // Assert: Exactly 175 apps remain in InstalledApps
        Assert.Equal(175, vm.InstalledApps.Count);

        // Assert: None of the uninstalled apps resurface in the inventory
        foreach (var remaining in vm.InstalledApps)
        {
            Assert.DoesNotContain(remaining.Id, uninstalledIds);
        }

        // Assert: Re-applying any filter never yields any uninstalled package
        foreach (var filter in fuzzFilters)
        {
            vm.InstalledFilterQuery = filter;
            foreach (var filteredItem in vm.InstalledApps)
            {
                Assert.DoesNotContain(filteredItem.Id, uninstalledIds);
            }
        }

        // Final verification on status text
        vm.InstalledFilterQuery = string.Empty;
        Assert.Contains("Loaded 175 installed application(s).", vm.InstalledStatusText);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 2. CROSS-COLLECTION PURGE (AVAILABLE UPDATES & INVENTORY SYNCHRONIZATION)
    // =========================================================================

    [Fact]
    public async Task CrossCollectionPurge_UninstallFilteredAppWithPendingUpdate_PurgesAvailableUpdatesImmediately()
    {
        var vm = CreateViewModel();

        // 1. Setup 5 installed apps
        var installed = new List<WingetInstalledApp>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget"),
            new("Git", "Git.Git", "2.46.0", "2.47.1", "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.0", "8.7.1", "winget"),
            new("Google Chrome", "Google.Chrome", "131.0", null, "winget"),
            new("Mozilla Firefox", "Mozilla.Firefox", "133.0", null, "winget")
        };

        // 2. Setup 3 available updates matching the first 3 installed apps
        var updates = new List<WingetUpdateItem>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget"),
            new("Git", "Git.Git", "2.46.0", "2.47.1", "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.0", "8.7.1", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Equal(5, vm.InstalledApps.Count);
        Assert.Equal(3, vm.AvailableUpdates.Count);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
        Assert.Equal("Found 3 available package update(s).", vm.UpdatesStatusText);

        // 3. Filter installed apps to "Chrome" (so 7-Zip, Git, Notepad++ are hidden from UI)
        vm.InstalledFilterQuery = "Chrome";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Google.Chrome", vm.InstalledApps[0].Id);
        Assert.Equal("Showing 1 of 5 installed application(s).", vm.InstalledStatusText);

        // 4. Uninstall 7-Zip (which has a pending update and is currently filtered out)
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "winget", true, "Uninstalled", true));

        await vm.UninstallAppAsync("7zip.7zip", "7-Zip");

        // Verify: 7-Zip is purged from AvailableUpdates immediately
        Assert.Equal(2, vm.AvailableUpdates.Count);
        Assert.DoesNotContain(vm.AvailableUpdates, u => u.Id == "7zip.7zip");
        Assert.Equal("Found 2 available package update(s).", vm.UpdatesStatusText);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));

        // Verify: InstalledStatusText correctly reflects that 7-Zip was uninstalled
        Assert.Equal("Showing 1 of 4 installed application(s).", vm.InstalledStatusText);

        // 5. Uninstall Git (also pending update, still filtered)
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Git.Git", "Git", "winget", true, "Uninstalled", true));

        await vm.UninstallAppAsync("Git.Git", "Git");

        Assert.Single(vm.AvailableUpdates);
        Assert.Equal("Notepad++.Notepad++", vm.AvailableUpdates[0].Id);
        Assert.Equal("Found 1 available package update(s).", vm.UpdatesStatusText);
        Assert.Equal("Showing 1 of 3 installed application(s).", vm.InstalledStatusText);

        // 6. Uninstall Notepad++ (the last update)
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Notepad++.Notepad++", "Notepad++", "winget", true, "Uninstalled", true));

        await vm.UninstallAppAsync("Notepad++.Notepad++", "Notepad++");

        // Verify AvailableUpdates is now completely empty
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));
        Assert.Equal("Showing 1 of 2 installed application(s).", vm.InstalledStatusText);

        // 7. Clear filter and verify master inventory has exactly Chrome and Firefox
        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(2, vm.InstalledApps.Count);
        Assert.Contains(vm.InstalledApps, a => a.Id == "Google.Chrome");
        Assert.Contains(vm.InstalledApps, a => a.Id == "Mozilla.Firefox");
        Assert.Equal("Loaded 2 installed application(s).", vm.InstalledStatusText);
    }

    [Fact]
    public async Task CrossCollectionPurge_CaseInsensitiveMatching_PurgesDespiteCasingDifferences()
    {
        var vm = CreateViewModel();

        // Installed with lowercase ID
        var installed = new List<WingetInstalledApp>
        {
            new("Visual Studio Code", "microsoft.visualstudiocode", "1.95.0", "1.96.0", "winget")
        };

        // Available update with UPPERCASE ID
        var updates = new List<WingetUpdateItem>
        {
            new("Visual Studio Code", "MICROSOFT.VISUALSTUDIOCODE", "1.95.0", "1.96.0", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Single(vm.AvailableUpdates);

        // Uninstall invoked with PascalCase ID
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Microsoft.VisualStudioCode", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Microsoft.VisualStudioCode", "VS Code", "winget", true, "Uninstalled", true));

        await vm.UninstallAppAsync("Microsoft.VisualStudioCode", "VS Code");

        // Both collections must be purged regardless of casing mismatch
        Assert.Empty(vm.InstalledApps);
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
    }

    // =========================================================================
    // 3. SUBSTRING COLLISION & EXACT MATCH DISCRIMINATION
    // =========================================================================

    [Fact]
    public async Task SubstringCollision_UninstallTarget_DoesNotPurgePrefixMatchingPackages()
    {
        var vm = CreateViewModel();

        // Three packages where one ID is an exact prefix substring of others
        var installed = new List<WingetInstalledApp>
        {
            new("App Base", "Vendor.App", "1.0", "1.1", "winget"),
            new("App Plugin", "Vendor.App.Plugin", "1.0", "1.1", "winget"),
            new("App Core", "Vendor.App.Core", "1.0", "1.1", "winget")
        };

        var updates = new List<WingetUpdateItem>
        {
            new("App Base", "Vendor.App", "1.0", "1.1", "winget"),
            new("App Plugin", "Vendor.App.Plugin", "1.0", "1.1", "winget"),
            new("App Core", "Vendor.App.Core", "1.0", "1.1", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Equal(3, vm.InstalledApps.Count);
        Assert.Equal(3, vm.AvailableUpdates.Count);

        // Uninstall ONLY "Vendor.App"
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Vendor.App", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.App", "App Base", "winget", true, "Uninstalled", true));

        await vm.UninstallAppAsync("Vendor.App", "App Base");

        // "Vendor.App" must be removed, but "Vendor.App.Plugin" and "Vendor.App.Core" MUST remain!
        Assert.Equal(2, vm.InstalledApps.Count);
        Assert.Contains(vm.InstalledApps, a => a.Id == "Vendor.App.Plugin");
        Assert.Contains(vm.InstalledApps, a => a.Id == "Vendor.App.Core");
        Assert.DoesNotContain(vm.InstalledApps, a => a.Id == "Vendor.App");

        Assert.Equal(2, vm.AvailableUpdates.Count);
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "Vendor.App.Plugin");
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "Vendor.App.Core");
        Assert.DoesNotContain(vm.AvailableUpdates, u => u.Id == "Vendor.App");
    }

    // =========================================================================
    // 4. UNTRACKED PACKAGE / DIRECT ID CALL RESILIENCE
    // =========================================================================

    [Fact]
    public async Task UntrackedPackage_UninstallDirectlyById_WhenNotInInventory_ExecutesSafely()
    {
        var vm = CreateViewModel();

        // Inventory contains some app, but NOT the package we are uninstalling
        var installed = new List<WingetInstalledApp>
        {
            new("Existing App", "Vendor.ExistingApp", "1.0", null, "winget")
        };

        // AvailableUpdates DOES happen to contain the package (e.g. detected externally)
        var updates = new List<WingetUpdateItem>
        {
            new("External App", "Vendor.ExternalApp", "1.0", "2.0", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Vendor.ExternalApp", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.ExternalApp", "External App", "winget", true, "Uninstalled", true));

        // Direct call without targetVm in _allInstalledApps
        await vm.UninstallAppAsync("Vendor.ExternalApp", "External App");

        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync("Vendor.ExternalApp", It.IsAny<CancellationToken>()), Times.Once);

        // Existing app is untouched
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Vendor.ExistingApp", vm.InstalledApps[0].Id);

        // External app was purged from AvailableUpdates
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 5. UNINSTALL SERVICE FAILURE / EXCEPTION WHILE FILTERED
    // =========================================================================

    [Fact]
    public async Task Uninstall_WhenServiceFails_WhileFiltered_DoesNotPurgeInventoryOrUpdates()
    {
        var vm = CreateViewModel();

        var installed = new List<WingetInstalledApp>
        {
            new("Protected App", "Vendor.ProtectedApp", "1.0", "2.0", "winget"),
            new("Other App", "Vendor.OtherApp", "1.0", null, "winget")
        };

        var updates = new List<WingetUpdateItem>
        {
            new("Protected App", "Vendor.ProtectedApp", "1.0", "2.0", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        // Filter to Other App
        vm.InstalledFilterQuery = "Other";
        Assert.Single(vm.InstalledApps);

        // Service returns failure result (e.g. exit code failure)
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Vendor.ProtectedApp", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Vendor.ProtectedApp", "Protected App", "winget", false, "Uninstaller exited with code 1603", true));

        await vm.UninstallAppAsync("Vendor.ProtectedApp", "Protected App");

        // Clear filter
        vm.InstalledFilterQuery = string.Empty;

        // Protected App MUST STILL be in installed apps and updates!
        Assert.Equal(2, vm.InstalledApps.Count);
        Assert.Contains(vm.InstalledApps, a => a.Id == "Vendor.ProtectedApp");

        Assert.Single(vm.AvailableUpdates);
        Assert.Equal("Vendor.ProtectedApp", vm.AvailableUpdates[0].Id);

        // Protected app status should reflect failure
        var app = vm.InstalledApps.First(a => a.Id == "Vendor.ProtectedApp");
        Assert.Equal("Failed: Uninstaller exited with code 1603", app.Status);
        Assert.False(app.IsUninstalling);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task Uninstall_WhenServiceThrowsException_WhileFiltered_RecoversStateAndPreservesCollections()
    {
        var vm = CreateViewModel();

        var installed = new List<WingetInstalledApp>
        {
            new("Locked App", "Vendor.LockedApp", "1.0", "2.0", "winget")
        };

        var updates = new List<WingetUpdateItem>
        {
            new("Locked App", "Vendor.LockedApp", "1.0", "2.0", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        // Filter out Locked App
        vm.InstalledFilterQuery = "NonExistentFilter";
        Assert.Empty(vm.InstalledApps);

        // Service throws unexpected fatal exception
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Vendor.LockedApp", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new System.IO.FileLoadException("DLL hijack blocked by OS"));

        await vm.UninstallAppAsync("Vendor.LockedApp", "Locked App");

        // Busy flags reset
        Assert.False(vm.IsBusy);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);

        // Clear filter: Locked App is still in master inventory
        vm.InstalledFilterQuery = string.Empty;
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Vendor.LockedApp", vm.InstalledApps[0].Id);

        // Update is still preserved
        Assert.Single(vm.AvailableUpdates);
        Assert.Equal("Vendor.LockedApp", vm.AvailableUpdates[0].Id);

        var appVm = vm.InstalledApps[0];
        Assert.False(appVm.IsUninstalling);
        Assert.Contains("Failed: DLL hijack blocked by OS", appVm.Status);
    }

    // =========================================================================
    // 6. CONCURRENT & RAPID DOUBLE-UNINSTALL EXECUTION GUARD
    // =========================================================================

    [Fact]
    public async Task ConcurrentUninstall_RapidParallelClicks_OnlyOneSucceedsSecondBlockedByBusyGuard()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Concurrency Target", "Target.App", "1.0", null, "winget");
        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        var appVm = vm.InstalledApps[0];

        var tcs = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Target.App", It.IsAny<CancellationToken>()))
            .Returns(tcs.Task);

        // Fire 10 parallel uninstall invocations
        var tasks = Enumerable.Range(0, 10)
            .Select(_ => vm.UninstallAppCommand.ExecuteAsync(appVm))
            .ToArray();

        // AppVm should be marked uninstalling
        Assert.True(appVm.IsUninstalling);
        Assert.Equal("Uninstalling...", appVm.Status);

        // Complete the mock uninstallation
        tcs.SetResult(new AppInstallResult("Target.App", "Concurrency Target", "winget", true, "Uninstalled", true));
        await Task.WhenAll(tasks);

        // Verify service was called EXACTLY ONCE (busy guard blocked the other 9)
        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync("Target.App", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.InstalledApps);
        Assert.False(vm.IsBusy);
    }
}
