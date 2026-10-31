namespace IToolkit.Core.Services.Office;

using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 2: Office & Outlook Productivity Suite implementation (Common & Word/Excel/PowerPoint).
/// </summary>
public class OfficeSuiteService : IOfficeSuiteService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _processLockGuard;
    private readonly IActivityLogger? _logger;

    public static readonly string[] OfficeProcessNames =
    {
        "WINWORD", "EXCEL", "POWERPNT", "OUTLOOK", "ONENOTE", "MSACCESS",
        "MSPUB", "VISIO", "WINPROJ", "OFFICECLICKTORUN", "MSOIA", "MSOSYNC",
        "LYNC", "COMMUNICATOR", "TEAMS", "ONEDRIVE"
    };

    public OfficeSuiteService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        AtomicRegistryService atomicRegistry,
        ProcessLockGuard processLockGuard,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _atomicRegistry = atomicRegistry ?? throw new ArgumentNullException(nameof(atomicRegistry));
        _processLockGuard = processLockGuard ?? throw new ArgumentNullException(nameof(processLockGuard));
        _logger = logger;
    }

    private string GetLocalAppData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    private string GetAppData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    private string GetProgramData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);

    private string GetProgramFiles() =>
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    public bool TerminateOfficeProcesses(TimeSpan? timeout = null)
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Terminating active Office processes via ProcessLockGuard...");
        return _processLockGuard.EnsureProcessesClosed(OfficeProcessNames, timeout);
    }

    public bool RepairClickToRunService()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Repairing Office Click-to-Run service and cleaning corrupt XML releases...");
        TerminateOfficeProcesses(TimeSpan.FromSeconds(3));
        _processRunner.Run("sc.exe", "config ClickToRunSvc start= auto");
        _processRunner.Run("net", "start ClickToRunSvc");

        string clickToRunReleases = Path.Combine(GetProgramData(), "Microsoft", "ClickToRun", "ProductReleases");
        if (_fileSystem.DirectoryExists(clickToRunReleases))
        {
            var files = _fileSystem.EnumerateFiles(clickToRunReleases, "*.xml", SearchOption.AllDirectories);
            foreach (var file in files)
            {
                try
                {
                    if (_fileSystem.GetFileSize(file) == 0)
                    {
                        _fileSystem.DeleteFile(file);
                    }
                }
                catch
                {
                    // Ignore transient lock
                }
            }
        }
        _processLockGuard.RestartClosedProcesses();
        return true;
    }

    public ProcessExecutionResult RunClickToRunRepair(bool online = false)
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), $"Initiating Click-to-Run {(online ? "Online" : "Quick")} repair...");
        TerminateOfficeProcesses(TimeSpan.FromSeconds(3));
        string repairType = online ? "FullRepair" : "QuickRepair";
        string args = $"scenario=Repair platform=x64 culture=en-us RepairType={repairType} DisplayLevel=True forceappshutdown=True";

        string defaultExePath = Path.Combine(GetProgramFiles(), "Common Files", "Microsoft Shared", "ClickToRun", "OfficeClickToRun.exe");
        string exe = _fileSystem.FileExists(defaultExePath) ? defaultExePath : "OfficeClickToRun.exe";

        var result = _processRunner.Run(exe, args);
        _processLockGuard.RestartClosedProcesses();
        return result;
    }

    public OperationResult ResetOfficeIdentityCache()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Resetting Office Identity & WAM tokens...");
        TerminateOfficeProcesses(TimeSpan.FromSeconds(3));

        // 1. Registry reset
        string identityKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity";
        var regResult = _atomicRegistry.ExecuteAtomicMutation(
            identityKey,
            () =>
            {
                string idKey = $@"{identityKey}\Identities";
                string profKey = $@"{identityKey}\Profiles";
                if (_registry.KeyExists(idKey)) _registry.DeleteKey(idKey, recursive: true);
                if (_registry.KeyExists(profKey)) _registry.DeleteKey(profKey, recursive: true);
                return true;
            },
            "Reset Office Identity & Profile Keys");

        // 2. Filesystem cache purge
        string localAppData = GetLocalAppData();
        var cacheDirs = new[]
        {
            Path.Combine(localAppData, "Microsoft", "IdentityCache"),
            Path.Combine(localAppData, "Microsoft", "OneAuth"),
            Path.Combine(localAppData, "Packages", "Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy", "AC", "TokenBroker", "Accounts")
        };

        foreach (var dir in cacheDirs)
        {
            if (_fileSystem.DirectoryExists(dir))
            {
                try
                {
                    _fileSystem.DeleteDirectory(dir, recursive: true);
                }
                catch (Exception ex)
                {
                    _logger?.LogWarning(nameof(OfficeSuiteService), $"Could not delete directory '{dir}': {ex.Message}");
                }
            }
        }

        _processLockGuard.RestartClosedProcesses();
        return regResult.Success ? OperationResult.Succeeded("Office Identity and WAM tokens reset successfully.") : regResult;
    }

    public OperationResult SetHardwareAcceleration(bool disable)
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), $"Setting suite-wide hardware acceleration: disable={disable}...");
        TerminateOfficeProcesses(TimeSpan.FromSeconds(3));
        try
        {
            return SetHardwareAccelerationCore(disable);
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses();
        }
    }

    private OperationResult SetHardwareAccelerationCore(bool disable)
    {
        string commonGraphicsKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Graphics";

        return _atomicRegistry.ExecuteAtomicMutation(
            commonGraphicsKey,
            () =>
            {
                int val = disable ? 1 : 0;
                var targets = new[]
                {
                    @"HKCU\Software\Microsoft\Office\16.0\Common\Graphics",
                    @"HKCU\Software\Microsoft\Office\16.0\Word\Options",
                    @"HKCU\Software\Microsoft\Office\16.0\Excel\Options",
                    @"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Options"
                };

                foreach (var key in targets)
                {
                    _registry.CreateKey(key);
                    _registry.SetValue(key, "DisableHardwareAcceleration", val, RegistryValueKind.DWord);
                }

                _registry.SetValue(@"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Options", "DisableSlideShowHardwareAcceleration", val, RegistryValueKind.DWord);
                return true;
            },
            $"Toggle Hardware Acceleration (disable={disable})");
    }

    public bool ResetWordNormalDotm()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Resetting Word Normal.dotm template...");
        _processLockGuard.EnsureProcessesClosed(new[] { "WINWORD" });
        string templateDir = Path.Combine(GetAppData(), "Microsoft", "Templates");
        string normalDotm = Path.Combine(templateDir, "Normal.dotm");

        if (_fileSystem.FileExists(normalDotm))
        {
            string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);
            string backupPath = Path.Combine(templateDir, $"Normal.dotm.bak_{timestamp}");
            _fileSystem.MoveFile(normalDotm, backupPath);
            return true;
        }
        return false;
    }

    public int DisableWordStartupAddIns()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Isolating Word startup add-ins...");
        int count = 0;
        var startupDirs = new[]
        {
            Path.Combine(GetAppData(), "Microsoft", "Word", "STARTUP"),
            Path.Combine(GetProgramFiles(), "Microsoft Office", "root", "Office16", "STARTUP")
        };

        foreach (var dir in startupDirs)
        {
            if (!_fileSystem.DirectoryExists(dir)) continue;

            foreach (var file in _fileSystem.EnumerateFiles(dir, "*"))
            {
                string ext = Path.GetExtension(file);
                if (ext.Equals(".dotm", StringComparison.OrdinalIgnoreCase) || ext.Equals(".wll", StringComparison.OrdinalIgnoreCase))
                {
                    string target = file + ".disabled";
                    _fileSystem.MoveFile(file, target);
                    count++;
                }
            }
        }
        return count;
    }

    public OperationResult ResetWordRegistryData()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Resetting Word Data and Options registry keys...");
        string wordKey = @"HKCU\Software\Microsoft\Office\16.0\Word";
        return _atomicRegistry.ExecuteAtomicMutation(
            wordKey,
            () =>
            {
                string dataKey = $@"{wordKey}\Data";
                string optionsKey = $@"{wordKey}\Options";
                if (_registry.KeyExists(dataKey)) _registry.DeleteKey(dataKey, recursive: true);
                if (_registry.KeyExists(optionsKey)) _registry.DeleteKey(optionsKey, recursive: true);
                return true;
            },
            "Reset Word Registry Data and Options");
    }

    public int CleanWordLockFiles(string? directory = null)
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Cleaning orphaned Word lock files...");
        int removed = 0;
        string targetDir = directory ?? GetAppData();

        if (_fileSystem.DirectoryExists(targetDir))
        {
            var files = _fileSystem.EnumerateFiles(targetDir, "*", SearchOption.AllDirectories);
            foreach (var file in files)
            {
                string name = Path.GetFileName(file);
                if ((name.StartsWith("~$", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".docx", StringComparison.OrdinalIgnoreCase)) ||
                    name.EndsWith(".asd", StringComparison.OrdinalIgnoreCase))
                {
                    if (!_fileSystem.IsFileLocked(file))
                    {
                        try
                        {
                            _fileSystem.DeleteFile(file);
                            removed++;
                        }
                        catch
                        {
                            // In use
                        }
                    }
                }
            }
        }
        return removed;
    }

    public OfficeAppRepairResult WordQuickRepair()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Executing Word Quick Repair composite pipeline...");
        _processLockGuard.EnsureProcessesClosed(new[] { "WINWORD" });

        bool dotmReset = ResetWordNormalDotm();
        int addInsDisabled = DisableWordStartupAddIns();
        var regReset = ResetWordRegistryData();
        int locksRemoved = CleanWordLockFiles();

        bool success = regReset.Success;
        _processLockGuard.RestartClosedProcesses(new[] { "WINWORD" });
        return new OfficeAppRepairResult("Word", dotmReset, addInsDisabled, success, locksRemoved, success, "Word quick repair completed.");
    }

    public int IsolateExcelXlStart()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Isolating Excel XLSTART add-ins...");
        _processLockGuard.EnsureProcessesClosed(new[] { "EXCEL" });
        int count = 0;
        string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);

        var dirs = new[]
        {
            Path.Combine(GetAppData(), "Microsoft", "Excel", "XLSTART"),
            Path.Combine(GetProgramFiles(), "Microsoft Office", "root", "Office16", "XLSTART")
        };

        foreach (var dir in dirs)
        {
            if (!_fileSystem.DirectoryExists(dir)) continue;

            foreach (var file in _fileSystem.EnumerateFiles(dir, "*"))
            {
                string name = Path.GetFileName(file);
                if (name.StartsWith("personal.xls", StringComparison.OrdinalIgnoreCase))
                {
                    // Backup personal workbook instead of disabling
                    string bak = Path.Combine(dir, $"{name}.bak_{timestamp}");
                    _fileSystem.CopyFile(file, bak, overwrite: true);
                }
                else
                {
                    string isolated = Path.Combine(dir, $"{name}.isolated.{timestamp}");
                    _fileSystem.MoveFile(file, isolated);
                    count++;
                }
            }
        }
        return count;
    }

    public bool ResetExcelUiCache()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Resetting Excel UI and toolbar cache...");
        string excelDir = Path.Combine(GetAppData(), "Microsoft", "Excel");
        var targets = new[] { "Excel16.xlb", "Excel.officeUI", "Excel.qat" };

        foreach (var t in targets)
        {
            string full = Path.Combine(excelDir, t);
            if (_fileSystem.FileExists(full))
            {
                _fileSystem.DeleteFile(full);
            }
        }

        string webCache = Path.Combine(GetLocalAppData(), "Microsoft", "Office", "16.0", "WebServiceCache");
        if (_fileSystem.DirectoryExists(webCache))
        {
            _fileSystem.DeleteDirectory(webCache, recursive: true);
        }
        return true;
    }

    public OperationResult RepairExcelDdeAndCalculation()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Repairing Excel DDE and Calculation options...");
        string excelOptionsKey = @"HKCU\Software\Microsoft\Office\16.0\Excel\Options";

        return _atomicRegistry.ExecuteAtomicMutation(
            excelOptionsKey,
            () =>
            {
                _registry.CreateKey(excelOptionsKey);
                _registry.SetValue(excelOptionsKey, "IgnoreRemoteRequests", 0, RegistryValueKind.DWord);
                _registry.SetValue(excelOptionsKey, "Calculation", 1, RegistryValueKind.DWord);
                return true;
            },
            "Repair Excel DDE and Auto Calculation");
    }

    public OperationResult PurgeExcelResiliency()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Purging Excel disabled items resiliency key...");
        string disabledKey = @"HKCU\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems";

        return _atomicRegistry.ExecuteAtomicMutation(
            disabledKey,
            () =>
            {
                if (_registry.KeyExists(disabledKey))
                {
                    _registry.DeleteKey(disabledKey, recursive: true);
                }
                return true;
            },
            "Purge Excel Resiliency DisabledItems");
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);

    public IReadOnlyList<GdiAuditResult> AuditAndMitigateGdiLeaks(int warningThreshold = 5000, int killThreshold = 8000)
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Auditing Excel GDI object leaks...");
        var results = new List<GdiAuditResult>();
        var procs = _processRunner.GetProcessesByName("EXCEL");

        foreach (var p in procs)
        {
            int gdiCount = 0;
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                try
                {
                    using var sysProc = System.Diagnostics.Process.GetProcessById(p.Id);
                    gdiCount = (int)GetGuiResources(sysProc.Handle, 0); // 0 = GR_GDIOBJECTS
                }
                catch
                {
                    gdiCount = 0;
                }
            }

            bool flagged = gdiCount >= warningThreshold;
            bool terminated = false;

            if (gdiCount >= killThreshold)
            {
                _logger?.LogWarning(nameof(OfficeSuiteService), $"Terminating leaking EXCEL process PID {p.Id} ({gdiCount} GDI handles >= {killThreshold})...");
                _processRunner.KillProcess(p.Id);
                terminated = true;
            }

            results.Add(new GdiAuditResult(p.Id, p.ProcessName, gdiCount, flagged, terminated));
        }

        return results;
    }

    public OfficeAppRepairResult ExcelQuickRepair()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Executing Excel Quick Repair composite pipeline...");
        _processLockGuard.EnsureProcessesClosed(new[] { "EXCEL" });

        int isolated = IsolateExcelXlStart();
        bool uiReset = ResetExcelUiCache();
        var ddeRes = RepairExcelDdeAndCalculation();
        var resRes = PurgeExcelResiliency();
        var gdiResults = AuditAndMitigateGdiLeaks();

        bool success = ddeRes.Success && resRes.Success && uiReset;
        _processLockGuard.RestartClosedProcesses(new[] { "EXCEL" });
        return new OfficeAppRepairResult("Excel", false, isolated, success, 0, success, "Excel quick repair completed.");
    }

    public bool PurgePowerPointCache()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Purging PowerPoint font and slide cache...");
        _processLockGuard.EnsureProcessesClosed(new[] { "POWERPNT" });
        string pptCache = Path.Combine(GetLocalAppData(), "Microsoft", "Office", "16.0", "PowerPoint", "Cache");
        if (_fileSystem.DirectoryExists(pptCache))
        {
            _fileSystem.DeleteDirectory(pptCache, recursive: true);
            return true;
        }
        return false;
    }

    public OperationResult PurgePowerPointResiliency()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Purging PowerPoint resiliency disabled items...");
        string disabledKey = @"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Resiliency\DisabledItems";

        return _atomicRegistry.ExecuteAtomicMutation(
            disabledKey,
            () =>
            {
                if (_registry.KeyExists(disabledKey))
                {
                    _registry.DeleteKey(disabledKey, recursive: true);
                }
                return true;
            },
            "Purge PowerPoint Resiliency DisabledItems");
    }

    public OfficeAppRepairResult PowerPointQuickRepair()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Executing PowerPoint Quick Repair composite pipeline...");
        _processLockGuard.EnsureProcessesClosed(new[] { "POWERPNT" });
        try
        {
            bool cachePurged = PurgePowerPointCache();
            var resRes = PurgePowerPointResiliency();
            var hwRes = SetHardwareAccelerationCore(disable: true);

            bool success = resRes.Success && hwRes.Success;
            return new OfficeAppRepairResult("PowerPoint", false, 0, success, 0, success, "PowerPoint quick repair completed.");
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses(new[] { "POWERPNT" });
        }
    }

    public OfficeScrubResult ScrubOfficeSuiteCleanly()
    {
        _logger?.LogInfo(nameof(OfficeSuiteService), "Executing complete Office Suite clean uninstallation and scrub...");

        // 1. Terminate all Office processes
        int terminated = 0;
        foreach (var name in OfficeProcessNames)
        {
            if (_processRunner.IsProcessRunning(name))
            {
                _processRunner.StopProcess(name, timeoutSeconds: 5, force: true);
                terminated++;
            }
        }
        _processLockGuard.EnsureProcessesClosed(OfficeProcessNames, TimeSpan.FromSeconds(3), forceKill: true);

        // 2. Stop and disable services
        int servicesStopped = 0;
        var services = new[] { "ClickToRunSvc", "OfficeSvc", "ose" };
        foreach (var svc in services)
        {
            _processRunner.Run("sc.exe", $"config {svc} start= disabled");
            _processRunner.Run("net", $"stop {svc} /y");
            servicesStopped++;
        }

        // 3. Remove scheduled tasks
        int tasksRemoved = 0;
        var taskRes = _processRunner.Run("schtasks.exe", "/delete /tn \"\\Microsoft\\Office\" /f");
        if (taskRes.ExitCode == 0) tasksRemoved++;

        // 4. Registry scrubbing
        var scrubKeys = new[]
        {
            @"HKLM\SOFTWARE\Microsoft\Office",
            @"HKCU\Software\Microsoft\Office",
            @"HKLM\SOFTWARE\Microsoft\AppVISV"
        };
        foreach (var k in scrubKeys)
        {
            if (_registry.KeyExists(k))
            {
                _registry.DeleteKey(k, recursive: true);
            }
        }

        // 5. Filesystem cleanup
        int filesDeleted = 0;
        string tokensPath = @"C:\ProgramData\Microsoft\OfficeSoftwareProtectionPlatform\tokens.dat";
        if (_fileSystem.FileExists(tokensPath))
        {
            _fileSystem.DeleteFile(tokensPath);
            filesDeleted++;
        }

        return new OfficeScrubResult(terminated, servicesStopped, tasksRemoved, true, filesDeleted, true, "Office suite scrubbed successfully.");
    }
}
