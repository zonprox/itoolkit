namespace IToolkit.Core.Services.Identity;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for user profile discovery, bookmark export, certificate handling, Robocopy, and SHA-256 manifest backup/restore.
/// </summary>
public interface IBackupService
{
    UserProfileMap GetUserProfileMap(string? username = null);
    IReadOnlyList<BookmarkExportResult> ExportBrowserBookmarks(string destinationDirectory);
    CertificateBackupResult ExportCertificates(string storeName, string destinationDirectory, string? password = null);
    RobocopySyncResult RunRobocopySync(string source, string destination, bool mirror = false);
    BackupManifestData CreateBackupManifest(string sourceDirectory, string manifestOutputPath);
    BackupValidationResult ValidateBackupManifest(string targetDirectory, string manifestPath);
    ProfileRestoreResult RestoreProfileData(string backupDirectory, string manifestPath, string? targetUser = null);
}
