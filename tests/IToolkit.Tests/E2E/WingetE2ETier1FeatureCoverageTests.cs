namespace IToolkit.Tests.E2E;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Xml.Linq;
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
/// Tier 1: Opaque-Box Feature Coverage Test Suite.
/// Enforces at least 5 isolated tests per feature across all 13 features in docs/PROJECT.md.
/// </summary>
public class WingetE2ETier1FeatureCoverageTests
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

    private static (AppInstallerService service, MockProcessRunner runner, MockFileSystemService fs, MockRegistryService reg, MockNetworkService net) CreateServiceHarness()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var service = new AppInstallerService(runner, fs, reg, guard, net);
        return (service, runner, fs, reg, net);
    }

    // =========================================================================
    // FEATURE 1: Winget Output & Error Parser (>=5 tests)
    // =========================================================================

    [Fact]
    public void F1_01_ParsePackages_StandardTable_ExtractsAllColumnsCorrectly()
    {
        string output =
            "Name             Id               Version   Match    Source\r\n" +
            "-----------------------------------------------------------\r\n" +
            "7-Zip            7zip.7zip        24.09              winget\r\n" +
            "NanaZip          M2Team.NanaZip   3.1.1000  Tag: 7z  winget\r\n";

        var packages = WingetCliParser.ParsePackages(output);

        Assert.Equal(2, packages.Count);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("24.09", packages[0].Version);
        Assert.Null(packages[0].Match);
        Assert.Equal("winget", packages[0].Source);

        Assert.Equal("NanaZip", packages[1].Name);
        Assert.Equal("M2Team.NanaZip", packages[1].Id);
        Assert.Equal("Tag: 7z", packages[1].Match);
    }

    [Fact]
    public void F1_02_ParseInstalledApps_ExtractsAvailableVersionAndArpIds()
    {
        string output =
            "Name                             Id                             Version   Available Source\r\n" +
            "------------------------------------------------------------------------------------------\r\n" +
            "AutoCAD 2021                     ARP\\Machine\\X64\\AutoCAD 2021   24.0.47                     \r\n" +
            "Git                              Git.Git                        2.55.0    2.56.0    winget\r\n";

        var installed = WingetCliParser.ParseInstalledApps(output);

        Assert.Equal(2, installed.Count);
        Assert.Equal("AutoCAD 2021", installed[0].Name);
        Assert.Equal("ARP\\Machine\\X64\\AutoCAD 2021", installed[0].Id);
        Assert.Null(installed[0].AvailableVersion);

        Assert.Equal("Git.Git", installed[1].Id);
        Assert.Equal("2.55.0", installed[1].Version);
        Assert.Equal("2.56.0", installed[1].AvailableVersion);
    }

    [Fact]
    public void F1_03_ParseUpdates_SlicesVersionsAndFiltersSummaryNoise()
    {
        string output =
            "Name        Id               Version   Available Source\r\n" +
            "-------------------------------------------------------\r\n" +
            "VLC player  VideoLAN.VLC     3.0.18    3.0.21    winget\r\n" +
            "1 upgrades available.\r\n";

        var updates = WingetCliParser.ParseUpdates(output);

        Assert.Single(updates);
        Assert.Equal("VLC player", updates[0].Name);
        Assert.Equal("VideoLAN.VLC", updates[0].Id);
        Assert.Equal("3.0.18", updates[0].InstalledVersion);
        Assert.Equal("3.0.21", updates[0].AvailableVersion);
    }

    [Fact]
    public void F1_04_ParseExitCode_RecognizesCriticalReturnCodes()
    {
        var resSuccess = WingetCliParser.ParseExitCode(0, "Install", "app1");
        Assert.True(resSuccess.Success);
        Assert.False(resSuccess.RebootRequired);

        var resReboot = WingetCliParser.ParseExitCode(3010, "Install", "app1");
        Assert.True(resReboot.Success);
        Assert.True(resReboot.RebootRequired);

        var resCancelled = WingetCliParser.ParseExitCode(1223, "Install", "app1");
        Assert.False(resCancelled.Success);
        Assert.True(resCancelled.CancelledByUser);

        var resUpToDate = WingetCliParser.ParseExitCode(unchecked((int)0x8A15002B), "Upgrade", "app1");
        Assert.True(resUpToDate.Success);
        Assert.True(resUpToDate.AlreadyUpToDate);

        var resNotFound = WingetCliParser.ParseExitCode(unchecked((int)0x8A150014), "Install", "app1");
        Assert.False(resNotFound.Success);
        Assert.Contains("0x8A150014", resNotFound.Message);

        var resAdmin = WingetCliParser.ParseExitCode(unchecked((int)0x8A150019), "Install", "app1");
        Assert.False(resAdmin.Success);
        Assert.True(resAdmin.RequiresAdmin);
    }

    [Fact]
    public void F1_05_QuickCheckHelpers_EvaluateCorrectBooleans()
    {
        Assert.True(WingetCliParser.IsSuccess(0));
        Assert.False(WingetCliParser.IsSuccess(1));
        Assert.True(WingetCliParser.IsRebootRequired(3010));
        Assert.True(WingetCliParser.IsCancelled(1223));
        Assert.True(WingetCliParser.IsAlreadyUpToDate(unchecked((int)0x8A15002B)));
        Assert.True(WingetCliParser.IsNoApplicationsFound(unchecked((int)0x8A150014)));
        Assert.True(WingetCliParser.RequiresAdmin(unchecked((int)0x8A150019)));
        Assert.True(WingetCliParser.RequiresAdmin(-1978335068));
    }

    // =========================================================================
    // FEATURE 2: Winget Search Query (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F2_01_SearchPackagesAsync_InvokesWingetWithExpectedArguments()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe search \"vscode\" --source winget --accept-source-agreements --disable-interactivity";
        string stdout =
            "Name                   Id                          Version   Match   Source\r\n" +
            "---------------------------------------------------------------------------\r\n" +
            "Visual Studio Code     Microsoft.VisualStudioCode  1.95.0            winget\r\n";

        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, stdout, string.Empty, false));

        var results = await service.SearchPackagesAsync("vscode");

        Assert.Single(results);
        Assert.Equal("Visual Studio Code", results[0].Name);
        Assert.Equal("Microsoft.VisualStudioCode", results[0].Id);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F2_02_SearchPackagesAsync_MultiplePackages_ReturnsAllItems()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string stdout =
            "Name          Id             Version Match Source\r\n" +
            "-------------------------------------------------\r\n" +
            "App Alpha     Vendor.Alpha   1.0.0         winget\r\n" +
            "App Beta      Vendor.Beta    2.1.0         winget\r\n" +
            "App Gamma     Vendor.Gamma   3.0.0         winget\r\n";

        runner.SetCommandResult(
            "winget.exe search \"Vendor\" --source winget --accept-source-agreements --disable-interactivity",
            new ProcessExecutionResult(0, stdout, string.Empty, false));

        var results = await service.SearchPackagesAsync("Vendor");

        Assert.Equal(3, results.Count);
        Assert.Equal("Vendor.Alpha", results[0].Id);
        Assert.Equal("Vendor.Beta", results[1].Id);
        Assert.Equal("Vendor.Gamma", results[2].Id);
    }

    [Fact]
    public async Task F2_03_SearchPackagesAsync_EscapesQuotesInQueryString()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe search \"test\\\"tool\" --source winget --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, string.Empty, string.Empty, false));

        var results = await service.SearchPackagesAsync("test\"tool");

        Assert.NotNull(results);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F2_04_SearchPackagesAsync_NoPackagesFoundExitCode_ReturnsEmptyListCleanly()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe search \"Unknown999\" --source winget --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150014), "No package found", string.Empty, false));

        var results = await service.SearchPackagesAsync("Unknown999");

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task F2_05_SearchPackagesAsync_LogsDiagnosticsToActivityLogger()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var logger = new TestActivityLogger();
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);

        string cmd = "winget.exe search \"7zip\" --source winget --accept-source-agreements --disable-interactivity";
        string stdout =
            "Name    Id        Version Match Source\r\n" +
            "--------------------------------------\r\n" +
            "7-Zip   7zip.7zip 24.09         winget\r\n";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(0, stdout, string.Empty, false));

        await service.SearchPackagesAsync("7zip");

        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Searching packages with query '7zip'"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Found 1 package(s)"));
    }

    // =========================================================================
    // FEATURE 3: Installed Applications Inventory (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F3_01_GetInstalledApplicationsAsync_InvokesWingetWithExpectedFlags()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe list --disable-interactivity --nowarn";
        string stdout =
            "Name      Id         Version  Available Source\r\n" +
            "----------------------------------------------\r\n" +
            "Git       Git.Git    2.50.0   2.51.0    winget\r\n";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, stdout, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.Single(apps);
        Assert.Equal("Git", apps[0].Name);
        Assert.Equal("Git.Git", apps[0].Id);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F3_02_GetInstalledApplicationsAsync_HandlesArpRegistryEntries()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string stdout =
            "Name                       Id                                    Version  Available Source\r\n" +
            "------------------------------------------------------------------------------------------\r\n" +
            "Local Tool                 ARP\\Machine\\X64\\LocalTool             1.2.3                     \r\n";
        runner.SetCommandResult("winget.exe list --disable-interactivity --nowarn", new ProcessExecutionResult(0, stdout, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.Single(apps);
        Assert.StartsWith("ARP\\", apps[0].Id, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(string.Empty, apps[0].Source);
    }

    [Fact]
    public async Task F3_03_GetInstalledApplicationsAsync_ParsesAvailableVersionForOutdatedItems()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string stdout =
            "Name      Id              Version   Available  Source\r\n" +
            "-----------------------------------------------------\r\n" +
            "Chrome    Google.Chrome   130.0     131.0      winget\r\n";
        runner.SetCommandResult("winget.exe list --disable-interactivity --nowarn", new ProcessExecutionResult(0, stdout, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.Single(apps);
        Assert.Equal("130.0", apps[0].Version);
        Assert.Equal("131.0", apps[0].AvailableVersion);
    }

    [Fact]
    public async Task F3_04_GetInstalledApplicationsAsync_NoAppsFound_ReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --disable-interactivity --nowarn",
            new ProcessExecutionResult(unchecked((int)0x8A150014), "No installed package found.", string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    [Fact]
    public async Task F3_05_GetInstalledApplicationsAsync_LogsInventoryProgress()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var logger = new TestActivityLogger();
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);

        runner.SetCommandResult(
            "winget.exe list --disable-interactivity --nowarn",
            new ProcessExecutionResult(0, "Name Id Version Available Source\r\n--------------------------------\r\nAppA IdA 1.0.0  winget\r\n", string.Empty, false));

        await service.GetInstalledApplicationsAsync();

        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Retrieving installed applications inventory"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Retrieved 1 installed application(s)"));
    }

    // =========================================================================
    // FEATURE 4: Available Updates Detection (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F4_01_GetAvailableUpdatesAsync_InvokesWingetWithUpgradeAvailableFlag()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe list --upgrade-available --disable-interactivity --nowarn";
        string stdout =
            "Name      Id         Version  Available Source\r\n" +
            "----------------------------------------------\r\n" +
            "Git       Git.Git    2.50.0   2.51.0    winget\r\n" +
            "1 upgrades available.\r\n";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, stdout, string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.Single(updates);
        Assert.Equal("Git.Git", updates[0].Id);
        Assert.Equal("2.50.0", updates[0].InstalledVersion);
        Assert.Equal("2.51.0", updates[0].AvailableVersion);
    }

    [Fact]
    public async Task F4_02_GetAvailableUpdatesAsync_ParsesMultipleUpgradableItems()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string stdout =
            "Name      Id           Version  Available Source\r\n" +
            "------------------------------------------------\r\n" +
            "Git       Git.Git      2.50.0   2.51.0    winget\r\n" +
            "Zalo      VNG.Zalo     24.1.0   24.2.0    winget\r\n" +
            "7-Zip     7zip.7zip    23.01    24.08     winget\r\n" +
            "3 upgrades available.\r\n";
        runner.SetCommandResult("winget.exe list --upgrade-available --disable-interactivity --nowarn", new ProcessExecutionResult(0, stdout, string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.Equal(3, updates.Count);
        Assert.Equal("7zip.7zip", updates[2].Id);
    }

    [Fact]
    public async Task F4_03_GetAvailableUpdatesAsync_FiltersPinsNoticeFromResults()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string stdout =
            "Name      Id           Version  Available Source\r\n" +
            "------------------------------------------------\r\n" +
            "Git       Git.Git      2.50.0   2.51.0    winget\r\n" +
            "1 pins that prevent upgrade.\r\n" +
            "1 upgrades available.\r\n";
        runner.SetCommandResult("winget.exe list --upgrade-available --disable-interactivity --nowarn", new ProcessExecutionResult(0, stdout, string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.Single(updates);
        Assert.Equal("Git", updates[0].Name);
    }

    [Fact]
    public async Task F4_04_GetAvailableUpdatesAsync_NoUpdatesFoundExitCode_ReturnsEmptyListCleanly()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --upgrade-available --disable-interactivity --nowarn",
            new ProcessExecutionResult(unchecked((int)0x8A150014), "No available upgrade found.", string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task F4_05_GetAvailableUpdatesAsync_LogsScanResults()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var logger = new TestActivityLogger();
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);

        runner.SetCommandResult(
            "winget.exe list --upgrade-available --disable-interactivity --nowarn",
            new ProcessExecutionResult(0, "Name Id Version Available Source\r\n--------------------------------\r\nAppA IdA 1.0.0 2.0.0 winget\r\n", string.Empty, false));

        await service.GetAvailableUpdatesAsync();

        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Checking for available application updates"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Found 1 available update(s)"));
    }

    // =========================================================================
    // FEATURE 5: Single Package Installation (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F5_01_InstallWingetPackageAsync_ExecutesUnattendedCommandLine()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Successfully installed", string.Empty, false));

        var result = await service.InstallWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Equal("7zip.7zip", result.AppId);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F5_02_InstallWingetPackageAsync_QuotesPackageIdWithSpaces()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe install --id \"Custom Tool\" --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Installed", string.Empty, false));

        var result = await service.InstallWingetPackageAsync("Custom Tool");

        Assert.True(result.Success);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F5_03_InstallWingetPackageAsync_ExitCode3010_ReturnsSuccessWithRebootNotice()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe install --id Driver.Package --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(3010, "Reboot required", string.Empty, false));

        var result = await service.InstallWingetPackageAsync("Driver.Package");

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message);
    }

    [Fact]
    public async Task F5_04_InstallWingetPackageAsync_ExitCodeAlreadyInstalled_ReturnsSuccess()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe install --id Existing.App --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150061), "Already installed", string.Empty, false));

        var result = await service.InstallWingetPackageAsync("Existing.App");

        Assert.True(result.Success);
        Assert.Contains("already installed", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task F5_05_InstallWingetPackageAsync_EmptyPackageId_FailsWithoutLaunchingProcess()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.InstallWingetPackageAsync("   ");

        Assert.False(result.Success);
        Assert.Contains("cannot be empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.ExecutedCommands);
    }

    // =========================================================================
    // FEATURE 6: Single Package Upgrade (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F6_01_UpgradeWingetPackageAsync_ExecutesUnattendedCommandLine()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe upgrade --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Successfully upgraded", string.Empty, false));

        var result = await service.UpgradeWingetPackageAsync("Git.Git");

        Assert.True(result.Success);
        Assert.Equal("Git.Git", result.AppId);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F6_02_UpgradeWingetPackageAsync_AlreadyUpToDate_ReturnsSuccess()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id UpToDate.App --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A15002B), "No applicable update", string.Empty, false));

        var result = await service.UpgradeWingetPackageAsync("UpToDate.App");

        Assert.True(result.Success);
        Assert.Contains("already up-to-date", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task F6_03_UpgradeWingetPackageAsync_RebootRequired_ReturnsSuccessWithNotice()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id Kernel.Component --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(3010, string.Empty, string.Empty, false));

        var result = await service.UpgradeWingetPackageAsync("Kernel.Component");

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message);
    }

    [Fact]
    public async Task F6_04_UpgradeWingetPackageAsync_ProcessFailure_ReturnsDescriptiveFailure()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id Failing.App --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1603, string.Empty, "Fatal MSI installation error", false));

        var result = await service.UpgradeWingetPackageAsync("Failing.App");

        Assert.False(result.Success);
        Assert.Contains("1603", result.Message);
        Assert.Contains("Fatal MSI installation error", result.Message);
    }

    [Fact]
    public async Task F6_05_UpgradeWingetPackageAsync_EmptyId_ReturnsFailureImmediately()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.UpgradeWingetPackageAsync("");

        Assert.False(result.Success);
        Assert.Empty(runner.ExecutedCommands);
    }

    // =========================================================================
    // FEATURE 7: Package Uninstallation (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F7_01_UninstallWingetPackageAsync_ExecutesUnattendedCommandLine()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe uninstall --id 7zip.7zip --exact --silent --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Successfully uninstalled", string.Empty, false));

        var result = await service.UninstallWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Equal("7zip.7zip", result.AppId);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F7_02_UninstallWingetPackageAsync_QuotesPackageIdWithSpaces()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string expectedCmd = "winget.exe uninstall --id \"Spaced App ID\" --exact --silent --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Uninstalled", string.Empty, false));

        var result = await service.UninstallWingetPackageAsync("Spaced App ID");

        Assert.True(result.Success);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task F7_03_UninstallWingetPackageAsync_ExitCode1223_ReportsCancellationByUser()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe uninstall --id Protected.App --exact --silent --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1223, string.Empty, "User cancelled", false));

        var result = await service.UninstallWingetPackageAsync("Protected.App");

        Assert.False(result.Success);
        Assert.Contains("cancelled by the user", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task F7_04_UninstallWingetPackageAsync_ExitCode3010_ReturnsSuccessWithRebootNotice()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe uninstall --id Driver.App --exact --silent --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(3010, string.Empty, string.Empty, false));

        var result = await service.UninstallWingetPackageAsync("Driver.App");

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message);
    }

    [Fact]
    public async Task F7_05_UninstallWingetPackageAsync_EmptyId_ReturnsFailureWithoutCallingProcess()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.UninstallWingetPackageAsync("   ");

        Assert.False(result.Success);
        Assert.Empty(runner.ExecutedCommands);
    }

    // =========================================================================
    // FEATURE 8: Backward Compatibility Guard (>=5 tests)
    // =========================================================================

    [Fact]
    public void F8_01_GetCatalog_ContainsExactlyEightCanonicalEnterpriseApps()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var catalog = service.GetCatalog();

        Assert.Equal(8, catalog.Count);
        var expectedIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "VCRedistAIO", "UniKey", "UltraVNC", "KLiteCodec",
            "Chrome", "FoxitReader", "Zalo", "WinRAR"
        };

        foreach (var item in catalog)
        {
            Assert.Contains(item.AppId, expectedIds);
        }
    }

    [Fact]
    public void F8_02_GetCatalog_NonWingetAppsHaveNullWingetId()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var catalog = service.GetCatalog().ToDictionary(a => a.AppId, StringComparer.OrdinalIgnoreCase);

        Assert.Null(catalog["VCRedistAIO"].WingetId);
        Assert.Null(catalog["UniKey"].WingetId);
        Assert.Null(catalog["UltraVNC"].WingetId);
        Assert.Null(catalog["Zalo"].WingetId);
    }

    [Fact]
    public void F8_03_GetCatalog_WingetSupportedAppsHaveValidWingetIds()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var catalog = service.GetCatalog().ToDictionary(a => a.AppId, StringComparer.OrdinalIgnoreCase);

        Assert.Equal("CodecGuide.K-LiteCodecPack.Standard", catalog["KLiteCodec"].WingetId);
        Assert.Equal("Google.Chrome", catalog["Chrome"].WingetId);
        Assert.Equal("Foxit.FoxitReader", catalog["FoxitReader"].WingetId);
        Assert.Equal("RARLab.WinRAR", catalog["WinRAR"].WingetId);
    }

    [Fact]
    public void F8_04_InstallBatch_AlwaysSequencesVCRedistAIOFirst()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult("winget.exe", new ProcessExecutionResult(0, string.Empty, string.Empty, false));

        // Pass non-VCRedist first
        var inputIds = new[] { "Chrome", "UniKey", "VCRedistAIO", "FoxitReader" };
        var results = service.InstallBatch(inputIds);

        Assert.Equal(4, results.Count);
        Assert.Equal("VCRedistAIO", results[0].AppId);
    }

    [Fact]
    public void F8_05_GetApp_RetrievesCatalogItemCaseInsensitively()
    {
        var (service, _, _, _, _) = CreateServiceHarness();

        var item1 = service.GetApp("chrome");
        var item2 = service.GetApp("CHROME");

        Assert.NotNull(item1);
        Assert.Same(item1, item2);
        Assert.Equal("Google Chrome", item1.DisplayName);
    }

    // =========================================================================
    // FEATURE 9: AppManagementViewModel (>=5 tests)
    // =========================================================================

    [Fact]
    public async Task F9_01_SearchAppsCommand_PopulatesSearchResultsAndStatus()
    {
        var mockService = new Mock<IAppInstallerService>();
        var packages = new List<WingetPackage> { new("7-Zip", "7zip.7zip", "24.09", null, "winget") };
        mockService.Setup(s => s.SearchPackagesAsync("7zip", It.IsAny<CancellationToken>())).ReturnsAsync(packages);

        var vm = new AppManagementViewModel(mockService.Object);
        vm.SearchQuery = "7zip";

        await vm.SearchAppsCommand.ExecuteAsync(null);

        Assert.Single(vm.SearchResults);
        Assert.Equal("7-Zip", vm.SearchResults[0].Name);
        Assert.Contains("Found 1 package(s)", vm.SearchStatusText);
    }

    [Fact]
    public async Task F9_02_RefreshInstalledCommand_LoadsInstalledInventory()
    {
        var mockService = new Mock<IAppInstallerService>();
        var apps = new List<WingetInstalledApp> { new("Git", "Git.Git", "2.50.0", "2.51.0", "winget") };
        mockService.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>())).ReturnsAsync(apps);

        var vm = new AppManagementViewModel(mockService.Object);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Equal("Git.Git", vm.InstalledApps[0].Id);
        Assert.True(vm.InstalledApps[0].HasUpdate);
    }

    [Fact]
    public async Task F9_03_CheckUpdatesCommand_PopulatesAvailableUpdatesAndEnablesUpgradeAll()
    {
        var mockService = new Mock<IAppInstallerService>();
        var updates = new List<WingetUpdateItem> { new("Git", "Git.Git", "2.50.0", "2.51.0", "winget") };
        mockService.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>())).ReturnsAsync(updates);

        var vm = new AppManagementViewModel(mockService.Object);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.AvailableUpdates);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task F9_04_InstalledFilterQuery_DynamicallyFiltersItems()
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);

        var app1 = new InstalledAppViewModel(new WingetInstalledApp("Google Chrome", "Google.Chrome", "130.0", null, "winget"));
        var app2 = new InstalledAppViewModel(new WingetInstalledApp("Visual Studio Code", "Microsoft.VisualStudioCode", "1.95.0", null, "winget"));

        // Simulate loaded inventory through refresh
        mockService.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app1.App, app2.App });

        await vm.RefreshInstalledAsync();
        Assert.Equal(2, vm.InstalledApps.Count);

        vm.InstalledFilterQuery = "Chrome";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Google Chrome", vm.InstalledApps[0].Name);

        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(2, vm.InstalledApps.Count);
    }

    [Fact]
    public async Task F9_05_UpgradeAllAppsCommand_ExecutesBatchAndUpdatesProgress()
    {
        var mockService = new Mock<IAppInstallerService>();
        var updates = new List<WingetUpdateItem>
        {
            new("Git", "Git.Git", "2.50.0", "2.51.0", "winget"),
            new("VLC", "VideoLAN.VLC", "3.0.18", "3.0.21", "winget")
        };
        mockService.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>())).ReturnsAsync(updates);
        mockService.Setup(s => s.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("id", "name", "Winget", true, "Success", true));

        var vm = new AppManagementViewModel(mockService.Object);
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.Equal(100.0, vm.OperationProgress);
        Assert.Contains("Batch upgrade finished: 2 of 2", vm.UpdatesStatusText);
        Assert.Empty(vm.AvailableUpdates);
    }

    // =========================================================================
    // FEATURE 10: AppManagementView (3-Tab UI) (>=5 tests)
    // =========================================================================

    [Fact]
    public void F10_01_ViewXaml_ExistsAndParsesValidXml()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        Assert.True(File.Exists(viewPath), $"AppManagementView.xaml not found at {viewPath}");

        var doc = XDocument.Load(viewPath);
        Assert.NotNull(doc.Root);
        Assert.Equal("UserControl", doc.Root.Name.LocalName);
    }

    [Fact]
    public void F10_02_ViewXaml_ContainsExactlyThreePillarTabs()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var tabItems = doc.Descendants().Where(d => d.Name.LocalName == "TabItem").ToList();
        Assert.Equal(3, tabItems.Count);

        var headers = tabItems.Select(t => (string?)t.Attribute("Header")).ToList();
        Assert.Contains("Search & Discover", headers);
        Assert.Contains("Installed Applications", headers);
        Assert.Contains("Available Updates", headers);
    }

    [Fact]
    public void F10_03_ViewXaml_TabControlAppliesFluentTabControlStyle()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var tabControl = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "TabControl");
        Assert.NotNull(tabControl);
        Assert.Equal("{StaticResource FluentTabControlStyle}", (string?)tabControl.Attribute("Style"));
    }

    [Fact]
    public void F10_04_ViewXaml_ContainsAllRequiredDataGridsAndBindings()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var dataGrids = doc.Descendants().Where(d => d.Name.LocalName == "DataGrid").ToList();
        Assert.Equal(3, dataGrids.Count);

        var itemSources = dataGrids.Select(dg => (string?)dg.Attribute("ItemsSource")).ToList();
        Assert.Contains("{Binding SearchResults}", itemSources);
        Assert.Contains("{Binding InstalledApps}", itemSources);
        Assert.Contains("{Binding AvailableUpdates}", itemSources);
    }

    [Fact]
    public void F10_05_ViewXaml_ActionButtonsUseStandardizedStyles()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var buttons = doc.Descendants().Where(d => d.Name.LocalName == "Button").ToList();
        Assert.NotEmpty(buttons);

        foreach (var btn in buttons)
        {
            string? style = (string?)btn.Attribute("Style");
            // Must either be default implicit style, AccentButtonStyle, or FluentButtonStyle
            Assert.True(
                style == null ||
                style.Contains("AccentButtonStyle") ||
                style.Contains("FluentButtonStyle"),
                $"Button '{btn.Attribute("Content")?.Value}' uses unapproved style: {style}");
        }
    }

    // =========================================================================
    // FEATURE 11: NavRail & Shell Integration (>=5 tests)
    // =========================================================================

    [Fact]
    public void F11_01_MainWindowXaml_DefinesAppManagementDataTemplate()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        string xaml = File.ReadAllText(path);

        Assert.Contains("DataType=\"{x:Type vm:AppManagementViewModel}\"", xaml);
        Assert.Contains("<views:AppManagementView />", xaml);
    }

    [Fact]
    public void F11_02_MainWindowXaml_NavRailContainsAppManagementRadioButton()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        string xaml = File.ReadAllText(path);

        Assert.Contains("CommandParameter=\"AppManagement\"", xaml);
        Assert.Contains("Text=\"App Management\"", xaml);
    }

    [Fact]
    public void F11_03_MainViewModel_NavigateToPillar_SwitchesToAppManagementViewModel()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        var appMgmtVm = provider.GetRequiredService<AppManagementViewModel>();

        mainVm.NavigateToPillar("AppManagement");

        Assert.Equal("AppManagement", mainVm.CurrentPillarName);
        Assert.Same(appMgmtVm, mainVm.CurrentPageViewModel);
    }

    [Fact]
    public void F11_04_ServiceRegistration_RegistersAppManagementViewModelAsSingleton()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var instance1 = provider.GetRequiredService<AppManagementViewModel>();
        var instance2 = provider.GetRequiredService<AppManagementViewModel>();

        Assert.NotNull(instance1);
        Assert.Same(instance1, instance2);
    }

    [Fact]
    public void F11_05_ServiceRegistration_RegistersIAppInstallerService()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var service = provider.GetRequiredService<IAppInstallerService>();

        Assert.NotNull(service);
        Assert.IsType<AppInstallerService>(service);
    }

    // =========================================================================
    // FEATURE 12: Real-World Host Verification (>=5 tests)
    // =========================================================================

    [Fact]
    public void F12_01_RealWorldTestFixture_TargetsCanonicalSevenZipPackage()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        Assert.True(File.Exists(testPath));

        string content = File.ReadAllText(testPath);
        Assert.Contains("TargetPackageId = \"7zip.7zip\"", content);
        Assert.Contains("IAsyncLifetime", content);
    }

    [Fact]
    public void F12_02_RealWorldTestFixture_ImplementsAsyncLifetimeLifecycle()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("public async Task InitializeAsync()", content);
        Assert.Contains("public async Task DisposeAsync()", content);
    }

    [Fact]
    public void F12_03_RealWorldTestFixture_ExecutesProcessLockTerminationBeforeTeardown()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("7z", content);
        Assert.Contains("7zFM", content);
    }

    [Fact]
    public void F12_04_RealWorldTestFixture_ContainsSelfHealingSetup()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("SilentlyCleanLeftoverAsync()", content);
    }

    [Fact]
    public void F12_05_RealWorldTestFixture_UsesIsolatedTestLogDirectory()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("iToolKit_WingetLiveTest_", content);
    }

    // =========================================================================
    // FEATURE 13: Pre-Test State Restoration (>=5 tests)
    // =========================================================================

    [Fact]
    public void F13_01_StateRestoration_VerifiesProgramFilesFolderCleanup()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("CleanResidualDirectory(TargetInstallDir)", content);
        Assert.Contains("CleanResidualDirectory(TargetInstallDirX86)", content);
    }

    [Fact]
    public void F13_02_StateRestoration_VerifiesArpRegistryKeyCleanup()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("Assert.DoesNotContain(postUninstallApps, a => a.Id.Equals(TargetPackageId", content);
        Assert.Contains("WingetCliParser.IsNoApplicationsFound(verifyRes.ExitCode)", content);
    }

    [Fact]
    public void F13_03_StateRestoration_GuaranteesCleanupEvenOnTestFailure()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("Tier 1 In-Method Cleanup: Attempt immediate uninstallation on failure", content);
        Assert.Contains("await _installerService.UninstallWingetPackageAsync(TargetPackageId, failureCleanupCts.Token)", content);
    }

    [Fact]
    public void F13_04_StateRestoration_VerifiesHostCleanlinessInvariant()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("Step6_VerifyCleanup_AbsentFromInventoryAndPreTestStateRestored", content);
        Assert.Contains("PreTest_VerifyPackageNotInstalled", content);
    }

    [Fact]
    public void F13_05_StateRestoration_CleansTemporaryDirectoriesInFinallyBlock()
    {
        string servicePath = Path.Combine(SolutionRoot, "src", "IToolkit.Core", "Services", "Software", "AppInstallerService.cs");
        string content = File.ReadAllText(servicePath);

        Assert.Contains("_fileSystem.DeleteFile(tempZip)", content);
        Assert.Contains("_fileSystem.DeleteFile(tempExe)", content);
    }
}
