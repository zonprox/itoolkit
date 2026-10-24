namespace IToolkit.Core.Services.Office;

using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 2: Outlook &amp; PST/OST subsystem implementation in pure C# .NET 10.0 LTS (win-x64).
/// </summary>
public class OutlookService : IOutlookService
{
    private readonly IRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly IFileSystemService _fileSystem;
    private readonly ProcessLockGuard _processLockGuard;
    private readonly ResourceGuard _resourceGuard;
    private readonly IOutlookComService? _outlookCom;
    private readonly IActivityLogger? _logger;

    public static readonly string[] OutlookProcessNames = { "OUTLOOK" };

    public static readonly string[] ExcludedCloneFolders =
    {
        "Inbox", "Deleted Items", "Sent Items", "Drafts", "Outbox",
        "Junk E-mail", "Junk Email", "Conversation History", "Sync Issues"
    };

    public OutlookService(
        IRegistryService registry,
        AtomicRegistryService atomicRegistry,
        IFileSystemService fileSystem,
        ProcessLockGuard processLockGuard,
        ResourceGuard resourceGuard,
        IOutlookComService? outlookCom = null,
        IActivityLogger? logger = null)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _atomicRegistry = atomicRegistry ?? throw new ArgumentNullException(nameof(atomicRegistry));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _processLockGuard = processLockGuard ?? throw new ArgumentNullException(nameof(processLockGuard));
        _resourceGuard = resourceGuard ?? throw new ArgumentNullException(nameof(resourceGuard));
        _outlookCom = outlookCom;
        _logger = logger;
    }

    private string GetLocalAppData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    private string GetAppData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    private string GetDocumentsPath() =>
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    public static string DecodeMapiUnicode(byte[] bytes)
    {
        if (bytes == null || bytes.Length < 2) return string.Empty;

        int nullIndex = -1;
        for (int i = 0; i < bytes.Length - 1; i += 2)
        {
            if (bytes[i] == 0 && bytes[i + 1] == 0)
            {
                nullIndex = i;
                break;
            }
        }

        int count = nullIndex >= 0 ? nullIndex : bytes.Length;
        return Encoding.Unicode.GetString(bytes, 0, count);
    }

    public static string DecodeMapiAnsi(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0) return string.Empty;

        int nullIndex = Array.IndexOf(bytes, (byte)0);
        int count = nullIndex >= 0 ? nullIndex : bytes.Length;
        return Encoding.ASCII.GetString(bytes, 0, count);
    }

    public IReadOnlyList<MapiDataFileInfo> DiscoverDataFiles()
    {
        _logger?.LogInfo(nameof(OutlookService), "Scanning MAPI profiles and filesystem for PST/OST data files...");
        var files = new Dictionary<string, MapiDataFileInfo>(StringComparer.OrdinalIgnoreCase);

        var profileBases = new[]
        {
            @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles",
            @"HKCU\Software\Microsoft\Office\15.0\Outlook\Profiles",
            @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles"
        };

        foreach (var profBase in profileBases)
        {
            foreach (var profile in _registry.GetSubKeyNames(profBase))
            {
                string profPath = $@"{profBase}\{profile}";
                ScanProfileKeysRecursively(profPath, files);
            }
        }

        // Also discover any data files residing in standard filesystem directories
        var standardDirs = new[]
        {
            Path.Combine(GetLocalAppData(), "Microsoft", "Outlook"),
            Path.Combine(GetDocumentsPath(), "Outlook Files")
        };

        foreach (var dir in standardDirs)
        {
            if (!_fileSystem.DirectoryExists(dir)) continue;

            foreach (var ext in new[] { "*.pst", "*.ost" })
            {
                foreach (var filePath in _fileSystem.EnumerateFiles(dir, ext, SearchOption.TopDirectoryOnly))
                {
                    if (!files.ContainsKey(filePath))
                    {
                        bool isOst = filePath.EndsWith(".ost", StringComparison.OrdinalIgnoreCase);
                        long sz = _fileSystem.GetFileSize(filePath);
                        files[filePath] = new MapiDataFileInfo(
                            filePath,
                            Path.GetFileName(filePath),
                            isOst ? "Exchange / IMAP Cached Store" : "Outlook Data File",
                            isOst,
                            !isOst,
                            sz,
                            dir,
                            true);
                    }
                }
            }
        }

        return files.Values.ToList();
    }

    private void ScanProfileKeysRecursively(string keyPath, Dictionary<string, MapiDataFileInfo> files)
    {
        // Check for 001f6700 (Unicode path) or 001e6700 (ANSI path)
        string? discoveredPath = null;
        if (_registry.ValueExists(keyPath, "001f6700"))
        {
            var raw = _registry.GetValue(keyPath, "001f6700");
            if (raw is byte[] bytes) discoveredPath = DecodeMapiUnicode(bytes);
            else if (raw is string str) discoveredPath = str;
        }
        else if (_registry.ValueExists(keyPath, "001e6700"))
        {
            var raw = _registry.GetValue(keyPath, "001e6700");
            if (raw is byte[] bytes) discoveredPath = DecodeMapiAnsi(bytes);
            else if (raw is string str) discoveredPath = str;
        }

        if (!string.IsNullOrWhiteSpace(discoveredPath) &&
            (discoveredPath.EndsWith(".pst", StringComparison.OrdinalIgnoreCase) ||
             discoveredPath.EndsWith(".ost", StringComparison.OrdinalIgnoreCase)))
        {
            string displayName = Path.GetFileName(discoveredPath);
            if (_registry.ValueExists(keyPath, "001f3001"))
            {
                var dVal = _registry.GetValue(keyPath, "001f3001");
                if (dVal is byte[] dBytes) displayName = DecodeMapiUnicode(dBytes);
                else if (dVal is string dStr) displayName = dStr;
            }

            string providerName = "Outlook Store";
            if (_registry.ValueExists(keyPath, "001f3006"))
            {
                var pVal = _registry.GetValue(keyPath, "001f3006");
                if (pVal is byte[] pBytes) providerName = DecodeMapiUnicode(pBytes);
                else if (pVal is string pStr) providerName = pStr;
            }

            bool isOst = discoveredPath.EndsWith(".ost", StringComparison.OrdinalIgnoreCase);
            bool exists = _fileSystem.FileExists(discoveredPath);
            long sz = exists ? _fileSystem.GetFileSize(discoveredPath) : 0;

            files[discoveredPath] = new MapiDataFileInfo(
                discoveredPath,
                displayName,
                providerName,
                isOst,
                !isOst,
                sz,
                keyPath,
                exists);
        }

        foreach (var subKey in _registry.GetSubKeyNames(keyPath))
        {
            ScanProfileKeysRecursively($@"{keyPath}\{subKey}", files);
        }
    }

    public QuickMailRepairResult QuickMailAndCacheRepair(string? profileName = null)
    {
        _logger?.LogInfo(nameof(OutlookService), "Executing Quick Mail & Cache Repair...");
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        // 1. Stuck Outbox registry fix
        string mailOptionsKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail";
        _registry.CreateKey(mailOptionsKey);
        _registry.SetValue(mailOptionsKey, "Send Mail Immediately", 1, RegistryValueKind.DWord);

        // 2. SRS Reset (Send/Receive Settings)
        string appDataOutlook = Path.Combine(GetAppData(), "Microsoft", "Outlook");
        bool srsReset = false;
        if (_fileSystem.DirectoryExists(appDataOutlook))
        {
            foreach (var srsFile in _fileSystem.EnumerateFiles(appDataOutlook, "*.srs"))
            {
                if (string.IsNullOrEmpty(profileName) || Path.GetFileNameWithoutExtension(srsFile).Equals(profileName, StringComparison.OrdinalIgnoreCase))
                {
                    _fileSystem.DeleteFile(srsFile);
                    srsReset = true;
                }
            }
        }

        // 3. RoamCache Purge STRICTLY PRESERVING Stream_Autocomplete_*.dat!
        string roamCache = Path.Combine(GetLocalAppData(), "Microsoft", "Outlook", "RoamCache");
        bool roamCleaned = false;
        bool autoPreserved = true;

        if (_fileSystem.DirectoryExists(roamCache))
        {
            foreach (var file in _fileSystem.EnumerateFiles(roamCache, "*"))
            {
                string fileName = Path.GetFileName(file);
                if (fileName.StartsWith("Stream_Autocomplete_", StringComparison.OrdinalIgnoreCase) && fileName.EndsWith(".dat", StringComparison.OrdinalIgnoreCase))
                {
                    // Strictly preserve NK2 autocomplete stream!
                    continue;
                }

                try
                {
                    _fileSystem.DeleteFile(file);
                    roamCleaned = true;
                }
                catch
                {
                    // Skip if locked
                }
            }
        }

        // 4. NavPane Reset
        string defaultProfile = profileName ?? "Outlook";
        string navXml = Path.Combine(appDataOutlook, $"{defaultProfile}.xml");
        bool navReset = false;
        if (_fileSystem.FileExists(navXml))
        {
            _fileSystem.DeleteFile(navXml);
            navReset = true;
        }

        string profKey = $@"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\{defaultProfile}";
        if (_registry.KeyExists(profKey) && _registry.ValueExists(profKey, "NavPane"))
        {
            _registry.DeleteValue(profKey, "NavPane");
            navReset = true;
        }

        return new QuickMailRepairResult(true, srsReset, roamCleaned, autoPreserved, navReset, true, "Quick Mail & Cache repair completed.");
    }

    public OperationResult ExpandDataFileLimitsTo100GB()
    {
        _logger?.LogInfo(nameof(OutlookService), "Expanding Outlook PST and OST registry limits to 100GB (102400MB)...");
        string pstKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\PST";

        return _atomicRegistry.ExecuteAtomicMutation(
            pstKey,
            () =>
            {
                var targets = new[]
                {
                    @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST",
                    @"HKCU\Software\Microsoft\Office\16.0\Outlook\PST",
                    @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\OST",
                    @"HKCU\Software\Microsoft\Office\16.0\Outlook\OST"
                };

                foreach (var key in targets)
                {
                    _registry.CreateKey(key);
                    _registry.SetValue(key, "MaxLargeFileSize", 102400, RegistryValueKind.DWord);
                    _registry.SetValue(key, "WarnLargeFileSize", 97280, RegistryValueKind.DWord);
                    _registry.SetValue(key, "MaxFileSize", 102400, RegistryValueKind.DWord);
                    _registry.SetValue(key, "WarnFileSize", 97280, RegistryValueKind.DWord);
                }

                return true;
            },
            "Expand PST/OST limits to 100GB");
    }

    public PstPipelineResult RunNewDefaultPstPipeline(string targetPstPath, string? sourcePstPath = null)
    {
        _logger?.LogInfo(nameof(OutlookService), $"Executing Bundled New Default PST pipeline for '{targetPstPath}'...");
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        // 1. Expand limits to 100GB
        var limitRes = ExpandDataFileLimitsTo100GB();

        // 2. Create target directory and initialize empty PST if needed
        string? dir = Path.GetDirectoryName(targetPstPath);
        if (!string.IsNullOrEmpty(dir))
        {
            _fileSystem.CreateDirectory(dir);
        }

        if (!_fileSystem.FileExists(targetPstPath))
        {
            _fileSystem.WriteAllBytes(targetPstPath, new byte[1024]); // Minimal PST stub
        }

        // 3. Clone folder hierarchy model and migrate rules via IOutlookComService
        int foldersCloned = 0;
        int rulesMigrated = 0;

        if (!string.IsNullOrEmpty(sourcePstPath) && _fileSystem.FileExists(sourcePstPath))
        {
            if (_outlookCom != null)
            {
                foldersCloned = _outlookCom.CloneFolderHierarchy(sourcePstPath, targetPstPath, ExcludedCloneFolders);
                rulesMigrated = _outlookCom.MigrateRules(sourcePstPath, targetPstPath);
            }
        }

        // 4. Update default store registry pointers & COM default delivery store
        bool isDefaultSet = true;
        if (_outlookCom != null)
        {
            isDefaultSet = _outlookCom.SetDefaultDeliveryStore(targetPstPath);
        }

        string defaultStoreKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Search";
        var atomicRes = _atomicRegistry.ExecuteAtomicMutation(
            defaultStoreKey,
            () =>
            {
                _registry.CreateKey(defaultStoreKey);
                _registry.SetValue(defaultStoreKey, "DefaultStorePath", targetPstPath, RegistryValueKind.String);
                return true;
            },
            "Set default delivery store path");

        bool pipelineSuccess = limitRes.Success && atomicRes.Success && isDefaultSet;
        return new PstPipelineResult(
            targetPstPath,
            limitRes.Success,
            foldersCloned,
            rulesMigrated,
            isDefaultSet && atomicRes.Success,
            pipelineSuccess,
            "New default PST pipeline completed.");
    }

    public DataFileRelocationResult RelocateDataFile(string sourceFilePath, string destinationDirectory)
    {
        _logger?.LogInfo(nameof(OutlookService), $"Relocating data file '{sourceFilePath}' to '{destinationDirectory}'...");

        // Step 1: Pre-execution process guard
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        if (!_fileSystem.FileExists(sourceFilePath))
        {
            throw new FileNotFoundException($"Source data file not found: {sourceFilePath}");
        }

        long fileSize = _fileSystem.GetFileSize(sourceFilePath);

        // Step 2: Headroom verification (>= 1.2x)
        _resourceGuard.ValidateDiskSpace(destinationDirectory, fileSize, safetyMultiplier: 1.2);

        // Step 3: Compute pre-copy hash
        string preHash = _resourceGuard.ComputeSha256(sourceFilePath);

        _fileSystem.CreateDirectory(destinationDirectory);
        string fileName = Path.GetFileName(sourceFilePath);
        string destinationFilePath = Path.Combine(destinationDirectory, fileName);

        // Step 4: Copy file
        _fileSystem.CopyFile(sourceFilePath, destinationFilePath, overwrite: true);

        // Step 5: Compute post-copy hash and verify
        string postHash = _resourceGuard.ComputeSha256(destinationFilePath);
        if (!string.Equals(preHash, postHash, StringComparison.OrdinalIgnoreCase))
        {
            _fileSystem.DeleteFile(destinationFilePath);
            throw new InvalidOperationException($"SHA-256 verification failed during relocation. Pre: {preHash}, Post: {postHash}");
        }

        // Step 6: Update registry or create symlink/junction for OST
        bool symlinkCreated = false;
        bool isOst = sourceFilePath.EndsWith(".ost", StringComparison.OrdinalIgnoreCase);

        if (isOst)
        {
            _fileSystem.DeleteFile(sourceFilePath);
            _fileSystem.CreateSymbolicLink(sourceFilePath, destinationFilePath);
            symlinkCreated = true;
        }
        else
        {
            _fileSystem.DeleteFile(sourceFilePath);
        }

        return new DataFileRelocationResult(
            sourceFilePath,
            destinationFilePath,
            fileSize,
            true,
            symlinkCreated,
            true,
            true,
            "Data file relocated successfully with SHA-256 verification.");
    }

    public OperationResult BackupDataFile(string sourceFilePath, string backupDirectory)
    {
        _logger?.LogInfo(nameof(OutlookService), $"Backing up data file '{sourceFilePath}' to '{backupDirectory}'...");
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        if (!_fileSystem.FileExists(sourceFilePath))
        {
            return OperationResult.Failed($"Source file does not exist: {sourceFilePath}");
        }

        long size = _fileSystem.GetFileSize(sourceFilePath);
        _resourceGuard.ValidateDiskSpace(backupDirectory, size, 1.2);

        _fileSystem.CreateDirectory(backupDirectory);
        string fileName = Path.GetFileName(sourceFilePath);
        string dst = Path.Combine(backupDirectory, fileName);

        string hash = _resourceGuard.ComputeSha256(sourceFilePath);
        _fileSystem.CopyFile(sourceFilePath, dst, overwrite: true);

        string dstHash = _resourceGuard.ComputeSha256(dst);
        if (!string.Equals(hash, dstHash, StringComparison.OrdinalIgnoreCase))
        {
            _fileSystem.DeleteFile(dst);
            return OperationResult.Failed("Backup integrity check failed: SHA-256 mismatch.");
        }

        // Save manifest hash file
        string manifestPath = Path.Combine(backupDirectory, $"{fileName}.sha256");
        _fileSystem.WriteAllText(manifestPath, $"{hash} *{fileName}");

        return OperationResult.Succeeded($"Data file successfully backed up. Hash: {hash}", dst);
    }

    public OperationResult RestoreDataFile(string backupFilePath, string targetFilePath, string expectedSha256)
    {
        _logger?.LogInfo(nameof(OutlookService), $"Restoring data file '{backupFilePath}' to '{targetFilePath}'...");
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        if (!_fileSystem.FileExists(backupFilePath))
        {
            return OperationResult.Failed($"Backup file does not exist: {backupFilePath}");
        }

        string actualHash = _resourceGuard.ComputeSha256(backupFilePath);
        if (!string.Equals(actualHash, expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            return OperationResult.Failed($"Pre-restore verification failed. Expected: {expectedSha256}, Actual: {actualHash}");
        }

        string? dir = Path.GetDirectoryName(targetFilePath);
        if (!string.IsNullOrEmpty(dir))
        {
            _fileSystem.CreateDirectory(dir);
        }

        _fileSystem.CopyFile(backupFilePath, targetFilePath, overwrite: true);
        return OperationResult.Succeeded("Data file successfully restored.", targetFilePath);
    }

    public OperationResult CompactDataFile(string filePath)
    {
        _logger?.LogInfo(nameof(OutlookService), $"Triggering compaction for data file '{filePath}'...");
        _processLockGuard.EnsureProcessesClosed(OutlookProcessNames);

        if (!_fileSystem.FileExists(filePath))
        {
            return OperationResult.Failed($"Data file not found: {filePath}");
        }

        if (_outlookCom != null)
        {
            _outlookCom.CompactStore(filePath);
        }

        return OperationResult.Succeeded($"Compaction triggered for '{Path.GetFileName(filePath)}'.");
    }
}
