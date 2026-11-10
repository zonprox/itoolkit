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
using Xunit;

/// <summary>
/// Empirical Challenger 2: Service Orchestration & Fault Injection Test Suite for AppInstallerService.
/// Validates process timeouts, process exceptions, cancellation tokens, exit codes (3010, 0x8A15002B,
/// 1223, 0x8A150019), defensive input guards, argument formatting, and legacy 8-app catalog isolation.
/// </summary>
public class WingetAppInstallerFaultInjectionEmpiricalTests
{
    private class FaultInjectingProcessRunner : IProcessRunner
    {
        private readonly MockProcessRunner _inner = new();

        private readonly Lock _sync = new();
        private readonly List<string> _executedCommands = new();

        public Func<string, string, Exception?>? ExceptionFactory { get; set; }
        public Func<string, string, ProcessExecutionResult?>? ResultFactory { get; set; }
        public bool CheckCancellation { get; set; } = true;
        public Action<string, string>? OnExecute { get; set; }

        public List<string> ExecutedCommands
        {
            get
            {
                lock (_sync)
                {
                    return new List<string>(_executedCommands);
                }
            }
        }

        public void SetCommandResult(string commandLine, ProcessExecutionResult result) =>
            _inner.SetCommandResult(commandLine, result);

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            string cmd = $"{fileName} {arguments}".Trim();
            lock (_sync)
            {
                _executedCommands.Add(cmd);
            }

            OnExecute?.Invoke(fileName, arguments);

            if (ExceptionFactory != null)
            {
                var ex = ExceptionFactory(fileName, arguments);
                if (ex != null) throw ex;
            }

            if (ResultFactory != null)
            {
                var customRes = ResultFactory(fileName, arguments);
                if (customRes != null)
                {
                    return customRes;
                }
            }

            return _inner.Run(fileName, arguments, workingDirectory, timeoutMs);
        }

