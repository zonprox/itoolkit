namespace IToolkit.Core.Services.Identity;

using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 4: User Profile Discovery, Bookmark &amp; Certificate Backup, Robocopy, and SHA-256 Manifest verification.
/// </summary>
public class BackupService : IBackupService
{
    public const string ManifestFileName = "iToolKit_Backup_Manifest.json";

    public static readonly string[] BrowserProcessNames = { "chrome", "msedge" };
    public static readonly string[] ProfileLockingProcessNames =
    {
        "OUTLOOK", "WINWORD", "EXCEL", "POWERPNT", "ONENOTE", "chrome", "msedge"
    };

    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IRegistryService _registry;
    private readonly ResourceGuard _resourceGuard;
    private readonly ICertificateService? _certificateService;
    private readonly IActivityLogger? _logger;
    private readonly ProcessLockGuard _processLockGuard;

    public BackupService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        ResourceGuard resourceGuard,
        ICertificateService? certificateService = null,
        IActivityLogger? logger = null,
        ProcessLockGuard? processLockGuard = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _resourceGuard = resourceGuard ?? throw new ArgumentNullException(nameof(resourceGuard));
        _certificateService = certificateService;
        _logger = logger;
        _processLockGuard = processLockGuard ?? new ProcessLockGuard(_processRunner, _fileSystem, _logger);
    }

    private string GetUserProfileDir(string? username = null)
    {
        string user = username ?? Environment.UserName;
        return $@"C:\Users\{user}";
    }

    private string GetLocalAppData() =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public UserProfileMap GetUserProfileMap(string? username = null)
    {
        _logger?.LogInfo(nameof(BackupService), "Resolving user profile shell folders and detecting OneDrive redirection...");
        string user = string.IsNullOrWhiteSpace(username) ? Environment.UserName : username.Trim();
        string profileDir = GetUserProfileDir(user);

        string shellFoldersKey = @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders";

        string desktop = ResolveShellFolder(shellFoldersKey, "Desktop", Path.Combine(profileDir, "Desktop"), profileDir, user);
        string personal = ResolveShellFolder(shellFoldersKey, "Personal", Path.Combine(profileDir, "Documents"), profileDir, user);
        string downloads = ResolveShellFolder(shellFoldersKey, "{374DE290-123F-4565-9164-39C4925E467B}", Path.Combine(profileDir, "Downloads"), profileDir, user);
        string favorites = ResolveShellFolder(shellFoldersKey, "Favorites", Path.Combine(profileDir, "Favorites"), profileDir, user);
        string pictures = ResolveShellFolder(shellFoldersKey, "My Pictures", Path.Combine(profileDir, "Pictures"), profileDir, user);

        bool isOneDriveRedirected = desktop.Contains("OneDrive", StringComparison.OrdinalIgnoreCase) ||
                                   personal.Contains("OneDrive", StringComparison.OrdinalIgnoreCase) ||
                                   downloads.Contains("OneDrive", StringComparison.OrdinalIgnoreCase) ||
                                   pictures.Contains("OneDrive", StringComparison.OrdinalIgnoreCase);

        return new UserProfileMap(user, profileDir, desktop, personal, downloads, favorites, pictures, isOneDriveRedirected);
    }

    private string ResolveShellFolder(string keyPath, string valueName, string fallbackPath, string profileDir, string user)
    {
        if (_registry.KeyExists(keyPath) && _registry.ValueExists(keyPath, valueName))
        {
            var raw = _registry.GetValue(keyPath, valueName)?.ToString();
            if (!string.IsNullOrWhiteSpace(raw))
            {
                string expanded = raw
                    .Replace("%USERPROFILE%", profileDir, StringComparison.OrdinalIgnoreCase)
                    .Replace("%USERNAME%", user, StringComparison.OrdinalIgnoreCase);
                return Environment.ExpandEnvironmentVariables(expanded);
            }
        }
        return fallbackPath;
    }

    public IReadOnlyList<BookmarkExportResult> ExportBrowserBookmarks(string destinationDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationDirectory);
        _logger?.LogInfo(nameof(BackupService), $"Exporting Chrome and Edge bookmarks to '{destinationDirectory}'...");
        _processLockGuard.EnsureProcessesClosed(BrowserProcessNames, TimeSpan.FromSeconds(3));

        _fileSystem.CreateDirectory(destinationDirectory);
        var results = new List<BookmarkExportResult>();

        string localAppData = GetLocalAppData();
        var browserRoots = new[]
        {
            ("Chrome", Path.Combine(localAppData, "Google", "Chrome", "User Data")),
            ("Edge", Path.Combine(localAppData, "Microsoft", "Edge", "User Data"))
        };

        foreach (var (browser, rootDir) in browserRoots)
        {
            if (!_fileSystem.DirectoryExists(rootDir)) continue;

            // Search Default and Profile *
            var profileDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string defaultDir = Path.Combine(rootDir, "Default");
            if (_fileSystem.DirectoryExists(defaultDir)) profileDirs.Add(defaultDir);

            foreach (var pDir in _fileSystem.EnumerateDirectories(rootDir, "Profile *", SearchOption.TopDirectoryOnly))
            {
                profileDirs.Add(pDir);
            }

            foreach (var pDir in profileDirs)
            {
                string pName = Path.GetFileName(pDir);
                string bookmarkSource = Path.Combine(pDir, "Bookmarks");

                if (_fileSystem.FileExists(bookmarkSource))
                {
                    string targetFile = Path.Combine(destinationDirectory, $"{browser}_{pName}_Bookmarks.json");
                    _fileSystem.CopyFile(bookmarkSource, targetFile, overwrite: true);

                    string hash = _resourceGuard.ComputeSha256(targetFile);
                    int count = 0;

                    try
                    {
                        string json = _fileSystem.ReadAllText(targetFile);
                        using var doc = JsonDocument.Parse(json);
                        if (doc.RootElement.TryGetProperty("roots", out var rootsElement))
                        {
                            count = CountBookmarkNodes(rootsElement);
                        }
                        else
                        {
                            count = CountBookmarkNodes(doc.RootElement);
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger?.LogWarning(nameof(BackupService), $"Failed to parse bookmark JSON for '{targetFile}': {ex.Message}");
                        count = 0;
                    }

                    results.Add(new BookmarkExportResult(browser, pName, bookmarkSource, targetFile, hash, count, true));
                }
            }
        }

        _processLockGuard.RestartClosedProcesses();
        return results;
    }

    private static int CountBookmarkNodes(JsonElement element)
    {
        int count = 0;
        if (element.ValueKind == JsonValueKind.Object)
        {
            if (element.TryGetProperty("type", out var typeProp) &&
                typeProp.GetString()?.Equals("url", StringComparison.OrdinalIgnoreCase) == true)
            {
                count++;
            }

            if (element.TryGetProperty("children", out var children) && children.ValueKind == JsonValueKind.Array)
            {
                foreach (var child in children.EnumerateArray())
                {
                    count += CountBookmarkNodes(child);
                }
            }
            else
            {
                foreach (var prop in element.EnumerateObject())
                {
                    count += CountBookmarkNodes(prop.Value);
                }
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                count += CountBookmarkNodes(item);
            }
        }
        return count;
    }

    public CertificateBackupResult ExportCertificates(string storeName, string destinationDirectory, string? password = null)
    {
        _logger?.LogInfo(nameof(BackupService), $"Backing up certificates from store '{storeName}' to '{destinationDirectory}'...");
        _fileSystem.CreateDirectory(destinationDirectory);

        string certOut = Path.Combine(destinationDirectory, $"{storeName}_Certificates.pfx");
        int count = 0;
        byte[] pfxData = Array.Empty<byte>();

        if (_certificateService != null)
        {
            var certs = _certificateService.GetCertificates(storeName, StoreLocation.CurrentUser);
            count = certs.Count;
            if (count > 0)
            {
                pfxData = _certificateService.ExportCertificatesToPfx(certs, password);
            }
        }
        else
        {
            // Standard .NET BCL fallback using X509Store
            StoreName sName = Enum.TryParse<StoreName>(storeName, ignoreCase: true, out var parsed) ? parsed : StoreName.My;
            using var store = new X509Store(sName, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadOnly);
            count = store.Certificates.Count;
            if (count > 0)
            {
                pfxData = store.Certificates.Export(X509ContentType.Pfx, password) ?? Array.Empty<byte>();
            }
        }

        _fileSystem.WriteAllBytes(certOut, pfxData);

        return new CertificateBackupResult(storeName, "CurrentUser", count, certOut, true,
            count > 0 ? $"Successfully exported {count} certificate(s)." : "No certificates found in specified store.");
    }

    public RobocopySyncResult RunRobocopySync(string source, string destination, bool mirror = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(source);
        ArgumentException.ThrowIfNullOrWhiteSpace(destination);

        _logger?.LogInfo(nameof(BackupService), $"Executing Robocopy sync: '{source}' -> '{destination}' (Mirror={mirror})...");
        _processLockGuard.EnsureProcessesClosed(ProfileLockingProcessNames, TimeSpan.FromSeconds(3));
        _fileSystem.CreateDirectory(destination);

        string syncMode = mirror ? "/MIR" : "/E";
        string args = $"\"{source}\" \"{destination}\" {syncMode} /MT:16 /COPY:DAT /R:2 /W:2 /XJ /ZB /NP";

        var res = _processRunner.Run("robocopy.exe", args);
        if (res.ExitCode == 16 &&
            (res.StandardOutput.Contains("Backup and Restore Files", StringComparison.OrdinalIgnoreCase) ||
             res.StandardError.Contains("Backup and Restore Files", StringComparison.OrdinalIgnoreCase)))
        {
            string fallbackArgs = $"\"{source}\" \"{destination}\" {syncMode} /MT:16 /COPY:DAT /R:2 /W:2 /XJ /NP";
            res = _processRunner.Run("robocopy.exe", fallbackArgs);
        }

        // Bitmask evaluation: Exit code < 8 is SUCCESS (0=no change, 1=copied, 2=extra files, 4=mismatches)
        bool isSuccess = res.ExitCode < 8;

        _processLockGuard.RestartClosedProcesses();
        return new RobocopySyncResult(source, destination, res.ExitCode, isSuccess, res.StandardOutput, res.StandardError);
    }

    public BackupManifestData CreateBackupManifest(string sourceDirectory, string manifestOutputPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestOutputPath);

        _logger?.LogInfo(nameof(BackupService), $"Generating SHA-256 backup manifest for '{sourceDirectory}'...");

        var entries = new List<BackupManifestItem>();
        long totalSize = 0;

        if (_fileSystem.DirectoryExists(sourceDirectory))
        {
            var files = _fileSystem.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories);
            foreach (var f in files)
            {
                if (f.EndsWith(ManifestFileName, StringComparison.OrdinalIgnoreCase)) continue;

                string normRoot = sourceDirectory.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
                string normFile = f.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
                string rel = Path.GetRelativePath(normRoot, normFile).Replace('\\', '/');
                long sz = _fileSystem.GetFileSize(f);
                string hash = _resourceGuard.ComputeSha256(f);

                entries.Add(new BackupManifestItem(rel, hash, sz));
                totalSize += sz;
            }
        }

        var manifest = new BackupManifestData(DateTime.UtcNow, sourceDirectory, totalSize, entries);
        string json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });

        string? dir = Path.GetDirectoryName(manifestOutputPath);
        if (!string.IsNullOrEmpty(dir)) _fileSystem.CreateDirectory(dir);
        _fileSystem.WriteAllText(manifestOutputPath, json);

        _logger?.LogSuccess(nameof(BackupService), $"Manifest created with {entries.Count} files, total size {totalSize:N0} bytes.");
        return manifest;
    }

    public BackupValidationResult ValidateBackupManifest(string targetDirectory, string manifestPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestPath);

        _logger?.LogInfo(nameof(BackupService), $"Validating manifest '{manifestPath}' against target directory '{targetDirectory}'...");

        if (!_fileSystem.FileExists(manifestPath))
        {
            throw new FileNotFoundException($"Manifest not found: {manifestPath}");
        }

        string json = _fileSystem.ReadAllText(manifestPath);
        var manifest = JsonSerializer.Deserialize<BackupManifestData>(json);
        if (manifest == null)
        {
            throw new InvalidOperationException("Failed to deserialize backup manifest.");
        }

        var missing = new List<string>();
        var corrupted = new List<string>();
        int matched = 0;

        foreach (var item in manifest.Files)
        {
            string normRel = item.RelativePath.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
            string normTarget = targetDirectory.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
            string fullPath = Path.Combine(normTarget, normRel);

            if (!_fileSystem.FileExists(fullPath))
            {
                missing.Add(item.RelativePath);
                continue;
            }

            long currentSz = _fileSystem.GetFileSize(fullPath);
            if (currentSz != item.SizeBytes)
            {
                corrupted.Add(item.RelativePath);
                continue;
            }

            string currentHash = _resourceGuard.ComputeSha256(fullPath);
            if (!string.Equals(currentHash, item.Sha256Hash, StringComparison.OrdinalIgnoreCase))
            {
                corrupted.Add(item.RelativePath);
                continue;
            }

            matched++;
        }

        bool isIntact = missing.Count == 0 && corrupted.Count == 0;
        return new BackupValidationResult(matched, corrupted.Count, missing.Count, isIntact, missing, corrupted);
    }

    public ProfileRestoreResult RestoreProfileData(string backupDirectory, string manifestPath, string? targetUser = null)
    {
        _logger?.LogInfo(nameof(BackupService), $"Initiating user profile restore from '{backupDirectory}'...");
        _processLockGuard.EnsureProcessesClosed(ProfileLockingProcessNames, TimeSpan.FromSeconds(3));
        try
        {
            // Pre-flight manifest verification
            var validation = ValidateBackupManifest(backupDirectory, manifestPath);
            if (!validation.IsIntact)
            {
                string err = $"Pre-flight restore validation failed: {validation.MissingCount} missing files, {validation.CorruptedCount} corrupted files.";
                _logger?.LogError(nameof(BackupService), err);
                return new ProfileRestoreResult(false, 0, false, err);
            }

            var userMap = GetUserProfileMap(targetUser);
            string json = _fileSystem.ReadAllText(manifestPath);
            var manifest = JsonSerializer.Deserialize<BackupManifestData>(json)!;

            int restored = 0;
            foreach (var item in manifest.Files)
            {
                string normRel = item.RelativePath.Replace('/', Path.DirectorySeparatorChar);
                string srcFile = Path.Combine(backupDirectory, normRel);
                string dstFile = Path.Combine(userMap.ProfilePath, normRel);

                string? dstDir = Path.GetDirectoryName(dstFile);
                if (!string.IsNullOrEmpty(dstDir)) _fileSystem.CreateDirectory(dstDir);

                _fileSystem.CopyFile(srcFile, dstFile, overwrite: true);
                restored++;
            }

            _logger?.LogSuccess(nameof(BackupService), $"Profile restore completed: {restored} files restored.");
            return new ProfileRestoreResult(true, restored, true, "Profile successfully restored from verified backup.");
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses();
        }
    }
}
