namespace IToolkit.Core.Services.Connectivity;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 3: Print Spooler management, Point &amp; Print policies, and 12-error-code catalog implementation in pure C# .NET 8 (win-x64).
/// </summary>
public class PrinterService : IPrinterService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _processLockGuard;
    private readonly IWmiService? _wmi;
    private readonly IActivityLogger? _logger;

    public static readonly string[] SpoolerProcessNames = { "spoolsv" };

    public static readonly string[] SupportedCatalogErrorCodes =
    {
        "0x0000011b", "0x00000709", "0x0000007c", "0x0000007e",
        "0x00000bcb", "0x00000002", "0x00000006", "0x00000057",
        "0x000003e3", "SpoolerCrash", "NePortConflict", "RefreshConnections"
    };

    public PrinterService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        AtomicRegistryService atomicRegistry,
        ProcessLockGuard processLockGuard,
        IWmiService? wmi = null,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _atomicRegistry = atomicRegistry ?? throw new ArgumentNullException(nameof(atomicRegistry));
        _processLockGuard = processLockGuard ?? throw new ArgumentNullException(nameof(processLockGuard));
        _wmi = wmi;
        _logger = logger;
    }

    private string GetSystemRoot()
    {
        string? winDir = Environment.GetEnvironmentVariable("SystemRoot");
        return !string.IsNullOrEmpty(winDir) ? winDir : @"C:\Windows";
    }

    public IReadOnlyList<string> GetSupportedErrorCodes() => SupportedCatalogErrorCodes;

    public SpoolerQueueResult PurgeSpoolerQueue()
    {
        _logger?.LogInfo(nameof(PrinterService), "Stopping Print Spooler and purging stuck queue items...");

        // 1. Stop spooler service & kill any hung spoolsv processes
        _processRunner.Run("net", "stop spooler /y");
        _processLockGuard.EnsureProcessesClosed(SpoolerProcessNames, TimeSpan.FromSeconds(2));

        string spoolPrinters = Path.Combine(GetSystemRoot(), "System32", "spool", "PRINTERS");
        int purged = 0;

        if (_fileSystem.DirectoryExists(spoolPrinters))
        {
            var files = _fileSystem.EnumerateFiles(spoolPrinters, "*", SearchOption.TopDirectoryOnly);
            foreach (var file in files)
            {
                string ext = Path.GetExtension(file);
                if (ext.Equals(".shd", StringComparison.OrdinalIgnoreCase) ||
                    ext.Equals(".spl", StringComparison.OrdinalIgnoreCase) ||
                    ext.Equals(".tmp", StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        _fileSystem.DeleteFile(file);
                        purged++;
                    }
                    catch
                    {
                        // In use
                    }
                }
            }
        }

        // 2. Restart spooler
        var startRes = _processRunner.Run("net", "start spooler");
        bool restarted = startRes.ExitCode == 0;

        _logger?.LogSuccess(nameof(PrinterService), $"Spooler queue purge completed: {purged} file(s) removed, Spooler restarted: {restarted}.");
        return new SpoolerQueueResult(true, true, restarted, purged, true, "Print Spooler queue purged successfully.");
    }

    public bool RegisterSpoolerComponents()
    {
        _logger?.LogInfo(nameof(PrinterService), "Re-registering Spooler DLLs, MOF schema, and RPCSS dependency...");
        string sys32 = Path.Combine(GetSystemRoot(), "System32");

        _processRunner.Run("regsvr32.exe", $"/s \"{Path.Combine(sys32, "printui.dll")}\"");
        _processRunner.Run("regsvr32.exe", $"/s \"{Path.Combine(sys32, "prntvpt.dll")}\"");
        _processRunner.Run("mofcomp.exe", $"\"{Path.Combine(sys32, "wbem", "prnprov.mof")}\"");
        _processRunner.Run("sc.exe", "config spooler depend= RPCSS start= auto");

        return true;
    }

    public int ResetNePortBindings()
    {
        _logger?.LogInfo(nameof(PrinterService), "Cleaning orphaned NeXX virtual printer port bindings in HKCU...");
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        if (!_registry.KeyExists(portsKey)) return 0;

        var installedPrinters = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Check installed printers via WMI if available
        if (_wmi != null)
        {
            var printers = _wmi.Query("SELECT Name FROM Win32_Printer");
            foreach (var p in printers)
            {
                if (p.TryGetValue("Name", out var nameVal) && nameVal != null)
                {
                    installedPrinters.Add(nameVal.ToString()!);
                }
            }
        }

        // Also check registry installed printers under Devices
        string devicesKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Devices";
        if (_registry.KeyExists(devicesKey))
        {
            foreach (var dev in _registry.GetValueNames(devicesKey))
            {
                installedPrinters.Add(dev);
            }
        }

        int removed = 0;
        var portValues = _registry.GetValueNames(portsKey).ToList();

        foreach (var valName in portValues)
        {
            // If we have installed printers list and this printer does not exist, or if it points to an invalid NeXX binding
            if (installedPrinters.Count > 0 && !installedPrinters.Contains(valName))
            {
                _registry.DeleteValue(portsKey, valName);
                removed++;
            }
        }

        _logger?.LogSuccess(nameof(PrinterService), $"Cleaned {removed} orphaned NeXX printer port bindings.");
        return removed;
    }

    public bool ApplyPointAndPrintPreset(PointAndPrintPreset preset)
    {
        _logger?.LogInfo(nameof(PrinterService), $"Applying Point & Print policy preset: {preset}...");
        int rpcPrivacy = preset == PointAndPrintPreset.StrictAdminOnly ? 1 : 0;
        int restrictAdmin = preset == PointAndPrintPreset.StrictAdminOnly ? 1 : 0;

        string printControlKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printControlKey);
        _registry.SetValue(printControlKey, "RpcAuthnLevelPrivacyEnabled", rpcPrivacy, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", restrictAdmin, RegistryValueKind.DWord);

        _processRunner.Run("net", "stop spooler /y");
        _processRunner.Run("net", "start spooler");
        return true;
    }

    public PrinterRemediationResult RemediatePrinterError(string errorCode)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        _logger?.LogInfo(nameof(PrinterService), $"Remediating printer error: {errorCode}...");

        string sysRoot = GetSystemRoot();
        bool policyApplied = false;
        bool servicesRestarted = false;
        string action = "";

        switch (errorCode.ToLowerInvariant())
        {
            case "0x0000011b":
                action = "Disable RPC privacy requirement & register remote RPC endpoint";
                _registry.CreateKey(@"HKLM\SYSTEM\CurrentControlSet\Control\Print");
                _registry.SetValue(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled", 0, RegistryValueKind.DWord);
                _registry.CreateKey(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers");
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "RegisterSpoolerRemoteRpcEndPoint", 1, RegistryValueKind.DWord);
                policyApplied = true;
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "0x00000709":
                action = "Force RPC over Named Pipes & preserve default printer mode";
                _registry.CreateKey(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC");
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC", "RpcUseNamedPipeProtocol", 1, RegistryValueKind.DWord);
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC", "RpcProtocols", 7, RegistryValueKind.DWord);

                string winKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows";
                _registry.CreateKey(winKey);
                _registry.SetValue(winKey, "UserSelectedDefault", 1, RegistryValueKind.DWord);
                _registry.SetValue(winKey, "LegacyDefaultPrinterMode", 1, RegistryValueKind.DWord);
                policyApplied = true;
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "0x0000007c":
                action = "Set CopyFilesPolicy to allow client-side driver copy";
                _registry.CreateKey(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers");
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "CopyFilesPolicy", 1, RegistryValueKind.DWord);
                policyApplied = true;
                break;

            case "0x0000007e":
                action = "Re-register printui/prntvpt, restore mscms.dll, recompile prnprov.mof";
                RegisterSpoolerComponents();
                string sys32Mscms = Path.Combine(sysRoot, "System32", "mscms.dll");
                string driverMscms = Path.Combine(sysRoot, "System32", "spool", "drivers", "x64", "3", "mscms.dll");
                if (_fileSystem.FileExists(sys32Mscms))
                {
                    string? dir = Path.GetDirectoryName(driverMscms);
                    if (!string.IsNullOrEmpty(dir)) _fileSystem.CreateDirectory(dir);
                    _fileSystem.CopyFile(sys32Mscms, driverMscms, overwrite: true);
                }
                policyApplied = true;
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "0x00000bcb":
                action = "Configure Point & Print non-admin installation & suppress elevation prompt";
                string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
                _registry.CreateKey(pnpKey);
                _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 0, RegistryValueKind.DWord);
                _registry.SetValue(pnpKey, "NoWarningNoElevationOnInstall", 1, RegistryValueKind.DWord);
                _registry.SetValue(pnpKey, "UpdatePromptSettings", 2, RegistryValueKind.DWord);
                policyApplied = true;
                break;

            case "0x00000002":
                action = "Ensure 64-bit spool driver directories and run pnputil scan-devices";
                _fileSystem.CreateDirectory(Path.Combine(sysRoot, "System32", "spool", "drivers", "x64", "3"));
                _fileSystem.CreateDirectory(Path.Combine(sysRoot, "System32", "spool", "prtprocs", "x64"));
                _registry.CreateKey(@"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64");
                _registry.SetValue(@"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64", "Directory", "W32X64", RegistryValueKind.String);
                _processRunner.Run("pnputil.exe", "/scan-devices");
                policyApplied = true;
                break;

            case "0x00000006":
                action = "Clean corrupt spool handles and restart spooler";
                PurgeSpoolerQueue();
                policyApplied = true;
                servicesRestarted = true;
                break;

            case "0x00000057":
                action = "Reset corrupt connections and restore standard DefaultSpoolDirectory";
                string connectionsKey = @"HKCU\Printers\Connections";
                if (_registry.KeyExists(connectionsKey))
                {
                    _registry.DeleteKey(connectionsKey, recursive: true);
                }
                string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
                _registry.CreateKey(printKey);
                _registry.SetValue(printKey, "DefaultSpoolDirectory", Path.Combine(sysRoot, "System32", "spool", "PRINTERS"), RegistryValueKind.String);
                policyApplied = true;
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "0x000003e3":
                action = "Purge stuck spool files and restart spooler";
                PurgeSpoolerQueue();
                policyApplied = true;
                servicesRestarted = true;
                break;

            case "spoolercrash":
                action = "Complete spool purge, apply SYSTEM/Admin icacls permissions, and re-link RPCSS";
                PurgeSpoolerQueue();
                string spoolPath = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
                _processRunner.Run("icacls.exe", $"\"{spoolPath}\" /grant \"SYSTEM:(OI)(CI)F\" \"Administrators:(OI)(CI)F\" /T /C /Q");
                _processRunner.Run("sc.exe", "config spooler depend= RPCSS start= auto");
                policyApplied = true;
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "neportconflict":
                action = "Reset stale NeXX printer port bindings";
                ResetNePortBindings();
                policyApplied = true;
                break;

            case "refreshconnections":
                action = "Restart Spooler to refresh mapped network printer connections";
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                policyApplied = true;
                servicesRestarted = true;
                break;

            default:
                action = "Unknown error code";
                policyApplied = false;
                break;
        }

        bool success = policyApplied;
        return new PrinterRemediationResult(errorCode, action, policyApplied, servicesRestarted, success, $"Remediation for '{errorCode}' executed.");
    }
}