        public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default)
        {
            if (CheckCancellation)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            return Task.FromResult(Run(fileName, arguments, workingDirectory, timeoutMs));
        }

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName) => _inner.GetProcessesByName(processName);
        public bool CloseMainWindow(int processId) => _inner.CloseMainWindow(processId);
        public bool WaitForExit(int processId, TimeSpan timeout) => _inner.WaitForExit(processId, timeout);
        public bool KillProcess(int processId, bool entireProcessTree = true) => _inner.KillProcess(processId, entireProcessTree);
        public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true) => _inner.StopProcess(processName, timeoutSeconds, force);
        public bool IsProcessRunning(string processName) => _inner.IsProcessRunning(processName);
        public bool StartProcess(string fileName, string? arguments = null) => _inner.StartProcess(fileName, arguments);
    }

    private readonly FaultInjectingProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly ProcessLockGuard _lockGuard;
    private readonly AppInstallerService _service;

    public WingetAppInstallerFaultInjectionEmpiricalTests()
    {
        _processRunner = new FaultInjectingProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _service = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, _network);
    }

    // =========================================================================
    // Category 1: Process Timeouts (TimedOut = true)
    // =========================================================================

    [Theory]
    [InlineData("Search")]
    [InlineData("List")]
    [InlineData("Updates")]
    public async Task QueryMethods_WhenProcessTimesOut_ReturnEmptyCollectionsWithoutThrowing(string method)
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(1, string.Empty, "Process timed out after 60000ms", true);

        switch (method)
        {
            case "Search":
                var searchResults = await _service.SearchPackagesAsync("7zip");
                Assert.NotNull(searchResults);
                Assert.Empty(searchResults);
                break;

            case "List":
                var installedResults = await _service.GetInstalledApplicationsAsync();
                Assert.NotNull(installedResults);
                Assert.Empty(installedResults);
                break;

            case "Updates":
                var updateResults = await _service.GetAvailableUpdatesAsync();
                Assert.NotNull(updateResults);
                Assert.Empty(updateResults);
                break;

            default:
                throw new ArgumentOutOfRangeException(nameof(method));
        }
    }

    [Theory]
    [InlineData("Install")]
    [InlineData("Upgrade")]
    [InlineData("Uninstall")]
    public async Task MutatingMethods_WhenProcessTimesOut_ReturnFailureResultWithTimeoutMessage(string action)
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(1, string.Empty, "Process timed out after 600000ms", true);

        AppInstallResult result = action switch
        {
            "Install" => await _service.InstallWingetPackageAsync("7zip.7zip"),
            "Upgrade" => await _service.UpgradeWingetPackageAsync("7zip.7zip"),
            "Uninstall" => await _service.UninstallWingetPackageAsync("7zip.7zip"),
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        Assert.NotNull(result);
        Assert.False(result.Success, $"Expected failure on timeout for action {action}");
        Assert.Contains("timed out", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("7zip.7zip", result.AppId);
    }

    // =========================================================================
    // Category 2: Process Exceptions / Runner Crashes
    // =========================================================================

    [Theory]
    [InlineData("Search")]
    [InlineData("List")]
    [InlineData("Updates")]
    public async Task QueryMethods_WhenRunnerThrowsWin32Exception_CatchAndReturnEmptyCollections(string method)
    {
        _processRunner.ExceptionFactory = (fn, args) =>
            new Win32Exception(5, "Access is denied (simulated Win32 crash)");

        switch (method)
        {
            case "Search":
                var searchResults = await _service.SearchPackagesAsync("git");
                Assert.NotNull(searchResults);
                Assert.Empty(searchResults);
                break;

            case "List":
                var installedResults = await _service.GetInstalledApplicationsAsync();
                Assert.NotNull(installedResults);
                Assert.Empty(installedResults);
                break;

            case "Updates":
                var updateResults = await _service.GetAvailableUpdatesAsync();
                Assert.NotNull(updateResults);
                Assert.Empty(updateResults);
                break;
        }
    }

    [Theory]
    [InlineData("Install")]
    [InlineData("Upgrade")]
    [InlineData("Uninstall")]
    public async Task MutatingMethods_WhenRunnerThrowsInvalidOperationException_CatchAndReturnFailureResult(string action)
    {
        _processRunner.ExceptionFactory = (fn, args) =>
            new InvalidOperationException("Fatal process start failure: winget binary damaged");

        AppInstallResult result = action switch
        {
            "Install" => await _service.InstallWingetPackageAsync("7zip.7zip"),
            "Upgrade" => await _service.UpgradeWingetPackageAsync("7zip.7zip"),
            "Uninstall" => await _service.UninstallWingetPackageAsync("7zip.7zip"),
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        Assert.NotNull(result);
        Assert.False(result.Success);
        Assert.Contains("winget binary damaged", result.Message);
        Assert.Equal("7zip.7zip", result.AppId);
    }

    // =========================================================================
    // Category 3: Cancellations (OperationCanceledException)
    // =========================================================================

    [Fact]
    public async Task AllAsyncMethods_WhenCancellationTokenPreCancelled_ThrowOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var token = cts.Token;

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.SearchPackagesAsync("7zip", token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.GetInstalledApplicationsAsync(token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.GetAvailableUpdatesAsync(token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.InstallWingetPackageAsync("7zip.7zip", token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.UpgradeWingetPackageAsync("7zip.7zip", token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => _service.UninstallWingetPackageAsync("7zip.7zip", token));
    }

    [Fact]
    public async Task MutatingMethods_WhenCancelledMidExecution_RethrowOperationCanceledException()
    {
        using var cts = new CancellationTokenSource();

        _processRunner.OnExecute = (fn, args) =>
        {
            cts.Cancel();
            cts.Token.ThrowIfCancellationRequested();
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            _service.InstallWingetPackageAsync("7zip.7zip", cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            _service.UpgradeWingetPackageAsync("7zip.7zip", cts.Token));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            _service.UninstallWingetPackageAsync("7zip.7zip", cts.Token));
    }

    // =========================================================================
    // Category 4: Exit Code 3010 (Reboot Required)
    // =========================================================================

    [Theory]
    [InlineData("Install")]
    [InlineData("Upgrade")]
    [InlineData("Uninstall")]
    public async Task MutatingMethods_ExitCode3010_TreatedAsSuccessWithRebootNotice(string action)
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(3010, "Operation complete. Restart required.", string.Empty, false);

        AppInstallResult result = action switch
        {
            "Install" => await _service.InstallWingetPackageAsync("Microsoft.VCRedist.2015+.x64"),
            "Upgrade" => await _service.UpgradeWingetPackageAsync("Microsoft.VCRedist.2015+.x64"),
            "Uninstall" => await _service.UninstallWingetPackageAsync("Microsoft.VCRedist.2015+.x64"),
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        Assert.True(result.Success, $"Exit code 3010 must be considered successful completion for {action}");
        Assert.Contains("Reboot required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // Category 5: Exit Code 0x8A15002B & 0x8A150061 (Already Up To Date / Installed)
    // =========================================================================

    [Fact]
    public async Task UpgradeWingetPackageAsync_ExitCode0x8A15002B_ReturnsSuccessAlreadyUpToDate()
    {
        const int exitCodeUpdateNotApplicable = unchecked((int)0x8A15002B); // -1978335189

        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(exitCodeUpdateNotApplicable, "No available upgrade found.", string.Empty, false);

        var result = await _service.UpgradeWingetPackageAsync("Notepad++.Notepad++");

        Assert.True(result.Success);
        Assert.Contains("already up-to-date", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_ExitCode0x8A150061_ReturnsSuccessAlreadyInstalled()
    {
        const int exitCodeAlreadyInstalled = unchecked((int)0x8A150061); // -1978335135

        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(exitCodeAlreadyInstalled, "Package already installed.", string.Empty, false);

        var result = await _service.InstallWingetPackageAsync("Git.Git");

        Assert.True(result.Success);
        Assert.Contains("already installed", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // Category 6: Exit Code 1223 (User Cancelled Elevation / UAC)
    // =========================================================================

    [Theory]
    [InlineData("Install")]
    [InlineData("Upgrade")]
    [InlineData("Uninstall")]
    public async Task MutatingMethods_ExitCode1223_ReturnsFailureWithCancelledByUserNotice(string action)
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(1223, string.Empty, "The operation was canceled by the user.", false);

        AppInstallResult result = action switch
        {
            "Install" => await _service.InstallWingetPackageAsync("7zip.7zip"),
            "Upgrade" => await _service.UpgradeWingetPackageAsync("7zip.7zip"),
            "Uninstall" => await _service.UninstallWingetPackageAsync("7zip.7zip"),
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        Assert.False(result.Success);
        Assert.Contains("cancelled by the user", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // Category 7: Exit Code 0x8A150019 & Alt (-1978335068) (Admin Required)
    // =========================================================================

    [Theory]
    [InlineData(unchecked((int)0x8A150019), "Install")]
    [InlineData(-1978335068, "Install")]
    [InlineData(unchecked((int)0x8A150019), "Upgrade")]
    [InlineData(-1978335068, "Upgrade")]
    [InlineData(unchecked((int)0x8A150019), "Uninstall")]
    [InlineData(-1978335068, "Uninstall")]
    public async Task MutatingMethods_AdminRequiredExitCodes_ReturnFailureWithAdminNotice(int exitCode, string action)
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(exitCode, string.Empty, "Administrator rights required.", false);

        AppInstallResult result = action switch
        {
            "Install" => await _service.InstallWingetPackageAsync("WiresharkFoundation.Wireshark"),
            "Upgrade" => await _service.UpgradeWingetPackageAsync("WiresharkFoundation.Wireshark"),
            "Uninstall" => await _service.UninstallWingetPackageAsync("WiresharkFoundation.Wireshark"),
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        Assert.False(result.Success);
        Assert.Contains("administrator", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    // =========================================================================
    // Category 8: Non-Zero Exit with Stderr vs Empty Stderr
    // =========================================================================

    [Fact]
    public async Task MutatingMethods_NonZeroExitWithDetailedStderr_EmbedsStderrDetail()
    {
        string detail = "Fatal: SHA256 checksum mismatch for downloaded payload.";
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(2, string.Empty, detail, false);

        var result = await _service.InstallWingetPackageAsync("Test.App");

        Assert.False(result.Success);
        Assert.Contains(detail, result.Message);
        Assert.Contains("0x00000002", result.Message);
    }

    [Fact]
    public async Task MutatingMethods_NonZeroExitWithEmptyStderr_FormatsHexCodeCleanlyWithoutTrailingNoise()
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(1603, string.Empty, "   \r\n   ", false);

        var result = await _service.InstallWingetPackageAsync("Test.App");

        Assert.False(result.Success);
        Assert.Contains("1603", result.Message);
        Assert.Contains("0x00000643", result.Message);
        Assert.DoesNotContain("Detail:", result.Message);
    }

    // =========================================================================
    // Category 9: Defensive Guards on Null, Empty, Whitespace Inputs
    // =========================================================================

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("    ")]
    public async Task DefensiveGuards_NullOrWhitespaceInputs_DoNotInvokeProcessRunner(string? badInput)
    {
        var searchRes = await _service.SearchPackagesAsync(badInput!);
        Assert.Empty(searchRes);

        var installRes = await _service.InstallWingetPackageAsync(badInput!);
        Assert.False(installRes.Success);
        Assert.Contains("empty", installRes.Message, StringComparison.OrdinalIgnoreCase);

        var upgradeRes = await _service.UpgradeWingetPackageAsync(badInput!);
        Assert.False(upgradeRes.Success);
        Assert.Contains("empty", upgradeRes.Message, StringComparison.OrdinalIgnoreCase);

        var uninstallRes = await _service.UninstallWingetPackageAsync(badInput!);
        Assert.False(uninstallRes.Success);
        Assert.Contains("empty", uninstallRes.Message, StringComparison.OrdinalIgnoreCase);

        Assert.Empty(_processRunner.ExecutedCommands);
    }

    // =========================================================================
    // Category 10: Argument Quoting & Query Sanitization
    // =========================================================================

    [Fact]
    public async Task MutatingMethods_PackageIdWithSpaces_EnclosesIdInQuotes()
    {
        string spacedId = "Google Chrome Dev";

        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(0, "Success", string.Empty, false);

        await _service.InstallWingetPackageAsync(spacedId);
        await _service.UpgradeWingetPackageAsync(spacedId);
        await _service.UninstallWingetPackageAsync(spacedId);

        Assert.Equal(3, _processRunner.ExecutedCommands.Count);
        Assert.All(_processRunner.ExecutedCommands, cmd =>
            Assert.Contains("--id \"Google Chrome Dev\"", cmd));
    }

    [Fact]
    public async Task MutatingMethods_PackageIdWithoutSpaces_DoesNotAddUnnecessaryQuotes()
    {
        string unspacedId = "7zip.7zip";

        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(0, "Success", string.Empty, false);

        await _service.InstallWingetPackageAsync(unspacedId);

        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Contains("--id 7zip.7zip", _processRunner.ExecutedCommands[0]);
        Assert.DoesNotContain("--id \"7zip.7zip\"", _processRunner.ExecutedCommands[0]);
    }

    [Fact]
    public async Task SearchPackagesAsync_QueryWithEmbeddedDoubleQuotes_EscapesQuotesCleanly()
    {
        _processRunner.ResultFactory = (fn, args) =>
            new ProcessExecutionResult(0, "Name Id Version\r\n---- -- -------\r\n", string.Empty, false);

        await _service.SearchPackagesAsync("visual \"studio\" code");

        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Contains("search \"visual \\\"studio\\\" code\"", _processRunner.ExecutedCommands[0]);
    }

    // =========================================================================
    // Category 11: Legacy 8-App Catalog Isolation & Concurrency Integrity
    // =========================================================================

    [Fact]
    public void LegacyCatalog_All8AppsPresentAndCorrectlyConfigured()
    {
        var catalog = _service.GetCatalog();
        Assert.Equal(8, catalog.Count);

        var expectedIds = new[]
        {
            "VCRedistAIO", "UniKey", "UltraVNC", "KLiteCodec",
            "Chrome", "FoxitReader", "Zalo", "WinRAR"
        };

        foreach (var id in expectedIds)
        {
            var app = _service.GetApp(id);
            Assert.NotNull(app);
            Assert.Equal(id, app.AppId, ignoreCase: true);
        }
    }

    [Fact]
    public async Task ConcurrentOperations_LegacyAndAsyncMethods_ExecuteDeterministicallyWithoutRaceConditions()
    {
        _processRunner.ResultFactory = (fn, args) =>
        {
            if (args.Contains("search", StringComparison.OrdinalIgnoreCase))
            {
                return new ProcessExecutionResult(0, "Name Id Version\r\n---- -- -------\r\n7-Zip 7zip 24.09\r\n", string.Empty, false);
            }
            if (args.Contains("list", StringComparison.OrdinalIgnoreCase))
            {
                return new ProcessExecutionResult(0, "Name Id Version\r\n---- -- -------\r\nGit Git.Git 2.40\r\n", string.Empty, false);
            }
            return new ProcessExecutionResult(0, "Success", string.Empty, false);
        };

        var tasks = new List<Task>();

        for (int i = 0; i < 10; i++)
        {
            tasks.Add(Task.Run(async () =>
            {
                var search = await _service.SearchPackagesAsync("7zip");
                Assert.Single(search);
            }));

            tasks.Add(Task.Run(async () =>
            {
                var list = await _service.GetInstalledApplicationsAsync();
                Assert.Single(list);
            }));

            tasks.Add(Task.Run(async () =>
            {
                var res = await _service.InstallWingetPackageAsync("7zip.7zip");
                Assert.True(res.Success);
            }));

            tasks.Add(Task.Run(() =>
            {
                var cat = _service.GetCatalog();
                Assert.Equal(8, cat.Count);
            }));
        }

        await Task.WhenAll(tasks);
        Assert.True(_processRunner.ExecutedCommands.Count >= 30);
    }
}
