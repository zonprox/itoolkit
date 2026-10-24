namespace IToolkit.Tests.PillarTests;

using System.Text;
using IToolkit.Core.Models;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class SystemHealthServiceTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly SystemHealthService _service;

    public SystemHealthServiceTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _service = new SystemHealthService(_processRunner, _fileSystem, registry: _registry);
    }

    [Fact]
    public void RunDismCheckHealth_ReturnsSuccess_WhenExitCodeIsZero()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /CheckHealth",
            new ProcessExecutionResult(0, "No component store corruption detected.", string.Empty, false));

        var result = _service.RunDismCheckHealth();

        Assert.True(result.Success);
        Assert.Equal(0, result.ExitCode);
        Assert.False(result.NeedsReboot);
        Assert.Contains("/CheckHealth", _processRunner.ExecutedCommands[0]);
    }

    [Fact]
    public void RunDismScanHealth_ReturnsFailed_WhenExitCodeIsNonZero()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /ScanHealth",
            new ProcessExecutionResult(87, string.Empty, "The parameter is incorrect.", false));

        var result = _service.RunDismScanHealth();

        Assert.False(result.Success);
        Assert.Equal(87, result.ExitCode);
        Assert.Equal("The parameter is incorrect.", result.ErrorOutput);
    }

    [Fact]
    public void RunDismRestoreHealth_DetectsRebootRequired_WhenExitCodeIs3010()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth",
            new ProcessExecutionResult(3010, "The restore operation completed successfully. A restart is required.", string.Empty, false));

        var result = _service.RunDismRestoreHealth();

        Assert.True(result.Success);
        Assert.True(result.NeedsReboot);
        Assert.Equal(3010, result.ExitCode);
    }

    [Fact]
    public void RunDismRestoreHealth_AppendsSourceAndLimitAccess_WhenSpecified()
    {
        string expectedCmd = "dism.exe /Online /Cleanup-Image /RestoreHealth /Source:\"D:\\sources\\sxs\" /LimitAccess";
        _processRunner.SetCommandResult(expectedCmd,
            new ProcessExecutionResult(0, "Restore completed.", string.Empty, false));

        var result = _service.RunDismRestoreHealth("D:\\sources\\sxs", limitAccess: true);

        Assert.True(result.Success);
        Assert.Contains(expectedCmd, _processRunner.ExecutedCommands);
    }

    [Theory]
    [InlineData(0, "Windows Resource Protection did not find any integrity violations.", false, false)]
    [InlineData(1, "Windows Resource Protection found corrupt files and successfully repaired them.", true, true)]
    [InlineData(2, "Windows Resource Protection could not perform the requested operation.", true, false)]
    public void RunSfcScan_EvaluatesExitCodesCorrectly(int exitCode, string stdout, bool violationsFound, bool repaired)
    {
        _processRunner.SetCommandResult("sfc.exe /scannow",
            new ProcessExecutionResult(exitCode, stdout, string.Empty, false));

        var result = _service.RunSfcScan();

        Assert.Equal(exitCode != 2, result.Success);
        Assert.Equal(violationsFound, result.IntegrityViolationsFound);
        Assert.Equal(repaired, result.SuccessfullyRepaired);
    }

    [Fact]
    public void RunDismSfcPipeline_ExecutesDismBeforeSfc()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth",
            new ProcessExecutionResult(0, "DISM success", string.Empty, false));
        _processRunner.SetCommandResult("sfc.exe /scannow",
            new ProcessExecutionResult(0, "SFC clean", string.Empty, false));

        var (dismRes, sfcRes) = _service.RunDismSfcPipeline();

        Assert.True(dismRes.Success);
        Assert.True(sfcRes.Success);

        int dismIndex = _processRunner.ExecutedCommands.FindIndex(c => c.Contains("dism.exe"));
        int sfcIndex = _processRunner.ExecutedCommands.FindIndex(c => c.Contains("sfc.exe"));

        Assert.True(dismIndex >= 0, "DISM command must be executed");
        Assert.True(sfcIndex >= 0, "SFC command must be executed");
        Assert.True(dismIndex < sfcIndex, "DISM RestoreHealth must execute BEFORE SFC scannow in the pipeline");
    }

    [Fact]
    public void ResetWindowsUpdateComponents_StopsServices_RenamesDirectories_Registers35Dlls_AndRestarts()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string sdPath = Path.Combine(sysRoot, "SoftwareDistribution");
        string catrootPath = Path.Combine(sysRoot, "System32", "catroot2");

        _fileSystem.CreateDirectory(sdPath);
        _fileSystem.CreateDirectory(catrootPath);

        var result = _service.ResetWindowsUpdateComponents();

        Assert.True(result.Success);
        Assert.Equal(4, result.StoppedServices.Count);
        Assert.Contains("wuauserv", result.StoppedServices);
        Assert.Contains("cryptsvc", result.StoppedServices);
        Assert.Contains("bits", result.StoppedServices);
        Assert.Contains("msiserver", result.StoppedServices);

        // 35 DLLs re-registered
        Assert.Equal(35, result.ReRegisteredDllCount);

        // Genuine directory renaming without fallback to (Purged) or (InUse)
        Assert.Equal(2, result.RenamedDirectories.Count);
        Assert.Contains(sdPath, result.RenamedDirectories);
        Assert.Contains(catrootPath, result.RenamedDirectories);
        Assert.DoesNotContain(result.RenamedDirectories, d => d.Contains("(Purged)") || d.Contains("(InUse)"));
        Assert.False(_fileSystem.DirectoryExists(sdPath));
        Assert.False(_fileSystem.DirectoryExists(catrootPath));

        // Winsock and proxy reset
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("netsh winsock reset"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("netsh winhttp reset proxy"));

        // Services restarted
        Assert.Equal(4, result.RestartedServices.Count);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start wuauserv"));
    }

    [Fact]
    public void RepairWmiRepository_PerformsVerifyAndSalvage()
    {
        _processRunner.SetCommandResult("winmgmt.exe /verifyrepository",
            new ProcessExecutionResult(0, "WMI repository is consistent", string.Empty, false));
        _processRunner.SetCommandResult("winmgmt.exe /salvagerepository",
            new ProcessExecutionResult(0, "WMI repository has been salvaged", string.Empty, false));

        var result = _service.RepairWmiRepository();

        Assert.True(result.Success);
        Assert.True(result.IsConsistent);
        Assert.True(result.Salvaged);
        Assert.False(result.Reset);
    }

    [Fact]
    public void CleanWinSxS_ExecutesStartComponentCleanup_WithOrWithoutResetBase()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /StartComponentCleanup",
            new ProcessExecutionResult(0, "Cleanup success", string.Empty, false));
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase",
            new ProcessExecutionResult(0, "Cleanup ResetBase success", string.Empty, false));

        var res1 = _service.CleanWinSxS(resetBase: false);
        var res2 = _service.CleanWinSxS(resetBase: true);

        Assert.True(res1.Success);
        Assert.True(res2.Success);
        Assert.Contains("dism.exe /Online /Cleanup-Image /StartComponentCleanup", _processRunner.ExecutedCommands);
        Assert.Contains("dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase", _processRunner.ExecutedCommands);
    }

    [Fact]
    public void RunUnifiedDiskCleanup_PreservesActiveLogs_AndDeletesOldTempFiles()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";

        // Setup active logs (MUST BE PRESERVED)
        string cbsDir = Path.Combine(sysRoot, "Logs", "CBS");
        string dismDir = Path.Combine(sysRoot, "Logs", "DISM");
        _fileSystem.CreateDirectory(cbsDir);
        _fileSystem.CreateDirectory(dismDir);

        string activeCbsLog = Path.Combine(cbsDir, "CBS.log");
        string archivedCbsLog = Path.Combine(cbsDir, "CbsPersist_20261022.log");
        _fileSystem.WriteAllText(activeCbsLog, "Active CBS Log Content");
        _fileSystem.WriteAllText(archivedCbsLog, "Archived CBS Log Content");

        string activeDismLog = Path.Combine(dismDir, "dism.log");
        string archivedDismLog = Path.Combine(dismDir, "dism.log.1");
        _fileSystem.WriteAllText(activeDismLog, "Active DISM Log Content");
        _fileSystem.WriteAllText(archivedDismLog, "Archived DISM Log Content");

        // Setup memory dump
        string memDump = Path.Combine(sysRoot, "MEMORY.DMP");
        _fileSystem.WriteAllBytes(memDump, new byte[1024 * 1024]);

        // Setup temp files
        string tempDir = Path.Combine(sysRoot, "Temp");
        _fileSystem.CreateDirectory(tempDir);
        string oldTemp = Path.Combine(tempDir, "old_cache.tmp");
        _fileSystem.WriteAllBytes(oldTemp, new byte[512]);

        var result = _service.RunUnifiedDiskCleanup(tempAgeHoursThreshold: 24);

        // Verification: Active CBS.log and dism.log MUST NOT be deleted
        Assert.True(_fileSystem.FileExists(activeCbsLog), "Active CBS.log must be preserved!");
        Assert.True(_fileSystem.FileExists(activeDismLog), "Active dism.log must be preserved!");

        // Verification: Archived logs and dump must be removed
        Assert.False(_fileSystem.FileExists(archivedCbsLog), "Archived CbsPersist_*.log should be deleted");
        Assert.False(_fileSystem.FileExists(archivedDismLog), "Archived dism.log.* should be deleted");
        Assert.False(_fileSystem.FileExists(memDump), "MEMORY.DMP should be deleted");

        Assert.True(result.Success);
        Assert.True(result.BytesReclaimed > 0);
        Assert.True(result.FilesDeleted >= 3);
    }

    [Fact]
    public void BlockAndUnblockWindowsUpdates_AppliesAndClearsServicesAndPoliciesForWindows10And11()
    {
        var blockRes = _service.BlockWindowsUpdates();

        Assert.True(blockRes.Success);
        Assert.True(blockRes.IsBlocked);
        Assert.True(blockRes.PolicyApplied);
        Assert.Contains("wuauserv", blockRes.ConfiguredServices);
        Assert.Contains("dosvc", blockRes.ConfiguredServices);
        Assert.Contains("UsoSvc", blockRes.ConfiguredServices);
        Assert.Contains("WaaSMedicSvc", blockRes.ConfiguredServices);
        Assert.Contains("sc.exe config wuauserv start= disabled", _processRunner.ExecutedCommands);
        Assert.Contains("sc.exe config UsoSvc start= disabled", _processRunner.ExecutedCommands);
        Assert.Equal(1, _registry.GetValue<int>(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));
        Assert.Equal(1, _registry.GetValue<int>(SystemHealthService.WindowsUpdateAuPolicyKey, "NoAutoUpdate"));
        Assert.Equal(4, _registry.GetValue<int>(SystemHealthService.WaaSMedicServiceKey, "Start"));

        var unblockRes = _service.UnblockWindowsUpdates();

        Assert.True(unblockRes.Success);
        Assert.False(unblockRes.IsBlocked);
        Assert.True(unblockRes.PolicyApplied);
        Assert.False(_registry.ValueExists(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));
        Assert.Equal(0, _registry.GetValue<int>(SystemHealthService.WindowsUpdateAuPolicyKey, "NoAutoUpdate"));
        Assert.Equal(3, _registry.GetValue<int>(SystemHealthService.WaaSMedicServiceKey, "Start"));
        Assert.Contains("sc.exe config wuauserv start= demand", _processRunner.ExecutedCommands);
        Assert.Contains("net start wuauserv", _processRunner.ExecutedCommands);
    }

    [Fact]
    public void SyncSystemTime_RegistersStartsAndResyncsW32Time()
    {
        var res = _service.SyncSystemTime();

        Assert.True(res.Success);
        Assert.True(res.ServiceRegistered);
        Assert.True(res.ServiceStarted);
        Assert.True(res.Resynced);
        Assert.Contains("net stop w32time /y", _processRunner.ExecutedCommands);
        Assert.Contains("w32tm.exe /unregister", _processRunner.ExecutedCommands);
        Assert.Contains("w32tm.exe /register", _processRunner.ExecutedCommands);
        Assert.Contains("sc.exe config w32time start= auto", _processRunner.ExecutedCommands);
        Assert.Contains("net start w32time", _processRunner.ExecutedCommands);
        Assert.Contains("w32tm.exe /resync /force", _processRunner.ExecutedCommands);
    }
}
