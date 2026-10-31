namespace IToolkit.Core.Services.Connectivity;

using System.Text.RegularExpressions;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Utilities;

/// <summary>
/// Pillar 3: Print Spooler management, Point &amp; Print policies, and 12-error-code catalog implementation in pure C# .NET 10.0 LTS (win-x64).
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
    private readonly INetworkService? _networkService;

    public static readonly string[] SpoolerProcessNames = { "spoolsv" };

    public static readonly string[] SupportedCatalogErrorCodes =
    {
        "0x0000011b", "0x00000709", "0x0000007c", "0x0000007e",
        "0x00000bcb", "0x00000002", "0x00000006", "0x00000057",
        "0x000003e3", "SpoolerCrash", "NePortConflict", "RefreshConnections"
    };

    public static readonly string[] SupportedGranularTokens =
    {
        "RpcAuthnLevel", "RemoteRpcEndPoint", "RpcProtocols", "SpoolerHealth",
        "PointAndPrintAdmin", "PointAndPrintPrompts", "RpcNamedPipe", "DefaultPrinterKey",
        "CopyFilesPolicy", "SpoolerDLLs", "DriverStoreRepair", "SpoolerHandles",
        "DriverConfig", "ClearStalledJobs", "SpoolerCrash", "SpoolerQueue",
        "NePorts", "RefreshConnections"
    };

    private static readonly HashSet<string> GranularTokenSet = new(SupportedGranularTokens, StringComparer.OrdinalIgnoreCase);

    private static readonly Regex UncServerRegex = new(@"^\\\\([^\\]+)", RegexOptions.Compiled);

    public PrinterService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        AtomicRegistryService atomicRegistry,
        ProcessLockGuard processLockGuard,
        IWmiService? wmi = null,
        IActivityLogger? logger = null,
        INetworkService? network = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _atomicRegistry = atomicRegistry ?? throw new ArgumentNullException(nameof(atomicRegistry));
        _processLockGuard = processLockGuard ?? throw new ArgumentNullException(nameof(processLockGuard));
        _wmi = wmi;
        _logger = logger;
        _networkService = network;
    }

    private string GetSystemRoot()
    {
        string? winDir = Environment.GetEnvironmentVariable("SystemRoot");
        return !string.IsNullOrEmpty(winDir) ? winDir : @"C:\Windows";
    }

    public IReadOnlyList<string> GetSupportedErrorCodes() => SupportedCatalogErrorCodes;

    public IReadOnlyList<string> GetSupportedGranularTokens() => SupportedGranularTokens;

    private string? EnsureKeyBackup(string keyPath, ISet<string> backedUpKeys, List<string> backupPaths)
    {
        if (string.IsNullOrWhiteSpace(keyPath)) return null;

        try
        {
            string standardPath = RegistryPathNormalizer.ToStandardFormat(keyPath);
            if (backedUpKeys.Add(standardPath))
            {
                string backupPath = _atomicRegistry.ExportKeyBackup(standardPath);
                if (!string.IsNullOrWhiteSpace(backupPath))
                {
                    backupPaths.Add(backupPath);
                    _logger?.LogInfo(nameof(PrinterService), $"Pre-mutation registry backup exported for '{standardPath}': {backupPath}");
                    return backupPath;
                }
            }
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(nameof(PrinterService), $"Failed to export pre-modification backup for '{keyPath}': {ex.Message}");
        }

        return null;
    }

    private bool RestartSpoolerService()
    {
        _logger?.LogInfo(nameof(PrinterService), "Restarting Print Spooler service...");
        _processRunner.Run("net", "stop spooler /y");
        _processLockGuard.EnsureProcessesClosed(SpoolerProcessNames, TimeSpan.FromSeconds(2));
        var res = _processRunner.Run("net", "start spooler");
        bool restarted = res.ExitCode == 0;
        _logger?.LogInfo(nameof(PrinterService), $"Print Spooler restarted: {restarted}");
        return restarted;
    }

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

        try
        {
            _atomicRegistry.ExportKeyBackup(portsKey);
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(nameof(PrinterService), $"Pre-mutation backup failed for '{portsKey}': {ex.Message}");
        }

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
        try
        {
            _atomicRegistry.ExportKeyBackup(printControlKey);
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(nameof(PrinterService), $"Pre-mutation backup failed for '{printControlKey}': {ex.Message}");
        }
        _registry.CreateKey(printControlKey);
        _registry.SetValue(printControlKey, "RpcAuthnLevelPrivacyEnabled", rpcPrivacy, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        try
        {
            _atomicRegistry.ExportKeyBackup(pnpKey);
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(nameof(PrinterService), $"Pre-mutation backup failed for '{pnpKey}': {ex.Message}");
        }
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", restrictAdmin, RegistryValueKind.DWord);

        _processRunner.Run("net", "stop spooler /y");
        _processRunner.Run("net", "start spooler");
        return true;
    }

    public BatchPrinterRemediationResult RemediateAll() => RemediateRole(PrinterRemediationRole.Both);

    public BatchPrinterRemediationResult RemediateRole(PrinterRemediationRole role)
    {
        _logger?.LogInfo(nameof(PrinterService), $"Starting batch printer remediation for role '{role}'...");

        IReadOnlyList<string> actionSequence = role switch
        {
            PrinterRemediationRole.Server => new[]
            {
                "RpcAuthnLevel",
                "RemoteRpcEndPoint",
                "RpcProtocols",
                "SpoolerHealth",
                "SpoolerDLLs",
                "DriverStoreRepair",
                "SpoolerHandles",
                "ClearStalledJobs",
                "SpoolerCrash"
            },
            PrinterRemediationRole.Client => new[]
            {
                "PointAndPrintAdmin",
                "PointAndPrintPrompts",
                "RpcNamedPipe",
                "DefaultPrinterKey",
                "CopyFilesPolicy",
                "SpoolerDLLs",
                "DriverStoreRepair",
                "SpoolerHandles",
                "DriverConfig",
                "ClearStalledJobs",
                "SpoolerQueue",
                "NePorts",
                "RefreshConnections"
            },
            PrinterRemediationRole.Both => new[]
            {
                "RpcAuthnLevel",
                "RemoteRpcEndPoint",
                "RpcProtocols",
                "SpoolerHealth",
                "PointAndPrintAdmin",
                "PointAndPrintPrompts",
                "RpcNamedPipe",
                "DefaultPrinterKey",
                "CopyFilesPolicy",
                "SpoolerDLLs",
                "DriverStoreRepair",
                "SpoolerHandles",
                "DriverConfig",
                "ClearStalledJobs",
                "SpoolerCrash",
                "NePorts",
                "RefreshConnections"
            },
            _ => throw new ArgumentOutOfRangeException(nameof(role), role, $"Unsupported printer remediation role: {role}")
        };

        var results = new List<PrinterRemediationResult>();
        var backupPaths = new List<string>();
        var backedUpKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var actionName in actionSequence)
        {
            try
            {
                var actionResult = ExecuteGranularAction(actionName, backedUpKeys, backupPaths, isBatch: true);
                results.Add(actionResult);
            }
            catch (Exception ex)
            {
                _logger?.LogError(nameof(PrinterService), $"Error executing granular action '{actionName}': {ex.Message}");
                results.Add(new PrinterRemediationResult(actionName, $"Failed executing {actionName}", false, false, false, ex.Message));
            }
        }

        // Consolidated Spooler restart at completion of batch
        bool spoolerRestarted = RestartSpoolerService();

        bool overallSuccess = results.All(r => r.Success) && spoolerRestarted;
        string message = overallSuccess
            ? $"Batch remediation for role '{role}' completed successfully: {results.Count} actions applied, {backupPaths.Count} registry backup(s) generated."
            : $"Batch remediation for role '{role}' completed with warnings: {results.Count(r => !r.Success)} failed action(s).";

        _logger?.LogInfo(nameof(PrinterService), message);

        return new BatchPrinterRemediationResult(
            role,
            actionSequence,
            results,
            backupPaths,
            spoolerRestarted,
            overallSuccess,
            message);
    }

    private PrinterRemediationResult ExecuteGranularAction(
        string actionName,
        ISet<string> backedUpKeys,
        List<string> backupPaths,
        bool isBatch)
    {
        string sysRoot = GetSystemRoot();
        string spoolPrinters = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");

        switch (actionName.ToLowerInvariant())
        {
            case "rpcauthnlevel":
                EnsureKeyBackup(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", backedUpKeys, backupPaths);
                _registry.CreateKey(@"HKLM\SYSTEM\CurrentControlSet\Control\Print");
                _registry.SetValue(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled", 0, RegistryValueKind.DWord);
                return new PrinterRemediationResult("RpcAuthnLevel", "Disable RPC privacy requirement (RpcAuthnLevelPrivacyEnabled=0)", true, false, true, "Disabled RPC privacy requirement.", backupPaths.LastOrDefault(), backupPaths);

            case "remoterpcendpoint":
                EnsureKeyBackup(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", backedUpKeys, backupPaths);
                _registry.CreateKey(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers");
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "RegisterSpoolerRemoteRpcEndPoint", 1, RegistryValueKind.DWord);
                return new PrinterRemediationResult("RemoteRpcEndPoint", "Register Spooler remote RPC endpoint (RegisterSpoolerRemoteRpcEndPoint=1)", true, false, true, "Registered remote RPC endpoint.", backupPaths.LastOrDefault(), backupPaths);

            case "rpcprotocols":
                string rpcKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC";
                EnsureKeyBackup(rpcKey, backedUpKeys, backupPaths);
                _registry.CreateKey(rpcKey);
                _registry.SetValue(rpcKey, "RpcUseNamedPipeProtocol", 1, RegistryValueKind.DWord);
                _registry.SetValue(rpcKey, "RpcProtocols", 7, RegistryValueKind.DWord);
                return new PrinterRemediationResult("RpcProtocols", "Configure RPC protocols (RpcUseNamedPipeProtocol=1, RpcProtocols=7)", true, false, true, "Configured RPC protocols.", backupPaths.LastOrDefault(), backupPaths);

            case "spoolerhealth":
                if (!_fileSystem.DirectoryExists(spoolPrinters)) _fileSystem.CreateDirectory(spoolPrinters);
                _processRunner.Run("icacls.exe", $"\"{spoolPrinters}\" /grant \"SYSTEM:(OI)(CI)F\" \"Administrators:(OI)(CI)F\" /T /C /Q");
                _processRunner.Run("sc.exe", "config spooler depend= RPCSS start= auto");
                bool shRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("SpoolerHealth", "Verify spool directory, permissions, and RPCSS dependency", true, shRestarted, true, "Configured spooler health.");

            case "pointandprintadmin":
                string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
                EnsureKeyBackup(pnpKey, backedUpKeys, backupPaths);
                _registry.CreateKey(pnpKey);
                _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 0, RegistryValueKind.DWord);
                return new PrinterRemediationResult("PointAndPrintAdmin", "Allow non-admin Point and Print driver installation", true, false, true, "Allowed non-admin Point & Print driver install.", backupPaths.LastOrDefault(), backupPaths);

            case "pointandprintprompts":
                string pnpPKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
                EnsureKeyBackup(pnpPKey, backedUpKeys, backupPaths);
                _registry.CreateKey(pnpPKey);
                _registry.SetValue(pnpPKey, "NoWarningNoElevationOnInstall", 1, RegistryValueKind.DWord);
                _registry.SetValue(pnpPKey, "UpdatePromptSettings", 2, RegistryValueKind.DWord);
                return new PrinterRemediationResult("PointAndPrintPrompts", "Configure Point and Print elevation prompts and warning bypasses", true, false, true, "Configured Point & Print prompt bypasses.", backupPaths.LastOrDefault(), backupPaths);

            case "rpcnamedpipe":
                string rnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC";
                EnsureKeyBackup(rnpKey, backedUpKeys, backupPaths);
                _registry.CreateKey(rnpKey);
                _registry.SetValue(rnpKey, "RpcUseNamedPipeProtocol", 1, RegistryValueKind.DWord);
                return new PrinterRemediationResult("RpcNamedPipe", "Force RPC over Named Pipes (RpcUseNamedPipeProtocol=1)", true, false, true, "Forced RPC over Named Pipes.", backupPaths.LastOrDefault(), backupPaths);

            case "defaultprinterkey":
                string winKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows";
                EnsureKeyBackup(winKey, backedUpKeys, backupPaths);
                _registry.CreateKey(winKey);
                _registry.SetValue(winKey, "UserSelectedDefault", 1, RegistryValueKind.DWord);
                _registry.SetValue(winKey, "LegacyDefaultPrinterMode", 1, RegistryValueKind.DWord);
                return new PrinterRemediationResult("DefaultPrinterKey", "Configure default printer mode (UserSelectedDefault=1, LegacyDefaultPrinterMode=1)", true, false, true, "Configured default printer mode.", backupPaths.LastOrDefault(), backupPaths);

            case "copyfilespolicy":
                string pKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers";
                EnsureKeyBackup(pKey, backedUpKeys, backupPaths);
                _registry.CreateKey(pKey);
                _registry.SetValue(pKey, "CopyFilesPolicy", 1, RegistryValueKind.DWord);
                return new PrinterRemediationResult("CopyFilesPolicy", "Set CopyFilesPolicy to allow client-side driver copy", true, false, true, "Configured CopyFilesPolicy.", backupPaths.LastOrDefault(), backupPaths);

            case "spoolerdlls":
                RegisterSpoolerComponents();
                string sys32Mscms = Path.Combine(sysRoot, "System32", "mscms.dll");
                string driverMscms = Path.Combine(sysRoot, "System32", "spool", "drivers", "x64", "3", "mscms.dll");
                if (_fileSystem.FileExists(sys32Mscms))
                {
                    string? dir = Path.GetDirectoryName(driverMscms);
                    if (!string.IsNullOrEmpty(dir)) _fileSystem.CreateDirectory(dir);
                    _fileSystem.CopyFile(sys32Mscms, driverMscms, overwrite: true);
                }
                bool dllRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("SpoolerDLLs", "Re-register printui/prntvpt, restore mscms.dll, recompile prnprov.mof", true, dllRestarted, true, "Re-registered Spooler components.");

            case "driverstorerepair":
                _fileSystem.CreateDirectory(Path.Combine(sysRoot, "System32", "spool", "drivers", "x64", "3"));
                _fileSystem.CreateDirectory(Path.Combine(sysRoot, "System32", "spool", "prtprocs", "x64"));
                string dirKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Directory";
                EnsureKeyBackup(dirKey, backedUpKeys, backupPaths);
                _registry.CreateKey(dirKey);
                _registry.SetValue(dirKey, "Directory", "W32X64", RegistryValueKind.String);

                string envKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64";
                EnsureKeyBackup(envKey, backedUpKeys, backupPaths);
                _registry.CreateKey(envKey);
                _registry.SetValue(envKey, "Directory", "W32X64", RegistryValueKind.String);

                _processRunner.Run("pnputil.exe", "/scan-devices");
                return new PrinterRemediationResult("DriverStoreRepair", "Ensure 64-bit spool driver directories and run pnputil scan-devices", true, false, true, "Repaired driver store directories.", backupPaths.LastOrDefault(), backupPaths);

            case "spoolerhandles":
                if (_fileSystem.DirectoryExists(spoolPrinters))
                {
                    var files = _fileSystem.EnumerateFiles(spoolPrinters, "*", SearchOption.TopDirectoryOnly);
                    foreach (var file in files)
                    {
                        string ext = Path.GetExtension(file);
                        if (ext.Equals(".tmp", StringComparison.OrdinalIgnoreCase) ||
                            ext.Equals(".shd", StringComparison.OrdinalIgnoreCase) ||
                            ext.Equals(".spl", StringComparison.OrdinalIgnoreCase))
                        {
                            try { _fileSystem.DeleteFile(file); } catch { }
                        }
                    }
                }
                bool hRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("SpoolerHandles", "Clean corrupt spool handles and restart spooler", true, hRestarted, true, "Cleaned temporary files and spool handles.");

            case "driverconfig":
                string connKey = @"HKCU\Printers\Connections";
                if (_registry.KeyExists(connKey))
                {
                    EnsureKeyBackup(connKey, backedUpKeys, backupPaths);
                    _registry.DeleteKey(connKey, recursive: true);
                }
                string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
                EnsureKeyBackup(printKey, backedUpKeys, backupPaths);
                _registry.CreateKey(printKey);
                _registry.SetValue(printKey, "DefaultSpoolDirectory", spoolPrinters, RegistryValueKind.String);
                bool dcRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("DriverConfig", "Reset corrupt connections and restore standard DefaultSpoolDirectory", true, dcRestarted, true, "Reset connections and default spool directory.", backupPaths.LastOrDefault(), backupPaths);

            case "clearstalledjobs":
                int purged = 0;
                if (_fileSystem.DirectoryExists(spoolPrinters))
                {
                    var files = _fileSystem.EnumerateFiles(spoolPrinters, "*", SearchOption.TopDirectoryOnly);
                    foreach (var file in files)
                    {
                        string ext = Path.GetExtension(file);
                        if (ext.Equals(".spl", StringComparison.OrdinalIgnoreCase) || ext.Equals(".shd", StringComparison.OrdinalIgnoreCase))
                        {
                            try { _fileSystem.DeleteFile(file); purged++; } catch { }
                        }
                    }
                }
                bool csRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("ClearStalledJobs", "Purge stuck spool files and restart spooler", true, csRestarted, true, $"Purged {purged} stalled print files.");

            case "spoolercrash":
                PurgeSpoolerQueue();
                _processRunner.Run("icacls.exe", $"\"{spoolPrinters}\" /grant \"SYSTEM:(OI)(CI)F\" \"Administrators:(OI)(CI)F\" /T /C /Q");
                _processRunner.Run("sc.exe", "config spooler depend= RPCSS start= auto");
                bool scRestarted = !isBatch && RestartSpoolerService();
                return new PrinterRemediationResult("SpoolerCrash", "Complete spool purge, apply SYSTEM/Admin icacls permissions, and re-link RPCSS", true, scRestarted, true, "Recovered Spooler from crash state.");

            case "spoolerqueue":
                var qRes = PurgeSpoolerQueue();
                return new PrinterRemediationResult("SpoolerQueue", "Purge Print Spooler queue", qRes.Success, qRes.SpoolerRestarted, qRes.Success, qRes.Message);

            case "neports":
                string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
                if (_registry.KeyExists(portsKey))
                {
                    EnsureKeyBackup(portsKey, backedUpKeys, backupPaths);
                }
                int cleaned = ResetNePortBindings();
                return new PrinterRemediationResult("NePorts", "Reset stale NeXX printer port bindings", true, false, true, $"Reset {cleaned} orphaned NeXX port bindings.", backupPaths.LastOrDefault(), backupPaths);

            case "refreshconnections":
                var rRes = ResetPrinterConnections();
                return new PrinterRemediationResult("RefreshConnections", "Restart Spooler to refresh mapped network printer connections", rRes.Success, true, rRes.Success, rRes.Message);

            default:
                return new PrinterRemediationResult(actionName, "Unknown granular action", false, false, false, $"Granular action '{actionName}' is not recognized.");
        }
    }

    public PrinterRemediationResult RemediatePrinterError(string errorCode)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        _logger?.LogInfo(nameof(PrinterService), $"Remediating printer error: {errorCode}...");

        string token = errorCode.Trim();
        string lower = token.ToLowerInvariant();

        // 1. Role Batch Alias Routing
        if (lower is "allserver" or "server")
        {
            var bRes = RemediateRole(PrinterRemediationRole.Server);
            return new PrinterRemediationResult(token, "Server Role Batch Remediation (9 actions executed)", bRes.Success, bRes.SpoolerRestarted, bRes.Success, bRes.Message, bRes.BackupPaths.FirstOrDefault(), bRes.BackupPaths);
        }
        if (lower is "allclient" or "client")
        {
            var bRes = RemediateRole(PrinterRemediationRole.Client);
            return new PrinterRemediationResult(token, "Client Role Batch Remediation (13 actions executed)", bRes.Success, bRes.SpoolerRestarted, bRes.Success, bRes.Message, bRes.BackupPaths.FirstOrDefault(), bRes.BackupPaths);
        }
        if (lower is "all" or "both" or "allboth")
        {
            var bRes = RemediateRole(PrinterRemediationRole.Both);
            return new PrinterRemediationResult(token, "Combined Role Batch Remediation (17 actions executed)", bRes.Success, bRes.SpoolerRestarted, bRes.Success, bRes.Message, bRes.BackupPaths.FirstOrDefault(), bRes.BackupPaths);
        }

        var backedUpKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var backupPaths = new List<string>();

        // 2. Granular Token Routing (check if it matches granular token and NOT one of the 12 canonical error codes)
        if (GranularTokenSet.Contains(token) && !IsCanonicalErrorCode(lower))
        {
            return ExecuteGranularAction(token, backedUpKeys, backupPaths, isBatch: false);
        }

        // 3. 12 Canonical Error Codes Routing
        string sysRoot = GetSystemRoot();
        bool policyApplied = false;
        bool servicesRestarted = false;
        string action = "";

        switch (lower)
        {
            case "0x0000011b":
                action = "Disable RPC privacy requirement & register remote RPC endpoint";
                EnsureKeyBackup(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", backedUpKeys, backupPaths);
                _registry.CreateKey(@"HKLM\SYSTEM\CurrentControlSet\Control\Print");
                _registry.SetValue(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled", 0, RegistryValueKind.DWord);

                EnsureKeyBackup(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", backedUpKeys, backupPaths);
                _registry.CreateKey(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers");
                _registry.SetValue(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "RegisterSpoolerRemoteRpcEndPoint", 1, RegistryValueKind.DWord);

                policyApplied = true;
                _processRunner.Run("net", "stop spooler /y");
                _processRunner.Run("net", "start spooler");
                servicesRestarted = true;
                break;

            case "0x00000709":
                action = "Force RPC over Named Pipes & preserve default printer mode";
                string rpcKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC";
                EnsureKeyBackup(rpcKey, backedUpKeys, backupPaths);
                _registry.CreateKey(rpcKey);
                _registry.SetValue(rpcKey, "RpcUseNamedPipeProtocol", 1, RegistryValueKind.DWord);
                _registry.SetValue(rpcKey, "RpcProtocols", 7, RegistryValueKind.DWord);

                string winKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows";
                EnsureKeyBackup(winKey, backedUpKeys, backupPaths);
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
                string pKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers";
                EnsureKeyBackup(pKey, backedUpKeys, backupPaths);
                _registry.CreateKey(pKey);
                _registry.SetValue(pKey, "CopyFilesPolicy", 1, RegistryValueKind.DWord);
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
                EnsureKeyBackup(pnpKey, backedUpKeys, backupPaths);
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

                string envDirKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Directory";
                EnsureKeyBackup(envDirKey, backedUpKeys, backupPaths);
                _registry.CreateKey(envDirKey);
                _registry.SetValue(envDirKey, "Directory", "W32X64", RegistryValueKind.String);

                string envKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64";
                EnsureKeyBackup(envKey, backedUpKeys, backupPaths);
                _registry.CreateKey(envKey);
                _registry.SetValue(envKey, "Directory", "W32X64", RegistryValueKind.String);

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
                    EnsureKeyBackup(connectionsKey, backedUpKeys, backupPaths);
                    _registry.DeleteKey(connectionsKey, recursive: true);
                }
                string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
                EnsureKeyBackup(printKey, backedUpKeys, backupPaths);
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
                string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
                if (_registry.KeyExists(portsKey))
                {
                    EnsureKeyBackup(portsKey, backedUpKeys, backupPaths);
                }
                ResetNePortBindings();
                policyApplied = true;
                break;

            case "refreshconnections":
                action = "Restart Spooler to refresh mapped network printer connections";
                ResetPrinterConnections();
                policyApplied = true;
                servicesRestarted = true;
                break;

            default:
                action = "Unknown error code";
                policyApplied = false;
                break;
        }

        bool success = policyApplied;
        return new PrinterRemediationResult(
            errorCode,
            action,
            policyApplied,
            servicesRestarted,
            success,
            $"Remediation for '{errorCode}' executed.",
            backupPaths.FirstOrDefault(),
            backupPaths);
    }

    private static bool IsCanonicalErrorCode(string lowerCode) => lowerCode switch
    {
        "0x0000011b" or "0x00000709" or "0x0000007c" or "0x0000007e" or
        "0x00000bcb" or "0x00000002" or "0x00000006" or "0x0000057" or "0x00000057" or
        "0x000003e3" or "spoolercrash" or "neportconflict" or "refreshconnections" => true,
        _ => false
    };

    public PrinterConnectionResetResult ResetPrinterConnections(bool all = true, string? printerName = null)
    {
        _logger?.LogInfo(nameof(PrinterService), $"Resetting printer connections (all={all}, printerName='{printerName ?? "all"}')...");

        var candidatePrinters = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var details = new List<string>();
        int reconnected = 0;
        int staleRemoved = 0;

        // 1. Discovery Phase
        if (!string.IsNullOrWhiteSpace(printerName))
        {
            candidatePrinters.Add(printerName.Trim());
        }
        else
        {
            // Source A: WMI Win32_Printer
            if (_wmi != null)
            {
                try
                {
                    var wmiPrinters = _wmi.Query("SELECT Name FROM Win32_Printer");
                    foreach (var p in wmiPrinters)
                    {
                        if (p.TryGetValue("Name", out var nameVal) && nameVal != null)
                        {
                            string pName = nameVal.ToString()!.Trim();
                            if (pName.StartsWith(@"\\", StringComparison.Ordinal))
                            {
                                candidatePrinters.Add(pName);
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger?.LogWarning(nameof(PrinterService), $"Failed to query Win32_Printer via WMI: {ex.Message}");
                }
            }

            // Source B: HKCU\Printers\Connections
            string connKey = @"HKCU\Printers\Connections";
            if (_registry.KeyExists(connKey))
            {
                try
                {
                    var subKeys = _registry.GetSubKeyNames(connKey);
                    foreach (var sk in subKeys)
                    {
                        string convertedName;
                        if (sk.StartsWith(",,", StringComparison.Ordinal))
                        {
                            convertedName = @"\\" + sk[2..].Replace(',', '\\');
                        }
                        else if (sk.StartsWith(@"\\", StringComparison.Ordinal))
                        {
                            convertedName = sk;
                        }
                        else
                        {
                            convertedName = @"\\" + sk.TrimStart(',').Replace(',', '\\');
                        }

                        if (!string.IsNullOrWhiteSpace(convertedName))
                        {
                            candidatePrinters.Add(convertedName);
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger?.LogWarning(nameof(PrinterService), $"Failed to enumerate {connKey}: {ex.Message}");
                }
            }
        }

        int discovered = candidatePrinters.Count;
        if (discovered == 0)
        {
            _logger?.LogInfo(nameof(PrinterService), "No network UNC printers discovered.");
            return new PrinterConnectionResetResult(0, 0, 0, details, true, "No network printer connections found to reset.");
        }

        // 2. Reachability & Remediation Phase
        foreach (var printer in candidatePrinters)
        {
            string server = string.Empty;
            var match = UncServerRegex.Match(printer);
            if (match.Success)
            {
                server = match.Groups[1].Value;
            }

            bool isReachable = false;
            if (string.IsNullOrWhiteSpace(server))
            {
                // Local printer: inherently reachable
                isReachable = true;
            }
            else if (_networkService != null)
            {
                try
                {
                    // Primary: Ping host (ICMP echo)
                    bool pingOk = _networkService.PingHost(server, 2000);
                    if (pingOk)
                    {
                        isReachable = true;
                    }
                    else
                    {
                        // Secondary: Fallback to TCP port 445 (SMB)
                        isReachable = _networkService.TestPort(server, 445, 2000);
                    }
                }
                catch (Exception ex)
                {
                    _logger?.LogWarning(nameof(PrinterService), $"Reachability test failed for '{server}': {ex.Message}");
                    isReachable = false;
                }
            }
            else
            {
                // Graceful fallback when INetworkService is not available:
                // Treat printer as reachable to avoid destructive removal of legitimate connections
                isReachable = true;
            }

            if (isReachable)
            {
                // Active printer: refresh connection
                try
                {
                    _processRunner.Run("rundll32.exe", $"printui.dll,PrintUIEntry /in /n \"{printer}\"", timeoutMs: 5000);
                }
                catch
                {
                }
                reconnected++;
                details.Add($"Active: '{printer}' verified reachable on server '{server}'.");
            }
            else
            {
                // Stale printer: server unreachable
                try
                {
                    _processRunner.Run("rundll32.exe", $"printui.dll,PrintUIEntry /dn /n \"{printer}\"", timeoutMs: 5000);
                }
                catch
                {
                }

                // Clean registry keys under HKCU\Printers\Connections
                string connKey = @"HKCU\Printers\Connections";
                if (_registry.KeyExists(connKey))
                {
                    try
                    {
                        _atomicRegistry.ExportKeyBackup(connKey);

                        string serverShare = printer.TrimStart('\\').Replace('\\', ',');
                        string subKeyName = $",,{serverShare}";
                        string fullSubKey = $@"{connKey}\{subKeyName}";

                        if (_registry.KeyExists(fullSubKey))
                        {
                            _registry.DeleteKey(fullSubKey, recursive: true);
                        }

                        string directSubKey = $@"{connKey}\{printer}";
                        if (_registry.KeyExists(directSubKey))
                        {
                            _registry.DeleteKey(directSubKey, recursive: true);
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger?.LogWarning(nameof(PrinterService), $"Failed to clean registry connection for '{printer}': {ex.Message}");
                    }
                }

                staleRemoved++;
                details.Add($"Stale: '{printer}' removed (server '{server}' unreachable).");
            }
        }

        // 3. Restart Spooler to apply connection state changes
        _processRunner.Run("net", "stop spooler /y");
        _processRunner.Run("net", "start spooler");

        string summary = $"Printer connections reset complete: {discovered} discovered, {reconnected} reconnected, {staleRemoved} stale removed.";
        _logger?.LogSuccess(nameof(PrinterService), summary);

        return new PrinterConnectionResetResult(discovered, reconnected, staleRemoved, details, true, summary);
    }

    public PointAndPrintPolicyAuditResult AuditPointAndPrintPolicy()
    {
        _logger?.LogInfo(nameof(PrinterService), "Auditing Point & Print registry policies and PrintNightmare CVE-2021-1678 posture...");

        // 1. Audit RpcAuthnLevelPrivacyEnabled
        string printControlKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        bool rpcAuthnEnabled = true;
        if (_registry.KeyExists(printControlKey) && _registry.ValueExists(printControlKey, "RpcAuthnLevelPrivacyEnabled"))
        {
            int rpcVal = _registry.GetValue<int>(printControlKey, "RpcAuthnLevelPrivacyEnabled");
            rpcAuthnEnabled = rpcVal != 0;
        }

        // 2. Audit RestrictDriverInstallationToAdministrators & Prompts
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        bool restrictAdmin = true;
        bool noWarning = false;
        int updatePrompt = 0;

        if (_registry.KeyExists(pnpKey))
        {
            if (_registry.ValueExists(pnpKey, "RestrictDriverInstallationToAdministrators"))
            {
                int adminVal = _registry.GetValue<int>(pnpKey, "RestrictDriverInstallationToAdministrators");
                restrictAdmin = adminVal != 0;
            }

            if (_registry.ValueExists(pnpKey, "NoWarningNoElevationOnInstall"))
            {
                int warnVal = _registry.GetValue<int>(pnpKey, "NoWarningNoElevationOnInstall");
                noWarning = warnVal != 0;
            }

            if (_registry.ValueExists(pnpKey, "UpdatePromptSettings"))
            {
                updatePrompt = _registry.GetValue<int>(pnpKey, "UpdatePromptSettings");
            }
        }

        // 3. Evaluate CVE-2021-1678 and Vulnerability Posture
        bool isVulnerableToCVE20211678 = !rpcAuthnEnabled;
        var recommendations = new List<string>();

        if (isVulnerableToCVE20211678)
        {
            recommendations.Add("RpcAuthnLevelPrivacyEnabled is 0 (Disabled). Vulnerable to CVE-2021-1678 / PrintNightmare. Set RpcAuthnLevelPrivacyEnabled to 1 to enforce RPC packet privacy.");
        }

        if (!restrictAdmin)
        {
            recommendations.Add("RestrictDriverInstallationToAdministrators is 0 (Disabled). Non-administrators can install print drivers. Set RestrictDriverInstallationToAdministrators to 1.");
        }

        if (noWarning)
        {
            recommendations.Add("NoWarningNoElevationOnInstall is enabled. Driver installation warning and elevation prompts are suppressed.");
        }

        string postureDescription;
        if (isVulnerableToCVE20211678 || !restrictAdmin)
        {
            postureDescription = "Vulnerable (Relaxed / Compatibility Mode): System is susceptible to PrintNightmare CVE-2021-1678 or unauthorized non-admin driver installation.";
        }
        else
        {
            postureDescription = "Secure (Strict Admin Only): RpcAuthnLevelPrivacyEnabled and RestrictDriverInstallationToAdministrators are properly enforced.";
        }

        _logger?.LogSuccess(nameof(PrinterService), $"Point & Print Policy Audit completed: {postureDescription}");

        return new PointAndPrintPolicyAuditResult(
            rpcAuthnEnabled,
            restrictAdmin,
            noWarning,
            updatePrompt,
            isVulnerableToCVE20211678,
            postureDescription,
            recommendations);
    }

    public SpoolerServiceStatus GetSpoolerStatus()
    {
        _logger?.LogInfo(nameof(PrinterService), "Querying Print Spooler service and queue health status...");

        bool isRunning = false;
        string serviceStatus = "Stopped";
        string startupType = "Automatic";
        int? pid = null;

        // 1. Query Service via WMI if available
        if (_wmi != null)
        {
            try
            {
                var svc = _wmi.QueryFirst("SELECT State, StartMode, ProcessId FROM Win32_Service WHERE Name='Spooler'");
                if (svc != null)
                {
                    if (svc.TryGetValue("State", out var stateVal) && stateVal != null)
                    {
                        serviceStatus = stateVal.ToString()!;
                        isRunning = serviceStatus.Equals("Running", StringComparison.OrdinalIgnoreCase);
                    }
                    if (svc.TryGetValue("StartMode", out var modeVal) && modeVal != null)
                    {
                        startupType = modeVal.ToString()!;
                    }
                    if (svc.TryGetValue("ProcessId", out var pidVal) && pidVal != null && int.TryParse(pidVal.ToString(), out int parsedPid) && parsedPid > 0)
                    {
                        pid = parsedPid;
                    }
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"Failed to query Spooler service via WMI: {ex.Message}");
            }
        }

        // 2. Fallback to ProcessRunner / sc.exe query spooler if WMI did not resolve
        if (serviceStatus == "Stopped" && !isRunning)
        {
            try
            {
                var scRes = _processRunner.Run("sc.exe", "query spooler");
                if (scRes.ExitCode == 0 && !string.IsNullOrWhiteSpace(scRes.StandardOutput))
                {
                    if (scRes.StandardOutput.Contains("RUNNING", StringComparison.OrdinalIgnoreCase))
                    {
                        isRunning = true;
                        serviceStatus = "Running";
                    }
                    else if (scRes.StandardOutput.Contains("PAUSED", StringComparison.OrdinalIgnoreCase))
                    {
                        serviceStatus = "Paused";
                    }
                    else if (scRes.StandardOutput.Contains("STOPPED", StringComparison.OrdinalIgnoreCase))
                    {
                        serviceStatus = "Stopped";
                    }
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"Failed to query sc.exe: {ex.Message}");
            }

            // Check active spoolsv process
            try
            {
                var procs = _processRunner.GetProcessesByName("spoolsv").ToList();
                if (procs.Count > 0)
                {
                    isRunning = true;
                    if (serviceStatus == "Stopped") serviceStatus = "Running";
                    pid ??= procs[0].Id;
                }
            }
            catch
            {
            }
        }

        // 3. Resolve Spool Directory
        string spoolDir = Path.Combine(GetSystemRoot(), "System32", "spool", "PRINTERS");
        string spoolRegKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
        if (_registry.KeyExists(spoolRegKey) && _registry.ValueExists(spoolRegKey, "DefaultSpoolDirectory"))
        {
            string? customDir = _registry.GetValue<string>(spoolRegKey, "DefaultSpoolDirectory");
            if (!string.IsNullOrWhiteSpace(customDir))
            {
                spoolDir = customDir;
            }
        }

        // 4. Enumerate Queue Files (.spl, .shd, .tmp)
        int pendingJobFileCount = 0;
        long totalQueueSizeBytes = 0;

        if (_fileSystem.DirectoryExists(spoolDir))
        {
            try
            {
                var files = _fileSystem.EnumerateFiles(spoolDir, "*", SearchOption.TopDirectoryOnly);
                foreach (var file in files)
                {
                    string ext = Path.GetExtension(file);
                    if (ext.Equals(".spl", StringComparison.OrdinalIgnoreCase) ||
                        ext.Equals(".shd", StringComparison.OrdinalIgnoreCase) ||
                        ext.Equals(".tmp", StringComparison.OrdinalIgnoreCase))
                    {
                        pendingJobFileCount++;
                        try
                        {
                            totalQueueSizeBytes += _fileSystem.GetFileSize(file);
                        }
                        catch
                        {
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"Failed to enumerate spool directory '{spoolDir}': {ex.Message}");
            }
        }

        bool hasStalledJobs = pendingJobFileCount > 0;
        string summary = $"Spooler status: {serviceStatus} (PID: {pid?.ToString() ?? "N/A"}), Queue: {pendingJobFileCount} file(s), {totalQueueSizeBytes} bytes, Directory: '{spoolDir}'.";
        _logger?.LogSuccess(nameof(PrinterService), summary);

        return new SpoolerServiceStatus(
            isRunning,
            serviceStatus,
            spoolDir,
            pendingJobFileCount,
            totalQueueSizeBytes,
            hasStalledJobs,
            pid,
            startupType,
            summary);
    }

    public PrinterConnectionResetResult ResetAllPrinterConnections() => ResetPrinterConnections(all: true, printerName: null);

    public PrinterConnectionResetResult ResetPrinterConnection(string printerName)
    {
        if (string.IsNullOrWhiteSpace(printerName))
        {
            return new PrinterConnectionResetResult(0, 0, 0, new[] { "Printer name cannot be null or whitespace." }, false, "Invalid printer name.");
        }
        return ResetPrinterConnections(all: false, printerName: printerName.Trim());
    }

    public IEnumerable<PrinterInfo> GetPrinters()
    {
        _logger?.LogInfo(nameof(PrinterService), "Enumerating installed printers via WMI and registry...");
        var printers = new List<PrinterInfo>();

        if (_wmi != null)
        {
            try
            {
                var queryResults = _wmi.Query("SELECT Name, DriverName, PortName, Default, Network, Status, ServerName, ShareName FROM Win32_Printer").ToList();
                if (queryResults.Count == 0)
                {
                    queryResults = _wmi.Query("SELECT Name FROM Win32_Printer").ToList();
                }

                foreach (var row in queryResults)
                {
                    if (row.TryGetValue("Name", out var nameObj) && nameObj != null)
                    {
                        string name = nameObj.ToString()!.Trim();
                        string driver = row.TryGetValue("DriverName", out var drvObj) && drvObj != null ? drvObj.ToString()! : "Generic Windows Printer Driver";
                        string port = row.TryGetValue("PortName", out var portObj) && portObj != null ? portObj.ToString()! : "LPT1:";
                        bool isDefault = row.TryGetValue("Default", out var defObj) && defObj is bool bDef ? bDef : false;
                        bool isNetwork = row.TryGetValue("Network", out var netObj) && netObj is bool bNet ? bNet : name.StartsWith(@"\\", StringComparison.Ordinal);
                        string status = row.TryGetValue("Status", out var statObj) && statObj != null ? statObj.ToString()! : "Ready";
                        string? server = row.TryGetValue("ServerName", out var srvObj) && srvObj != null ? srvObj.ToString() : null;
                        string? share = row.TryGetValue("ShareName", out var shrObj) && shrObj != null ? shrObj.ToString() : null;

                        int jobCount = 0;
                        try
                        {
                            jobCount = GetPrinterJobs(name).Count();
                        }
                        catch { }

                        printers.Add(new PrinterInfo(name, driver, port, isDefault, isNetwork, status, jobCount, server, share));
                    }
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"WMI query for Win32_Printer failed: {ex.Message}");
            }
        }

        if (printers.Count == 0)
        {
            string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
            if (_registry.KeyExists(portsKey))
            {
                string defaultDevice = _registry.GetValue<string>(@"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows", "Device") ?? "";
                string defaultName = defaultDevice.Split(',')[0].Trim();

                foreach (var name in _registry.GetValueNames(portsKey))
                {
                    string portVal = _registry.GetValue<string>(portsKey, name) ?? "";
                    string portName = portVal.Split(',')[0].Trim();
                    bool isDefault = string.Equals(name, defaultName, StringComparison.OrdinalIgnoreCase);
                    bool isNetwork = name.StartsWith(@"\\", StringComparison.Ordinal);
                    printers.Add(new PrinterInfo(name, "Generic Driver", portName, isDefault, isNetwork, "Ready", 0));
                }
            }
        }

        return printers;
    }

    public IEnumerable<PrinterJobInfo> GetPrinterJobs(string printerName)
    {
        if (string.IsNullOrWhiteSpace(printerName)) return Enumerable.Empty<PrinterJobInfo>();
        var jobs = new List<PrinterJobInfo>();

        if (_wmi != null)
        {
            try
            {
                var queryResults = _wmi.Query($"SELECT JobId, Document, Owner, Size, Status, TimeSubmitted FROM Win32_PrintJob WHERE Name LIKE '{printerName.Replace("'", "''")}%'");
                foreach (var row in queryResults)
                {
                    int jobId = row.TryGetValue("JobId", out var idObj) && idObj is int id ? id : (int.TryParse(idObj?.ToString(), out int parsedId) ? parsedId : 0);
                    string doc = row.TryGetValue("Document", out var docObj) && docObj != null ? docObj.ToString()! : "Document";
                    string owner = row.TryGetValue("Owner", out var ownObj) && ownObj != null ? ownObj.ToString()! : "SYSTEM";
                    long size = row.TryGetValue("Size", out var szObj) && szObj is long sz ? sz : (long.TryParse(szObj?.ToString(), out long parsedSz) ? parsedSz : 0);
                    string status = row.TryGetValue("Status", out var stObj) && stObj != null ? stObj.ToString()! : "Spooling";
                    DateTime submitted = DateTime.UtcNow;

                    jobs.Add(new PrinterJobInfo(jobId, doc, owner, size, status, submitted));
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"WMI query for Win32_PrintJob failed for '{printerName}': {ex.Message}");
            }
        }

        return jobs;
    }

    [System.Runtime.InteropServices.DllImport("winspool.drv", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
    private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);

    [System.Runtime.InteropServices.DllImport("winspool.drv", SetLastError = true)]
    private static extern bool SetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int Command);

    [System.Runtime.InteropServices.DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr hPrinter);

    private const int PRINTER_CONTROL_PURGE = 3;

    public bool PurgePrinterQueue(string printerName)
    {
        if (string.IsNullOrWhiteSpace(printerName)) return false;
        _logger?.LogInfo(nameof(PrinterService), $"Purging print jobs specifically for printer '{printerName}'...");

        bool success = false;
        if (OperatingSystem.IsWindows())
        {
            try
            {
                if (OpenPrinter(printerName, out IntPtr hPrinter, IntPtr.Zero))
                {
                    try
                    {
                        success = SetPrinter(hPrinter, 0, IntPtr.Zero, PRINTER_CONTROL_PURGE);
                    }
                    finally
                    {
                        ClosePrinter(hPrinter);
                    }
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(nameof(PrinterService), $"Win32 purge printer queue failed for '{printerName}': {ex.Message}");
            }
        }

        if (_wmi != null)
        {
            try
            {
                int code = _wmi.ExecuteMethod("Win32_Printer", "CancelAllJobs");
                if (code == 0)
                {
                    success = true;
                }
            }
            catch { }
        }

        return success;
    }

    public bool PrintTestPage(string printerName)
    {
        if (string.IsNullOrWhiteSpace(printerName)) return false;
        _logger?.LogInfo(nameof(PrinterService), $"Sending test page to printer '{printerName}'...");

        var result = _processRunner.Run("rundll32.exe", $"printui.dll,PrintUIEntry /k /n \"{printerName}\"");
        return result.ExitCode == 0;
    }

    public bool SetDefaultPrinter(string printerName)
    {
        if (string.IsNullOrWhiteSpace(printerName)) return false;
        _logger?.LogInfo(nameof(PrinterService), $"Setting default printer to '{printerName}'...");

        var result = _processRunner.Run("rundll32.exe", $"printui.dll,PrintUIEntry /y /n \"{printerName}\"");

        string winKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows";
        if (_registry.KeyExists(winKey))
        {
            string existing = _registry.GetValue<string>(winKey, "Device") ?? "";
            string[] parts = existing.Split(',');
            string driverAndPort = parts.Length > 1 ? string.Join(",", parts.Skip(1)) : "winspool,Ne00:";
            _registry.SetValue(winKey, "Device", $"{printerName},{driverAndPort}", RegistryValueKind.String);
        }

        return result.ExitCode == 0;
    }
}
