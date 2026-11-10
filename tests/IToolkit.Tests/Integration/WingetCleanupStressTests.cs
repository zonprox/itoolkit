namespace IToolkit.Tests.Integration;

using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.Native;
using IToolkit.Core.Services.Software;
using Xunit;

/// <summary>
/// Empirical Challenger Stress Tests for Winget Host Cleanup, Process Termination, and Interruption Recovery.
/// Stress-tests:
/// 1. Mid-lifecycle interruption recovery via DisposeAsync.
/// 2. Self-healing state recovery via InitializeAsync when dirty host state pre-exists.
/// 3. Process termination resilience for orphan 7zFM / 7z processes.
/// 4. Live host exit code 0x8A150014 and 0 residual files guarantee.
/// </summary>
[Collection("RealWorldHostWingetIntegration")]
public sealed class WingetCleanupStressTests
{
    private const string TargetPackageId = "7zip.7zip";
    private static readonly string TargetInstallDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "7-Zip");
    private static readonly string TargetInstallDirX86 = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "7-Zip");

    [Fact(Timeout = 180000, DisplayName = "StressTest 1: DisposeAsync Guarantees Cleanup When Interrupted After Install")]
    public async Task DisposeAsync_WhenInterruptedAfterInstall_PurgesHostAndRestoresExitCode()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetInstalled())
        {
            return;
        }

        var fixture = new WingetRealWorldVerificationTests();
        try
        {
            await fixture.InitializeAsync();

            // 1. Execute install
            await fixture.Step1_SearchPackages_FindsCandidateApp();
            await fixture.Step2_InstallPackage_SucceedsSilently();

            // 2. Verify installed
            await fixture.Step3_VerifyInstalled_PresentInInventoryWithValidVersion();

            // 3. SIMULATE INTERRUPTION / CRASH:
            // An unhandled exception occurs before Step 5 (uninstall) and before Step 6 (cleanup).
            // Normal xUnit runner flow calls DisposeAsync on failure.
        }
        finally
        {
            // Call DisposeAsync as backstop
            await fixture.DisposeAsync();
        }

        // Post-Teardown Host Integrity Assertions:
        // A. Host returns exit code 0x8A150014 (or 1) with "No installed package found"
        var runner = new WindowsProcessRunner();
        var listRes = runner.Run("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn");
        Assert.True(WingetCliParser.IsNoApplicationsFound(listRes.ExitCode) || listRes.ExitCode == 1,
            $"Expected exit code 0x8A150014 or 1 after DisposeAsync, got {listRes.ExitCode}");
        Assert.Contains("No installed package found", listRes.StandardOutput, StringComparison.OrdinalIgnoreCase);

        // B. Zero residual binaries or folders in Program Files
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7z.exe")), "7z.exe must not remain after DisposeAsync.");
        Assert.False(File.Exists(Path.Combine(TargetInstallDir, "7zFM.exe")), "7zFM.exe must not remain after DisposeAsync.");
        Assert.False(Directory.Exists(TargetInstallDir), "C:\\Program Files\\7-Zip directory must be removed.");

        // C. Zero residual WinGet temporary cache folders
        string wingetTemp = Path.Combine(Path.GetTempPath(), "WinGet");
        if (Directory.Exists(wingetTemp))
        {
            var caches = Directory.GetDirectories(wingetTemp, "7zip.7zip*");
            Assert.Empty(caches);
        }
    }

    [Fact(Timeout = 180000, DisplayName = "StressTest 5: DisposeAsync When Real 7zFM Running During Teardown")]
    public async Task DisposeAsync_WhenOrphan7zFMRunning_CleansHostAndStopsProcess()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetInstalled())
        {
            return;
        }

        var fixture = new WingetRealWorldVerificationTests();
        Process? orphanProc = null;
        try
        {
            await fixture.InitializeAsync();
            await fixture.Step1_SearchPackages_FindsCandidateApp();
            await fixture.Step2_InstallPackage_SucceedsSilently();

            // Launch real 7zFM process from installed location
            string exePath = Path.Combine(TargetInstallDir, "7zFM.exe");
            if (!File.Exists(exePath))
            {
                exePath = Path.Combine(TargetInstallDirX86, "7zFM.exe");
            }

            Assert.True(File.Exists(exePath), $"7zFM.exe must exist at {exePath}");
            orphanProc = Process.Start(new ProcessStartInfo(exePath)
            {
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Minimized
            });

            Thread.Sleep(1000);
            var runner = new WindowsProcessRunner();
            Assert.True(runner.IsProcessRunning("7zFM"), "7zFM must be running.");
        }
        finally
        {
            await fixture.DisposeAsync();
            orphanProc?.Dispose();
        }

        // Verify that 7zFM was stopped and host is completely clean
        var postRunner = new WindowsProcessRunner();
        Assert.False(postRunner.IsProcessRunning("7zFM"), "7zFM must be stopped after DisposeAsync.");

        var listRes = postRunner.Run("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn");
        Assert.True(WingetCliParser.IsNoApplicationsFound(listRes.ExitCode) || listRes.ExitCode == 1,
            $"Expected exit code 0x8A150014 or 1 after DisposeAsync with orphan process, got {listRes.ExitCode}");
        Assert.False(Directory.Exists(TargetInstallDir), "TargetInstallDir must not exist.");
    }

    [Fact(Timeout = 180000, DisplayName = "StressTest 2: InitializeAsync Self-Healing Recovers When Host Left In Dirty State")]
    public async Task InitializeAsync_WhenHostPreInstalledFromPriorRun_SilentlyCleansHost()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetInstalled())
        {
            return;
        }

        // 1. Purposefully leave host in dirty state (install without teardown)
        var dirtyFixture = new WingetRealWorldVerificationTests();
        await dirtyFixture.InitializeAsync();
        await dirtyFixture.Step2_InstallPackage_SucceedsSilently();

        // Verify package is currently installed
        var runner = new WindowsProcessRunner();
        var checkRes = runner.Run("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn");
        Assert.Equal(0, checkRes.ExitCode);

        // 2. Instantiate a brand new fixture simulating a subsequent run
        var healingFixture = new WingetRealWorldVerificationTests();

        // 3. Execute InitializeAsync: Tier 3 self-healing setup must detect and purge lingering package
        await healingFixture.InitializeAsync();

        // 4. Assert host is now restored to clean state
        var postHealRes = runner.Run("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn");
        Assert.True(WingetCliParser.IsNoApplicationsFound(postHealRes.ExitCode) || postHealRes.ExitCode == 1,
            $"Expected exit code 0x8A150014 or 1 after self-healing, got {postHealRes.ExitCode}");
        Assert.Contains("No installed package found", postHealRes.StandardOutput, StringComparison.OrdinalIgnoreCase);

        Assert.False(Directory.Exists(TargetInstallDir), "Residual install directory must be purged by self-healing.");

        await healingFixture.DisposeAsync();
    }

    [Fact(Timeout = 60000, DisplayName = "StressTest 3: Process Termination Resilience For 7z / 7zFM Processes")]
    public async Task StopProcess_WhenTargetProcessesRunning_TerminatesThemResiliently()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        await Task.Yield();
        var runner = new WindowsProcessRunner();
        string tempDir = Path.Combine(Path.GetTempPath(), $"iToolKit_ProcStress_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        try
        {
            // Create dummy executables mimicking 7zFM.exe and 7z.exe
            // Using conhost.exe / powershell / cmd as harmless stand-in
            string systemCmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
            string dummy7zFM = Path.Combine(tempDir, "7zFM.exe");
            string dummy7z = Path.Combine(tempDir, "7z.exe");

            File.Copy(systemCmd, dummy7zFM, overwrite: true);
            File.Copy(systemCmd, dummy7z, overwrite: true);

            var psi1 = new ProcessStartInfo(dummy7zFM, "/k ping 127.0.0.1 -n 60")
            {
                CreateNoWindow = true,
                UseShellExecute = false
            };
            var psi2 = new ProcessStartInfo(dummy7z, "/k ping 127.0.0.1 -n 60")
            {
                CreateNoWindow = true,
                UseShellExecute = false
            };

            using var p1 = Process.Start(psi1);
            using var p2 = Process.Start(psi2);

            Assert.NotNull(p1);
            Assert.NotNull(p2);
            Thread.Sleep(500);

            Assert.True(runner.IsProcessRunning("7zFM"), "7zFM process should be detected as running.");
            Assert.True(runner.IsProcessRunning("7z"), "7z process should be detected as running.");

            // Act: Stop processes via process runner
            bool stopped1 = runner.StopProcess("7zFM", timeoutSeconds: 3, force: true);
            bool stopped2 = runner.StopProcess("7z", timeoutSeconds: 3, force: true);

            // Assert: Processes must be terminated
            Assert.True(stopped1, "StopProcess(7zFM) must return true.");
            Assert.True(stopped2, "StopProcess(7z) must return true.");
            Assert.False(runner.IsProcessRunning("7zFM"), "7zFM must no longer be running.");
            Assert.False(runner.IsProcessRunning("7z"), "7z must no longer be running.");
        }
        finally
        {
            try
            {
                runner.StopProcess("7zFM", timeoutSeconds: 2, force: true);
                runner.StopProcess("7z", timeoutSeconds: 2, force: true);
                if (Directory.Exists(tempDir))
                {
                    Directory.Delete(tempDir, recursive: true);
                }
            }
            catch { }
        }
    }

    [Fact(Timeout = 60000, DisplayName = "StressTest 4: Host Cleanliness Invariant Verification")]
    public async Task HostState_BaselineCleanliness_AssertsPristineState()
    {
        if (!OperatingSystem.IsWindows() || !IsWingetInstalled())
        {
            return;
        }

        await Task.Yield();
        var runner = new WindowsProcessRunner();
        var res = runner.Run("winget.exe", $"list --id {TargetPackageId} --disable-interactivity --nowarn");

        Assert.True(WingetCliParser.IsNoApplicationsFound(res.ExitCode) || res.ExitCode == 1,
            $"Invariant failure: Winget list returned unexpected code {res.ExitCode}. Output: {res.StandardOutput}");
        Assert.Contains("No installed package found", res.StandardOutput, StringComparison.OrdinalIgnoreCase);

        Assert.False(Directory.Exists(TargetInstallDir), $"Invariant failure: '{TargetInstallDir}' exists.");
        Assert.False(Directory.Exists(TargetInstallDirX86), $"Invariant failure: '{TargetInstallDirX86}' exists.");

        string wingetTemp = Path.Combine(Path.GetTempPath(), "WinGet");
        if (Directory.Exists(wingetTemp))
        {
            var caches = Directory.GetDirectories(wingetTemp, "7zip.7zip*");
            Assert.Empty(caches);
        }
    }

    private static bool IsWingetInstalled()
    {
        try
        {
            var runner = new WindowsProcessRunner();
            var res = runner.Run("winget.exe", "--version", timeoutMs: 5000);
            return res.ExitCode == 0 && !res.TimedOut;
        }
        catch
        {
            return false;
        }
    }
}
