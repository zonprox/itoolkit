namespace IToolkit.Core.Models;

/// <summary>
/// Individual file entry tracked in a cleanup or backup manifest.
/// </summary>
public record ManifestFileEntry(
    string RelativePath,
    long SizeBytes,
    string Sha256Hash,
    DateTime LastModifiedUtc);

/// <summary>
/// Cryptographically verified manifest generated prior to system cleanup or file migrations.
/// </summary>
public record CleanupManifest(
    string ManifestId,
    DateTime CreatedUtc,
    string SourceRoot,
    long TotalSizeBytes,
    IReadOnlyList<ManifestFileEntry> Files);
