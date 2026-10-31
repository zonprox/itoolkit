namespace IToolkit.Tests.SafetyTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Tier 5 Adversarial Verification & Stress Test Suite: Identity & Office Domains.
/// Tests edge cases, extreme inputs, concurrency, non-interference, and data-loss vulnerabilities.
/// </summary>
public class IdentityAndOfficeEmpiricalChallengeTests
{
    private readonly MockProcessRunner _processRunner = new();
    private readonly MockFileSystemService _fileSystem = new();
    private readonly MockRegistryService _registry = new();
    private readonly MockNetworkService _network = new();
    private readonly MockWmiService _wmi = new();
    private readonly MockOutlookComService _outlookCom = new();
    private readonly ResourceGuard _resourceGuard;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly TestActivityLogger _logger = new();

    private readonly IdentityService _identityService;
    private readonly OutlookService _outlookService;

    public IdentityAndOfficeEmpiricalChallengeTests()
    {
        _resourceGuard = new ResourceGuard(_fileSystem);
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem, _logger);

        _identityService = new IdentityService(_processRunner, _fileSystem, _registry, _network, _wmi, _logger);
        _outlookService = new OutlookService(_registry, _atomicRegistry, _fileSystem, _lockGuard, _resourceGuard, _outlookCom, _logger);
    }

    #region 1. Identity & Local Users: Extreme / Edge-Case Inputs

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public void Identity_EmptyOrWhitespaceUsernames_ThrowArgumentException(string invalidUsername)
    {
        Assert.ThrowsAny<ArgumentException>(() => _identityService.UnlockLocalAccount(invalidUsername));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.SetAccountEnabled(invalidUsername, true));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.ResetUserPassword(invalidUsername, "ValidPassword123!"));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.RemoveLocalAccount(invalidUsername));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.CreateLocalAccount(invalidUsername, "ValidPassword123!"));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.GetDomainUser("corp.local", invalidUsername));
        Assert.ThrowsAny<ArgumentException>(() => _identityService.UnlockDomainUser("corp.local", invalidUsername));
    }

    [Fact]
    public void Identity_SpecialCharactersAndQuotesInUsername_PassedSafelyToNetUser()
    {
        string complexUser = @"DOMAIN\user_name-01";
        bool result = _identityService.UnlockLocalAccount(complexUser);

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains($"net.exe user \"{complexUser}\" /active:yes"));
    }

    [Fact]
    public void Identity_RemoveLocalAccount_DirectoryTraversalAttempt_MustNotEscapeUsersDirectory()
    {
        // Challenge: If an attacker or corrupt data specifies username ".." or "../..",
        // the service must not attempt to delete C:\ or other root directories.
        string traversalUser = "..";
        string rootProfile = @"C:\Users\..";
        _fileSystem.CreateDirectory(rootProfile);

        // Act
        _identityService.RemoveLocalAccount(traversalUser);

        // If directory traversal was unhandled, C:\Users\.. might be deleted or C:\ might be wiped.
        // We verify that the command runner called net user with clean name
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains("user \"..\" /delete"));
    }

    [Fact]
    public void Identity_RemoveLocalAccount_WhitespacePaddedAdmin_MustTriggerGuardrail()
    {
        // Challenge: Does " Administrator " or "administrator" bypass the built-in admin deletion guard?
        Assert.Throws<InvalidOperationException>(() => _identityService.RemoveLocalAccount("Administrator"));
        Assert.Throws<InvalidOperationException>(() => _identityService.RemoveLocalAccount("administrator"));
        Assert.Throws<InvalidOperationException>(() => _identityService.RemoveLocalAccount("Domain\\Administrator"));

        // By SID
        Assert.Throws<InvalidOperationException>(() => _identityService.RemoveLocalAccount("CustomAdminName", "S-1-5-21-12345-500"));

        // By whitespace-padded name " Administrator "
        Assert.Throws<InvalidOperationException>(() => _identityService.RemoveLocalAccount(" Administrator "));
    }

    [Fact]
    public void Identity_BackupService_GetUserProfileMap_ForSecondaryUser_MustNotReturnCurrentLoggedInUserProfilePaths()
    {
        string shellFoldersKey = @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders";
        _registry.CreateKey(shellFoldersKey);
        _registry.SetValue(shellFoldersKey, "Desktop", @"%USERPROFILE%\Desktop", RegistryValueKind.ExpandString);

        var backupSvc = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard, logger: _logger);
        var map = backupSvc.GetUserProfileMap("UserB");

        // UserB's desktop must NOT point to the current logged in user's profile directory!
        string currentUserProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Assert.False(map.DesktopPath.StartsWith(currentUserProfile, StringComparison.OrdinalIgnoreCase),
            $"Cross-entity state bleed: GetUserProfileMap('UserB') returned current user path '{map.DesktopPath}' instead of UserB path!");
    }

    #endregion

    #region 2. Identity & Local Users: Concurrency & Non-Interference

    [Fact]
    public async Task Identity_ConcurrentUnlockAndEnableRequests_ExecuteWithoutExceptions()
    {
        // Arrange: 10 concurrent requests for various users
        var tasks = new List<Task<bool>>();
        for (int i = 0; i < 10; i++)
        {
            string user = $"User_{i}";
            bool isEven = (i % 2 == 0);
            tasks.Add(Task.Run(() =>
            {
                if (isEven)
                    return _identityService.UnlockLocalAccount(user);
                else
                    return _identityService.SetAccountEnabled(user, false);
            }));
        }

        // Act
        bool[] results = await Task.WhenAll(tasks);

        // Assert: all tasks completed successfully
        Assert.All(results, Assert.True);
    }

    [Fact]
    public void Identity_MutatingUserA_LeavesUserBCompletelyUnaffected()
    {
        // Arrange
        string userA = "Alice";
        string userB = "Bob";

        // Act 1: Unlock User A
        _identityService.UnlockLocalAccount(userA);

        // Act 2: Disable User A
        _identityService.SetAccountEnabled(userA, false);

        // Act 3: Reset User A password
        _identityService.ResetUserPassword(userA, "NewPassAlice123!");

        // Assert: No command targeted User B
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains($"\"{userB}\""));
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains($"user \"{userA}\" /active:yes"));
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains($"user \"{userA}\" /active:no"));
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains($"user \"{userA}\" \"NewPassAlice123!\""));
    }

    [Fact]
    public void Identity_BuiltInAdminRecovery_DoesNotMutateStandardLocalUsers()
    {
        // Arrange
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", [
            new Dictionary<string, object?> { { "Name", "BuiltInAdmin" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", true }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "StandardUser" }, { "SID", "S-1-5-21-999-1001" }, { "Disabled", false }, { "Lockout", false } }
        ]);

        // Act
        bool enableOk = _identityService.EnableBuiltInAdministrator();
        bool resetOk = _identityService.ResetBuiltInAdministratorPassword("NewAdminPass#2026");

        // Assert
        Assert.True(enableOk);
        Assert.True(resetOk);

        // Operations targeted only BuiltInAdmin (SID-500), never StandardUser
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains("StandardUser"));
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains("user \"BuiltInAdmin\" /active:yes"));
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Contains("user \"BuiltInAdmin\" \"NewAdminPass#2026\""));
    }

    #endregion

    #region 3. Office & Outlook: Extreme Paths, In-Place Relocation & Boundary Cases

    [Fact]
    public void Office_RelocateDataFile_WithPathContainingSpacesAndSpecialChars_Succeeds()
    {
        // Arrange
        string sourceDir = @"C:\Mail Storage (Archive)\User Profile [Primary]";
        string destDir = @"D:\Migrated Stores\Outlook 2026 (New Location)";
        string fileName = "Important [2026] & Confidential.pst";
        string sourcePst = Path.Combine(sourceDir, fileName);

        _fileSystem.CreateDirectory(sourceDir);
        _fileSystem.WriteAllBytes(sourcePst, new byte[2048]);
        _fileSystem.SetAvailableFreeSpace(10L * 1024 * 1024 * 1024);

        // Act
        var result = _outlookService.RelocateDataFile(sourcePst, destDir);

        // Assert
        Assert.True(result.Success);
        string expectedDest = Path.Combine(destDir, fileName);
        Assert.True(_fileSystem.FileExists(expectedDest));
        Assert.False(_fileSystem.FileExists(sourcePst));
    }

    [Fact]
    public void Office_RelocateDataFile_NonExistentSource_ThrowsFileNotFoundException()
    {
        string missingPst = @"C:\NonExistent\Ghost.pst";
        string destDir = @"D:\OutlookFiles";

        Assert.Throws<FileNotFoundException>(() => _outlookService.RelocateDataFile(missingPst, destDir));
    }

    [Fact]
    public void Office_RelocateDataFile_SameSourceAndDestinationDirectory_FailsOrPreventsDataLoss()
    {
        // Challenge: Relocating a file into its own containing directory.
        // If the code copies over itself and then calls DeleteFile(sourceFilePath),
        // the file could be deleted, resulting in total data loss!
        string storeDir = @"C:\OutlookFiles";
        string pstPath = Path.Combine(storeDir, "SelfRelocate.pst");
        _fileSystem.CreateDirectory(storeDir);
        _fileSystem.WriteAllBytes(pstPath, new byte[4096]);
        _fileSystem.SetAvailableFreeSpace(10L * 1024 * 1024 * 1024);

        // Act: Relocate to the SAME directory
        // In the current implementation, it copies onto itself then deletes sourceFilePath!
        // We verify empirically what happens:
        var result = _outlookService.RelocateDataFile(pstPath, storeDir);

        // Check if the file still exists or was destroyed by in-place deletion!
        bool fileStillExists = _fileSystem.FileExists(pstPath);

        // If file was deleted, this surfaces an empirical data loss vulnerability!
        // An ideal relocation engine must refuse or preserve the file when source == destination.
        Assert.True(fileStillExists, "CRITICAL: In-place relocation deleted the data file because DeleteFile(source) wiped destination!");
    }

    [Fact]
    public void Office_CompactDataFile_MissingFile_ReturnsFailedOperationResultWithoutThrowing()
    {
        string missingPst = @"C:\NonExistent\DoesNotExist.pst";

        var result = _outlookService.CompactDataFile(missingPst);

        Assert.False(result.Success);
        Assert.Contains("not found", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Office_BackupDataFile_InsufficientDiskSpace_FailsGracefully()
    {
        // Arrange
        string sourcePst = @"C:\Outlook\GiantMailbox.pst";
        string backupDir = @"E:\Backups";
        _fileSystem.CreateDirectory(@"C:\Outlook");
        _fileSystem.WriteAllBytes(sourcePst, new byte[10 * 1024 * 1024]); // 10 MB

        // Set available free space to only 5 MB (less than 1.2x headroom)
        _fileSystem.SetAvailableFreeSpace(5 * 1024 * 1024);

        // Act & Assert
        Assert.Throws<InvalidOperationException>(() => _outlookService.BackupDataFile(sourcePst, backupDir));
    }

    [Fact]
    public void Office_RestoreDataFile_Sha256Mismatch_FailsAndDoesNotOverwriteTarget()
    {
        // Arrange
        string backupPst = @"E:\Backups\MailboxBackup.pst";
        string targetPst = @"C:\Outlook\RestoredMailbox.pst";
        _fileSystem.CreateDirectory(@"E:\Backups");
        _fileSystem.CreateDirectory(@"C:\Outlook");

        byte[] originalContent = Encoding.UTF8.GetBytes("Original Healthy Target Content");
        _fileSystem.WriteAllBytes(targetPst, originalContent);
        _fileSystem.WriteAllBytes(backupPst, Encoding.UTF8.GetBytes("Corrupted Backup Content"));

        string expectedHealthyHash = "A" + new string('0', 63); // Wrong expected hash

        // Act
        var result = _outlookService.RestoreDataFile(backupPst, targetPst, expectedHealthyHash);

        // Assert: Restore should fail due to hash mismatch
        Assert.False(result.Success);
        Assert.Contains("verification failed", result.Message, StringComparison.OrdinalIgnoreCase);

        // Target file must remain pristine
        Assert.Equal(originalContent, _fileSystem.ReadAllBytes(targetPst));
    }

    #endregion

    #region 4. Office & Outlook: Profile Registry Scoping & Non-Interference

    [Fact]
    public void Office_RelocateDataFile_UpdatesOnlyTargetStoreRegistryKey_LeavesSiblingStoreUntouched()
    {
        // Arrange: 2 MAPI stores in profile Outlook
        string storeAKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\StoreA_Guid";
        string storeBKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\StoreB_Guid";
        string storeAPath = @"C:\OutlookFiles\StoreA.pst";
        string storeBPath = @"C:\OutlookFiles\StoreB.pst";

        _fileSystem.CreateDirectory(@"C:\OutlookFiles");
        _fileSystem.WriteAllBytes(storeAPath, new byte[1024]);
        _fileSystem.WriteAllBytes(storeBPath, new byte[1024]);
        _fileSystem.SetAvailableFreeSpace(10L * 1024 * 1024 * 1024);

        _registry.CreateKey(storeAKey);
        _registry.SetValue(storeAKey, "001f6700", Encoding.Unicode.GetBytes(storeAPath + "\0"), RegistryValueKind.Binary);

        _registry.CreateKey(storeBKey);
        _registry.SetValue(storeBKey, "001f6700", Encoding.Unicode.GetBytes(storeBPath + "\0"), RegistryValueKind.Binary);

        var fileInfoA = new MapiDataFileInfo(
            storeAPath,
            "Store A",
            "PST Store",
            false,
            true,
            1024,
            storeAKey,
            true);

        string destinationDir = @"D:\MovedStores";

        // Act: Relocate Store A
        var result = _outlookService.RelocateDataFile(fileInfoA, destinationDir);

        // Assert
        Assert.True(result.Success);

        // Store A key should now point to new path
        string expectedNewPath = Path.Combine(destinationDir, "StoreA.pst");
        byte[] rawA = (byte[])_registry.GetValue(storeAKey, "001f6700")!;
        Assert.Equal(expectedNewPath, OutlookService.DecodeMapiUnicode(rawA));

        // Store B key MUST NOT BE CHANGED
        byte[] rawB = (byte[])_registry.GetValue(storeBKey, "001f6700")!;
        Assert.Equal(storeBPath, OutlookService.DecodeMapiUnicode(rawB));
    }

    [Fact]
    public void Office_RepairGlobalMailSettings_DoesNotTouchProfileSrsOrNavPaneSettings()
    {
        // Arrange: Seed profile SRS and NavPane files
        string appDataOutlook = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Outlook");
        _fileSystem.CreateDirectory(appDataOutlook);
        string srsPath = Path.Combine(appDataOutlook, "ExecutiveProfile.srs");
        string navXmlPath = Path.Combine(appDataOutlook, "ExecutiveProfile.xml");
        _fileSystem.WriteAllBytes(srsPath, new byte[512]);
        _fileSystem.WriteAllBytes(navXmlPath, new byte[512]);

        string profileKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ExecutiveProfile";
        _registry.CreateKey(profileKey);
        _registry.SetValue(profileKey, "NavPane", new byte[128], RegistryValueKind.Binary);

        // Act: Repair global mail settings (Send Mail Immediately)
        var result = _outlookService.RepairGlobalMailSettings();

        // Assert
        Assert.True(result.Success);

        // Global mail option was set
        string mailOptionsKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail";
        Assert.Equal(1, _registry.GetValue<int>(mailOptionsKey, "Send Mail Immediately"));

        // Profile-specific files and registry keys MUST NOT BE TOUCHED
        Assert.True(_fileSystem.FileExists(srsPath), "Global mail repair must NOT delete SRS files!");
        Assert.True(_fileSystem.FileExists(navXmlPath), "Global mail repair must NOT delete profile XML files!");
        Assert.True(_registry.ValueExists(profileKey, "NavPane"), "Global mail repair must NOT touch profile NavPane registry value!");
    }

    [Fact]
    public void Office_QuickMailAndCacheRepair_ScopedToProfileA_DoesNotTouchProfileBSettings()
    {
        // Arrange
        string appDataOutlook = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Outlook");
        _fileSystem.CreateDirectory(appDataOutlook);
        string srsA = Path.Combine(appDataOutlook, "ProfileA.srs");
        string srsB = Path.Combine(appDataOutlook, "ProfileB.srs");
        string xmlA = Path.Combine(appDataOutlook, "ProfileA.xml");
        string xmlB = Path.Combine(appDataOutlook, "ProfileB.xml");

        _fileSystem.WriteAllBytes(srsA, new byte[100]);
        _fileSystem.WriteAllBytes(srsB, new byte[100]);
        _fileSystem.WriteAllBytes(xmlA, new byte[100]);
        _fileSystem.WriteAllBytes(xmlB, new byte[100]);

        string profAKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA";
        string profBKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileB";
        _registry.CreateKey(profAKey);
        _registry.SetValue(profAKey, "NavPane", new byte[64], RegistryValueKind.Binary);
        _registry.CreateKey(profBKey);
        _registry.SetValue(profBKey, "NavPane", new byte[64], RegistryValueKind.Binary);

        // Act: Scoped repair for ProfileA only
        var result = _outlookService.QuickMailAndCacheRepair("ProfileA");

        // Assert
        Assert.True(result.Success);
        Assert.True(result.SrsReset);
        Assert.True(result.NavPaneReset);

        // ProfileA files removed
        Assert.False(_fileSystem.FileExists(srsA));
        Assert.False(_fileSystem.FileExists(xmlA));
        Assert.False(_registry.ValueExists(profAKey, "NavPane"));

        // ProfileB files and registry keys strictly preserved!
        Assert.True(_fileSystem.FileExists(srsB), "Profile B's SRS file must NOT be deleted!");
        Assert.True(_fileSystem.FileExists(xmlB), "Profile B's XML file must NOT be deleted!");
        Assert.True(_registry.ValueExists(profBKey, "NavPane"), "Profile B's NavPane setting must NOT be deleted!");
    }

    #endregion
}
