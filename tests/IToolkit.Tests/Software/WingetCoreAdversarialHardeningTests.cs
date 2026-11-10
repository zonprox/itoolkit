namespace IToolkit.Tests.Software;

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Software;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Tier 5 Adversarial Coverage Hardening Test Suite for Core Winget Engine in IToolkit.Core.
/// White-box stress testing targeting untested branches, corner cases, dynamic slicing limits,
/// unrecognized exit codes, process failure modes, and concurrency invariants.
/// </summary>
public class WingetCoreAdversarialHardeningTests
{
    private static (AppInstallerService Service, MockProcessRunner Runner, MockFileSystemService Fs, MockRegistryService Reg, MockNetworkService Net) CreateHarness()
    {
        var runner = new MockProcessRunner();
        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(runner, fs);
        var service = new AppInstallerService(runner, fs, reg, guard, net);
        return (service, runner, fs, reg, net);
    }

    private static AppInstallerService CreateThrowingHarness(Exception exceptionToThrow)
    {
        var mockRunner = new Mock<IProcessRunner>();
        mockRunner
            .Setup(r => r.RunAsync(
                It.IsAny<string>(),
                It.IsAny<string>(),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ThrowsAsync(exceptionToThrow);

        var fs = new MockFileSystemService();
        var reg = new MockRegistryService();
        var net = new MockNetworkService(fs);
        var guard = new ProcessLockGuard(mockRunner.Object, fs);
        return new AppInstallerService(mockRunner.Object, fs, reg, guard, net);
    }

    // =========================================================================
    // 1. DYNAMIC TABLE SLICING, DELIMITERS, AND BOUNDARY LIMITS
    // =========================================================================

    [Fact]
    public void TableParser_ColumnOrderingReversed_ExtractsFieldsCorrectly()
    {
        // Headers in non-standard order: Id, Name, Version, Source
        string reversedTable =
            "Id               Name             Version  Source\r\n" +
            "-------------------------------------------------\r\n" +
            "7zip.7zip        7-Zip            24.09    winget\r\n" +
            "Git.Git          Git              2.47.0   winget\r\n";

        var packages = WingetCliParser.ParsePackages(reversedTable);

        Assert.Equal(2, packages.Count);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("24.09", packages[0].Version);
        Assert.Equal("winget", packages[0].Source);

        Assert.Equal("Git", packages[1].Name);
        Assert.Equal("Git.Git", packages[1].Id);
        Assert.Equal("2.47.0", packages[1].Version);
        Assert.Equal("winget", packages[1].Source);
    }

    [Fact]
    public void TableParser_LineShorterThanFirstColumnEnd_ExtractsSafelyWithoutOutOfRange()
    {
        // Header defines Name (0..17), Id (17..34), Version (34..)
        // Row 1 has only 6 characters.
        string shortRowTable =
            "Name             Id               Version  Source\r\n" +
            "-------------------------------------------------\r\n" +
            "Short\r\n" +
            "ValidApp         Valid.Id         1.0.0    winget\r\n";

        var packages = WingetCliParser.ParsePackages(shortRowTable);

        // Row 1 lacks Id so it is skipped. Row 2 is parsed cleanly.
        Assert.Single(packages);
        Assert.Equal("ValidApp", packages[0].Name);
        Assert.Equal("Valid.Id", packages[0].Id);
    }

    [Fact]
    public void TableParser_LineLengthExactlyAtColumnStartBoundary_HandlesGracefully()
    {
        // Column starts at exact index where string terminates
        string boundaryTable =
            "Name             Id               Version\r\n" +
            "-----------------------------------------\r\n" +
            "ExactBoundaryApp \r\n" +
            "FullApp          Full.Id          1.2.3  \r\n";

        var packages = WingetCliParser.ParsePackages(boundaryTable);

        Assert.Single(packages);
        Assert.Equal("FullApp", packages[0].Name);
    }

    [Fact]
    public void TableParser_ExtremeCellLength_PreservesLargeStringsWhenColumnWidthAccommodates()
    {
        string longName = "VeryLongApplicationNameWithLotsOfPunctuationAndDescriptiveDetails_" + new string('X', 200);
        string longId = "Enterprise.Organization.Department.Software.Product.Identifier." + new string('Y', 150);

        // Header allocates 300 chars for Name, 250 chars for Id
        string header = $"{"Name",-300} {"Id",-250} {"Version",-10} Source";
        string separator = $"{new string('-', 300)} {new string('-', 250)} {new string('-', 10)} ------";
        string dataRow = $"{longName,-300} {longId,-250} {"9.9.9",-10} winget";

        string table = $"{header}\r\n{separator}\r\n{dataRow}\r\n";

        var packages = WingetCliParser.ParsePackages(table);

        Assert.Single(packages);
        Assert.Equal(longName, packages[0].Name);
        Assert.Equal(longId, packages[0].Id);
        Assert.Equal("9.9.9", packages[0].Version);
    }

    [Fact]
    public void TableParser_CellOverflowBeyondNextColumnBoundary_TruncatesAtNextColumn()
    {
        // Header allocates only 15 chars for Name (0..16), Id at 16
        string header = "Name             Id               Version\r\n";
        string separator = "---------------- ---------------- -------\r\n";
        // Data row has Name with 25 characters, overflowing into Id column
        string dataRow = "VeryLongApplicationNameThatOverflows NextId 1.0.0\r\n";

        var packages = WingetCliParser.ParsePackages(header + separator + dataRow);

        Assert.Single(packages);
        // Name is truncated at index 17 (the start of Id column)
        Assert.Equal("VeryLongApplicati", packages[0].Name);
    }

    [Fact]
    public void TableParser_MixedLineEndings_CRLF_LF_CR_ParsesConsistently()
    {
        // Table constructed with alternating CRLF, LF, and CR line endings
        string mixedTable =
            "Name             Id               Version  Source\r\n" +
            "-------------------------------------------------\n" +
            "AppOne           App.One          1.0.0    winget\r" +
            "AppTwo           App.Two          2.0.0    winget\r\n";

        var packages = WingetCliParser.ParsePackages(mixedTable);

        Assert.Equal(2, packages.Count);
        Assert.Equal("AppOne", packages[0].Name);
        Assert.Equal("AppTwo", packages[1].Name);
    }

    [Fact]
    public void TableParser_MultipleHeaderSeparatorBlocks_OnlyFirstHeaderRowDeterminesColumns()
    {
        // Stream containing a repeated header/separator block
        string repeatedHeaderTable =
            "Name             Id               Version  Source\r\n" +
            "-------------------------------------------------\r\n" +
            "AppOne           App.One          1.0.0    winget\r\n" +
            "Name             Id               Version  Source\r\n" +
            "-------------------------------------------------\r\n" +
            "AppTwo           App.Two          2.0.0    winget\r\n";

        var packages = WingetCliParser.ParsePackages(repeatedHeaderTable);

        // The second header line lacks Id in second col if parsed as data or gets parsed as data row
        // Because "Name" and "Id" are in data row, it may parse AppOne and AppTwo
        Assert.Contains(packages, p => p.Name == "AppOne" && p.Id == "App.One");
        Assert.Contains(packages, p => p.Name == "AppTwo" && p.Id == "App.Two");
    }

    [Fact]
    public void TableParser_UnknownInterspersedColumns_SpansUntilNextKnownColumn()
    {
        // Columns include unknown "Architecture" between Name and Id, and "Publisher" between Id and Version
        // Because Architecture and Publisher are not in ColumnHeaderRegex, each recognized column
        // slices until the start of the next recognized column
        string customColumnsTable =
            "Name             Architecture Id               Publisher        Version  Source\r\n" +
            "-------------------------------------------------------------------------------\r\n" +
            "AppA             x64          AppA.Id          PublisherA       1.0.0    winget\r\n";

        var packages = WingetCliParser.ParsePackages(customColumnsTable);

        Assert.Single(packages);
        // Name contains everything up to Id column start because Architecture is not recognized
        Assert.Equal("AppA             x64", packages[0].Name);
        // Id contains everything up to Version column start because Publisher is not recognized
        Assert.Equal("AppA.Id          PublisherA", packages[0].Id);
        Assert.Equal("1.0.0", packages[0].Version);
        Assert.Equal("winget", packages[0].Source);
    }

    [Fact]
    public void TableParser_CaseMismatchedHeader_FailsHeaderDetection_ReturnsEmpty()
    {
        // IsHeaderLine requires exact case "Name", "Id", "Version"
        string uppercaseTable =
            "NAME             ID               VERSION  SOURCE\r\n" +
            "-------------------------------------------------\r\n" +
            "AppA             AppA.Id          1.0.0    winget\r\n";

        var packages = WingetCliParser.ParsePackages(uppercaseTable);

        Assert.Empty(packages);
    }

    [Fact]
    public void TableParser_MissingVersionInHeader_FailsHeaderDetection_ReturnsEmpty()
    {
        // Lacks "Version" in header
        string incompleteHeaderTable =
            "Name             Id               Source\r\n" +
            "----------------------------------------\r\n" +
            "AppA             AppA.Id          winget\r\n";

        var packages = WingetCliParser.ParsePackages(incompleteHeaderTable);

        Assert.Empty(packages);
    }

    [Theory]
    [InlineData("--- === ---")]
    [InlineData("--- ******* ---")]
    [InlineData("-----------------x")]
    public void TableParser_SeparatorLineWithNonDashCharacters_FailsSeparatorDetection_ReturnsEmpty(string invalidSeparator)
    {
        string table =
            "Name             Id               Version\r\n" +
            invalidSeparator + "\r\n" +
            "AppA             AppA.Id          1.0.0\r\n";

        var packages = WingetCliParser.ParsePackages(table);

        Assert.Empty(packages);
    }

    [Theory]
    [InlineData("--")]
    [InlineData("-")]
    [InlineData("")]
    public void TableParser_SeparatorLineTooShort_FailsSeparatorDetection_ReturnsEmpty(string shortSeparator)
    {
        string table =
            "Name             Id               Version\r\n" +
            shortSeparator + "\r\n" +
            "AppA             AppA.Id          1.0.0\r\n";

        var packages = WingetCliParser.ParsePackages(table);

        Assert.Empty(packages);
    }

    [Fact]
    public void TableParser_SeparatorWithArbitrarySpacesBetweenDashes_Succeeds()
    {
        // Winget format often groups dashes per column with spaces
        string table =
            "Name             Id               Version   Source\r\n" +
            "---------------- ---------------- --------- ------\r\n" +
            "7-Zip            7zip.7zip        24.09     winget\r\n";

        var packages = WingetCliParser.ParsePackages(table);

        Assert.Single(packages);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
    }

    [Fact]
    public void TableParser_AllNoiseVariations_FilteredWithoutProducingGhostItems()
    {
        string table =
            "Name             Id               Version   Available Source\r\n" +
            "---------------- ---------------- --------- --------- ------\r\n" +
            "<progress 45%>\r\n" +
            "<additional entries truncated due to result limit>\r\n" +
            "0 upgrades available.\r\n" +
            "1 upgrade available.\r\n" +
            "999 upgrades available.\r\n" +
            "2 packages have pins that prevent upgrade. Use --include-pinned to see them.\r\n" +
            "No package found matching input criteria.\r\n" +
            "No installed package found matching input criteria.\r\n" +
            "No available upgrade found.\r\n" +
            "   \r\n" +
            "ValidApp         Valid.Id         1.0.0     1.1.0     winget\r\n";

        var packages = WingetCliParser.ParsePackages(table);
        var apps = WingetCliParser.ParseInstalledApps(table);
        var updates = WingetCliParser.ParseUpdates(table);

        Assert.Single(packages);
        Assert.Equal("ValidApp", packages[0].Name);

        Assert.Single(apps);
        Assert.Equal("ValidApp", apps[0].Name);

        Assert.Single(updates);
        Assert.Equal("ValidApp", updates[0].Name);
    }

    [Fact]
    public void TableParser_RowMissingNameOrId_SkippedSafely()
    {
        string table =
            "Name             Id               Version   Source\r\n" +
            "---------------- ---------------- --------- ------\r\n" +
            "                 MissingName.Id   1.0.0     winget\r\n" +
            "MissingIdApp                      1.0.0     winget\r\n" +
            "ValidApp         Valid.Id         1.0.0     winget\r\n";

        var packages = WingetCliParser.ParsePackages(table);

        Assert.Single(packages);
        Assert.Equal("ValidApp", packages[0].Name);
        Assert.Equal("Valid.Id", packages[0].Id);
    }

    // =========================================================================
    // 2. EXIT CODES, HRESULTS, AND ERROR FORMATTING
    // =========================================================================

    [Theory]
    [InlineData(0, true, false, false, false, false)]
    [InlineData(3010, true, true, false, false, false)]
    [InlineData(unchecked((int)0x8A15002B), true, false, true, false, false)]
    [InlineData(unchecked((int)0x8A150061), true, false, false, false, false)]
    [InlineData(1223, false, false, false, false, true)]
    [InlineData(unchecked((int)0x8A150019), false, false, false, true, false)]
    [InlineData(-1978335068, false, false, false, true, false)]
    [InlineData(unchecked((int)0x8A150014), false, false, false, false, false)]
    [InlineData(unchecked((int)0x8A150016), false, false, false, false, false)]
    [InlineData(unchecked((int)0x8A150041), false, false, false, false, false)]
    [InlineData(unchecked((int)0x8A150046), false, false, false, false, false)]
    [InlineData(unchecked((int)0x8A15002C), false, false, false, false, false)]
    [InlineData(unchecked((int)0x8A150002), false, false, false, false, false)]
    public void ParseExitCode_AllWellKnownConstants_VerifyStructuredFlags(
        int exitCode,
        bool expectedSuccess,
        bool expectedReboot,
        bool expectedUpToDate,
        bool expectedRequiresAdmin,
        bool expectedCancelled)
    {
        var result = WingetCliParser.ParseExitCode(exitCode, "Install", "Test.Package");

        Assert.Equal(expectedSuccess, result.Success);
        Assert.Equal(expectedReboot, result.RebootRequired);
        Assert.Equal(expectedUpToDate, result.AlreadyUpToDate);
        Assert.Equal(expectedRequiresAdmin, result.RequiresAdmin);
        Assert.Equal(expectedCancelled, result.CancelledByUser);
    }

    [Theory]
    [InlineData(unchecked((int)0x8A150003), "0x8A150003")]
    [InlineData(int.MinValue, "0x80000000")]
    [InlineData(int.MaxValue, "0x7FFFFFFF")]
    [InlineData(-1, "0xFFFFFFFF")]
    [InlineData(1, "0x00000001")]
    [InlineData(1603, "0x00000643")]
    [InlineData(1618, "0x00000652")]
    [InlineData(unchecked((int)0x80070005), "0x80070005")]
    [InlineData(unchecked((int)0x80004005), "0x80004005")]
    public void ParseExitCode_UnrecognizedAndBoundaryCodes_FormatsCorrectHexadecimal(int exitCode, string expectedHex)
    {
        var outcome = WingetCliParser.ParseExitCode(exitCode, "Upgrade", "Custom.App");

        Assert.False(outcome.Success);
        Assert.Contains(expectedHex, outcome.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("failed with exit code", outcome.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("   \r\n\t  ", false)]
    [InlineData("Corrupted download archive payload.", true)]
    [InlineData("   Hash mismatch detected.   ", true)]
    public void ParseExitCode_StderrVariations_AppendsTrimmedDetailWhenNotEmpty(string? stderr, bool shouldContainDetail)
    {
        var outcome = WingetCliParser.ParseExitCode(9999, "Install", "Custom.App", stderr);

        if (shouldContainDetail)
        {
            Assert.Contains("Detail:", outcome.Message);
            Assert.Contains(stderr!.Trim(), outcome.Message);
        }
        else
        {
            Assert.DoesNotContain("Detail:", outcome.Message);
        }
    }

    [Theory]
    [InlineData(null, null, "Package", "Operation")]
    [InlineData("", "", "Package", "Operation")]
    [InlineData("   ", "   ", "Package", "Operation")]
    [InlineData("Custom.Id", "Install", "Package 'Custom.Id'", "Install")]
    public void ParseExitCode_NullOrWhitespacePackageAndOperation_DefaultsGracefully(
        string? packageId,
        string? operation,
        string expectedTargetSubstr,
        string expectedOpSubstr)
    {
        var outcome = WingetCliParser.ParseExitCode(0, operation, packageId);

        Assert.True(outcome.Success);
        Assert.Contains(expectedTargetSubstr, outcome.Message);
        Assert.Contains(expectedOpSubstr.ToLowerInvariant(), outcome.Message);
    }

    [Fact]
    public void FactoryMethods_CreateInstallUpgradeUninstallResult_PreserveAllContractFields()
    {
        var install = WingetCliParser.CreateInstallResult("App.Id", "Display App", 0);
        Assert.Equal("App.Id", install.AppId);
        Assert.Equal("Display App", install.DisplayName);
        Assert.Equal("Winget", install.MethodUsed);
        Assert.True(install.Success);
        Assert.True(install.TempCleanedUp);

        var upgrade = WingetCliParser.CreateUpgradeResult("App.Id", "Display App", 3010);
        Assert.Equal("App.Id", upgrade.AppId);
        Assert.Equal("Display App", upgrade.DisplayName);
        Assert.Equal("Winget", upgrade.MethodUsed);
        Assert.True(upgrade.Success);
        Assert.True(upgrade.TempCleanedUp);
        Assert.Contains("Reboot required", upgrade.Message);

        var uninstall = WingetCliParser.CreateUninstallResult("App.Id", "Display App", unchecked((int)0x8A150014));
        Assert.Equal("App.Id", uninstall.AppId);
        Assert.Equal("Display App", uninstall.DisplayName);
        Assert.Equal("Winget", uninstall.MethodUsed);
        Assert.False(uninstall.Success);
        Assert.True(uninstall.TempCleanedUp);
        Assert.Contains("No package found", uninstall.Message);
    }

    [Fact]
    public void QuickCheckHelpers_CompleteTruthTableVerification()
    {
        Assert.True(WingetCliParser.IsSuccess(0));
        Assert.False(WingetCliParser.IsSuccess(3010));
        Assert.False(WingetCliParser.IsSuccess(1));

        Assert.True(WingetCliParser.IsRebootRequired(3010));
        Assert.False(WingetCliParser.IsRebootRequired(0));

        Assert.True(WingetCliParser.IsNoApplicationsFound(unchecked((int)0x8A150014)));
        Assert.False(WingetCliParser.IsNoApplicationsFound(0));

        Assert.True(WingetCliParser.IsAlreadyInstalled(unchecked((int)0x8A150061)));
        Assert.False(WingetCliParser.IsAlreadyInstalled(0));

        Assert.True(WingetCliParser.IsAlreadyUpToDate(unchecked((int)0x8A15002B)));
        Assert.False(WingetCliParser.IsAlreadyUpToDate(0));

        Assert.True(WingetCliParser.RequiresAdmin(unchecked((int)0x8A150019)));
        Assert.True(WingetCliParser.RequiresAdmin(-1978335068));
        Assert.False(WingetCliParser.RequiresAdmin(0));

        Assert.True(WingetCliParser.IsCancelled(1223));
        Assert.False(WingetCliParser.IsCancelled(0));

        string msg = WingetCliParser.GetErrorMessage(1603);
        Assert.Contains("failed with exit code 1603", msg);
    }

    // =========================================================================
    // 3. APPINSTALLERSERVICE PROCESS RESILIENCE & FAILURE MODES
    // =========================================================================

    [Fact]
    public async Task SearchPackagesAsync_QueryWithSpecialCharacters_EscapesQuotesAndExecutesSafely()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string query = "test \"package\" & more";
        string expectedArgs = "search \"test \\\"package\\\" & more\" --source winget --accept-source-agreements --disable-interactivity";
        string fullCmd = $"winget.exe {expectedArgs}";

        string output =
            "Name             Id               Version   Source\r\n" +
            "---------------- ---------------- --------- ------\r\n" +
            "TestApp          Test.App         1.0.0     winget\r\n";

        runner.SetCommandResult(fullCmd, new ProcessExecutionResult(0, output, string.Empty, false));

        var results = await service.SearchPackagesAsync(query);

        Assert.Single(results);
        Assert.Equal("TestApp", results[0].Name);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(fullCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task SearchPackagesAsync_ProcessRunnerThrowsException_LogsAndReturnsEmptyList()
    {
        var service = CreateThrowingHarness(new IOException("Disk read error during process invocation"));

        var results = await service.SearchPackagesAsync("AnyQuery");

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task SearchPackagesAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.SearchPackagesAsync("CancelledQuery", cts.Token));
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_ProcessRunnerThrowsException_LogsAndReturnsEmptyList()
    {
        var service = CreateThrowingHarness(new UnauthorizedAccessException("Access denied to winget executable"));

        var results = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.GetInstalledApplicationsAsync(cts.Token));
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_ProcessTimeout_LogsAndReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string cmd = "winget.exe list --disable-interactivity --nowarn";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1, string.Empty, "Timeout", true));

        var results = await service.GetInstalledApplicationsAsync();

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_ARPPackagesWithBackslashesAndNoSource_ParsedCorrectly()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string cmd = "winget.exe list --disable-interactivity --nowarn";

        string header = $"{"Name",-35}{"Id",-45}{"Version",-15}{"Available",-12}Source";
        string separator = $"{new string('-', 34)} {new string('-', 44)} {new string('-', 14)} {new string('-', 11)} ------";
        string dataRow = $"{"Enterprise Utility",-35}{@"ARP\Machine\X64\Enterprise Utility",-45}{"3.5.0",-15}";
        string output = $"{header}\r\n{separator}\r\n{dataRow}\r\n";

        runner.SetCommandResult(cmd, new ProcessExecutionResult(0, output, string.Empty, false));

        var apps = await service.GetInstalledApplicationsAsync();

        Assert.Single(apps);
        Assert.Equal("Enterprise Utility", apps[0].Name);
        Assert.Equal(@"ARP\Machine\X64\Enterprise Utility", apps[0].Id);
        Assert.Equal("3.5.0", apps[0].Version);
        Assert.Null(apps[0].AvailableVersion);
        Assert.Equal(string.Empty, apps[0].Source);
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_ProcessRunnerThrowsException_LogsAndReturnsEmptyList()
    {
        var service = CreateThrowingHarness(new Win32Exception(10060, "Connection timed out to package source"));

        var results = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.GetAvailableUpdatesAsync(cts.Token));
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_ProcessTimeout_LogsAndReturnsEmptyList()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string cmd = "winget.exe list --upgrade-available --disable-interactivity --nowarn";
        runner.SetCommandResult(cmd, new ProcessExecutionResult(1, string.Empty, "Timeout", true));

        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_PackageIdWithSpaces_EnclosesIdInQuotes()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string packageId = "Mozilla Firefox Developer Edition";
        string expectedCmd = "winget.exe install --id \"Mozilla Firefox Developer Edition\" --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";

        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Success", string.Empty, false));

        var result = await service.InstallWingetPackageAsync(packageId);

        Assert.True(result.Success);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_PackageIdWithoutSpaces_DoesNotEncloseInQuotes()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string packageId = "7zip.7zip";
        string expectedCmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";

        runner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Success", string.Empty, false));

        var result = await service.InstallWingetPackageAsync(packageId);

        Assert.True(result.Success);
        Assert.Contains(runner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_ProcessThrowsException_ReturnsFailureResultGracefully()
    {
        var service = CreateThrowingHarness(new InvalidOperationException("Process runner crashed during execution"));

        var result = await service.InstallWingetPackageAsync("Crashing.App");

        Assert.False(result.Success);
        Assert.Equal("Crashing.App", result.AppId);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains("Installation error:", result.Message);
        Assert.Contains("Process runner crashed", result.Message);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.InstallWingetPackageAsync("Cancelled.App", cts.Token));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_PackageAlreadyInstalledCode_ReturnsSuccessResult()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string packageId = "Existing.App";
        string cmd = $"winget.exe install --id {packageId} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";

        runner.SetCommandResult(cmd, new ProcessExecutionResult(unchecked((int)0x8A150061), string.Empty, string.Empty, false));

        var result = await service.InstallWingetPackageAsync(packageId);

        Assert.True(result.Success);
        Assert.Contains("already installed", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UpgradeWingetPackageAsync_ProcessThrowsException_ReturnsFailureResultGracefully()
    {
        var service = CreateThrowingHarness(new IOException("Process pipe failed"));

        var result = await service.UpgradeWingetPackageAsync("Throwing.App");

        Assert.False(result.Success);
        Assert.Equal("Throwing.App", result.AppId);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains("Upgrade error:", result.Message);
    }

    [Fact]
    public async Task UpgradeWingetPackageAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.UpgradeWingetPackageAsync("Cancelled.App", cts.Token));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task UpgradeWingetPackageAsync_EmptyPackageId_ReturnsFailureWithoutCallingWinget(string? packageId)
    {
        var (service, runner, _, _, _) = CreateHarness();

        var result = await service.UpgradeWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(runner.ExecutedCommands, c => c.StartsWith("winget.exe upgrade", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_ProcessThrowsException_ReturnsFailureResultGracefully()
    {
        var service = CreateThrowingHarness(new FileNotFoundException("winget.exe not found"));

        var result = await service.UninstallWingetPackageAsync("Missing.App");

        Assert.False(result.Success);
        Assert.Equal("Missing.App", result.AppId);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains("Uninstallation error:", result.Message);
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_CancellationRequested_RethrowsOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var service = CreateThrowingHarness(new OperationCanceledException(cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.UninstallWingetPackageAsync("Cancelled.App", cts.Token));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task UninstallWingetPackageAsync_EmptyPackageId_ReturnsFailureWithoutCallingWinget(string? packageId)
    {
        var (service, runner, _, _, _) = CreateHarness();

        var result = await service.UninstallWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(runner.ExecutedCommands, c => c.StartsWith("winget.exe uninstall", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_RebootRequiredCode3010_ReturnsSuccessWithRebootNotice()
    {
        var (service, runner, _, _, _) = CreateHarness();
        string packageId = "Driver.Package";
        string cmd = $"winget.exe uninstall --id {packageId} --exact --silent --disable-interactivity";

        runner.SetCommandResult(cmd, new ProcessExecutionResult(3010, string.Empty, string.Empty, false));

        var result = await service.UninstallWingetPackageAsync(packageId);

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // 4. CONCURRENCY STRESS & HIGH-LOAD RELIABILITY
    // =========================================================================

    [Fact]
    public async Task AppInstallerService_ConcurrentOperationsStress_NoRaceConditionOrDeadlock()
    {
        var (service, runner, _, _, _) = CreateHarness();

        string sampleSearch =
            "Name             Id               Version   Source\r\n" +
            "---------------- ---------------- --------- ------\r\n" +
            "7-Zip            7zip.7zip        24.09     winget\r\n";

        string sampleList =
            "Name             Id               Version   Source\r\n" +
            "---------------- ---------------- --------- ------\r\n" +
            "Git              Git.Git          2.47.0    winget\r\n";

        string sampleUpdates =
            "Name             Id               Version   Available Source\r\n" +
            "---------------- ---------------- --------- --------- ------\r\n" +
            "Git              Git.Git          2.47.0    2.48.0    winget\r\n";

        runner.SetCommandResult("winget.exe search \"app\" --source winget --accept-source-agreements --disable-interactivity", new ProcessExecutionResult(0, sampleSearch, string.Empty, false));
        runner.SetCommandResult("winget.exe list --disable-interactivity --nowarn", new ProcessExecutionResult(0, sampleList, string.Empty, false));
        runner.SetCommandResult("winget.exe list --upgrade-available --disable-interactivity --nowarn", new ProcessExecutionResult(0, sampleUpdates, string.Empty, false));
        runner.SetCommandResult("winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity", new ProcessExecutionResult(0, "Success", string.Empty, false));

        // Dispatch 50 concurrent mixed tasks
        var tasks = new List<Task>();
        for (int i = 0; i < 50; i++)
        {
            int op = i % 4;
            switch (op)
            {
                case 0:
                    tasks.Add(service.SearchPackagesAsync("app"));
                    break;
                case 1:
                    tasks.Add(service.GetInstalledApplicationsAsync());
                    break;
                case 2:
                    tasks.Add(service.GetAvailableUpdatesAsync());
                    break;
                case 3:
                    tasks.Add(service.InstallWingetPackageAsync("7zip.7zip"));
                    break;
            }
        }

        // Wait with a 10-second timeout guard to prove no deadlocks
        var completed = Task.WhenAll(tasks);
        var timeout = Task.Delay(10000);
        var finished = await Task.WhenAny(completed, timeout);

        Assert.Same(completed, finished);
        await completed; // Ensure none threw unhandled exceptions
    }

    // =========================================================================
    // 5. PURE 7-BIT ASCII AND STRING COMPLIANCE
    // =========================================================================

    [Fact]
    public void WingetParserAndModels_GeneratedMessages_AreStrictlyPureAscii()
    {
        int[] testExitCodes = new[]
        {
            0,
            3010,
            1223,
            unchecked((int)0x8A150002),
            unchecked((int)0x8A150003),
            unchecked((int)0x8A150014),
            unchecked((int)0x8A150016),
            unchecked((int)0x8A150019),
            -1978335068,
            unchecked((int)0x8A15002B),
            unchecked((int)0x8A15002C),
            unchecked((int)0x8A150041),
            unchecked((int)0x8A150046),
            unchecked((int)0x8A150061),
            1603,
            1618,
            -1,
            int.MinValue,
            int.MaxValue
        };

        foreach (int code in testExitCodes)
        {
            var outcome = WingetCliParser.ParseExitCode(code, "Install", "Ascii.Package", "Sample error detail");
            Assert.True(
                outcome.Message.All(c => c <= 127),
                $"Message for code {code} contains non-ASCII characters: '{outcome.Message}'");

            var install = WingetCliParser.CreateInstallResult("Ascii.Package", "Ascii Display", code, "Detail");
            Assert.True(
                install.Message.All(c => c <= 127),
                $"Install message for code {code} contains non-ASCII characters: '{install.Message}'");
        }
    }
}
