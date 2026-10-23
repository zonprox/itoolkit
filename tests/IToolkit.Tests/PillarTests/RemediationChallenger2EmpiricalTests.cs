namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class RemediationChallenger2EmpiricalTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly ResourceGuard _resourceGuard;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly IdentityService _identityService;
    private readonly MockCertificateService _certificateService;
    private readonly BackupService _backupService;
    private readonly MockOutlookComService _outlookCom;
    private readonly OutlookService _outlookService;

    public RemediationChallenger2EmpiricalTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _wmi = new MockWmiService();
        _resourceGuard = new ResourceGuard(_fileSystem);
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _identityService = new IdentityService(_processRunner, _fileSystem, _registry, _network, _wmi);
        _certificateService = new MockCertificateService();
        _backupService = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard, _certificateService);

        _outlookCom = new MockOutlookComService();
        _outlookService = new OutlookService(_registry, _atomicRegistry, _fileSystem, _lockGuard, _resourceGuard, _outlookCom);
    }

    #region Pillar 4: BackupService Bookmark Parsing Edge Cases

    [Fact]
    public void ExportBrowserBookmarks_DeeplyNestedAndNonUrlNodes_CountsOnlyUrlNodes()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDir = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        _fileSystem.CreateDirectory(chromeDir);

        // JSON structure: 6 URL bookmarks nested across 4 folder levels, interspersed with non-url nodes (folders, separators)
        string bookmarkJson = @"
{
  ""roots"": {
    ""bookmark_bar"": {
      ""children"": [
        { ""name"": ""Root Bookmark 1"", ""type"": ""url"", ""url"": ""https://site1.com"" },
        {
          ""name"": ""Folder Level 1"",
          ""type"": ""folder"",
          ""children"": [
            { ""name"": ""Separator A"", ""type"": ""separator"" },
            { ""name"": ""L1 Bookmark"", ""type"": ""url"", ""url"": ""https://site2.com"" },
            {
              ""name"": ""Folder Level 2"",
              ""type"": ""folder"",
              ""children"": [
                {
                  ""name"": ""Folder Level 3"",
                  ""type"": ""folder"",
                  ""children"": [
                    { ""name"": ""L3 Bookmark A"", ""type"": ""url"", ""url"": ""https://site3.com"" },
                    { ""name"": ""L3 Bookmark B"", ""type"": ""url"", ""url"": ""https://site4.com"" },
                    { ""name"": ""Custom Type Node"", ""type"": ""search_engine"" }
                  ]
                }
              ]
            }
          ]
        }
      ]
    },
    ""other"": {
      ""children"": [
        { ""name"": ""Other Bookmark 1"", ""type"": ""url"", ""url"": ""https://site5.com"" },
        { ""name"": ""Other Bookmark 2"", ""type"": ""url"", ""url"": ""https://site6.com"" }
      ]
    }
  }
}";

        _fileSystem.WriteAllText(Path.Combine(chromeDir, "Bookmarks"), bookmarkJson);

        var results = _backupService.ExportBrowserBookmarks(@"C:\Backups\Bookmarks");
        Assert.Single(results);
        var chromeRes = results[0];
        Assert.Equal("Chrome", chromeRes.Browser);
        Assert.Equal(6, chromeRes.EntryCount);
    }

    [Fact]
    public void ExportBrowserBookmarks_EmptyJsonObject_YieldsZeroBookmarks()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string edgeDir = Path.Combine(localAppData, "Microsoft", "Edge", "User Data", "Default");
        _fileSystem.CreateDirectory(edgeDir);

        _fileSystem.WriteAllText(Path.Combine(edgeDir, "Bookmarks"), "{}");

        var results = _backupService.ExportBrowserBookmarks(@"C:\Backups\Bookmarks");
        Assert.Single(results);
        Assert.Equal(0, results[0].EntryCount);
    }

    [Fact]
    public void ExportBrowserBookmarks_EmptyRootsStructure_YieldsZeroBookmarks()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDir = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        _fileSystem.CreateDirectory(chromeDir);

        _fileSystem.WriteAllText(Path.Combine(chromeDir, "Bookmarks"), "{\"roots\":{\"bookmark_bar\":{\"children\":[]},\"other\":{\"children\":[]}}}");

        var results = _backupService.ExportBrowserBookmarks(@"C:\Backups\Bookmarks");
        Assert.Single(results);
        Assert.Equal(0, results[0].EntryCount);
    }

    [Fact]
    public void ExportBrowserBookmarks_EmptyFile_ExposesFallbackStubBug()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDir = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        _fileSystem.CreateDirectory(chromeDir);

        // An empty file has 0 bytes (no JSON)
        _fileSystem.WriteAllText(Path.Combine(chromeDir, "Bookmarks"), "");

        var results = _backupService.ExportBrowserBookmarks(@"C:\Backups\Bookmarks");
        Assert.Single(results);
        // An empty file has 0 bookmarks. But BackupService catch block has `count = 1;`!
        // We test whether it returns 0 (expected behavior) or 1 (the buggy fallback stub).
        Assert.Equal(0, results[0].EntryCount);
    }

    [Fact]
    public void ExportBrowserBookmarks_MalformedJson_ExposesFallbackStubBug()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDir = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        _fileSystem.CreateDirectory(chromeDir);

        // Malformed, corrupted JSON
        _fileSystem.WriteAllText(Path.Combine(chromeDir, "Bookmarks"), "{ \"roots\": { unterminated json string ... ");

        var results = _backupService.ExportBrowserBookmarks(@"C:\Backups\Bookmarks");
        Assert.Single(results);
        // Corrupted JSON cannot contain valid bookmarks. It should count 0.
        // But BackupService catch block sets `count = 1;`!
        Assert.Equal(0, results[0].EntryCount);
    }

    #endregion

    #region Pillar 4: BackupService Certificate Export via ICertificateService

    [Fact]
    public void ExportCertificates_WithPassword_ExportsValidPfxRoundTrip()
    {
        string storeName = "My";
        string password = "PfxSecurePassword!999";
        _certificateService.AddSelfSignedCertificate(storeName, "CN=ChallengerTestCert1");
        _certificateService.AddSelfSignedCertificate(storeName, "CN=ChallengerTestCert2");

        var result = _backupService.ExportCertificates(storeName, @"C:\Backups\Certificates", password);

        Assert.True(result.Success);
        Assert.Equal(2, result.ExportedCount);
        Assert.True(_fileSystem.FileExists(result.ExportPath));

        byte[] pfxBytes = _fileSystem.ReadAllBytes(result.ExportPath);
        Assert.NotEmpty(pfxBytes);

        // Verification: load with correct password
        var certCollection = new X509Certificate2Collection();
        certCollection.Import(pfxBytes, password, X509KeyStorageFlags.DefaultKeySet);
        Assert.Equal(2, certCollection.Count);

        // Verification: load with wrong password fails
        var failCollection = new X509Certificate2Collection();
        Assert.ThrowsAny<CryptographicException>(() =>
            failCollection.Import(pfxBytes, "WrongPassword!", X509KeyStorageFlags.DefaultKeySet));
    }

    [Fact]
    public void ExportCertificates_EmptyStore_ReturnsZeroCountAndEmptyFile()
    {
        string storeName = "EmptyStore";
        var result = _backupService.ExportCertificates(storeName, @"C:\Backups\Certificates", "Password123");

        Assert.True(result.Success);
        Assert.Equal(0, result.ExportedCount);
        Assert.Contains("No certificates found", result.Message);
        Assert.True(_fileSystem.FileExists(result.ExportPath));
        Assert.Empty(_fileSystem.ReadAllBytes(result.ExportPath));
    }

    #endregion

    #region Pillar 4: IdentityService Active User Deletion Guardrail

    [Fact]
    public void RemoveLocalAccount_ActiveUserByName_IsBlocked()
    {
        string activeUser = Environment.UserName;
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(activeUser));

        Assert.Contains("Safety Guardrail Violation: Cannot delete the currently active user account", ex.Message);
    }

    [Fact]
    public void RemoveLocalAccount_ActiveUserWithDomainPrefix_IsBlocked()
    {
        string activeUser = Environment.UserName;
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount($@"CONTOSO\{activeUser}"));

        Assert.Contains("Safety Guardrail Violation: Cannot delete the currently active user account", ex.Message);
    }

    [Fact]
    public void RemoveLocalAccount_ActiveUserSid_WhenAccountNameDiffers_MustBeBlocked()
    {
        string activeUser = Environment.UserName;
        string activeSid = "S-1-5-21-999-1002";

        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", activeUser }, { "SID", activeSid }, { "Disabled", false }, { "Lockout", false } }
        });

        string activeProfileKey = $@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{activeSid}";
        _registry.CreateKey(activeProfileKey);

        // Attacker attempts to delete the active user by targeting their SID with an unrelated username
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount("SomeOtherName", activeSid));

        Assert.Contains("Safety Guardrail Violation", ex.Message);
        Assert.True(_registry.KeyExists(activeProfileKey), "Active user ProfileList registry key must NOT be purged!");
    }

    #endregion

    #region Pillar 5: OutlookService RunNewDefaultPstPipeline

    [Fact]
    public void RunNewDefaultPstPipeline_ExcludesSystemFolders_AndClonesUserFolders()
    {
        string targetPst = @"C:\Outlook\NewDefault.pst";
        string sourcePst = @"C:\Outlook\OldSource.pst";
        _fileSystem.WriteAllBytes(sourcePst, new byte[2048]);

        // Add user folders
        _outlookCom.AddStoreFolder(sourcePst, "Projects");
        _outlookCom.AddStoreFolder(sourcePst, "Financials 2026");
        _outlookCom.AddStoreFolder(sourcePst, "Archives");

        // Add standard system folders that should be ignored
        _outlookCom.AddStoreFolder(sourcePst, "Inbox");
        _outlookCom.AddStoreFolder(sourcePst, "Sent Items");
        _outlookCom.AddStoreFolder(sourcePst, "Deleted Items");
        _outlookCom.AddStoreFolder(sourcePst, "Drafts");
        _outlookCom.AddStoreFolder(sourcePst, "Outbox");
        _outlookCom.AddStoreFolder(sourcePst, "Junk E-mail");
        _outlookCom.AddStoreFolder(sourcePst, "Junk Email"); // Note: check without hyphen
        _outlookCom.AddStoreFolder(sourcePst, "Conversation History");
        _outlookCom.AddStoreFolder(sourcePst, "Sync Issues");

        // Add rules
        _outlookCom.AddStoreRule(sourcePst, "Rule 1: Move Invoices");
        _outlookCom.AddStoreRule(sourcePst, "Rule 2: Flag Manager Emails");

        var result = _outlookService.RunNewDefaultPstPipeline(targetPst, sourcePst);

        Assert.True(result.Success);
        Assert.True(result.SizeLimitExpanded);
        Assert.True(_fileSystem.FileExists(targetPst));
        Assert.Equal(2, result.RulesMigratedCount);

        // System folders should not be cloned. User folders cloned should be 3 (or 4 if Junk Email wasn't excluded).
        var clonedFolders = _outlookCom.GetStoreFolders(targetPst);
        Assert.Contains("Projects", clonedFolders);
        Assert.Contains("Financials 2026", clonedFolders);
        Assert.Contains("Archives", clonedFolders);
        Assert.DoesNotContain("Inbox", clonedFolders);
        Assert.DoesNotContain("Sent Items", clonedFolders);
        Assert.DoesNotContain("Deleted Items", clonedFolders);
        Assert.DoesNotContain("Junk Email", clonedFolders); // Verifying Junk Email exclusion
    }

    [Fact]
    public void RunNewDefaultPstPipeline_DefaultDeliveryStoreRegistryUpdate_MustBeAtomicWithBackup()
    {
        string targetPst = @"C:\Outlook\NewDefault.pst";
        string searchKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Search";

        // Set initial state
        _registry.CreateKey(searchKey);
        _registry.SetValue(searchKey, "DefaultStorePath", @"C:\Outlook\OldDefault.pst", RegistryValueKind.String);

        // Run pipeline
        var result = _outlookService.RunNewDefaultPstPipeline(targetPst);

        Assert.True(result.Success);
        Assert.Equal(targetPst, _registry.GetValue<string>(searchKey, "DefaultStorePath"));

        // Empirically verify that default delivery store registry update was executed within an atomic transaction
        // An atomic transaction MUST generate a .reg backup file for the Search key
        string backupDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Backups", "Registry");
        var backupFiles = _fileSystem.EnumerateFiles(backupDir)
            .Where(f => f.Contains("Search", StringComparison.OrdinalIgnoreCase))
            .ToList();

        Assert.NotEmpty(backupFiles);
    }

    #endregion
}
