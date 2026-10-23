namespace IToolkit.Core.Safety;

using System.Security.Cryptography;
using System.Text.Json;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Result of validating a cleanup or backup manifest against physical files.
/// </summary>
public record ManifestValidationResult(
    bool IsValid,
    int TotalFiles,
    int MatchedFiles,
    IReadOnlyList<string> MissingFiles,
    IReadOnlyList<string> MismatchedFiles);

/// <summary>
/// Enforces storage headroom constraints (>= 1.2x safety multiplier), provides cryptographic SHA-256
/// calculations, and generates/validates manifests before system cleanups or file migrations.
/// </summary>
public class ResourceGuard
{
    public const double DefaultHeadroomMultiplier = 1.2;

    private readonly IFileSystemService _fileSystem;
    private readonly IActivityLogger? _logger;

    public ResourceGuard(
        IFileSystemService fileSystem,
        IActivityLogger? logger = null)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _logger = logger;
    }

    /// <summary>
    /// Calculates the required disk space including the safety multiplier.
    /// Formula: Math.Ceiling(requiredBytes * safetyMultiplier)
    /// </summary>
    public static long CalculateRequiredHeadroom(long requiredBytes, double safetyMultiplier = DefaultHeadroomMultiplier)
    {
        if (requiredBytes <= 0) return 0;
        return (long)Math.Ceiling(requiredBytes * safetyMultiplier);
    }

    /// <summary>
    /// Checks whether the target volume has at least (requiredBytes * safetyMultiplier) free bytes.
    /// </summary>
    public bool CheckDiskSpace(string destinationPath, long requiredBytes, double safetyMultiplier = DefaultHeadroomMultiplier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);
        if (requiredBytes <= 0) return true;

        long threshold = CalculateRequiredHeadroom(requiredBytes, safetyMultiplier);
        long available = _fileSystem.GetAvailableFreeSpace(destinationPath);

        return available >= threshold;
    }

    /// <summary>
    /// Asserts that sufficient disk space exists on the target volume; throws InvalidOperationException if insufficient.
    /// </summary>
    public void ValidateDiskSpace(string destinationPath, long requiredBytes, double safetyMultiplier = DefaultHeadroomMultiplier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);
        if (requiredBytes <= 0) return;

        long threshold = CalculateRequiredHeadroom(requiredBytes, safetyMultiplier);
        long available = _fileSystem.GetAvailableFreeSpace(destinationPath);

        if (available < threshold)
        {
            string message =
                $"Insufficient disk space on target volume for '{destinationPath}'. " +
                $"Available: {available:N0} bytes ({available / (1024 * 1024):N0} MB), " +
                $"Required (with {safetyMultiplier:F1}x headroom): {threshold:N0} bytes ({threshold / (1024 * 1024):N0} MB).";

            _logger?.LogError(nameof(ResourceGuard), message);
            throw new InvalidOperationException(message);
        }

        _logger?.LogInfo(nameof(ResourceGuard),
            $"Disk space validated for '{destinationPath}': {available:N0} bytes available vs {threshold:N0} bytes required ({safetyMultiplier:F1}x headroom).");
    }

    /// <summary>
    /// Computes the uppercase hexadecimal SHA-256 hash of a file.
    /// </summary>
    public string ComputeSha256(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        return _fileSystem.ComputeSha256(filePath);
    }

    /// <summary>
    /// Asynchronously computes the uppercase hexadecimal SHA-256 hash of a file.
    /// </summary>
    public Task<string> ComputeSha256Async(string filePath, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        return _fileSystem.ComputeSha256Async(filePath, cancellationToken);
    }

    /// <summary>
    /// Computes the uppercase hexadecimal SHA-256 hash from a stream.
    /// </summary>
    public static string ComputeSha256(Stream stream)
    {
        ArgumentNullException.ThrowIfNull(stream);
        byte[] hash = SHA256.HashData(stream);
        return Convert.ToHexString(hash);
    }

    /// <summary>
    /// Verifies whether the file's SHA-256 hash matches the expected hash.
    /// </summary>
    public bool VerifyFileHash(string filePath, string expectedHash)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedHash);

        if (!_fileSystem.FileExists(filePath)) return false;

        string actualHash = ComputeSha256(filePath);
        return string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Verifies whether two files produce identical SHA-256 hashes.
    /// </summary>
    public bool VerifyFilesMatch(string sourcePath, string destinationPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);

        if (!_fileSystem.FileExists(sourcePath) || !_fileSystem.FileExists(destinationPath))
        {
            return false;
        }

        string sourceHash = ComputeSha256(sourcePath);
        string destHash = ComputeSha256(destinationPath);

        return string.Equals(sourceHash, destHash, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Generates a cryptographic manifest of the specified files relative to sourceRoot prior to cleanup or backup.
    /// </summary>
    public CleanupManifest GenerateCleanupManifest(string sourceRoot, IEnumerable<string> filePaths)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceRoot);
        ArgumentNullException.ThrowIfNull(filePaths);

        string manifestId = $"MANIFEST_{DateTime.UtcNow:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}";
        var entries = new List<ManifestFileEntry>();
        long totalSize = 0;

        string normalizedRoot = sourceRoot.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);

        foreach (var fullPath in filePaths)
        {
            if (!_fileSystem.FileExists(fullPath)) continue;

            string normalizedFile = fullPath.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
            string relativePath = Path.GetRelativePath(normalizedRoot, normalizedFile).Replace('\\', '/');
            long size = _fileSystem.GetFileSize(fullPath);
            string hash = ComputeSha256(fullPath);
            DateTime lastModified = _fileSystem.GetLastWriteTimeUtc(fullPath);

            entries.Add(new ManifestFileEntry(relativePath, size, hash, lastModified));
            totalSize += size;
        }

        var manifest = new CleanupManifest(manifestId, DateTime.UtcNow, sourceRoot, totalSize, entries);
        _logger?.LogInfo(nameof(ResourceGuard), $"Generated manifest '{manifestId}' with {entries.Count} file(s), total size {totalSize:N0} bytes.");
        return manifest;
    }

    /// <summary>
    /// Serializes a cleanup manifest to JSON and saves it to disk.
    /// </summary>
    public void SaveManifest(CleanupManifest manifest, string destinationPath)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);

        string json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
        _fileSystem.WriteAllText(destinationPath, json);
        _logger?.LogInfo(nameof(ResourceGuard), $"Saved manifest '{manifest.ManifestId}' to: {destinationPath}");
    }

    /// <summary>
    /// Reads and deserializes a cleanup manifest from disk.
    /// </summary>
    public CleanupManifest LoadManifest(string manifestPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestPath);

        string json = _fileSystem.ReadAllText(manifestPath);
        var manifest = JsonSerializer.Deserialize<CleanupManifest>(json);
        return manifest ?? throw new InvalidOperationException($"Failed to deserialize manifest from '{manifestPath}'.");
    }

    /// <summary>
    /// Validates files on disk against the provided manifest, asserting hash integrity and existence.
    /// </summary>
    public ManifestValidationResult ValidateManifest(CleanupManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);

        var missing = new List<string>();
        var mismatched = new List<string>();
        int matched = 0;

        foreach (var entry in manifest.Files)
        {
            string normalizedRelPath = entry.RelativePath.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
            string fullPath = Path.Combine(manifest.SourceRoot, normalizedRelPath);

            if (!_fileSystem.FileExists(fullPath))
            {
                missing.Add(entry.RelativePath);
                continue;
            }

            long currentSize = _fileSystem.GetFileSize(fullPath);
            if (currentSize != entry.SizeBytes)
            {
                mismatched.Add(entry.RelativePath);
                continue;
            }

            string currentHash = ComputeSha256(fullPath);
            if (!string.Equals(currentHash, entry.Sha256Hash, StringComparison.OrdinalIgnoreCase))
            {
                mismatched.Add(entry.RelativePath);
                continue;
            }

            matched++;
        }

        bool isValid = missing.Count == 0 && mismatched.Count == 0;
        var result = new ManifestValidationResult(isValid, manifest.Files.Count, matched, missing, mismatched);

        if (isValid)
        {
            _logger?.LogSuccess(nameof(ResourceGuard), $"Manifest '{manifest.ManifestId}' validated successfully: {matched}/{manifest.Files.Count} files match.");
        }
        else
        {
            _logger?.LogError(nameof(ResourceGuard), $"Manifest '{manifest.ManifestId}' validation failed: {missing.Count} missing, {mismatched.Count} mismatched.");
        }

        return result;
    }
}
