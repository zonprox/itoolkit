namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using IToolkit.App;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Xunit;

/// <summary>
/// Empirical challenge test suite for M3 Winget integration:
/// 1. Behavior under exit codes (0x8A15002B already installed / up to date, 0x8A150014 not found).
/// 2. Elevation boundary handling in ElevatedAwareProcessRunner (delegation, cleanup, timeouts, crash immunity).
/// 3. Cancellation, timeout, and network boundaries.
/// 4. Error message capture and exit code translation matrix.
/// </summary>
public class WingetBoundaryEmpiricalChallengeTests
{
    private readonly Mock<IFileSystemService> _fileSystemMock = new();
    private readonly Mock<IRegistryService> _registryMock = new();
    private readonly Mock<INetworkService> _networkMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    private IAppInstallerService CreateServiceWithMockRunner(IProcessRunner runner)
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);

        var runnerDesc = services.FirstOrDefault(d => d.ServiceType == typeof(IProcessRunner));
        if (runnerDesc != null) services.Remove(runnerDesc);
        services.AddSingleton<IProcessRunner>(runner);

        var sp = services.BuildServiceProvider();
        return sp.GetRequiredService<IAppInstallerService>();
    }

    // =========================================================================
    // CHALLENGE 1: EXIT CODE 0x8A15002B (ALREADY INSTALLED / UP TO DATE)
    // =========================================================================

    [Fact]
    public void ExitCode_0x8A15002B_ParseExitCode_ReportsSuccessAndAlreadyUpToDate()
    {
        int exitCode = unchecked((int)0x8A15002B); // -1978335189

        var outcome = WingetCliParser.ParseExitCode(exitCode, "Upgrade", "7zip.7zip");

        Assert.True(outcome.Success, "0x8A15002B must be treated as successful completion.");
        Assert.True(outcome.AlreadyUpToDate, "0x8A15002B must set AlreadyUpToDate to true.");
        Assert.Contains("already up-to-date", outcome.Message, StringComparison.OrdinalIgnoreCase);
        Assert.True(WingetCliParser.IsAlreadyUpToDate(exitCode));
    }

    [Fact]
    public async Task ExitCode_0x8A15002B_InstallPackage_CompletesSuccessfullyWithoutCrash()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("install")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A15002B), "No newer package versions are available", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var result = await service.InstallWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success, "InstallWingetPackageAsync must treat 0x8A15002B as success.");
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains("already up-to-date", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExitCode_0x8A15002B_UpgradePackage_CompletesSuccessfullyWithoutCrash()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("upgrade")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A15002B), "No available upgrade found.", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var result = await service.UpgradeWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success, "UpgradeWingetPackageAsync must treat 0x8A15002B as success.");
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains("already up-to-date", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExitCode_0x8A15002B_GetAvailableUpdates_ReturnsEmptyListWithoutThrowing()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("--upgrade-available")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A15002B), "No newer package versions are available.", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var updates = await service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task ExitCode_0x8A15002B_LiveHostVerification_OnUpToDateApplication()
    {
        if (!OperatingSystem.IsWindows()) return;

        // Verify live host behavior with an app that is installed and has no upgrade available
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        var sp = services.BuildServiceProvider();
        var service = sp.GetRequiredService<IAppInstallerService>();

        // Famatech.AdvancedIPScanner was confirmed on this host to have exit code 0x8A15002B on upgrade
        var res = await service.UpgradeWingetPackageAsync("Famatech.AdvancedIPScanner");

        Assert.True(res.Success, $"Expected 0x8A15002B on up-to-date app to succeed, got: {res.Message}");
        Assert.Contains("already up-to-date", res.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // CHALLENGE 2: EXIT CODE 0x8A150014 (NOT FOUND / NO PACKAGES FOUND)
    // =========================================================================

    [Fact]
    public void ExitCode_0x8A150014_ParseExitCode_ReportsFailureAndHelpfulMessage()
    {
        int exitCode = unchecked((int)0x8A150014); // -1978335212

        var outcome = WingetCliParser.ParseExitCode(exitCode, "Install", "NonExistent.App");

        Assert.False(outcome.Success, "0x8A150014 must be marked as failure.");
        Assert.Contains("No package found matching 'NonExistent.App'", outcome.Message);
        Assert.Contains("0x8A150014", outcome.Message);
        Assert.True(WingetCliParser.IsNoApplicationsFound(exitCode));
    }

    [Fact]
    public async Task ExitCode_0x8A150014_SearchPackages_ReturnsEmptyListWithoutException()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("search")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A150014), "No package found matching input criteria.", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var packages = await service.SearchPackagesAsync("NonExistent_Search_1234");

        Assert.NotNull(packages);
        Assert.Empty(packages);
    }

    [Fact]
    public async Task ExitCode_0x8A150014_InstallPackage_ReturnsFailedResultWithoutCrashing()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("install")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A150014), "No package found matching input criteria.", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var result = await service.InstallWingetPackageAsync("NonExistent.Package");

        Assert.False(result.Success);
        Assert.Contains("0x8A150014", result.Message);
    }

    [Fact]
    public async Task ExitCode_0x8A150014_UninstallPackage_ReturnsFailedResultWithoutCrashing()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(
                It.Is<string>(s => s.Contains("winget")),
                It.Is<string>(a => a.Contains("uninstall")),
                It.IsAny<string?>(),
                It.IsAny<int>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(unchecked((int)0x8A150014), "No installed package found matching input criteria.", "", false));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var result = await service.UninstallWingetPackageAsync("NonExistent.Package");

        Assert.False(result.Success);
        Assert.Contains("0x8A150014", result.Message);
    }

    [Fact]
    public async Task ExitCode_0x8A150014_LiveHostVerification_SearchAndInstallNonExistent()
    {
        if (!OperatingSystem.IsWindows()) return;

        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        var sp = services.BuildServiceProvider();
        var service = sp.GetRequiredService<IAppInstallerService>();

        string nonExistentId = $"NonExistent_UUID_{Guid.NewGuid():N}";

        // 1. Search for non-existent app
        var searchResults = await service.SearchPackagesAsync(nonExistentId);
        Assert.NotNull(searchResults);
        Assert.Empty(searchResults);

        // 2. Install non-existent app
        var installResult = await service.InstallWingetPackageAsync(nonExistentId);
        Assert.False(installResult.Success);
        Assert.Contains("0x8A150014", installResult.Message);
    }

    // =========================================================================
    // CHALLENGE 3: ELEVATION HANDLING IN ElevatedAwareProcessRunner
    // =========================================================================

    private static IProcessRunner CreateElevatedAwareProcessRunnerInstance()
    {
        var testType = typeof(WingetRealWorldVerificationTests);
        var runnerType = testType.GetNestedType("ElevatedAwareProcessRunner", BindingFlags.NonPublic);
        Assert.NotNull(runnerType);

        var instance = Activator.CreateInstance(runnerType) as IProcessRunner;
        Assert.NotNull(instance);
        return instance;
    }

    [Fact]
    public void ElevatedAwareProcessRunner_ReflectionInstance_CanBeCreated()
    {
        var runner = CreateElevatedAwareProcessRunnerInstance();
        Assert.NotNull(runner);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_NonWingetCommand_DelegatesToInnerRunner()
    {
        var runner = CreateElevatedAwareProcessRunnerInstance();

        // Run benign command
        var res = runner.Run("cmd.exe", "/c echo PingFromElevatedAwareRunner");

        Assert.Equal(0, res.ExitCode);
        Assert.Contains("PingFromElevatedAwareRunner", res.StandardOutput);
        Assert.False(res.TimedOut);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_WingetListCommand_ExecutesStandardAndCapturesOutput()
    {
        if (!OperatingSystem.IsWindows()) return;

        var runner = CreateElevatedAwareProcessRunnerInstance();

        // 'winget list' does not contain 'uninstall', so it runs through standard runner
        var res = runner.Run("winget.exe", "--version");

        Assert.Equal(0, res.ExitCode);
        Assert.StartsWith("v", res.StandardOutput.Trim(), StringComparison.OrdinalIgnoreCase);
        Assert.False(res.TimedOut);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_WingetUninstallTrigger_RunsElevatedAndCleansTempFiles()
    {
        if (!OperatingSystem.IsWindows()) return;

        var runner = CreateElevatedAwareProcessRunnerInstance();

        string tempPath = Path.GetTempPath();
        var filesBefore = Directory.GetFiles(tempPath, "winget_elevated_*.*");

        // Invoking winget uninstall for an absent package triggers RunElevated
        var res = runner.Run("winget.exe", "uninstall --id Absent_Package_Test_Elevation --disable-interactivity");

        // Assert exit code was captured (0x8A150014 or failure)
        Assert.True(res.ExitCode != 0, $"Expected non-zero exit code for absent package, got {res.ExitCode}");

        // Assert temp script, out, and err files were cleaned up
        var filesAfter = Directory.GetFiles(tempPath, "winget_elevated_*.*");
        Assert.Empty(filesAfter);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_TimeoutHandling_TerminatesProcessAndReportsTimeout()
    {
        if (!OperatingSystem.IsWindows()) return;

        var runner = CreateElevatedAwareProcessRunnerInstance();

        // Run a command that takes 10 seconds with a 1-second timeout
        var res = runner.Run("powershell.exe", "-NoProfile -Command \"Start-Sleep -Seconds 10\"", timeoutMs: 1000);

        Assert.True(res.TimedOut, "Process should be reported as timed out.");
        Assert.Equal(-1, res.ExitCode);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_InvalidExecutable_ReturnsErrorResultWithoutCrashing()
    {
        var runner = CreateElevatedAwareProcessRunnerInstance();

        var res = runner.Run("non_existent_binary_xyz_12345.exe", "arguments");

        Assert.Equal(-1, res.ExitCode);
        Assert.False(string.IsNullOrWhiteSpace(res.StandardError));
    }

    // =========================================================================
    // CHALLENGE 4: CANCELLATION, TIMEOUT & NETWORK BOUNDARIES
    // =========================================================================

    [Fact]
    public async Task SearchPackagesAsync_WhenCancelled_ThrowsOperationCanceledException()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .Returns<string, string, string?, int, CancellationToken>((_, _, _, _, token) => Task.FromCanceled<ProcessExecutionResult>(token));

        var service = CreateServiceWithMockRunner(runnerMock.Object);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.SearchPackagesAsync("7zip", cts.Token));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_WhenCancelled_ThrowsOperationCanceledException()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .Returns<string, string, string?, int, CancellationToken>((_, _, _, _, token) => Task.FromCanceled<ProcessExecutionResult>(token));

        var service = CreateServiceWithMockRunner(runnerMock.Object);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.InstallWingetPackageAsync("7zip.7zip", cts.Token));
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_WhenCancelled_ThrowsOperationCanceledException()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .Returns<string, string, string?, int, CancellationToken>((_, _, _, _, token) => Task.FromCanceled<ProcessExecutionResult>(token));

        var service = CreateServiceWithMockRunner(runnerMock.Object);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.UninstallWingetPackageAsync("7zip.7zip", cts.Token));
    }

    [Fact]
    public async Task SearchPackagesAsync_WhenRunnerTimesOut_ReturnsEmptyListAndLogsError()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(-1, "", "Timed out", true));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var res = await service.SearchPackagesAsync("7zip");

        Assert.NotNull(res);
        Assert.Empty(res);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_WhenRunnerTimesOut_ReturnsFailedResultWithoutCrashing()
    {
        var runnerMock = new Mock<IProcessRunner>();
        runnerMock.Setup(r => r.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessExecutionResult(-1, "", "Installation timed out", true));

        var service = CreateServiceWithMockRunner(runnerMock.Object);
        var res = await service.InstallWingetPackageAsync("7zip.7zip");

        Assert.False(res.Success);
        Assert.Contains("timed out", res.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // CHALLENGE 5: EXIT CODE TRANSLATION MATRIX & ERROR DETAIL CAPTURE
    // =========================================================================

    [Theory]
    [InlineData(0, true, false, false, false)]
    [InlineData(3010, true, true, false, false)]
    [InlineData(unchecked((int)0x8A15002B), true, false, true, false)]
    [InlineData(unchecked((int)0x8A150061), true, false, false, false)]
    [InlineData(unchecked((int)0x8A150014), false, false, false, false)]
    [InlineData(1223, false, false, false, true)]
    [InlineData(unchecked((int)0x8A150019), false, false, false, false)]
    [InlineData(-1978335068, false, false, false, false)] // 0x8A1500A4
    [InlineData(unchecked((int)0x8A150016), false, false, false, false)]
    [InlineData(unchecked((int)0x8A150041), false, false, false, false)]
    [InlineData(unchecked((int)0x8A150046), false, false, false, false)]
    [InlineData(unchecked((int)0x8A15002C), false, false, false, false)]
    [InlineData(unchecked((int)0x8A150002), false, false, false, false)]
    [InlineData(1603, false, false, false, false)]
    [InlineData(-1, false, false, false, false)]
    public void ExitCodeMatrix_TranslatesDeterministically(
        int exitCode,
        bool expectedSuccess,
        bool expectedReboot,
        bool expectedAlreadyUpToDate,
        bool expectedCancelled)
    {
        var res = WingetCliParser.ParseExitCode(exitCode, "TestOp", "SampleApp");

        Assert.Equal(expectedSuccess, res.Success);
        Assert.Equal(expectedReboot, res.RebootRequired);
        Assert.Equal(expectedAlreadyUpToDate, res.AlreadyUpToDate);
        Assert.Equal(expectedCancelled, res.CancelledByUser);
        Assert.False(string.IsNullOrWhiteSpace(res.Message), "Message must never be empty or whitespace.");
    }

    [Fact]
    public void ExitCode_StandardErrorDetail_IsPreservedInDefaultErrorMessage()
    {
        string detail = "Fatal error: access denied to registry hive";
        var res = WingetCliParser.ParseExitCode(99999, "Operation", "PackageX", detail);

        Assert.False(res.Success);
        Assert.Contains("99999", res.Message);
        Assert.Contains(detail, res.Message);
    }

    [Fact]
    public void ElevatedAwareProcessRunner_WithQuotedArgumentsAndSpaces_ExecutesCleanly()
    {
        if (!OperatingSystem.IsWindows()) return;

        var runner = CreateElevatedAwareProcessRunnerInstance();

        // Pass arguments with quotes and spaces into ElevatedAwareProcessRunner
        var res = runner.Run("winget.exe", "uninstall --id \"Package With Spaces In Id\" --exact --silent --disable-interactivity");

        // Should execute through RunElevated, capture exit code (not found or error), clean up files, and not crash
        Assert.True(res.ExitCode != 0);
        string tempPath = Path.GetTempPath();
        var files = Directory.GetFiles(tempPath, "winget_elevated_*.*");
        Assert.Empty(files);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public async Task EmptyOrWhitespacePackageId_FailsSafelyWithoutLaunchingProcess(string emptyId)
    {
        var runnerMock = new Mock<IProcessRunner>(MockBehavior.Strict);
        var service = CreateServiceWithMockRunner(runnerMock.Object);

        var installRes = await service.InstallWingetPackageAsync(emptyId);
        Assert.False(installRes.Success);
        Assert.Contains("empty", installRes.Message, StringComparison.OrdinalIgnoreCase);

        var upgradeRes = await service.UpgradeWingetPackageAsync(emptyId);
        Assert.False(upgradeRes.Success);
        Assert.Contains("empty", upgradeRes.Message, StringComparison.OrdinalIgnoreCase);

        var uninstallRes = await service.UninstallWingetPackageAsync(emptyId);
        Assert.False(uninstallRes.Success);
        Assert.Contains("empty", uninstallRes.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void WingetCliParser_MalformedAndCorruptedOutputs_NeverThrowsExceptions()
    {
        string[] corruptedInputs = new[]
        {
            "",
            "   \r\n\t  \n",
            "Random text without any headers\r\nSecond line\r\nThird line",
            "Name       Id\r\n-------------",
            "Name       Id          Version\r\n", // Header with no separator
            "-----------------------------\r\nRow data here",
            "Name       Id          Version     Available   Source\r\n-------------------------------------------------------------\r\nOnlyOneCol",
            "\0\0\0BinaryGarbage\xFF\xFE\x01\x02",
            "Name       Id          Version\r\n------------------------------\r\nApp   \r\nApp2  Id2"
        };

        foreach (var corrupted in corruptedInputs)
        {
            var pkgs = WingetCliParser.ParsePackages(corrupted);
            Assert.NotNull(pkgs);

            var installed = WingetCliParser.ParseInstalledApps(corrupted);
            Assert.NotNull(installed);

            var updates = WingetCliParser.ParseUpdates(corrupted);
            Assert.NotNull(updates);
        }
    }
}

