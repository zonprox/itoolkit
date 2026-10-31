namespace IToolkit.Tests.PillarTests;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Identity;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class IdentityAndBackupServiceTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly ResourceGuard _resourceGuard;
    private readonly IdentityService _identityService;
    private readonly BackupService _backupService;

    public IdentityAndBackupServiceTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService();
        _wmi = new MockWmiService();
        _resourceGuard = new ResourceGuard(_fileSystem);

        _identityService = new IdentityService(_processRunner, _fileSystem, _registry, _network, _wmi);
        _backupService = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard);
    }

    [Fact]
    public void GetLocalAccounts_ExtractsAccountsViaWmi()
    {
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", false }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "TechUser" }, { "SID", "S-1-5-21-999-1001" }, { "Disabled", false }, { "Lockout", true } }
        });

        var accounts = _identityService.GetLocalAccounts();

        Assert.Equal(2, accounts.Count);
        var admin = accounts.First(a => a.Username == "Administrator");
        Assert.True(admin.IsBuiltInAdmin);
        Assert.True(admin.IsAdmin);
        Assert.True(admin.IsEnabled);

        var tech = accounts.First(a => a.Username == "TechUser");
        Assert.False(tech.IsBuiltInAdmin);
        Assert.True(tech.IsLocked);
    }

    [Fact]
    public void RemoveLocalAccount_Throws_WhenTargetIsBuiltInAdminOrActiveUser()
    {
        // Guardrail 1: Built-in Administrator protection
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount("Administrator", "S-1-5-21-999-500"));

        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount("CustomAdminName", "S-1-5-21-999-500"));

        // Guardrail 2: Currently active user protection
        string currentUser = Environment.UserName;
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(currentUser, "S-1-5-21-999-1002"));
    }

    [Fact]
    public void RemoveLocalAccount_SucceedsForStandardUser_AndPurgesProfileDirectory()
    {
        string targetUser = "DepartedWorker";
        string targetSid = "S-1-5-21-999-1005";
        string profileDir = $@"C:\Users\{targetUser}";
        _fileSystem.CreateDirectory(profileDir);

        string profileListKey = $@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{targetSid}";
        _registry.CreateKey(profileListKey);

        bool result = _identityService.RemoveLocalAccount(targetUser, targetSid);

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains($"net.exe user \"{targetUser}\" /delete"));
        Assert.False(_fileSystem.DirectoryExists(profileDir), "User profile directory should be removed");
        Assert.False(_registry.KeyExists(profileListKey), "ProfileList key should be purged");
    }

    [Fact]
    public void EnableBuiltInAdministrator_AndResetPassword_LocatesSid500Account()
    {
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "Administrateur" }, { "SID", "S-1-5-21-123-500" }, { "Disabled", true }, { "Lockout", false } }
        });

        bool enabled = _identityService.EnableBuiltInAdministrator();
        bool pwReset = _identityService.ResetBuiltInAdministratorPassword("NewP@ssw0rd!");

        Assert.True(enabled);
        Assert.True(pwReset);

        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("Administrateur") && c.Contains("/active:yes"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("Administrateur") && c.Contains("NewP@ssw0rd!"));
    }

    [Fact]
    public void TestDomainReachability_ProbesDnsAndPorts_88_389_445()
    {
        string domain = "corp.contoso.com";
        _network.SetHostReachable(domain, true);
        _network.SetPortOpen(domain, 88, true);   // Kerberos
        _network.SetPortOpen(domain, 389, true);  // LDAP
        _network.SetPortOpen(domain, 445, true);  // SMB

        var result = _identityService.TestDomainReachability(domain);

        Assert.True(result.IsReachable);
        Assert.True(result.DnsResolved);
        Assert.True(result.KerberosPortOpen);
        Assert.True(result.LdapPortOpen);
        Assert.True(result.SmbPortOpen);
    }

    [Fact]
    public void DisjoinDomain_EnforcesLocalAdminLockoutDefense()
    {
        // 1. Without enabled local admin: MUST throw!
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", true }, { "Lockout", false } }
        });

        Assert.Throws<InvalidOperationException>(() => _identityService.DisjoinDomain("WORKGROUP"));

        // 2. With enabled local admin: succeeds
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", false }, { "Lockout", false } }
        });

        bool disjoinOk = _identityService.DisjoinDomain("WORKGROUP");
        Assert.True(disjoinOk);
    }

    [Fact]
    public void GetUserProfileMap_DetectsOneDriveRedirection()
    {
        string shellFoldersKey = @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders";
        _registry.CreateKey(shellFoldersKey);
        _registry.SetValue(shellFoldersKey, "Desktop", @"C:\Users\John\OneDrive - Contoso\Desktop", RegistryValueKind.ExpandString);
        _registry.SetValue(shellFoldersKey, "Personal", @"C:\Users\John\OneDrive - Contoso\Documents", RegistryValueKind.ExpandString);

        var map = _backupService.GetUserProfileMap("John");

        Assert.Equal("John", map.Username);
        Assert.True(map.IsOneDriveRedirected, "Should flag true when paths contain OneDrive");
        Assert.Contains("OneDrive", map.DesktopPath);
    }

    [Fact]
    public void ExportBrowserBookmarks_DiscoversChromeAndEdgeProfiles_AndExtractsBookmarks()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDefault = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        string edgeProfile1 = Path.Combine(localAppData, "Microsoft", "Edge", "User Data", "Profile 1");

        _fileSystem.CreateDirectory(chromeDefault);
        _fileSystem.CreateDirectory(edgeProfile1);

        string chromeJson = "{\"roots\":{\"bookmark_bar\":{\"children\":[{\"name\":\"Google\",\"type\":\"url\",\"url\":\"https://google.com\"},{\"name\":\"GitHub\",\"type\":\"url\",\"url\":\"https://github.com\"}]}}}";
        string edgeJson = "{\"roots\":{\"bookmark_bar\":{\"children\":[{\"name\":\"Bing\",\"type\":\"url\",\"url\":\"https://bing.com\"}]}}}";

        _fileSystem.WriteAllText(Path.Combine(chromeDefault, "Bookmarks"), chromeJson);
        _fileSystem.WriteAllText(Path.Combine(edgeProfile1, "Bookmarks"), edgeJson);

        string outDir = @"C:\Backups\Bookmarks";
        var results = _backupService.ExportBrowserBookmarks(outDir);

        Assert.Equal(2, results.Count);
        var chromeResult = results.First(r => r.Browser == "Chrome" && r.ProfileName == "Default");
        Assert.Equal(2, chromeResult.EntryCount);
        var edgeResult = results.First(r => r.Browser == "Edge" && r.ProfileName == "Profile 1");
        Assert.Equal(1, edgeResult.EntryCount);
    }

    [Fact]
    public void ExportCertificates_WithMockCertificateService_ExportsGenuinePfx()
    {
        var certMock = new MockCertificateService();
        certMock.AddSelfSignedCertificate("My", "CN=TestUser1");
        certMock.AddSelfSignedCertificate("My", "CN=TestUser2");

        var backupService = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard, certMock);

        string outDir = @"C:\Backups\Certs";
        var result = backupService.ExportCertificates("My", outDir, "SecurePfxPass123!");

        Assert.True(result.Success);
        Assert.Equal(2, result.ExportedCount);
        Assert.True(_fileSystem.FileExists(result.ExportPath));
        byte[] pfxBytes = _fileSystem.ReadAllBytes(result.ExportPath);
        Assert.NotEmpty(pfxBytes);
    }

    [Theory]
    [InlineData(0, true)]
    [InlineData(1, true)]
    [InlineData(4, true)]
    [InlineData(7, true)]
    [InlineData(8, false)]
    [InlineData(16, false)]
    public void RunRobocopySync_EvaluatesBitmaskExitCodesCorrectly(int exitCode, bool expectedSuccess)
    {
        _processRunner.SetCommandResult("robocopy.exe \"C:\\Data\" \"D:\\Backup\" /E /MT:16 /COPY:DAT /R:2 /W:2 /XJ /ZB /NP",
            new ProcessExecutionResult(exitCode, "Robocopy output", string.Empty, false));

        var result = _backupService.RunRobocopySync(@"C:\Data", @"D:\Backup", mirror: false);

        Assert.Equal(expectedSuccess, result.IsSuccess);
        Assert.Equal(exitCode, result.ExitCode);
    }

    [Fact]
    public void CreateAndValidateBackupManifest_DetectsIntact_Corrupted_AndMissingFiles()
    {
        string srcDir = @"C:\UserData";
        _fileSystem.CreateDirectory(srcDir);
        string file1 = Path.Combine(srcDir, "doc1.txt");
        string file2 = Path.Combine(srcDir, "doc2.txt");
        _fileSystem.WriteAllText(file1, "content_1");
        _fileSystem.WriteAllText(file2, "content_2");

        string manifestFile = Path.Combine(srcDir, BackupService.ManifestFileName);

        // 1. Create Manifest
        var manifest = _backupService.CreateBackupManifest(srcDir, manifestFile);
        Assert.Equal(2, manifest.Files.Count);
        Assert.True(_fileSystem.FileExists(manifestFile));

        // 2. Validate Intact
        var validRes = _backupService.ValidateBackupManifest(srcDir, manifestFile);
        Assert.True(validRes.IsIntact);
        Assert.Equal(2, validRes.MatchedCount);
        Assert.Equal(0, validRes.MissingCount);
        Assert.Equal(0, validRes.CorruptedCount);

        // 3. Corrupt one file
        _fileSystem.WriteAllText(file1, "TAMPERED_CONTENT");
        var corruptRes = _backupService.ValidateBackupManifest(srcDir, manifestFile);
        Assert.False(corruptRes.IsIntact);
        Assert.Equal(1, corruptRes.CorruptedCount);

        // 4. Delete one file
        _fileSystem.DeleteFile(file2);
        var missingRes = _backupService.ValidateBackupManifest(srcDir, manifestFile);
        Assert.False(missingRes.IsIntact);
        Assert.Equal(1, missingRes.MissingCount);
    }

    [Fact]
    public void RestoreProfileData_PreFlightValidationPreventsCorruptedRestore()
    {
        string backupDir = @"E:\Backup";
        _fileSystem.CreateDirectory(backupDir);
        string f1 = Path.Combine(backupDir, "file.txt");
        _fileSystem.WriteAllText(f1, "original");

        string manifestPath = Path.Combine(backupDir, BackupService.ManifestFileName);
        _backupService.CreateBackupManifest(backupDir, manifestPath);

        // Tamper with file
        _fileSystem.WriteAllText(f1, "tampered");

        // Restore should abort
        var result = _backupService.RestoreProfileData(backupDir, manifestPath);

        Assert.False(result.Success);
        Assert.False(result.Validated);
        Assert.Contains("Pre-flight restore validation failed", result.Message);
    }

    [Fact]
    public void ResetUserPassword_InvokesNetUserWithProperEscaping()
    {
        bool success = _identityService.ResetUserPassword("TargetUser", "P@ss\"word\"123");

        Assert.True(success);
        Assert.Contains("net.exe user \"TargetUser\" \"P@ss\\\"word\\\"123\"", _processRunner.ExecutedCommands);
    }

    [Fact]
    public void ResetUserPassword_WhenNetUserFails_ReturnsFalse()
    {
        _processRunner.SetCommandResult(
            "net.exe user \"LockedUser\" \"NewPass123\"",
            new ProcessExecutionResult(2, "", "System error 5 has occurred. Access is denied.", false));

        bool success = _identityService.ResetUserPassword("LockedUser", "NewPass123");

        Assert.False(success);
    }

    [Fact]
    public void GetUserProfileMap_WhenTargetUserSpecified_ResolvesSpecifiedUserDirectory()
    {
        var map = _backupService.GetUserProfileMap("CustomUser");

        Assert.Equal("CustomUser", map.Username);
        Assert.Equal(@"C:\Users\CustomUser", map.ProfilePath);
    }

    [Fact]
    public void RestoreProfileData_WhenTargetUserSpecified_RestoresIntoTargetUserDirectory()
    {
        string backupDir = @"E:\ValidBackup";
        _fileSystem.CreateDirectory(backupDir);
        string f1 = Path.Combine(backupDir, "data.txt");
        _fileSystem.WriteAllText(f1, "verified_content");

        string manifestPath = Path.Combine(backupDir, BackupService.ManifestFileName);
        _backupService.CreateBackupManifest(backupDir, manifestPath);

        var result = _backupService.RestoreProfileData(backupDir, manifestPath, "RestoredAlice");

        Assert.True(result.Success);
        Assert.True(result.Validated);
        Assert.Equal(1, result.FilesRestored);
        Assert.True(_fileSystem.FileExists(@"C:\Users\RestoredAlice\data.txt"));
        Assert.Equal("verified_content", _fileSystem.ReadAllText(@"C:\Users\RestoredAlice\data.txt"));
    }
}
