namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using IToolkit.App;
using IToolkit.App.Native;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Xunit;

/// <summary>
/// Real-world host Windows Package Manager (winget.exe) integration and state restoration test suite.
/// Executes full lifecycle verification on an active Windows host environment:
/// PreTest -> Search -> Install -> Verify Inventory -> Check Updates -> Uninstall -> Verify Cleanup.
/// Implements IAsyncLifetime to guarantee fail-safe 3-tier restoration to pre-test state even on failure or timeout.
/// </summary>
[Collection("RealWorldHostWingetIntegration")]
public sealed class WingetRealWorldVerificationTests : IAsyncLifetime
{
    private const string TargetPackageId = "7zip.7zip";
    private static readonly string TargetInstallDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "7-Zip");
    private static readonly string TargetInstallDirX86 = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "7-Zip");

    private readonly string _testLogDir;
    private readonly ServiceProvider _serviceProvider;
    private readonly IAppInstallerService _installerService;
    private readonly IProcessRunner _processRunner;
    private readonly IActivityLogger _logger;

    private bool _testAppInstalled;

    public WingetRealWorldVerificationTests()
    {
        string runId = $"{DateTime.UtcNow:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}";
        _testLogDir = Path.Combine(Path.GetTempPath(), $"iToolKit_WingetLiveTest_{runId}");
        Directory.CreateDirectory(_testLogDir);

        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);

        _logger = new ActivityLogger(_testLogDir);

        // Replace logger with isolated test directory instance
        var loggerDescriptor = services.FirstOrDefault(d => d.ServiceType == typeof(IActivityLogger));
        if (loggerDescriptor != null)
        {
            services.Remove(loggerDescriptor);
        }
        services.AddSingleton<IActivityLogger>(_logger);

        // Replace process runner with elevation-aware runner for unattended MSI cleanup support
        var runnerDescriptor = services.FirstOrDefault(d => d.ServiceType == typeof(IProcessRunner));
        if (runnerDescriptor != null)
        {
            services.Remove(runnerDescriptor);
        }
        services.AddSingleton<IProcessRunner, ElevatedAwareProcessRunner>();

        _serviceProvider = services.BuildServiceProvider();
        _installerService = _serviceProvider.GetRequiredService<IAppInstallerService>();
        _processRunner = _serviceProvider.GetRequiredService<IProcessRunner>();
    }

    /// <summary>
    /// Tier 3 Self-Healing Setup: Verifies baseline and uninstalls test package if left by an aborted prior run.
    /// </summary>
    public async Task InitializeAsync()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetAvailable())
        {
            return;
        }

        await SilentlyCleanLeftoverAsync();
    }

    /// <summary>
    /// Tier 2 Fixture Teardown: Guaranteed cleanup invoked by xUnit even if test method throws or times out.
    /// </summary>
    public async Task DisposeAsync()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetAvailable())
        {
            return;
        }

        if (_testAppInstalled)
        {
            try
            {
                _logger.LogWarning(nameof(WingetRealWorldVerificationTests),
                    $"Fail-safe backstop in DisposeAsync: uninstallation needed for '{TargetPackageId}'.");

                using var cleanupCts = new CancellationTokenSource(TimeSpan.FromMinutes(2));
                var res = await _installerService.UninstallWingetPackageAsync(TargetPackageId, cleanupCts.Token);
                _logger.LogInfo(nameof(WingetRealWorldVerificationTests),
                    $"DisposeAsync uninstallation outcome: Success={res.Success}, Message={res.Message}");
            }
            catch (Exception ex)
            {
                _logger.LogError(nameof(WingetRealWorldVerificationTests), "Error during DisposeAsync fail-safe uninstall", ex);
            }
            finally
            {
                _testAppInstalled = false;
            }
        }

        // Contain and stop any orphan processes started by the application
        try
        {
            _processRunner.StopProcess("7zFM", timeoutSeconds: 3, force: true);
            _processRunner.StopProcess("7z", timeoutSeconds: 3, force: true);
        }
        catch { }

        CleanResidualDirectory(TargetInstallDir);
        CleanResidualDirectory(TargetInstallDirX86);
        PurgeTempCaches();

        try
        {
            if (Directory.Exists(_testLogDir))
            {
                Directory.Delete(_testLogDir, recursive: true);
            }
        }
        catch { }

        await _serviceProvider.DisposeAsync();
    }

    [Fact(Timeout = 300000, DisplayName = "Real-World Host Winget Verification: Search -> Install -> Verify -> Update Check -> Uninstall -> State Cleanup")]
    public async Task RealWorld_Winget_FullLifecycle_SearchInstallVerifyUpdateUninstallCleanup_Succeeds()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetAvailable())
        {
            // Gracefully pass on non-Windows environments
            return;
        }

        using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        var ct = cts.Token;

        // Step 0: Pre-test baseline verification
        await PreTest_VerifyPackageNotInstalled(ct);

        try
        {
            // Step 1: Package discovery via live search
            await Step1_SearchPackages_FindsCandidateApp(ct);

            // Step 2: Unattended silent installation
            await Step2_InstallPackage_SucceedsSilently(ct);

            // Step 3: Verify package presence in inventory and on disk
            await Step3_VerifyInstalled_PresentInInventoryWithValidVersion(ct);

            // Step 4: Check for updates without error
            await Step4_CheckUpdates_ExecutesDetectionWithoutError(ct);

            // Step 5: Unattended silent uninstallation
            await Step5_UninstallPackage_SucceedsSilently(ct);

            // Step 6: Verify complete removal and restoration of pre-test state
            await Step6_VerifyCleanup_AbsentFromInventoryAndPreTestStateRestored(ct);
        }
        catch
        {
            // Tier 1 In-Method Cleanup: Attempt immediate uninstallation on failure
            if (_testAppInstalled)
            {
                try
                {
                    using var failureCleanupCts = new CancellationTokenSource(TimeSpan.FromMinutes(2));
                    await _installerService.UninstallWingetPackageAsync(TargetPackageId, failureCleanupCts.Token);
                    CleanResidualDirectory(TargetInstallDir);
                    CleanResidualDirectory(TargetInstallDirX86);
                    PurgeTempCaches();
                    _testAppInstalled = false;
                }
                catch { }
            }
            throw;
        }
    }

    internal async Task PreTest_VerifyPackageNotInstalled(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 0: PreTest_VerifyPackageNotInstalled...");

        // 1. Assert absent from GetInstalledApplicationsAsync
        var installed = await _installerService.GetInstalledApplicationsAsync(ct);
        Assert.DoesNotContain(installed, a => a.Id.Equals(TargetPackageId, StringComparison.OrdinalIgnoreCase));

        // 2. Assert winget list --id 7zip.7zip returns exit code 0x8A150014 or 1
        var listRes = await _processRunner.RunAsync("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn", cancellationToken: ct);
        Assert.True(WingetCliParser.IsNoApplicationsFound(listRes.ExitCode) || listRes.ExitCode == 1,
            $"Expected winget list exit code 0x8A150014 or 1 for absent package, got {listRes.ExitCode}");
        Assert.Contains("No installed package found", listRes.StandardOutput, StringComparison.OrdinalIgnoreCase);

        // 3. Assert filesystem binary absence
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7z.exe")), "7-Zip binary must not exist before test execution.");
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7zFM.exe")), "7-Zip file manager must not exist before test execution.");
    }

    internal async Task Step1_SearchPackages_FindsCandidateApp(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 1: Step1_SearchPackages_FindsCandidateApp...");

        var packages = await _installerService.SearchPackagesAsync("7zip", ct);
        Assert.NotEmpty(packages);

        var candidate = packages.FirstOrDefault(p => p.Id.Equals(TargetPackageId, StringComparison.OrdinalIgnoreCase));
        Assert.NotNull(candidate);
        Assert.Contains("7-Zip", candidate.Name, StringComparison.OrdinalIgnoreCase);
        Assert.False(string.IsNullOrWhiteSpace(candidate.Version), "Package version must be present in search result.");
        Assert.Equal("winget", candidate.Source, ignoreCase: true);
    }

    internal async Task Step2_InstallPackage_SucceedsSilently(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 2: Step2_InstallPackage_SucceedsSilently...");

        // Arm cleanup flag before attempting install so teardown runs if installation aborts midway
        _testAppInstalled = true;

        var installResult = await _installerService.InstallWingetPackageAsync(TargetPackageId, ct);
        Assert.True(installResult.Success, $"Winget installation failed: {installResult.Message}");
        Assert.Equal(TargetPackageId, installResult.AppId);
        Assert.Equal("Winget", installResult.MethodUsed);
    }

    internal async Task Step3_VerifyInstalled_PresentInInventoryWithValidVersion(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 3: Step3_VerifyInstalled_PresentInInventoryWithValidVersion...");

        var installed = await _installerService.GetInstalledApplicationsAsync(ct);
        var pkg = installed.FirstOrDefault(a => a.Id.Equals(TargetPackageId, StringComparison.OrdinalIgnoreCase));

        Assert.NotNull(pkg);
        Assert.Contains("7-Zip", pkg.Name, StringComparison.OrdinalIgnoreCase);
        Assert.False(string.IsNullOrWhiteSpace(pkg.Version), "Installed package must have a valid non-empty version.");
        Assert.Equal("winget", pkg.Source, ignoreCase: true);

        // Real filesystem validation
        bool binaryExists = File.Exists(Path.Combine(TargetInstallDir, "7z.exe")) ||
                            File.Exists(Path.Combine(TargetInstallDirX86, "7z.exe"));
        Assert.True(binaryExists, $"Expected 7-Zip executable at '{TargetInstallDir}\\7z.exe'.");

        string exePath = File.Exists(Path.Combine(TargetInstallDir, "7z.exe"))
            ? Path.Combine(TargetInstallDir, "7z.exe")
            : Path.Combine(TargetInstallDirX86, "7z.exe");
        var fileInfo = new FileInfo(exePath);
        Assert.True(fileInfo.Length > 100_000, $"Expected executable size > 100KB, got {fileInfo.Length} bytes.");
    }

    internal async Task Step4_CheckUpdates_ExecutesDetectionWithoutError(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 4: Step4_CheckUpdates_ExecutesDetectionWithoutError...");

        var updates = await _installerService.GetAvailableUpdatesAsync(ct);
        Assert.NotNull(updates);
    }

    internal async Task Step5_UninstallPackage_SucceedsSilently(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 5: Step5_UninstallPackage_SucceedsSilently...");

        var uninstallResult = await _installerService.UninstallWingetPackageAsync(TargetPackageId, ct);
        Assert.True(uninstallResult.Success, $"Winget uninstallation failed: {uninstallResult.Message}");
        Assert.Equal(TargetPackageId, uninstallResult.AppId);
        Assert.Equal("Winget", uninstallResult.MethodUsed);
    }

    internal async Task Step6_VerifyCleanup_AbsentFromInventoryAndPreTestStateRestored(CancellationToken ct = default)
    {
        _logger.LogInfo(nameof(WingetRealWorldVerificationTests), "Executing Step 6: Step6_VerifyCleanup_AbsentFromInventoryAndPreTestStateRestored...");

        // 1. Assert absent from GetInstalledApplicationsAsync
        var postUninstallApps = await _installerService.GetInstalledApplicationsAsync(ct);
        Assert.DoesNotContain(postUninstallApps, a => a.Id.Equals(TargetPackageId, StringComparison.OrdinalIgnoreCase));

        // 2. Assert CLI exit code 0x8A150014 or 1
        var verifyRes = await _processRunner.RunAsync("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn", cancellationToken: ct);
        Assert.True(WingetCliParser.IsNoApplicationsFound(verifyRes.ExitCode) || verifyRes.ExitCode == 1,
            $"Expected winget list exit code 0x8A150014 or 1 after uninstallation, got {verifyRes.ExitCode}");
        Assert.Contains("No installed package found", verifyRes.StandardOutput, StringComparison.OrdinalIgnoreCase);

        // 3. Assert filesystem binary absence
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7z.exe")), "7-Zip binary must not exist after uninstallation.");
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7zFM.exe")), "7-Zip file manager must not exist after uninstallation.");

        // 4. Delete residual empty folder and purge temporary caches
        CleanResidualDirectory(TargetInstallDir);
        CleanResidualDirectory(TargetInstallDirX86);
        PurgeTempCaches();

        // 5. Disarm cleanup flag because full lifecycle cleanup was completed
        _testAppInstalled = false;
    }

    private bool IsWingetAvailable()
    {
        try
        {
            var res = _processRunner.Run("winget.exe", "--version", timeoutMs: 5000);
            return res.ExitCode == 0 && !res.TimedOut;
        }
        catch
        {
            return false;
        }
    }

    private async Task SilentlyCleanLeftoverAsync()
    {
        try
        {
            var installed = await _installerService.GetInstalledApplicationsAsync();
            if (installed.Any(a => a.Id.Equals(TargetPackageId, StringComparison.OrdinalIgnoreCase)))
            {
                _logger.LogWarning(nameof(WingetRealWorldVerificationTests),
                    $"Self-healing: Detected lingering '{TargetPackageId}' from prior aborted run. Performing silent cleanup...");

                using var cleanupCts = new CancellationTokenSource(TimeSpan.FromMinutes(2));
                await _installerService.UninstallWingetPackageAsync(TargetPackageId, cleanupCts.Token);
            }
        }
        catch { }

        try
        {
            _processRunner.StopProcess("7zFM", timeoutSeconds: 3, force: true);
            _processRunner.StopProcess("7z", timeoutSeconds: 3, force: true);
        }
        catch { }

        CleanResidualDirectory(TargetInstallDir);
        CleanResidualDirectory(TargetInstallDirX86);
        PurgeTempCaches();
    }

    private static void CleanResidualDirectory(string dirPath)
    {
        try
        {
            if (Directory.Exists(dirPath))
            {
                var exes = Directory.GetFiles(dirPath, "*.exe", SearchOption.AllDirectories);
                if (exes.Length == 0)
                {
                    Directory.Delete(dirPath, recursive: true);
                }
            }
        }
        catch { }
    }

    private static void PurgeTempCaches()
    {
        try
        {
            string wingetTemp = Path.Combine(Path.GetTempPath(), "WinGet");
            if (Directory.Exists(wingetTemp))
            {
                foreach (var dir in Directory.GetDirectories(wingetTemp, "7zip.7zip*"))
                {
                    try { Directory.Delete(dir, recursive: true); } catch { }
                }
            }
        }
        catch { }
    }

    /// <summary>
    /// Process runner decorator that supports seamless silent execution for operations
    /// that require administrator elevation (such as MSI quiet uninstallation) when run from a filtered user token.
    /// </summary>
    private sealed class ElevatedAwareProcessRunner : IProcessRunner
    {
        private readonly WindowsProcessRunner _inner = new();

        private static bool IsCurrentProcessElevated()
        {
            if (!OperatingSystem.IsWindows()) return false;
            try
            {
                using var identity = WindowsIdentity.GetCurrent();
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch
            {
                return false;
            }
        }

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            bool isWinget = fileName.Contains("winget", StringComparison.OrdinalIgnoreCase);
            bool isUninstall = arguments.Contains("uninstall", StringComparison.OrdinalIgnoreCase);

            // If running un-elevated on Windows, silent MSI uninstallation requires elevation
            if (OperatingSystem.IsWindows() && !IsCurrentProcessElevated() && isWinget && isUninstall)
            {
                return RunElevated(fileName, arguments, workingDirectory, timeoutMs);
            }

            var result = _inner.Run(fileName, arguments, workingDirectory, timeoutMs);

            // If execution failed due to elevation requirement (exit code 740, 1603, or -1978335184 / 0x8A150030)
            if (OperatingSystem.IsWindows() && !IsCurrentProcessElevated() && isWinget &&
                (result.ExitCode == 740 || result.ExitCode == 1603 || result.ExitCode == unchecked((int)0x8A150030)))
            {
                return RunElevated(fileName, arguments, workingDirectory, timeoutMs);
            }

            return result;
        }

        public async Task<ProcessExecutionResult> RunAsync(
            string fileName,
            string arguments,
            string? workingDirectory = null,
            int timeoutMs = 60000,
            CancellationToken cancellationToken = default)
        {
            return await Task.Run(() => Run(fileName, arguments, workingDirectory, timeoutMs), cancellationToken);
        }

        private static ProcessExecutionResult RunElevated(string fileName, string arguments, string? workingDirectory, int timeoutMs)
        {
            string runId = Guid.NewGuid().ToString("N");
            string tempDir = Path.GetTempPath();
            string scriptFile = Path.Combine(tempDir, $"winget_elevated_{runId}.ps1");
            string outFile = Path.Combine(tempDir, $"winget_elevated_{runId}.out");
            string errFile = Path.Combine(tempDir, $"winget_elevated_{runId}.err");

            try
            {
                string scriptContent = $@"& ""{fileName}"" {arguments} > ""{outFile}"" 2> ""{errFile}""
exit $LASTEXITCODE";
                File.WriteAllText(scriptFile, scriptContent, Encoding.ASCII);

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{scriptFile}\"",
                    WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null)
                {
                    return new ProcessExecutionResult(-1, string.Empty, "Failed to launch elevated powershell process.", false);
                }

                bool exited = process.WaitForExit(timeoutMs);
                if (!exited)
                {
                    try { process.Kill(true); } catch { }
                    return new ProcessExecutionResult(-1, string.Empty, $"Elevated process timed out after {timeoutMs}ms.", true);
                }

                int exitCode = process.ExitCode;
                string stdout = File.Exists(outFile) ? File.ReadAllText(outFile) : string.Empty;
                string stderr = File.Exists(errFile) ? File.ReadAllText(errFile) : string.Empty;

                return new ProcessExecutionResult(exitCode, stdout, stderr, false);
            }
            catch (Exception ex)
            {
                return new ProcessExecutionResult(-1, string.Empty, ex.Message, false);
            }
            finally
            {
                try { if (File.Exists(scriptFile)) File.Delete(scriptFile); } catch { }
                try { if (File.Exists(outFile)) File.Delete(outFile); } catch { }
                try { if (File.Exists(errFile)) File.Delete(errFile); } catch { }
            }
        }

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName) => _inner.GetProcessesByName(processName);
        public bool CloseMainWindow(int processId) => _inner.CloseMainWindow(processId);
        public bool WaitForExit(int processId, TimeSpan timeout) => _inner.WaitForExit(processId, timeout);
        public bool KillProcess(int processId, bool entireProcessTree = true) => _inner.KillProcess(processId, entireProcessTree);
        public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true) => _inner.StopProcess(processName, timeoutSeconds, force);
        public bool IsProcessRunning(string processName) => _inner.IsProcessRunning(processName);
        public bool StartProcess(string fileName, string? arguments = null) => _inner.StartProcess(fileName, arguments);
    }
}
