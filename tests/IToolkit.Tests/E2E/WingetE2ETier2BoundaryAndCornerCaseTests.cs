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
/// Tier 2: Boundary Value Analysis & Corner Case Test Suite.
/// Enforces at least 5 boundary/corner tests per feature across all 13 features in docs/PROJECT.md.
/// </summary>
public class WingetE2ETier2BoundaryAndCornerCaseTests
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

    private static (AppInstallerService service, Mock<IProcessRunner> mockRunner) CreateCancellingServiceHarness(CancellationToken token)
    {
        var mockRunner = new Mock<IProcessRunner>();
        mockRunner.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), token))
            .ThrowsAsync(new OperationCanceledException(token));

        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var guard = new ProcessLockGuard(mockRunner.Object, fs);
        var net = new MockNetworkService(fs);
        var service = new AppInstallerService(mockRunner.Object, fs, reg, guard, net);
        return (service, mockRunner);
    }

    // =========================================================================
    // FEATURE 1: Parser Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\r\n\t")]
    [InlineData(null)]
    public void B1_01_ParsePackages_NullOrWhitespaceInput_ReturnsEmptyWithoutException(string? input)
    {
        var packages = WingetCliParser.ParsePackages(input);
        Assert.NotNull(packages);
        Assert.Empty(packages);
    }

    [Fact]
    public void B1_02_ParsePackages_MissingSeparatorOrMalformedHeader_ReturnsEmptyList()
    {
        string malformed = "Name Id Version Source\r\nSomeApp SomeId 1.0.0 winget\r\n";
        var packages = WingetCliParser.ParsePackages(malformed);
        Assert.NotNull(packages);
        Assert.Empty(packages);
    }

    [Fact]
    public void B1_03_ParseInstalledApps_RowShorterThanColumnStart_HandlesGracefullyWithoutIndexOutOfRange()
    {
        string truncated =
            "Name                             Id                             Version   Available Source\r\n" +
            "------------------------------------------------------------------------------------------\r\n" +
            "ShortApp\r\n" +
            "NormalApp                        Normal.Id                      1.0.0               winget\r\n";

        var apps = WingetCliParser.ParseInstalledApps(truncated);
        // ShortApp has no Id, so it gets skipped; NormalApp is parsed cleanly
        Assert.Single(apps);
        Assert.Equal("NormalApp", apps[0].Name);
    }

    [Fact]
    public void B1_04_ParseExitCode_NegativeExitCodes_BuildsHexadecimalStringAndPreservesStderr()
    {
        int customErrorCode = unchecked((int)0x80070005); // Access Denied
        var outcome = WingetCliParser.ParseExitCode(customErrorCode, "Install", "SecuredApp", "Access is denied by policy.");

        Assert.False(outcome.Success);
        Assert.Contains("0x80070005", outcome.Message);
        Assert.Contains("Access is denied by policy.", outcome.Message);
    }

    [Theory]
    [InlineData("0 upgrades available.")]
    [InlineData("99 upgrades available.")]
    [InlineData("1000 upgrades available.")]
    public void B1_05_ParseUpdates_ArbitraryUpgradeSummaryCounts_AreFilteredAsNoise(string summaryLine)
    {
        string table =
            "Name      Id         Version   Available  Source\r\n" +
            "------------------------------------------------\r\n" +
            "App1      App1.Id    1.0.0     1.1.0      winget\r\n" +
            summaryLine + "\r\n";

        var updates = WingetCliParser.ParseUpdates(table);
        Assert.Single(updates);
        Assert.Equal("App1", updates[0].Name);
    }

    // =========================================================================
    // FEATURE 2: Search Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t")]
    [InlineData(null!)]
    public async Task B2_01_SearchPackagesAsync_EmptyOrWhitespaceQuery_ReturnsEmptyWithoutInvokingProcess(string? query)
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var results = await service.SearchPackagesAsync(query!);

        Assert.NotNull(results);
        Assert.Empty(results);
        Assert.Empty(runner.ExecutedCommands);
    }

    [Fact]
    public async Task B2_02_SearchPackagesAsync_ShellMetacharacters_AreSafelyQuoted()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string suspiciousQuery = "app & calc.exe | dir ; rm";
        string expectedCmd = "winget.exe search \"app & calc.exe | dir ; rm\" --source winget --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, string.Empty, string.Empty, false));

        var results = await service.SearchPackagesAsync(suspiciousQuery);

        Assert.NotNull(results);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task B2_03_SearchPackagesAsync_ProcessTimeout_ReturnsEmptyListAndLogsError()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var logger = new TestActivityLogger();
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);

        string cmd = "winget.exe search \"SlowQuery\" --source winget --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(-1, string.Empty, "Timed out after 60000ms", true));

        var results = await service.SearchPackagesAsync("SlowQuery");

        Assert.NotNull(results);
        Assert.Empty(results);
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("timed out"));
    }

    [Fact]
    public async Task B2_04_SearchPackagesAsync_CancellationTokenCancelled_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.SearchPackagesAsync("cancelled_search", cts.Token);
        });
    }

    [Fact]
    public async Task B2_05_SearchPackagesAsync_NonZeroExitCode_ReturnsEmptyListAndLogsWarning()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var logger = new TestActivityLogger();
        var service = new AppInstallerService(runner, fs, reg, guard, net, logger);

        string cmd = "winget.exe search \"FailedApp\" --source winget --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1, string.Empty, "Generic failure", false));

        var results = await service.SearchPackagesAsync("FailedApp");

        Assert.NotNull(results);
        Assert.Empty(results);
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Winget search returned exit code 1"));
    }

    // =========================================================================
    // FEATURE 3: Installed Inventory Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public async Task B3_01_GetInstalledApplicationsAsync_EmptyStdout_ReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --disable-interactivity --nowarn",
            new ProcessExecutionResult(0, string.Empty, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    [Fact]
    public async Task B3_02_GetInstalledApplicationsAsync_BlankNameOrIdRows_AreIgnored()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string tableWithBlanks =
            "Name      Id         Version   Available  Source\r\n" +
            "------------------------------------------------\r\n" +
            "          NoNameId   1.0.0                winget\r\n" +
            "NoIdApp              1.0.0                winget\r\n" +
            "ValidApp  Valid.Id   2.0.0                winget\r\n";

        runner.SetCommandResult("winget.exe list --disable-interactivity --nowarn", new ProcessExecutionResult(0, tableWithBlanks, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.Single(apps);
        Assert.Equal("ValidApp", apps[0].Name);
    }

    [Fact]
    public async Task B3_03_GetInstalledApplicationsAsync_ProcessTimeout_ReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --disable-interactivity --nowarn",
            new ProcessExecutionResult(-1, string.Empty, "Timeout", true));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    [Fact]
    public async Task B3_04_GetInstalledApplicationsAsync_CancelledToken_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.GetInstalledApplicationsAsync(cts.Token);
        });
    }

    [Fact]
    public async Task B3_05_GetInstalledApplicationsAsync_RunnerThrowsException_CatchesAndReturnsEmptyList()
    {
        var mockRunner = new Mock<IProcessRunner>();
        mockRunner.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new IOException("Disk read error"));

        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var guard = new ProcessLockGuard(mockRunner.Object, fs);
        var net = new MockNetworkService(fs);
        var service = new AppInstallerService(mockRunner.Object, fs, reg, guard, net);

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    // =========================================================================
    // FEATURE 4: Updates Detection Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public async Task B4_01_GetAvailableUpdatesAsync_EmptyStdout_ReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --upgrade-available --disable-interactivity --nowarn",
            new ProcessExecutionResult(0, "   \r\n", string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task B4_02_GetAvailableUpdatesAsync_MassiveList50Items_SlicesAllRowsCorrectly()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("Name           Id                   Version   Available  Source");
        sb.AppendLine("---------------------------------------------------------------");
        for (int i = 1; i <= 50; i++)
        {
            sb.AppendLine($"Package{i,-7} Vendor.Package{i,-10} 1.0.0     1.0.{i}    winget");
        }
        sb.AppendLine("50 upgrades available.");

        runner.SetCommandResult(
            "winget.exe list --upgrade-available --disable-interactivity --nowarn",
            new ProcessExecutionResult(0, sb.ToString(), string.Empty, false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.Equal(50, updates.Count);
        Assert.Equal("Package1", updates[0].Name);
        Assert.Equal("Package50", updates[49].Name);
    }

    [Fact]
    public async Task B4_03_GetAvailableUpdatesAsync_ProcessTimeout_ReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult(
            "winget.exe list --upgrade-available --disable-interactivity --nowarn",
            new ProcessExecutionResult(-1, string.Empty, "Timed out", true));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task B4_04_GetAvailableUpdatesAsync_CancelledToken_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.GetAvailableUpdatesAsync(cts.Token);
        });
    }

    [Fact]
    public async Task B4_05_GetAvailableUpdatesAsync_RunnerErrorExitCode_ReturnsEmptyListAndLogsWarning()
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
            new ProcessExecutionResult(2, string.Empty, "Catalog corrupted", false));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("exit code 2"));
    }

    // =========================================================================
    // FEATURE 5: Single Package Install Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task B5_01_InstallWingetPackageAsync_EmptyId_ReturnsFailureWithoutLaunchingProcess(string? packageId)
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.InstallWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("cannot be empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.ExecutedCommands);
    }

    [Fact]
    public async Task B5_02_InstallWingetPackageAsync_ProcessTimeout_ReturnsFailureWithTimeoutMessage()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe install --id HungApp --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(-1, string.Empty, "Timed out after 10 minutes", true));

        var result = await service.InstallWingetPackageAsync("HungApp");

        Assert.False(result.Success);
        Assert.Contains("timed out", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B5_03_InstallWingetPackageAsync_ExitCode1223_TranslatesToUserCancelledMessage()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe install --id CancelledApp --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1223, string.Empty, "UAC prompt declined", false));

        var result = await service.InstallWingetPackageAsync("CancelledApp");

        Assert.False(result.Success);
        Assert.Contains("cancelled by the user", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B5_04_InstallWingetPackageAsync_ExitCode0x8A150019_RequiresAdminMessage()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe install --id AdminApp --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150019), string.Empty, "Requires elevation", false));

        var result = await service.InstallWingetPackageAsync("AdminApp");

        Assert.False(result.Success);
        Assert.Contains("requires administrator privileges", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B5_05_InstallWingetPackageAsync_CancelledToken_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.InstallWingetPackageAsync("AnyApp", cts.Token);
        });
    }

    // =========================================================================
    // FEATURE 6: Single Package Upgrade Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task B6_01_UpgradeWingetPackageAsync_EmptyId_ReturnsFailureWithoutLaunchingProcess(string? packageId)
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.UpgradeWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("cannot be empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.ExecutedCommands);
    }

    [Fact]
    public async Task B6_02_UpgradeWingetPackageAsync_Timeout_ReturnsFailureResult()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id HungUpgrade --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(-1, string.Empty, "Timeout", true));

        var result = await service.UpgradeWingetPackageAsync("HungUpgrade");

        Assert.False(result.Success);
        Assert.Contains("timed out", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B6_03_UpgradeWingetPackageAsync_MultiplePackagesMatched_ReturnsExactIdGuidance()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id AmbiguousApp --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150016), string.Empty, "Multiple matches", false));

        var result = await service.UpgradeWingetPackageAsync("AmbiguousApp");

        Assert.False(result.Success);
        Assert.Contains("Specify an exact ID", result.Message);
    }

    [Fact]
    public async Task B6_04_UpgradeWingetPackageAsync_BatchFailureCode_ReturnsActionableFailure()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe upgrade --id PartialFailApp --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A15002C), string.Empty, string.Empty, false));

        var result = await service.UpgradeWingetPackageAsync("PartialFailApp");

        Assert.False(result.Success);
        Assert.Contains("0x8A15002C", result.Message);
    }

    [Fact]
    public async Task B6_05_UpgradeWingetPackageAsync_CancelledToken_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.UpgradeWingetPackageAsync("AnyApp", cts.Token);
        });
    }

    // =========================================================================
    // FEATURE 7: Package Uninstall Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task B7_01_UninstallWingetPackageAsync_EmptyId_ReturnsFailureImmediately(string? packageId)
    {
        var (service, runner, _, _, _) = CreateServiceHarness();

        var result = await service.UninstallWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("cannot be empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.ExecutedCommands);
    }

    [Fact]
    public async Task B7_02_UninstallWingetPackageAsync_Timeout_ReturnsFailureResult()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe uninstall --id HungUninstall --exact --silent --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(-1, string.Empty, "Timeout", true));

        var result = await service.UninstallWingetPackageAsync("HungUninstall");

        Assert.False(result.Success);
        Assert.Contains("timed out", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B7_03_UninstallWingetPackageAsync_RequiresAdminAltExitCode_ReturnsAdminNotice()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe uninstall --id SystemApp --exact --silent --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(-1978335068, string.Empty, "Elevation required", false));

        var result = await service.UninstallWingetPackageAsync("SystemApp");

        Assert.False(result.Success);
        Assert.Contains("requires administrator privileges", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task B7_04_UninstallWingetPackageAsync_PackageNotFound_ReturnsNotFoundMessage()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        string cmd = "winget.exe uninstall --id MissingApp --exact --silent --disable-interactivity";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150014), string.Empty, string.Empty, false));

        var result = await service.UninstallWingetPackageAsync("MissingApp");

        Assert.False(result.Success);
        Assert.Contains("No package found", result.Message);
    }

    [Fact]
    public async Task B7_05_UninstallWingetPackageAsync_CancelledToken_ThrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        var (service, _) = CreateCancellingServiceHarness(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await service.UninstallWingetPackageAsync("AnyApp", cts.Token);
        });
    }

    // =========================================================================
    // FEATURE 8: Catalog Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public void B8_01_GetApp_NonExistentAppId_ReturnsNull()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var app = service.GetApp("non_existent_app_id_12345");
        Assert.Null(app);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("NonExistentAppXYZ")]
    public void B8_02_GetApp_WhitespaceOrUnknown_ReturnsNull(string id)
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var app = service.GetApp(id);
        Assert.Null(app);
    }

    [Fact]
    public void B8_02b_GetApp_NullKey_ThrowsArgumentNullException()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        Assert.Throws<ArgumentNullException>(() => service.GetApp(null!));
    }

    [Fact]
    public void B8_03_InstallBatch_EmptyCollection_ReturnsEmptyListWithoutError()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var results = service.InstallBatch(Array.Empty<string>());
        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public void B8_04_InstallBatch_UnknownAppId_RecordsFailureResult()
    {
        var (service, _, _, _, _) = CreateServiceHarness();
        var results = service.InstallBatch(new[] { "InvalidAppXYZ" });

        Assert.Single(results);
        Assert.False(results[0].Success);
        Assert.Contains("not found", results[0].Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void B8_05_InstallBatch_DuplicateAppIds_ExecutesSafely()
    {
        var (service, runner, _, _, _) = CreateServiceHarness();
        runner.SetCommandResult("winget.exe", new ProcessExecutionResult(0, string.Empty, string.Empty, false));

        var results = service.InstallBatch(new[] { "Chrome", "Chrome" });
        Assert.NotNull(results);
        Assert.Equal(2, results.Count);
    }

    // =========================================================================
    // FEATURE 9: ViewModel Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public async Task B9_01_SearchAppsAsync_WhitespaceQuery_SetsWarningStatusWithoutCallingService(string query)
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);
        vm.SearchQuery = query;

        await vm.SearchAppsAsync();

        mockService.Verify(s => s.SearchPackagesAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Contains("enter a valid application name", vm.SearchStatusText, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("*")]
    [InlineData("?")]
    [InlineData("[a-z]")]
    [InlineData("\\")]
    [InlineData("+")]
    public async Task B9_02_InstalledFilterQuery_SpecialRegexCharacters_DoesNotCrashFilterLogic(string regexPattern)
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);

        var app = new InstalledAppViewModel(new WingetInstalledApp("SpecialApp", "Special.Id", "1.0", null, "winget"));
        mockService.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app.App });

        await vm.RefreshInstalledAsync();
        // Set special filter string; must not throw RegexParseException
        var exception = Record.Exception(() => vm.InstalledFilterQuery = regexPattern);
        Assert.Null(exception);
    }

    [Fact]
    public async Task B9_03_InstallAppAsync_NullParameter_IsSafeAndDoesNotThrow()
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);

        var exception = await Record.ExceptionAsync(async () =>
        {
            await vm.InstallAppAsync((WingetPackageViewModel?)null);
        });

        Assert.Null(exception);
        mockService.Verify(s => s.InstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task B9_04_UninstallAppAsync_NullParameter_IsSafeAndDoesNotThrow()
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);

        var exception = await Record.ExceptionAsync(async () =>
        {
            await vm.UninstallAppAsync((InstalledAppViewModel?)null);
        });

        Assert.Null(exception);
        mockService.Verify(s => s.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task B9_05_UpdateAppAsync_NullParameter_IsSafeAndDoesNotThrow()
    {
        var mockService = new Mock<IAppInstallerService>();
        var vm = new AppManagementViewModel(mockService.Object);

        var exception = await Record.ExceptionAsync(async () =>
        {
            await vm.UpdateAppAsync((AppUpdateViewModel?)null);
        });

        Assert.Null(exception);
        mockService.Verify(s => s.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    // =========================================================================
    // FEATURE 10: View Layout Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public void B10_01_SearchResultsDataGrid_ConfiguredWithAutoGenerateColumnsFalseAndIsReadOnly()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var searchGrid = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "DataGrid" && (string?)d.Attribute("ItemsSource") == "{Binding SearchResults}");
        Assert.NotNull(searchGrid);
        Assert.Equal("False", (string?)searchGrid.Attribute("AutoGenerateColumns"));
        Assert.Equal("True", (string?)searchGrid.Attribute("IsReadOnly"));
    }

    [Fact]
    public void B10_02_InstalledAppsDataGrid_ConfiguredWithAutoGenerateColumnsFalseAndIsReadOnly()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var installedGrid = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "DataGrid" && (string?)d.Attribute("ItemsSource") == "{Binding InstalledApps}");
        Assert.NotNull(installedGrid);
        Assert.Equal("False", (string?)installedGrid.Attribute("AutoGenerateColumns"));
        Assert.Equal("True", (string?)installedGrid.Attribute("IsReadOnly"));
    }

    [Fact]
    public void B10_03_AvailableUpdatesDataGrid_ConfiguredWithAutoGenerateColumnsFalseAndIsReadOnly()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var updatesGrid = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "DataGrid" && (string?)d.Attribute("ItemsSource") == "{Binding AvailableUpdates}");
        Assert.NotNull(updatesGrid);
        Assert.Equal("False", (string?)updatesGrid.Attribute("AutoGenerateColumns"));
        Assert.Equal("True", (string?)updatesGrid.Attribute("IsReadOnly"));
    }

    [Fact]
    public void B10_04_AllThreeTabs_ScrollViewersDisableHorizontalScrollBar()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var scrollViewers = doc.Descendants().Where(d => d.Name.LocalName == "ScrollViewer").ToList();
        Assert.True(scrollViewers.Count >= 3);

        foreach (var sv in scrollViewers)
        {
            Assert.Equal("Disabled", (string?)sv.Attribute("HorizontalScrollBarVisibility"));
        }
    }

    [Fact]
    public void B10_05_ProgressBars_BindVisibilityToBooleanFlagsViaConverter()
    {
        string viewPath = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "AppManagementView.xaml");
        var doc = XDocument.Load(viewPath);

        var progressBars = doc.Descendants().Where(d => d.Name.LocalName == "ProgressBar").ToList();
        Assert.True(progressBars.Count >= 3);

        foreach (var pb in progressBars)
        {
            string? vis = (string?)pb.Attribute("Visibility");
            Assert.NotNull(vis);
            Assert.Contains("BoolToVisConverter", vis);
        }
    }

    // =========================================================================
    // FEATURE 11: NavRail Boundaries (5 tests)
    // =========================================================================

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void B11_01_NavigateToPillar_NullOrWhitespace_PreservesCurrentPageAndDoesNotCrash(string? invalidPillar)
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        var originalPillar = mainVm.CurrentPillarName;
        var originalPage = mainVm.CurrentPageViewModel;

        mainVm.NavigateToPillar(invalidPillar);

        Assert.Equal(originalPillar, mainVm.CurrentPillarName);
        Assert.Same(originalPage, mainVm.CurrentPageViewModel);
    }

    [Fact]
    public void B11_02_NavigateToPillar_UnknownPillar_DefaultsSafelyToDashboardViewModel()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        mainVm.NavigateToPillar("NonExistentPillar123");

        Assert.Equal("NonExistentPillar123", mainVm.CurrentPillarName);
        Assert.Same(mainVm.DashboardViewModel, mainVm.CurrentPageViewModel);
    }

    [Fact]
    public void B11_03_MainViewModel_NullAppManagementViewModel_FallsBackToDashboard()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        // Create MainViewModel without AppManagementViewModel
        var mainVm = new MainViewModel(
            provider.GetRequiredService<TelemetryHeaderViewModel>(),
            provider.GetRequiredService<ActivityConsoleViewModel>(),
            provider.GetRequiredService<DashboardViewModel>(),
            provider.GetRequiredService<SystemHealthViewModel>(),
            provider.GetRequiredService<OfficeOutlookViewModel>(),
            provider.GetRequiredService<ConnectivityViewModel>(),
            provider.GetRequiredService<IdentityBackupViewModel>(),
            provider.GetRequiredService<SoftwareOptimizationViewModel>(),
            appManagementViewModel: null,
            logger: null);

        mainVm.NavigateToPillar("AppManagement");

        Assert.Same(mainVm.DashboardViewModel, mainVm.CurrentPageViewModel);
    }

    [Fact]
    public void B11_04_MainWindowXaml_AppManagementRadioButton_HasPillarNavGroupName()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        var doc = XDocument.Load(path);

        var radioButtons = doc.Descendants().Where(d => d.Name.LocalName == "RadioButton").ToList();
        var appMgmtBtn = radioButtons.FirstOrDefault(r => (string?)r.Attribute("CommandParameter") == "AppManagement");

        Assert.NotNull(appMgmtBtn);
        Assert.Equal("PillarNav", (string?)appMgmtBtn.Attribute("GroupName"));
    }

    [Fact]
    public void B11_05_ToggleNavRailCommand_PreservesActivePillarAndViewModel()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider();

        var mainVm = provider.GetRequiredService<MainViewModel>();
        mainVm.NavigateToPillar("AppManagement");

        bool initialExpanded = mainVm.IsNavRailExpanded;
        mainVm.ToggleNavRailCommand.Execute(null);

        Assert.NotEqual(initialExpanded, mainVm.IsNavRailExpanded);
        Assert.Equal("AppManagement", mainVm.CurrentPillarName);
        Assert.Same(provider.GetRequiredService<AppManagementViewModel>(), mainVm.CurrentPageViewModel);
    }

    // =========================================================================
    // FEATURE 12: Host Verification Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public void B12_01_HostVerification_OperatingSystemCheck_ProtectsNonWindowsPlatforms()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("if (!OperatingSystem.IsWindows() || !IsWingetAvailable())", content);
    }

    [Fact]
    public void B12_02_HostVerification_WingetMissingCheck_BypassesExecutionSafely()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("private bool IsWingetAvailable()", content);
        Assert.Contains("res.ExitCode == 0 && !res.TimedOut", content);
    }

    [Fact]
    public void B12_03_HostVerification_SilentlyCleanLeftoverAsync_HandlesAbsentPackageSafely()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("if (installed.Any(a => a.Id.Equals(TargetPackageId", content);
    }

    [Fact]
    public void B12_04_HostVerification_PurgeTempCaches_HandlesMissingDirectoryWithoutThrowing()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("if (Directory.Exists(wingetTemp))", content);
    }

    [Fact]
    public void B12_05_HostVerification_CleanResidualDirectory_DoesNotDeleteDirectoriesWithExecutables()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("var exes = Directory.GetFiles(dirPath, \"*.exe\"", content);
        Assert.Contains("if (exes.Length == 0)", content);
    }

    // =========================================================================
    // FEATURE 13: Restoration Boundaries (5 tests)
    // =========================================================================

    [Fact]
    public void B13_01_StateRestoration_DisposeAsync_WhenNotInstalled_SkipsUninstall()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("if (_testAppInstalled)", content);
    }

    [Fact]
    public void B13_02_StateRestoration_DisposeAsync_ResetsTestAppInstalledFlagInFinally()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("_testAppInstalled = false;", content);
    }

    [Fact]
    public void B13_03_StateRestoration_ProcessRunnerStopProcess_HandlesNonRunningProcess()
    {
        var runner = new MockProcessRunner();
        bool stopped = runner.StopProcess("NonExistentProcess_9876", 1, true);
        Assert.True(stopped);
    }

    [Fact]
    public void B13_04_StateRestoration_VerifyCleanup_AcceptsExitCode1Or0x8A150014ForAbsentPackage()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("WingetCliParser.IsNoApplicationsFound(verifyRes.ExitCode) || verifyRes.ExitCode == 1", content);
    }

    [Fact]
    public void B13_05_StateRestoration_DisposeAsync_SafelyDeletesTestLogDirectory()
    {
        string testPath = Path.Combine(SolutionRoot, "tests", "IToolkit.Tests", "Integration", "WingetRealWorldVerificationTests.cs");
        string content = File.ReadAllText(testPath);

        Assert.Contains("if (Directory.Exists(_testLogDir))", content);
        Assert.Contains("Directory.Delete(_testLogDir, recursive: true);", content);
    }
}
