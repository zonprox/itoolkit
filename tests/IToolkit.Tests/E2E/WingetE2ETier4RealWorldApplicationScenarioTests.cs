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
/// Tier 4: Real-World Application Scenario Test Suite.
/// Exercises end-to-end user journeys, enterprise provisioning, resilience,
/// and edge conditions simulating actual field IT operations.
/// </summary>
public class WingetE2ETier4RealWorldApplicationScenarioTests
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
    // SCENARIO 1: Developer Workstation Setup Journey
    // =========================================================================
    [Fact]
    public async Task S01_DeveloperWorkstationSetup_SequentialToolchainInstallationAndVerification()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // Toolchain to install: Git, VS Code, Windows Terminal
        var toolchain = new (string query, string name, string id, string version)[]
        {
            ("git", "Git", "Git.Git", "2.44.0"),
            ("vscode", "Visual Studio Code", "Microsoft.VisualStudioCode", "1.87.0"),
            ("terminal", "Windows Terminal", "Microsoft.WindowsTerminal", "1.19.0")
        };

        foreach (var tool in toolchain)
        {
            // 1. Search for package
            string searchTable = BuildWingetTable(
                ["Name", "Id", "Version", "Match", "Source"],
                [tool.name, tool.id, tool.version, $"Tag: {tool.query}", "winget"]);
            SetMockResult(runner, $"winget.exe search \"{tool.query}\"", 0, searchTable);

            vm.SearchQuery = tool.query;
            await vm.SearchAppsCommand.ExecuteAsync(null);

            Assert.Single(vm.SearchResults);
            var pkg = vm.SearchResults[0];
            Assert.Equal(tool.id, pkg.Id);

            // 2. Install package
            SetMockResult(runner, $"winget.exe install --id {tool.id}", 0, $"Successfully installed {tool.name}");
            await vm.InstallAppCommand.ExecuteAsync(pkg);

            Assert.Equal("Installed", pkg.Status);
            Assert.Contains("completed successfully", vm.StatusMessage);
        }

        // 3. Final Verification: Refresh Installed Inventory
        string installedTable = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Git", "Git.Git", "2.44.0", "", "winget"],
            ["Visual Studio Code", "Microsoft.VisualStudioCode", "1.87.0", "", "winget"],
            ["Windows Terminal", "Microsoft.WindowsTerminal", "1.19.0", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, installedTable);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.Equal(3, vm.InstalledApps.Count);
        Assert.Contains(vm.InstalledApps, a => a.Id == "Git.Git");
        Assert.Contains(vm.InstalledApps, a => a.Id == "Microsoft.VisualStudioCode");
        Assert.Contains(vm.InstalledApps, a => a.Id == "Microsoft.WindowsTerminal");
    }

    // =========================================================================
    // SCENARIO 2: Sysadmin Routine Maintenance Journey (Bulk Upgrade)
    // =========================================================================
    [Fact]
    public async Task S02_SysadminRoutineMaintenance_BatchScanAndBulkUpgradeWorkflow()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // Step 1: Scan for updates
        string updateOutput = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["7-Zip", "7zip.7zip", "23.01", "24.08", "winget"],
            ["Notepad++", "Notepad++.Notepad++", "8.6.0", "8.6.4", "winget"],
            ["PowerToys", "Microsoft.PowerToys", "0.79.0", "0.80.0", "winget"]);
        SetMockResult(runner, "winget.exe list --upgrade-available", 0, updateOutput);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Equal(3, vm.AvailableUpdates.Count);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));

        // Step 2: Configure individual upgrade results
        SetMockResult(runner, "winget.exe upgrade --id 7zip.7zip", 0, "Success");
        SetMockResult(runner, "winget.exe upgrade --id Notepad++.Notepad++", 0, "Success");
        SetMockResult(runner, "winget.exe upgrade --id Microsoft.PowerToys", 0, "Success");

        // Step 3: Run Upgrade All
        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.Equal(100, vm.OperationProgress);
        Assert.Equal("Batch update completed.", vm.OperationProgressText);
        Assert.Contains("3 of 3 package(s) updated", vm.UpdatesStatusText);
        Assert.Empty(vm.AvailableUpdates);
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    // =========================================================================
    // SCENARIO 3: Software Deprecation & Decommissioning Journey
    // =========================================================================
    [Fact]
    public async Task S03_SoftwareDeprecationAndDecommissioning_ConfirmedRemovalWorkflow()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var dialogs = new MockDialogService(logger) { ConfirmationResult = true };
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // 1. Initial inventory with deprecated app
        string listTable = BuildWingetTable(
            ["Name", "Id", "Version", "Available", "Source"],
            ["Google Chrome", "Google.Chrome", "122.0", "", "winget"],
            ["Visual Studio Code", "Microsoft.VisualStudioCode", "1.87", "", "winget"],
            ["Legacy Torrent", "Legacy.BitTorrent", "7.10", "", "winget"],
            ["Mozilla Firefox", "Mozilla.Firefox", "123.0", "", "winget"]);
        SetMockResult(runner, "winget.exe list --disable-interactivity", 0, listTable);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(4, vm.InstalledApps.Count);

        // 2. Audit and filter for deprecated software
        vm.InstalledFilterQuery = "Torrent";
        Assert.Single(vm.InstalledApps);
        var deprecatedApp = vm.InstalledApps[0];
        Assert.Equal("Legacy.BitTorrent", deprecatedApp.Id);

        // 3. Initiate confirmed removal
        SetMockResult(runner, "winget.exe uninstall --id Legacy.BitTorrent", 0, "Successfully uninstalled");
        await vm.UninstallAppCommand.ExecuteAsync(deprecatedApp);

        // 4. Assert decommissioned
        Assert.Empty(vm.InstalledApps);

        // 5. Clear filter and verify remaining enterprise apps
        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(3, vm.InstalledApps.Count);
        Assert.DoesNotContain(vm.InstalledApps, a => a.Id == "Legacy.BitTorrent");
    }

    // =========================================================================
    // SCENARIO 4: Network Interruption Resilience & Retry Journey
    // =========================================================================
    [Fact]
    public async Task S04_NetworkInterruptionAndResilience_TransientFailureAndSuccessfulRetry()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        // Search finds Chrome
        string searchTable = BuildWingetTable(
            ["Name", "Id", "Version", "Match", "Source"],
            ["Google Chrome", "Google.Chrome", "122.0", "Tag: chrome", "winget"]);
        SetMockResult(runner, "winget.exe search", 0, searchTable);

        vm.SearchQuery = "chrome";
        await vm.SearchAppsCommand.ExecuteAsync(null);

        var chromePkg = vm.SearchResults[0];

        // Attempt 1: Transient network drop (ExitCode 0x8A150056)
        int networkErrorCode = unchecked((int)0x8A150056);
        SetMockResult(runner, "winget.exe install", networkErrorCode, "", "Network connection failed. (0x8A150056)");

        await vm.InstallAppCommand.ExecuteAsync(chromePkg);

        Assert.Contains("failed", chromePkg.Status, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Installation failed.", vm.OperationProgressText);
        Assert.Equal(0, vm.OperationProgress);

        // Attempt 2: Network recovered, user retries
        SetMockResult(runner, "winget.exe install", 0, "Successfully installed Google.Chrome");

        await vm.InstallAppCommand.ExecuteAsync(chromePkg);

        Assert.Equal("Installed", chromePkg.Status);
        Assert.Equal(100, vm.OperationProgress);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    // =========================================================================
    // SCENARIO 5: UAC Elevation Rejection & Subsequent Approval Journey
    // =========================================================================
    [Fact]
    public async Task S05_UacElevationRejectionAndSubsequentPrivilegeElevation()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var dialogs = new MockDialogService(logger);
        var vm = new AppManagementViewModel(service, dialogs, logger);

        var packageVm = new WingetPackageViewModel(new WingetPackage("Wireshark", "WiresharkFoundation.Wireshark", "4.2.3", null, "winget"));

        // Attempt 1: User clicks No / Cancel on UAC prompt (Exit code 1223)
        SetMockResult(runner, "winget.exe install", 1223, "", "User cancelled the operation in UAC prompt.");

        await vm.InstallAppCommand.ExecuteAsync(packageVm);

        Assert.Contains("failed", packageVm.Status, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("cancelled by the user", packageVm.Status, StringComparison.OrdinalIgnoreCase);

        // Attempt 2: User retries and accepts elevation prompt (Exit code 0)
        SetMockResult(runner, "winget.exe install", 0, "Successfully installed Wireshark.");

        await vm.InstallAppCommand.ExecuteAsync(packageVm);

        Assert.Equal("Installed", packageVm.Status);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    // =========================================================================
    // SCENARIO 6: Enterprise Bulk Provisioning Across Catalog and Winget
    // =========================================================================
    [Fact]
    public async Task S06_EnterpriseBulkProvisioning_FivePillarIntegrationWithSoftwareCatalog()
    {
        var logger = new TestActivityLogger();
        var (service, runner, fs, reg, net) = CreateServiceHarness(logger);

        // Configure successful mock results
        SetMockResult(runner, "winget.exe", 0, "Success");

        // 1. Enterprise catalog apps batch execution
        var catalogApps = service.GetCatalog().Select(a => a.AppId).Take(3).ToList();
        var catalogResults = service.InstallBatch(catalogApps);

        Assert.Equal(3, catalogResults.Count);
        Assert.All(catalogResults, r => Assert.True(r.Success));

        // 2. Custom corporate Winget tools install
        var slackResult = await service.InstallWingetPackageAsync("SlackTechnologies.Slack");
        var teamsResult = await service.InstallWingetPackageAsync("Microsoft.Teams");

        Assert.True(slackResult.Success);
        Assert.True(teamsResult.Success);

        // 3. Desktop shortcuts created for corporate desktop
        bool shortcutCreated = service.CreateDesktopShortcut("Slack", @"C:\Program Files\Slack\slack.exe");
        Assert.True(shortcutCreated);

        // 4. Verify telemetry recorded all events
        var logs = logger.CapturedEntries;
        Assert.Contains(logs, l => l.Message.Contains("SlackTechnologies.Slack"));
        Assert.Contains(logs, l => l.Message.Contains("Microsoft.Teams"));
    }

    // =========================================================================
    // SCENARIO 7: Rapid Tab Navigation & Concurrent State Integrity
    // =========================================================================
    [Fact]
    public async Task S07_RapidTabNavigationAndConcurrentStateIntegrity()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        var appMgmtVm = provider.GetRequiredService<AppManagementViewModel>();

        // Start background search
        appMgmtVm.SearchQuery = "python";
        var searchTask = appMgmtVm.SearchAppsCommand.ExecuteAsync(null);

        // Rapidly switch between multiple pillars
        string[] pillars = ["SystemHealth", "SoftwareOptimization", "Connectivity", "Dashboard", "AppManagement"];
        foreach (var p in pillars)
        {
            mainVm.NavigateToPillar(p);
            Assert.Equal(p, mainVm.CurrentPillarName);
        }

        await searchTask;

        // Verify AppManagementViewModel remains active and intact
        Assert.Same(appMgmtVm, mainVm.CurrentPageViewModel);
        Assert.Equal("python", appMgmtVm.SearchQuery);
        Assert.False(appMgmtVm.IsSearching);
    }

    // =========================================================================
    // SCENARIO 8: Corrupted Winget CLI Output Noise Filtering & Recovery
    // =========================================================================
    [Fact]
    public void S08_CorruptedWingetCliOutput_GracefulNoiseFilteringAndPartialParsing()
    {
        string corruptedOutput =
            "Windows PowerShell\r\n" +
            "Copyright (C) Microsoft Corporation. All rights reserved.\r\n" +
            "\r\n" +
            "WARNING: Winget is running in non-standard console mode.\r\n" +
            "\\ | / - \\ | / -\r\n" +
            "Name                   Id                          Version   Match       Source\r\n" +
            "--------------------------------------------------------------------------------\r\n" +
            "Google Chrome          Google.Chrome               122.0     Tag: chrome winget\r\n" +
            "Mozilla Firefox        Mozilla.Firefox             123.0                 winget\r\n" +
            "\r\n" +
            "Found 2 package(s).\r\n";

        var packages = WingetCliParser.ParsePackages(corruptedOutput);

        Assert.Equal(2, packages.Count);
        Assert.Equal("Google Chrome", packages[0].Name);
        Assert.Equal("Google.Chrome", packages[0].Id);
        Assert.Equal("122.0", packages[0].Version);
        Assert.Equal("Tag: chrome", packages[0].Match);
        Assert.Equal("winget", packages[0].Source);

        Assert.Equal("Mozilla Firefox", packages[1].Name);
        Assert.Equal("Mozilla.Firefox", packages[1].Id);
        Assert.Equal("123.0", packages[1].Version);
        Assert.Null(packages[1].Match);
        Assert.Equal("winget", packages[1].Source);
    }

    // =========================================================================
    // SCENARIO 9: Package Already Installed (0x8A150061) Graceful Handling
    // =========================================================================
    [Fact]
    public async Task S09_PackageAlreadyInstalled_ExitCode0x8A150061_GracefulHandling()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        int alreadyInstalledCode = unchecked((int)0x8A150061);
        SetMockResult(runner, "winget.exe install", alreadyInstalledCode, "", "Package is already installed.");

        var packageVm = new WingetPackageViewModel(new WingetPackage("Git", "Git.Git", "2.44.0", null, "winget"));
        await vm.InstallAppCommand.ExecuteAsync(packageVm);

        // Outcome must be successful and marked Installed
        Assert.Equal("Installed", packageVm.Status);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    // =========================================================================
    // SCENARIO 10: Package Already Up-To-Date (0x8A15002B) Graceful Handling
    // =========================================================================
    [Fact]
    public async Task S10_PackageAlreadyUpToDate_ExitCode0x8A15002B_GracefulHandling()
    {
        var logger = new TestActivityLogger();
        var (service, runner, _, _, _) = CreateServiceHarness(logger);
        var vm = new AppManagementViewModel(service, new MockDialogService(logger), logger);

        int upToDateCode = unchecked((int)0x8A15002B);
        SetMockResult(runner, "winget.exe upgrade", upToDateCode, "", "No applicable update found.");

        var updateItem = new WingetUpdateItem("Git.Git", "Git", "2.44.0", "2.44.0", "winget");
        var updateVm = new AppUpdateViewModel(updateItem);

        await vm.UpdateAppAsync(updateVm);

        Assert.Contains("completed successfully", vm.StatusMessage);
    }
}
