namespace IToolkit.Core.Models;

/// <summary>
/// Information about a local Windows user account.
/// </summary>
public record LocalAccountItem(
    string Username,
    string Sid,
    bool IsEnabled,
    bool IsLocked,
    bool IsAdmin,
    bool IsBuiltInAdmin);

/// <summary>
/// Pre-flight domain reachability test across DNS and critical Active Directory ports.
/// </summary>
public record DomainReachabilityResult(
    string Domain,
    bool DnsResolved,
    bool KerberosPortOpen,
    bool LdapPortOpen,
    bool SmbPortOpen,
    bool IsReachable,
    string DiagnosticsSummary);

/// <summary>
/// Domain user account status via Zero-RSAT directory query.
/// </summary>
public record DomainUserInfo(
    string SamAccountName,
    string UserPrincipalName,
    string EmailAddress,
    bool IsEnabled,
    bool IsLockedOut);

/// <summary>
/// Mapping of user profile shell directories and OneDrive redirection state.
/// </summary>
public record UserProfileMap(
    string Username,
    string ProfilePath,
    string DesktopPath,
    string DocumentsPath,
    string DownloadsPath,
    string FavoritesPath,
    string PicturesPath,
    bool IsOneDriveRedirected);

/// <summary>
/// Result of Chrome / Edge bookmark JSON export.
/// </summary>
public record BookmarkExportResult(
    string Browser,
    string ProfileName,
    string SourceFile,
    string ExportPath,
    string Sha256Hash,
    int EntryCount,
    bool Success);

/// <summary>
/// Result of certificate store backup.
/// </summary>
public record CertificateBackupResult(
    string StoreName,
    string Location,
    int ExportedCount,
    string ExportPath,
    bool Success,
    string Message = "");

/// <summary>
/// Result of Robocopy synchronization execution with bitmask exit code verification.
/// </summary>
public record RobocopySyncResult(
    string Source,
    string Destination,
    int ExitCode,
    bool IsSuccess,
    string Output,
    string ErrorOutput = "");

/// <summary>
/// An individual file entry in the IToolkit backup manifest.
/// </summary>
public record BackupManifestItem(
    string RelativePath,
    string Sha256Hash,
    long SizeBytes);

/// <summary>
/// Manifest container written to IToolkit_Backup_Manifest.json.
/// </summary>
public record BackupManifestData(
    DateTime CreatedAtUtc,
    string SourceDirectory,
    long TotalSizeBytes,
    IReadOnlyList<BackupManifestItem> Files);

/// <summary>
/// Result of verifying physical files against a backup manifest.
/// </summary>
public record BackupValidationResult(
    int MatchedCount,
    int CorruptedCount,
    int MissingCount,
    bool IsIntact,
    IReadOnlyList<string> MissingFiles,
    IReadOnlyList<string> CorruptedFiles);

/// <summary>
/// Result of user profile restore from verified backup.
/// </summary>
public record ProfileRestoreResult(
    bool Validated,
    int FilesRestored,
    bool Success,
    string Message = "");
