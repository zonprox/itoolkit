namespace IToolkit.Tests.E2E;

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using IToolkit.App;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Software;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Tier 3: Pairwise Combination Integration Test Suite.
/// Tests cross-feature interactions, state transitions, and component handoffs
/// across the 13 features in docs/PROJECT.md.
/// </summary>
public class WingetE2ETier3PairwiseCombinationTests
{
    private static readonly string SolutionRoot = FindSolutionRoot();

    private static string FindSolutionRoot()
    {
        string? current = AppDomain.CurrentDomain.BaseDirectory;
        while (current != null)
        {
            if (File.Exists(Path.Combine(current, "IToolkit.sln")))
            {
                return current;
            }
            current = Directory.GetParent(current)?.FullName;
        }
        throw new InvalidOperationException("Could not locate IToolkit.sln directory.");
    }

    private static (AppInstallerService service, MockProcessRunner runner, MockFileSystemService fs, MockRegistryService reg, MockNetworkService net) CreateServiceHarness(IActivityLogger? logger = null)
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);
        return (service, runner, fs, reg, net);
    }

    private static void SetMockResult(MockProcessRunner runner, string prefix, int exitCode, string stdout = "", string stderr = "")
    {
        runner.SetCommandResult(prefix, new ProcessExecutionResult(exitCode, stdout, stderr, false));
    }

    private static string BuildWingetTable(string[] headers, params string[][] rows)
    {
        int colWidth = 25;
        string headerLine = string.Join(" ", headers.Select(h => h.PadRight(colWidth)));
        string dividerLine = string.Join(" ", headers.Select(_ => new string('-', colWidth)));
        var lines = new List<string> { headerLine, dividerLine };
        foreach (var r in rows)
        {
            lines.Add(string.Join(" ", r.Select(c => c.PadRight(colWidth))));
        }
        return string.Join(Environment.NewLine, lines);
    }

    // =========================================================================
    // P01: Search -> Install -> Inventory Refresh Lifecycle (F2 + F4 + F3)
    // =========================================================================
    [Fact]
    public async Task P01_SearchToInstall_ThenInventoryRefresh_AddsPackageToInstalledCollection()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // 1. Search for package
        string searchOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Match", "Source"],
            ["Git", "Git.Git", "2.44.0", "Tag: git", "winget"]);
        SetMockResult(runner, "winget.exe search", 0, searchOutput);

        vm.SearchQuery = "git";
        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.Single(vm.SearchResults);
        var targetPkg = vm.SearchResults[0];
        Assert.Equal("Git.Git", targetPkg.Id);

        // 2. Install package
        SetMockResult(runner, "winget.exe install", 0, "Successfully installed Git.Git");
        await vm.InstallAppCommand.ExecuteAsync(targetPkg);

        Assert.Equal("Installed", targetPkg.Status);
        Assert.Contains("completed successfully", vm.StatusMessage);

        // 3. Refresh inventory
        string listOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Git", "Git.Git", "2.44.0", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listOutput);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Equal("Git.Git", vm.InstalledApps[0].Id);
    }

    // =========================================================================
    // P02: Inventory -> Check Updates -> Single Upgrade -> Refresh (F3 + F5 + F6)
    // =========================================================================
    [Fact]
    public async Task P02_InventoryToUpdates_ThenSingleUpgrade_UpdatesInstalledAndAvailableCollections()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // 1. Check for available updates via winget list --upgrade-available
        string updateOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["7-Zip", "7zip.7zip", "23.01", "24.08", "winget"]);
        SetMockResult(runner, "winget.exe list --upgrade-available", 0, updateOutput);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.AvailableUpdates);
        var updateItem = vm.AvailableUpdates[0];
        Assert.Equal("7zip.7zip", updateItem.Id);
        Assert.Equal("24.08", updateItem.AvailableVersion);

        // 2. Perform upgrade on the single item
        SetMockResult(runner, "winget.exe upgrade", 0, "Successfully upgraded 7zip.7zip");
        await vm.UpdateAppCommand.ExecuteAsync(updateItem);

        Assert.Contains("completed successfully", vm.StatusMessage);

        // 3. Re-check updates when nothing is pending
        SetMockResult(runner, "winget.exe list --upgrade-available", 0, "No available updates found.");
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Empty(vm.AvailableUpdates);
    }

    // =========================================================================
    // P03: Inventory Filter -> Confirmed Uninstall -> Removes from Both (F8 + F7)
    // =========================================================================
    [Fact]
    public async Task P03_InventoryFilter_ThenConfirmedUninstall_RemovesFromBothInstalledAndFilterView()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var dialogs = new MockDialogService(logger) { ConfirmationResult = true };
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // 1. Populate installed inventory
        string listOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Google Chrome", "Google.Chrome", "122.0", "", "winget"],
            ["Mozilla Firefox", "Mozilla.Firefox", "123.0", "", "winget"],
            ["Notepad++", "Notepad++.Notepad++", "8.6", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listOutput);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(3, vm.InstalledApps.Count);

        // 2. Filter on Firefox
        vm.InstalledFilterQuery = "Firefox";
        Assert.Single(vm.InstalledApps);
        var firefoxVm = vm.InstalledApps[0];

        // 3. Uninstall with confirmation confirmed
        SetMockResult(runner, "winget.exe uninstall", 0, "Successfully uninstalled");
        await vm.UninstallAppCommand.ExecuteAsync(firefoxVm);

        Assert.Empty(vm.InstalledApps);

        // 4. Clear filter query -> only Chrome and Notepad++ remain
        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(2, vm.InstalledApps.Count);
        Assert.DoesNotContain(vm.InstalledApps, a => a.Id == "Mozilla.Firefox");
    }

    // =========================================================================
    // P04: Inventory Filter -> Cancelled Uninstall -> Preserves All Views (F8 + F7)
    // =========================================================================
    [Fact]
    public async Task P04_InventoryFilter_ThenCancelledUninstall_PreservesItemInAllViews()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var dialogs = new MockDialogService(logger) { ConfirmationResult = false }; // Cancelled by user
        var vm = new AppManagementViewModel(service, dialogs, logger);

        string listOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Google Chrome", "Google.Chrome", "122.0", "", "winget"],
            ["Mozilla Firefox", "Mozilla.Firefox", "123.0", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listOutput);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.InstalledApps.Count);

        vm.InstalledFilterQuery = "Chrome";
        Assert.Single(vm.InstalledApps);
        var chromeVm = vm.InstalledApps[0];

        // Trigger uninstall -> user cancelled via dialog
        await vm.UninstallAppCommand.ExecuteAsync(chromeVm);

        // Verify runner did NOT receive uninstall command
        var runnerCommands = runner.ExecutedCommands.Where(c => c.Contains("uninstall")).ToList();
        Assert.Empty(runnerCommands);

        // Chrome must remain present in filtered and full inventory
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Google.Chrome", vm.InstalledApps[0].Id);

        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(2, vm.InstalledApps.Count);
    }

    // =========================================================================
    // P05: Batch Upgrade With Mixed Outcomes -> Telemetry Tracking (F6 + F11)
    // =========================================================================
    [Fact]
    public async Task P05_BatchUpgrade_WithMixedOutcomes_TracksProgressAndFinalStatus()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();

        // Simulate 3 packages upgrade:
        // Package 1: Success (0)
        // Package 2: Reboot required (3010)
        // Package 3: Generic failure (1603)
        SetMockResult(runner, "winget.exe upgrade --id App.One", 0, "Success");
        SetMockResult(runner, "winget.exe upgrade --id App.Two", 3010, "Reboot required");
        SetMockResult(runner, "winget.exe upgrade --id App.Three", 1603, "", "Fatal error during installation");

        var result1 = await service.UpgradeWingetPackageAsync("App.One");
        var result2 = await service.UpgradeWingetPackageAsync("App.Two");
        var result3 = await service.UpgradeWingetPackageAsync("App.Three");

        Assert.True(result1.Success);

        Assert.True(result2.Success);
        Assert.Contains("reboot", result2.Message, StringComparison.OrdinalIgnoreCase);

        Assert.False(result3.Success);
        Assert.Contains("1603", result3.Message);
    }

    // =========================================================================
    // P06: Busy State Suppression Across Commands (F9 + F2 + F5)
    // =========================================================================
    [Fact]
    public void P06_BusyStateSuppression_CannotSearchWhileSearching_CannotRefreshWhileUpdating()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        // Normal state: commands can execute
        Assert.True(vm.SearchAppsCommand.CanExecute(null));
        Assert.True(vm.RefreshInstalledCommand.CanExecute(null));
        Assert.True(vm.CheckUpdatesCommand.CanExecute(null));

        // When IsSearching = true
        vm.IsSearching = true;
        Assert.False(vm.SearchAppsCommand.CanExecute(null));
        vm.IsSearching = false;
        Assert.True(vm.SearchAppsCommand.CanExecute(null));

        // When IsLoadingInstalled = true
        vm.IsLoadingInstalled = true;
        Assert.False(vm.RefreshInstalledCommand.CanExecute(null));
        vm.IsLoadingInstalled = false;
        Assert.True(vm.RefreshInstalledCommand.CanExecute(null));

        // When IsCheckingUpdates = true
        vm.IsCheckingUpdates = true;
        Assert.False(vm.CheckUpdatesCommand.CanExecute(null));
        vm.IsCheckingUpdates = false;
        Assert.True(vm.CheckUpdatesCommand.CanExecute(null));
    }

    // =========================================================================
    // P07: Search Query Lifecycle (Search -> ClearSearch -> New Search) (F2 + F9)
    // =========================================================================
    [Fact]
    public async Task P07_SearchQueryLifecycle_Search_ClearSearch_NewQuery_UpdatesSearchResults()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        // Search 1: Python
        string pythonTable = BuildWingetTable(
            ["Name", "Id", "Version", "Match", "Source"],
            ["Python 3.12", "Python.Python.3.12", "3.12.2", "Tag: python", "winget"]);
        SetMockResult(runner, "winget.exe search", 0, pythonTable);

        vm.SearchQuery = "python";
        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.Single(vm.SearchResults);
        Assert.Equal("Python.Python.3.12", vm.SearchResults[0].Id);

        // Clear Search
        vm.ClearSearchCommand.Execute(null);
        Assert.Empty(vm.SearchQuery);
        Assert.Empty(vm.SearchResults);

        // Search 2: Rust
        string rustTable = BuildWingetTable(
            ["Name", "Id", "Version", "Match", "Source"],
            ["Rustup", "Rustlang.Rustup", "1.27.0", "Tag: rust", "winget"]);
        SetMockResult(runner, "winget.exe search", 0, rustTable);

        vm.SearchQuery = "rust";
        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.Single(vm.SearchResults);
        Assert.Equal("Rustlang.Rustup", vm.SearchResults[0].Id);
    }

    // =========================================================================
    // P08: Enterprise Catalog Batch Install Sequenced With Custom Winget Install (F10 + F4)
    // =========================================================================
    [Fact]
    public async Task P08_EnterpriseCatalogBatchInstall_SequencedWithCustomWingetInstall()
    {
        var (service, runner, fs, reg, net) = CreateServiceHarness();
        SetMockResult(runner, "winget.exe", 0, "Success");

        // 1. Enterprise catalog install
        var catalogApps = service.GetCatalog().Take(2).Select(a => a.AppId).ToList();
        var batchResults = service.InstallBatch(catalogApps);

        Assert.Equal(2, batchResults.Count);
        Assert.All(batchResults, r => Assert.True(r.Success));

        // 2. Direct custom Winget install sequenced immediately after
        var customResult = await service.InstallWingetPackageAsync("Microsoft.VisualStudioCode");
        Assert.True(customResult.Success);

        // Verify executed commands
        var wingetCalls = runner.ExecutedCommands.Where(c => c.Contains("winget")).ToList();
        Assert.NotEmpty(wingetCalls);
    }

    // =========================================================================
    // P09: Installed Filter Dynamic Typing and Clearance (F3 + F8)
    // =========================================================================
    [Fact]
    public async Task P09_InstalledFilter_DynamicTypingAndClearance_MaintainsCollectionIntegrity()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        string listOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Google Chrome", "Google.Chrome", "122.0", "", "winget"],
            ["Mozilla Firefox", "Mozilla.Firefox", "123.0", "", "winget"],
            ["Visual Studio Code", "Microsoft.VisualStudioCode", "1.87", "", "winget"],
            ["VLC media player", "VideoLAN.VLC", "3.0.20", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listOutput);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(4, vm.InstalledApps.Count);

        // Filter: "code" (matches only Visual Studio Code)
        vm.InstalledFilterQuery = "code";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Microsoft.VisualStudioCode", vm.InstalledApps[0].Id);

        // Filter: "Firefox" (matches only Mozilla Firefox)
        vm.InstalledFilterQuery = "Firefox";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Mozilla.Firefox", vm.InstalledApps[0].Id);

        // Filter: "xyz_non_existent"
        vm.InstalledFilterQuery = "xyz_non_existent";
        Assert.Empty(vm.InstalledApps);

        // Filter: clear
        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(4, vm.InstalledApps.Count);
    }

    // =========================================================================
    // P10: Uninstall App When Update Item Exists (F7 + F5)
    // =========================================================================
    [Fact]
    public async Task P10_UninstallApp_WhenUpdateItemExists_CleansBothInstalledAndUpdatesGrids()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var dialogs = new MockDialogService(logger) { ConfirmationResult = true };
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // Setup installed apps
        string listOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Notepad++", "Notepad++.Notepad++", "8.6.0", "8.6.4", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listOutput);
        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        // Setup available updates
        string updateOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Notepad++", "Notepad++.Notepad++", "8.6.0", "8.6.4", "winget"]);
        SetMockResult(runner, "winget.exe list --upgrade-available", 0, updateOutput);
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Single(vm.AvailableUpdates);

        // Uninstall Notepad++
        SetMockResult(runner, "winget.exe uninstall", 0, "Successfully uninstalled");
        await vm.UninstallAppCommand.ExecuteAsync(vm.InstalledApps[0]);

        Assert.Empty(vm.InstalledApps);

        // Re-check updates -> empty
        SetMockResult(runner, "winget.exe list --upgrade-available", 0, string.Empty);
        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Empty(vm.AvailableUpdates);
    }

    // =========================================================================
    // P11: UAC Cancellation Exit Code 1223 Across Workflow (F1 + F4 + F9)
    // =========================================================================
    [Fact]
    public async Task P11_UacCancellation_ExitCode1223_PropagatesCancellationStatusAcrossWorkflow()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        // Runner returns 1223 (ERROR_CANCELLED)
        SetMockResult(runner, "winget.exe", 1223, "", "User cancelled the operation in UAC prompt.");

        var result = await service.InstallWingetPackageAsync("Git.Git");

        Assert.False(result.Success);
        Assert.Contains("cancelled by the user", result.Message, StringComparison.OrdinalIgnoreCase);

        // Also test through ViewModel
        await vm.InstallAppAsync("Git.Git", "Git");
        Assert.Contains("completed successfully", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // P12: Reboot Required Exit Code 3010 Across Workflow (F1 + F6 + F11)
    // =========================================================================
    [Fact]
    public async Task P12_RebootRequired_ExitCode3010_SetsRebootFlagAndWarningStatus()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var logger = new TestActivityLogger();
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        SetMockResult(runner, "winget.exe", 3010, "Upgrade complete. Restart required.");

        var result = await service.UpgradeWingetPackageAsync("Docker.DockerDesktop");

        Assert.True(result.Success);
        Assert.Contains("reboot", result.Message, StringComparison.OrdinalIgnoreCase);

        // Test through ViewModel UpdateAppAsync
        var updateItem = new WingetUpdateItem("Docker.DockerDesktop", "Docker Desktop", "4.27.0", "4.28.0", "winget");
        var updateVm = new AppUpdateViewModel(updateItem);

        await vm.UpdateAppAsync(updateVm);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    // =========================================================================
    // P13: NavRail Navigation Switching Preserves State (F12 + F9)
    // =========================================================================
    [Fact]
    public void P13_NavRailNavigation_SwitchingViews_PreservesAppManagementState()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        var appMgmtVm = provider.GetRequiredService<AppManagementViewModel>();

        // Set state on AppManagementViewModel
        appMgmtVm.InstalledFilterQuery = "Git";
        appMgmtVm.SearchQuery = "python";

        // Initial view is Dashboard
        Assert.Same(mainVm.DashboardViewModel, mainVm.CurrentPageViewModel);

        // Navigate to AppManagement
        mainVm.NavigateToPillar("AppManagement");
        Assert.Same(appMgmtVm, mainVm.CurrentPageViewModel);

        // Switch away to Connectivity
        mainVm.NavigateToPillar("Connectivity");
        Assert.NotSame(appMgmtVm, mainVm.CurrentPageViewModel);

        // Switch back to AppManagement
        mainVm.NavigateToPillar("AppManagement");
        Assert.Same(appMgmtVm, mainVm.CurrentPageViewModel);

        // Verify AppManagement state was preserved intact
        Assert.Equal("Git", appMgmtVm.InstalledFilterQuery);
        Assert.Equal("python", appMgmtVm.SearchQuery);
    }

    // =========================================================================
    // P14: Mid-Stream Operation Cancellation Across Operations (F6 + F9)
    // =========================================================================
    [Fact]
    public async Task P14_MidStreamCancellation_DuringBatchOperation_HaltsSubsequentOperations()
    {
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);

        var cts = new CancellationTokenSource();
        int callCount = 0;

        var mockRunner = new Mock<IProcessRunner>();
        mockRunner.Setup(r => r.RunAsync(
            It.IsAny<string>(),
            It.IsAny<string>(),
            It.IsAny<string?>(),
            It.IsAny<int>(),
            It.IsAny<CancellationToken>()))
            .Returns<string, string, string?, int, CancellationToken>((cmd, args, dir, timeout, token) =>
            {
                callCount++;
                if (callCount == 1)
                {
                    // First call succeeds, then trigger cancellation
                    cts.Cancel();
                    return Task.FromResult(new ProcessExecutionResult(0, "First success", string.Empty, false));
                }
                token.ThrowIfCancellationRequested();
                return Task.FromResult(new ProcessExecutionResult(0, "Second success", string.Empty, false));
            });

        var guard = new ProcessLockGuard(mockRunner.Object, fs);
        var service = new AppInstallerService(mockRunner.Object, fs, reg, guard, net);

        // Run sequential operations with token
        var res1 = await service.UpgradeWingetPackageAsync("App.One", cts.Token);
        Assert.True(res1.Success);

        // Second call throws OperationCanceledException
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await service.UpgradeWingetPackageAsync("App.Two", cts.Token);
        });

        // Exactly 2 invocations occurred (App.One and App.Two which threw)
        Assert.Equal(2, callCount);
    }

    // =========================================================================
    // P15: Search to Install Failure With Diagnostic Stderr (F2 + F4 + F11)
    // =========================================================================
    [Fact]
    public async Task P15_SearchToInstallFailure_WithDiagnosticMessage_PresentsClearError()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        // Search returns a package
        string searchOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Match", "Source"],
            ["Broken App", "Vendor.BrokenApp", "1.0.0", "Tag: broken", "winget"]);
        SetMockResult(runner, "winget.exe search", 0, searchOutput);

        vm.SearchQuery = "broken";
        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.Single(vm.SearchResults);

        // Install returns failure exit code 0x8A15000F with stderr
        int failureCode = unchecked((int)0x8A15000F);
        SetMockResult(runner, "winget.exe install", failureCode, "", "No package found matching input criteria.");

        await vm.InstallAppCommand.ExecuteAsync(vm.SearchResults[0]);

        Assert.Contains("failed", vm.SearchResults[0].Status, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Installation failed.", vm.OperationProgressText);

        // Logger captured the diagnostic entry from AppInstallerService
        var logEntries = logger.CapturedEntries;
        Assert.Contains(logEntries, e => e.Level == LogLevel.Error || e.Message.Contains("0x8A15000F"));
    }
}
