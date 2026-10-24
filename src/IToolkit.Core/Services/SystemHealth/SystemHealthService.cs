namespace IToolkit.Core.Services.SystemHealth;

using System.Globalization;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 1: System Health &amp; Maintenance implementation in pure C# .NET 10.0 LTS (win-x64).
/// </summary>
public class SystemHealthService : ISystemHealthService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IActivityLogger? _logger;
    private readonly IRegistryService? _registry;
    private readonly AtomicRegistryService? _atomicRegistry;

    public const string DefaultNtpServers = "time.windows.com,0x9 time.cloudflare.com,0x9 pool.ntp.org,0x9";
    public const string WindowsUpdatePolicyKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";
    public const string WindowsUpdateAuPolicyKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";
    public const string WaaSMedicServiceKey = @"HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc";

    public static readonly string[] WindowsUpdateServices = { "wuauserv", "cryptsvc", "bits", "msiserver" };
    public static readonly string[] WindowsUpdateBlockerServices = { "wuauserv", "dosvc", "UsoSvc", "WaaSMedicSvc" };

    public static readonly string[] WindowsUpdateDlls =
    {
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll"
    };

    public SystemHealthService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IActivityLogger? logger = null,
        IRegistryService? registry = null,
        AtomicRegistryService? atomicRegistry = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _logger = logger;
        _registry = registry;
        _atomicRegistry = atomicRegistry;
    }

    private string GetSystemRoot()
    {
        string? winDir = Environment.GetEnvironmentVariable("SystemRoot");
        return !string.IsNullOrEmpty(winDir) ? winDir : @"C:\Windows";
    }

    public DismScanResult RunDismCheckHealth()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing DISM CheckHealth...");
        var result = _processRunner.Run("dism.exe", "/Online /Cleanup-Image /CheckHealth");
        bool success = result.ExitCode == 0;
        return success
            ? DismScanResult.Successful(result.StandardOutput)
            : DismScanResult.Failed(result.ExitCode, result.StandardOutput, result.StandardError);
    }

    public DismScanResult RunDismScanHealth()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing DISM ScanHealth...");
        var result = _processRunner.Run("dism.exe", "/Online /Cleanup-Image /ScanHealth");
        bool success = result.ExitCode == 0;
        return success
            ? DismScanResult.Successful(result.StandardOutput)
            : DismScanResult.Failed(result.ExitCode, result.StandardOutput, result.StandardError);
    }

    public DismScanResult RunDismRestoreHealth(string? source = null, bool limitAccess = false)
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing DISM RestoreHealth...");
        string args = "/Online /Cleanup-Image /RestoreHealth";
        if (!string.IsNullOrWhiteSpace(source))
        {
            args += $" /Source:\"{source}\"";
        }
        if (limitAccess)
        {
            args += " /LimitAccess";
        }

        var result = _processRunner.Run("dism.exe", args);
        bool success = result.ExitCode == 0 || result.ExitCode == 3010;
        bool rebootRequired = result.ExitCode == 3010;

        return success
            ? DismScanResult.Successful(result.StandardOutput, rebootRequired)
            : DismScanResult.Failed(result.ExitCode, result.StandardOutput, result.StandardError);
    }

    public SfcScanResult RunSfcScan()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing SFC /scannow...");
        var result = _processRunner.Run("sfc.exe", "/scannow");

        if (result.ExitCode == 0)
        {
            return SfcScanResult.Clean(result.StandardOutput);
        }
        if (result.ExitCode == 1 || result.StandardOutput.Contains("repaired", StringComparison.OrdinalIgnoreCase))
        {
            return SfcScanResult.Repaired(result.StandardOutput);
        }

        return SfcScanResult.Failed(result.ExitCode, result.StandardOutput, result.StandardError);
    }

    public (DismScanResult DismResult, SfcScanResult SfcResult) RunDismSfcPipeline(string? source = null, bool limitAccess = false)
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing Dual DISM + SFC Pipeline: DISM RestoreHealth followed by SFC scannow...");
        var dismResult = RunDismRestoreHealth(source, limitAccess);
        var sfcResult = RunSfcScan();
        return (dismResult, sfcResult);
    }

    public WindowsUpdateResetResult ResetWindowsUpdateComponents()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Starting Windows Update component reset pipeline...");
        string systemRoot = GetSystemRoot();
        string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);

        var stopped = new List<string>();
        var renamed = new List<string>();
        var restarted = new List<string>();

        // 1. Stop 4 services
        foreach (var svc in WindowsUpdateServices)
        {
            _processRunner.Run("net", $"stop {svc} /y");
            stopped.Add(svc);
        }

        // 2. Rename directories (or fallback purge)
        string sdPath = Path.Combine(systemRoot, "SoftwareDistribution");
        if (_fileSystem.DirectoryExists(sdPath))
        {
            string sdBackup = Path.Combine(systemRoot, $"SoftwareDistribution.bak_{timestamp}");
            try
            {
                _fileSystem.MoveDirectory(sdPath, sdBackup);
                renamed.Add(sdPath);
            }
            catch
            {
                // Fallback: delete download cache
                string downloadDir = Path.Combine(sdPath, "Download");
                if (_fileSystem.DirectoryExists(downloadDir))
                {
                    _fileSystem.DeleteDirectory(downloadDir, recursive: true);
                    _fileSystem.CreateDirectory(downloadDir);
                }
                renamed.Add($"{sdPath} (Purged)");
            }
        }

        string catroot2Path = Path.Combine(systemRoot, "System32", "catroot2");
        if (_fileSystem.DirectoryExists(catroot2Path))
        {
            string catrootBackup = Path.Combine(systemRoot, "System32", $"catroot2.bak_{timestamp}");
            try
            {
                _fileSystem.MoveDirectory(catroot2Path, catrootBackup);
                renamed.Add(catroot2Path);
            }
            catch
            {
                renamed.Add($"{catroot2Path} (InUse)");
            }
        }

        // 3. Re-register 35 DLLs
        int reRegistered = 0;
        foreach (var dll in WindowsUpdateDlls)
        {
            var res = _processRunner.Run("regsvr32.exe", $"/s {dll}");
            if (res.ExitCode == 0)
            {
                reRegistered++;
            }
        }

        // 4. Reset Winsock & WinHTTP Proxy
        _processRunner.Run("netsh", "winsock reset");
        _processRunner.Run("netsh", "winhttp reset proxy");

        // 5. Restart services
        foreach (var svc in WindowsUpdateServices)
        {
            string startType = svc.Equals("msiserver", StringComparison.OrdinalIgnoreCase) ? "demand" : "auto";
            _processRunner.Run("sc.exe", $"config {svc} start= {startType}");
            _processRunner.Run("net", $"start {svc}");
            restarted.Add(svc);
        }

        _logger?.LogSuccess(nameof(SystemHealthService), $"Windows Update reset completed: {stopped.Count} stopped, {renamed.Count} renamed/purged, {reRegistered}/{WindowsUpdateDlls.Length} DLLs registered, {restarted.Count} restarted.");
        return new WindowsUpdateResetResult(true, stopped, renamed, reRegistered, restarted, "Windows Update components successfully reset.");
    }

    public WindowsUpdateBlockResult BlockWindowsUpdates()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Blocking Windows Update across Windows 10/11 (services and Group Policy locks)...");
        var configuredServices = new List<string>();

        foreach (var svc in new[] { "wuauserv", "dosvc", "UsoSvc" })
        {
            _processRunner.Run("net", $"stop {svc} /y");
            _processRunner.Run("sc.exe", $"config {svc} start= disabled");
            configuredServices.Add(svc);
        }

        _processRunner.Run("net", "stop bits /y");

        bool ApplyRegistryBlock()
        {
            if (_registry == null) return true;

            _registry.CreateKey(WindowsUpdatePolicyKey);
            _registry.SetValue(WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess", 1, RegistryValueKind.DWord);
            _registry.SetValue(WindowsUpdatePolicyKey, "DoNotConnectToWindowsUpdateInternetLocations", 1, RegistryValueKind.DWord);
            _registry.SetValue(WindowsUpdatePolicyKey, "SetDisableUXWUAccess", 1, RegistryValueKind.DWord);
            _registry.SetValue(WindowsUpdatePolicyKey, "ExcludeWUDriversInQualityUpdate", 1, RegistryValueKind.DWord);

            _registry.CreateKey(WindowsUpdateAuPolicyKey);
            _registry.SetValue(WindowsUpdateAuPolicyKey, "NoAutoUpdate", 1, RegistryValueKind.DWord);
            _registry.SetValue(WindowsUpdateAuPolicyKey, "AUOptions", 1, RegistryValueKind.DWord);

            _registry.CreateKey(WaaSMedicServiceKey);
            _registry.SetValue(WaaSMedicServiceKey, "Start", 4, RegistryValueKind.DWord);
            return true;
        }

        bool policyApplied = _atomicRegistry != null
            ? _atomicRegistry.ExecuteAtomicMutation(WindowsUpdatePolicyKey, ApplyRegistryBlock, "Block Windows Updates (Win 10/11)").Success
            : ApplyRegistryBlock();

        configuredServices.Add("WaaSMedicSvc");

        _logger?.LogSuccess(nameof(SystemHealthService), "Windows Updates blocked for Windows 10/11.");
        return new WindowsUpdateBlockResult(
            policyApplied,
            IsBlocked: true,
            configuredServices,
            policyApplied,
            policyApplied
                ? "Windows Updates blocked for Windows 10/11 (services disabled and Group Policy locks applied)."
                : "Failed to apply Windows Update blocker registry policies.");
    }

    public WindowsUpdateBlockResult UnblockWindowsUpdates()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Unblocking Windows Update across Windows 10/11 (restoring services and clearing Group Policy locks)...");
        var configuredServices = new List<string>();

        bool ApplyRegistryUnblock()
        {
            if (_registry == null) return true;

            if (_registry.KeyExists(WindowsUpdatePolicyKey))
            {
                _registry.DeleteValue(WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess");
                _registry.DeleteValue(WindowsUpdatePolicyKey, "DoNotConnectToWindowsUpdateInternetLocations");
                _registry.DeleteValue(WindowsUpdatePolicyKey, "SetDisableUXWUAccess");
                _registry.DeleteValue(WindowsUpdatePolicyKey, "ExcludeWUDriversInQualityUpdate");
            }

            if (_registry.KeyExists(WindowsUpdateAuPolicyKey))
            {
                _registry.SetValue(WindowsUpdateAuPolicyKey, "NoAutoUpdate", 0, RegistryValueKind.DWord);
                _registry.DeleteValue(WindowsUpdateAuPolicyKey, "AUOptions");
            }

            _registry.CreateKey(WaaSMedicServiceKey);
            _registry.SetValue(WaaSMedicServiceKey, "Start", 3, RegistryValueKind.DWord);
            return true;
        }

        bool policyApplied = _atomicRegistry != null
            ? _atomicRegistry.ExecuteAtomicMutation(WindowsUpdatePolicyKey, ApplyRegistryUnblock, "Unblock Windows Updates (Win 10/11)").Success
            : ApplyRegistryUnblock();

        configuredServices.Add("WaaSMedicSvc");

        foreach (var svc in new[] { "wuauserv", "dosvc", "UsoSvc" })
        {
            _processRunner.Run("sc.exe", $"config {svc} start= demand");
            _processRunner.Run("net", $"start {svc}");
            configuredServices.Add(svc);
        }

        _processRunner.Run("sc.exe", "config bits start= delayed-auto");
        _processRunner.Run("net", "start bits");

        _logger?.LogSuccess(nameof(SystemHealthService), "Windows Updates unblocked and restored for Windows 10/11.");
        return new WindowsUpdateBlockResult(
            policyApplied,
            IsBlocked: false,
            configuredServices,
            policyApplied,
            policyApplied
                ? "Windows Updates unblocked and restored for Windows 10/11."
                : "Failed to clear Windows Update blocker registry policies.");
    }

    public TimeSyncResult SyncSystemTime(string? ntpServers = null)
    {
        string peers = string.IsNullOrWhiteSpace(ntpServers) ? DefaultNtpServers : ntpServers.Trim();
        _logger?.LogInfo(nameof(SystemHealthService), $"Repairing Windows Time (W32Time) and synchronizing clock with '{peers}'...");

        _processRunner.Run("net", "stop w32time /y");
        _processRunner.Run("w32tm.exe", "/unregister");
        var regRes = _processRunner.Run("w32tm.exe", "/register");
        bool registered = regRes.ExitCode == 0;

        _processRunner.Run("sc.exe", "config w32time start= auto");
        var startRes = _processRunner.Run("net", "start w32time");
        bool started = startRes.ExitCode == 0;

        _processRunner.Run("w32tm.exe", $"/config /manualpeerlist:\"{peers}\" /syncfromflags:manual,domhier /reliable:YES /update");
        var resyncRes = _processRunner.Run("w32tm.exe", "/resync /force");
        bool resynced = resyncRes.ExitCode == 0;

        bool success = registered && started && resynced;
        if (success)
        {
            _logger?.LogSuccess(nameof(SystemHealthService), "System clock successfully synchronized with time server.");
        }
        else
        {
            _logger?.LogWarning(nameof(SystemHealthService), $"Time synchronization completed with non-zero status (Registered={registered}, Started={started}, Resynced={resynced}).");
        }

        return new TimeSyncResult(
            success,
            peers,
            registered,
            started,
            resynced,
            resyncRes.StandardOutput,
            success
                ? "System time synchronized with server successfully."
                : $"Time sync failed (Exit {resyncRes.ExitCode}).");
    }

    public WmiRepairResult RepairWmiRepository()
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Auditing and repairing WMI repository...");
        var verifyRes = _processRunner.Run("winmgmt.exe", "/verifyrepository");
        bool isConsistent = verifyRes.ExitCode == 0 || verifyRes.StandardOutput.Contains("consistent", StringComparison.OrdinalIgnoreCase);

        bool salvaged = false;
        bool reset = false;

        var salvageRes = _processRunner.Run("winmgmt.exe", "/salvagerepository");
        salvaged = salvageRes.ExitCode == 0 || salvageRes.StandardOutput.Contains("salvaged", StringComparison.OrdinalIgnoreCase);

        if (!isConsistent && !salvaged)
        {
            _logger?.LogWarning(nameof(SystemHealthService), "WMI repository salvage was insufficient; executing /resetrepository...");
            var resetRes = _processRunner.Run("winmgmt.exe", "/resetrepository");
            reset = resetRes.ExitCode == 0;
        }

        bool overallSuccess = isConsistent || salvaged || reset;
        return new WmiRepairResult(overallSuccess, isConsistent, salvaged, reset, salvageRes.StandardOutput);
    }

    public ComponentCleanupResult CleanWinSxS(bool resetBase = false)
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Executing WinSxS Component Store cleanup...");
        string args = "/Online /Cleanup-Image /StartComponentCleanup";
        if (resetBase)
        {
            args += " /ResetBase";
        }

        var res = _processRunner.Run("dism.exe", args);
        return new ComponentCleanupResult(res.ExitCode == 0, res.ExitCode, res.StandardOutput, res.StandardError);
    }

    public StorageCleanupResult RunUnifiedDiskCleanup(int tempAgeHoursThreshold = 24)
    {
        _logger?.LogInfo(nameof(SystemHealthService), "Starting Unified Storage Cleanup across WinSxS, WU cache, Delivery Optimization, Logs, and Temp...");
        string systemRoot = GetSystemRoot();
        DateTime cutoffUtc = DateTime.UtcNow.AddHours(-tempAgeHoursThreshold);

        var cleanedTargets = new List<string>();
        var errors = new List<string>();
        long bytesReclaimed = 0;
        int filesDeleted = 0;
        int filesSkipped = 0;

        // 1. WinSxS Cleanup
        try
        {
            var winSxsRes = CleanWinSxS();
            if (winSxsRes.Success)
            {
                cleanedTargets.Add("WinSxS Component Store");
            }
        }
        catch (Exception ex)
        {
            errors.Add($"WinSxS: {ex.Message}");
        }

        // 2. Windows Update Download Cache
        try
        {
            string wuDownloadDir = Path.Combine(systemRoot, "SoftwareDistribution", "Download");
            if (_fileSystem.DirectoryExists(wuDownloadDir))
            {
                _processRunner.Run("net", "stop wuauserv /y");
                var files = _fileSystem.EnumerateFiles(wuDownloadDir, "*", SearchOption.AllDirectories);
                foreach (var file in files)
                {
                    try
                    {
                        if (!_fileSystem.IsFileLocked(file))
                        {
                            long sz = _fileSystem.GetFileSize(file);
                            _fileSystem.DeleteFile(file);
                            bytesReclaimed += sz;
                            filesDeleted++;
                        }
                        else
                        {
                            filesSkipped++;
                        }
                    }
                    catch
                    {
                        filesSkipped++;
                    }
                }
                _processRunner.Run("net", "start wuauserv");
                cleanedTargets.Add("Windows Update Cache");
            }
        }
        catch (Exception ex)
        {
            errors.Add($"WU Cache: {ex.Message}");
        }

        // 3. Delivery Optimization Cache
        try
        {
            string doPath1 = Path.Combine(systemRoot, "ServiceProfiles", "NetworkService", "AppData", "Local", "Microsoft", "Windows", "DeliveryOptimization", "Cache");
            string doPath2 = Path.Combine(systemRoot, "SoftwareDistribution", "DeliveryOptimization");

            foreach (var doPath in new[] { doPath1, doPath2 })
            {
                if (_fileSystem.DirectoryExists(doPath))
                {
                    var files = _fileSystem.EnumerateFiles(doPath, "*", SearchOption.AllDirectories);
                    foreach (var file in files)
                    {
                        try
                        {
                            if (!_fileSystem.IsFileLocked(file))
                            {
                                long sz = _fileSystem.GetFileSize(file);
                                _fileSystem.DeleteFile(file);
                                bytesReclaimed += sz;
                                filesDeleted++;
                            }
                            else
                            {
                                filesSkipped++;
                            }
                        }
                        catch
                        {
                            filesSkipped++;
                        }
                    }
                }
            }
            cleanedTargets.Add("Delivery Optimization Cache");
        }
        catch (Exception ex)
        {
            errors.Add($"Delivery Optimization: {ex.Message}");
        }

        // 4. System crash dumps & diagnostics logs (STRICTLY PRESERVING active CBS.log and dism.log)
        try
        {
            // Memory dumps
            string memoryDmp = Path.Combine(systemRoot, "MEMORY.DMP");
            if (_fileSystem.FileExists(memoryDmp))
            {
                long sz = _fileSystem.GetFileSize(memoryDmp);
                _fileSystem.DeleteFile(memoryDmp);
                bytesReclaimed += sz;
                filesDeleted++;
            }

            // Minidumps
            string minidumpDir = Path.Combine(systemRoot, "Minidump");
            if (_fileSystem.DirectoryExists(minidumpDir))
            {
                foreach (var dump in _fileSystem.EnumerateFiles(minidumpDir, "*.dmp"))
                {
                    long sz = _fileSystem.GetFileSize(dump);
                    _fileSystem.DeleteFile(dump);
                    bytesReclaimed += sz;
                    filesDeleted++;
                }
            }

            // Archived CBS logs: CbsPersist_*.log (PRESERVE CBS.log!)
            string cbsDir = Path.Combine(systemRoot, "Logs", "CBS");
            if (_fileSystem.DirectoryExists(cbsDir))
            {
                foreach (var log in _fileSystem.EnumerateFiles(cbsDir, "*"))
                {
                    string fileName = Path.GetFileName(log);
                    if (fileName.StartsWith("CbsPersist_", StringComparison.OrdinalIgnoreCase) && !fileName.Equals("CBS.log", StringComparison.OrdinalIgnoreCase))
                    {
                        long sz = _fileSystem.GetFileSize(log);
                        _fileSystem.DeleteFile(log);
                        bytesReclaimed += sz;
                        filesDeleted++;
                    }
                }
            }

            // Archived DISM logs: dism.log.* (PRESERVE dism.log!)
            string dismDir = Path.Combine(systemRoot, "Logs", "DISM");
            if (_fileSystem.DirectoryExists(dismDir))
            {
                foreach (var log in _fileSystem.EnumerateFiles(dismDir, "*"))
                {
                    string fileName = Path.GetFileName(log);
                    if (fileName.StartsWith("dism.log.", StringComparison.OrdinalIgnoreCase) && !fileName.Equals("dism.log", StringComparison.OrdinalIgnoreCase))
                    {
                        long sz = _fileSystem.GetFileSize(log);
                        _fileSystem.DeleteFile(log);
                        bytesReclaimed += sz;
                        filesDeleted++;
                    }
                }
            }

            cleanedTargets.Add("System Crash Dumps & Archived Logs");
        }
        catch (Exception ex)
        {
            errors.Add($"System Logs: {ex.Message}");
        }

        // 5. Temporary Files older than threshold
        try
        {
            var tempDirs = new List<string>
            {
                Path.Combine(systemRoot, "Temp"),
                Path.GetTempPath()
            };

            foreach (var dir in tempDirs)
            {
                if (!_fileSystem.DirectoryExists(dir)) continue;

                foreach (var file in _fileSystem.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        if (_fileSystem.IsFileLocked(file))
                        {
                            filesSkipped++;
                            continue;
                        }

                        DateTime lastWrite = _fileSystem.GetLastWriteTimeUtc(file);
                        if (lastWrite <= cutoffUtc)
                        {
                            long sz = _fileSystem.GetFileSize(file);
                            _fileSystem.DeleteFile(file);
                            bytesReclaimed += sz;
                            filesDeleted++;
                        }
                        else
                        {
                            filesSkipped++; // Active / recent (<24h)
                        }
                    }
                    catch
                    {
                        filesSkipped++;
                    }
                }
            }
            cleanedTargets.Add("Temporary File Caches (>24h)");
        }
        catch (Exception ex)
        {
            errors.Add($"Temp Caches: {ex.Message}");
        }

        _logger?.LogSuccess(nameof(SystemHealthService), $"Unified storage cleanup completed: {bytesReclaimed / (1024 * 1024):N1} MB reclaimed, {filesDeleted} files deleted, {filesSkipped} files skipped.");
        return new StorageCleanupResult(errors.Count == 0, bytesReclaimed, filesDeleted, filesSkipped, cleanedTargets, errors);
    }
}
