namespace IToolkit.Tests.PillarTests;

using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class OutlookServiceTests
{
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockProcessRunner _processRunner;
    private readonly ProcessLockGuard _lockGuard;
    private readonly ResourceGuard _resourceGuard;
    private readonly OutlookService _service;

    public OutlookServiceTests()
    {
        _registry = new MockRegistryService();
        _fileSystem = new MockFileSystemService();
        _processRunner = new MockProcessRunner();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _resourceGuard = new ResourceGuard(_fileSystem);
        _service = new OutlookService(_registry, _atomicRegistry, _fileSystem, _lockGuard, _resourceGuard);
    }

    [Fact]
    public void MapiDecoding_CorrectlyExtractsUnicodeAndAnsiFilePaths()
    {
        string expectedUnicode = @"C:\Users\John\Documents\Outlook Files\Archive.pst";
        byte[] unicodeBytes = Encoding.Unicode.GetBytes(expectedUnicode + "\0\0extra_padding");
        string decodedUnicode = OutlookService.DecodeMapiUnicode(unicodeBytes);
        Assert.Equal(expectedUnicode, decodedUnicode);

        string expectedAnsi = @"C:\Users\John\AppData\Local\Microsoft\Outlook\mailbox.ost";
        byte[] ansiBytes = Encoding.ASCII.GetBytes(expectedAnsi + "\0extra_bytes");
        string decodedAnsi = OutlookService.DecodeMapiAnsi(ansiBytes);
        Assert.Equal(expectedAnsi, decodedAnsi);
    }

    [Fact]
    public void DiscoverDataFiles_DiscoversPstAndOstFromRegistryAndFilesystem()
    {
        string profileKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375CFF0413111d3B88A00104B2A6676";
        _registry.CreateKey(profileKey);

        string pstPath = @"C:\Users\John\Documents\Outlook Files\Work.pst";
        byte[] binPath = Encoding.Unicode.GetBytes(pstPath + "\0\0");
        _registry.SetValue(profileKey, "001f6700", binPath, RegistryValueKind.Binary);
        _fileSystem.WriteAllBytes(pstPath, new byte[1024]);

        var files = _service.DiscoverDataFiles();

        Assert.NotEmpty(files);
        var found = files.FirstOrDefault(f => f.FilePath.Equals(pstPath, StringComparison.OrdinalIgnoreCase));
        Assert.NotNull(found);
        Assert.True(found.IsPst);
        Assert.False(found.IsOst);
        Assert.True(found.ExistsOnDisk);
    }

    [Fact]
    public void QuickMailAndCacheRepair_PurgesRoamCache_StrictlyPreservingAutoComplete()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string roamCache = Path.Combine(localAppData, "Microsoft", "Outlook", "RoamCache");
        _fileSystem.CreateDirectory(roamCache);

        // Files in RoamCache
        string autocompleteFile = Path.Combine(roamCache, "Stream_Autocomplete_0_7A8B9C.dat");
        string junkCache = Path.Combine(roamCache, "Stream_Calendar_1.dat");

        _fileSystem.WriteAllText(autocompleteFile, "nk2_user_cache_data");
        _fileSystem.WriteAllText(junkCache, "stale_calendar_cache");

        var result = _service.QuickMailAndCacheRepair();

        Assert.True(result.Success);
        Assert.True(result.AutocompletePreserved);

        // Crucial test: Autocomplete MUST NOT be deleted
        Assert.True(_fileSystem.FileExists(autocompleteFile), "Stream_Autocomplete_*.dat must be preserved to prevent losing user contacts/autocomplete!");
        Assert.False(_fileSystem.FileExists(junkCache), "Other stale RoamCache entries should be purged");

        // Outbox send immediately flag check
        var sendImmediately = _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail", "Send Mail Immediately");
        Assert.Equal(1, sendImmediately);
    }

    [Fact]
    public void ExpandDataFileLimitsTo100GB_SetsDWORDValuesAcrossPoliciesAndPstKeys()
    {
        var result = _service.ExpandDataFileLimitsTo100GB();

        Assert.True(result.Success);

        var keys = new[]
        {
            @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST",
            @"HKCU\Software\Microsoft\Office\16.0\Outlook\PST",
            @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\OST",
            @"HKCU\Software\Microsoft\Office\16.0\Outlook\OST"
        };

        foreach (var key in keys)
        {
            Assert.Equal(102400, _registry.GetValue<int>(key, "MaxLargeFileSize"));
            Assert.Equal(97280, _registry.GetValue<int>(key, "WarnLargeFileSize"));
            Assert.Equal(102400, _registry.GetValue<int>(key, "MaxFileSize"));
            Assert.Equal(97280, _registry.GetValue<int>(key, "WarnFileSize"));
        }
    }

    [Fact]
    public void RunNewDefaultPstPipeline_CreatesPst_ClonesFolders_AndSetsDefault()
    {
        var outlookCom = new MockOutlookComService();
        var service = new OutlookService(_registry, _atomicRegistry, _fileSystem, _lockGuard, _resourceGuard, outlookCom);

        string targetPst = @"C:\Users\John\Documents\Outlook Files\NewMain.pst";
        string sourcePst = @"C:\Users\John\Documents\Outlook Files\OldMain.pst";
        _fileSystem.WriteAllBytes(sourcePst, new byte[2048]);

        // Populate source PST with 3 user folders and 2 excluded system folders
        outlookCom.AddStoreFolder(sourcePst, "Projects");
        outlookCom.AddStoreFolder(sourcePst, "Invoices");
        outlookCom.AddStoreFolder(sourcePst, "Personal");
        outlookCom.AddStoreFolder(sourcePst, "Inbox");        // Excluded
        outlookCom.AddStoreFolder(sourcePst, "Deleted Items"); // Excluded

        // Populate source PST with 2 rules
        outlookCom.AddStoreRule(sourcePst, "Move Invoices to Invoices");
        outlookCom.AddStoreRule(sourcePst, "Flag VIP Customers");

        var result = service.RunNewDefaultPstPipeline(targetPst, sourcePst);

        Assert.True(result.Success);
        Assert.True(result.SizeLimitExpanded);
        Assert.True(_fileSystem.FileExists(targetPst));
        Assert.Equal(3, result.FoldersClonedCount); // Exactly 3 user folders cloned
        Assert.Equal(2, result.RulesMigratedCount); // Exactly 2 rules migrated
        Assert.True(result.IsDefaultSet);
        Assert.True(outlookCom.DefaultStoreSet);
        Assert.Equal(targetPst, outlookCom.LastDefaultStorePath);
    }

    [Fact]
    public void RelocateDataFile_Succeeds_WhenHeadroomIsSufficientAndSha256Matches()
    {
        string src = @"C:\Outlook\archive.pst";
        string dstDir = @"D:\Outlook";
        _fileSystem.WriteAllText(src, "sample_pst_data_stream");

        // 100 GB available headroom (far exceeds 1.2x of sample data)
        _fileSystem.SetAvailableFreeSpace(100L * 1024 * 1024 * 1024);

        var result = _service.RelocateDataFile(src, dstDir);

        Assert.True(result.Success);
        Assert.True(result.Sha256Matched);
        Assert.False(_fileSystem.FileExists(src), "Source file should be removed after verified relocation");
        Assert.True(_fileSystem.FileExists(result.DestinationPath), "Destination file should exist");
    }

    [Fact]
    public void RelocateDataFile_Throws_WhenFreeDiskSpaceIsLessThan1_2x()
    {
        string src = @"C:\Outlook\big_mailbox.pst";
        string dstDir = @"D:\Outlook";
        byte[] data = new byte[10 * 1024 * 1024]; // 10 MB
        _fileSystem.WriteAllBytes(src, data);

        // Set available space to 11 MB (less than 12 MB needed for 1.2x headroom)
        _fileSystem.SetAvailableFreeSpace(11 * 1024 * 1024);

        Assert.Throws<InvalidOperationException>(() => _service.RelocateDataFile(src, dstDir));
    }

    [Fact]
    public void BackupAndRestoreDataFile_ValidatesSha256Integrity()
    {
        string srcPst = @"C:\Outlook\important.pst";
        string backupDir = @"E:\Backups\Outlook";
        _fileSystem.WriteAllText(srcPst, "critical_pst_records");

        // 1. Backup
        var backupRes = _service.BackupDataFile(srcPst, backupDir);
        Assert.True(backupRes.Success);
        Assert.NotNull(backupRes.BackupPath);
        Assert.True(_fileSystem.FileExists(backupRes.BackupPath!));

        string originalHash = _resourceGuard.ComputeSha256(srcPst);

        // 2. Restore with valid hash
        string restoredTarget = @"C:\Outlook\restored_important.pst";
        var restoreRes = _service.RestoreDataFile(backupRes.BackupPath!, restoredTarget, originalHash);
        Assert.True(restoreRes.Success);
        Assert.True(_fileSystem.FileExists(restoredTarget));

        // 3. Restore with invalid hash should fail
        var corruptedRestore = _service.RestoreDataFile(backupRes.BackupPath!, @"C:\Outlook\fail.pst", "BAD_HASH_12345");
        Assert.False(corruptedRestore.Success);
    }

    [Fact]
    public void RepairGlobalMailSettings_SetsSendMailImmediately_WithoutDeletingSrsOrNavPane()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string appDataOutlook = Path.Combine(appData, "Microsoft", "Outlook");
        _fileSystem.CreateDirectory(appDataOutlook);

        string srsFile = Path.Combine(appDataOutlook, "ProfileA.srs");
        string navXml = Path.Combine(appDataOutlook, "ProfileA.xml");
        _fileSystem.WriteAllText(srsFile, "SRS content");
        _fileSystem.WriteAllText(navXml, "<NavPaneXml/>");

        string profKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA";
        _registry.CreateKey(profKey);
        _registry.SetValue(profKey, "NavPane", new byte[] { 1, 2, 3 }, RegistryValueKind.Binary);

        var result = _service.RepairGlobalMailSettings();

        Assert.True(result.Success);
        Assert.Equal(1, _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail", "Send Mail Immediately"));

        // Crucial non-interference: profile SRS, XML, and registry NavPane MUST NOT be deleted
        Assert.True(_fileSystem.FileExists(srsFile), "Profile SRS must be preserved during global mail repair");
        Assert.True(_fileSystem.FileExists(navXml), "Profile NavPane XML must be preserved during global mail repair");
        Assert.True(_registry.ValueExists(profKey, "NavPane"), "Profile registry NavPane must be preserved during global mail repair");
    }

    [Fact]
    public void QuickMailAndCacheRepair_WhenProfileSpecified_OnlyDeletesTargetProfileSrsAndNavPane_LeavesSiblingUntouched()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string appDataOutlook = Path.Combine(appData, "Microsoft", "Outlook");
        _fileSystem.CreateDirectory(appDataOutlook);

        string srsA = Path.Combine(appDataOutlook, "ProfileA.srs");
        string srsB = Path.Combine(appDataOutlook, "ProfileB.srs");
        string xmlA = Path.Combine(appDataOutlook, "ProfileA.xml");
        string xmlB = Path.Combine(appDataOutlook, "ProfileB.xml");

        _fileSystem.WriteAllText(srsA, "SRS A");
        _fileSystem.WriteAllText(srsB, "SRS B");
        _fileSystem.WriteAllText(xmlA, "<XmlA/>");
        _fileSystem.WriteAllText(xmlB, "<XmlB/>");

        string keyA = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA";
        string keyB = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileB";
        _registry.CreateKey(keyA);
        _registry.CreateKey(keyB);
        _registry.SetValue(keyA, "NavPane", new byte[] { 1 }, RegistryValueKind.Binary);
        _registry.SetValue(keyB, "NavPane", new byte[] { 2 }, RegistryValueKind.Binary);

        var result = _service.QuickMailAndCacheRepair("ProfileA");

        Assert.True(result.Success);
        Assert.True(result.SrsReset);
        Assert.True(result.NavPaneReset);

        // Profile A targeted items deleted
        Assert.False(_fileSystem.FileExists(srsA), "Profile A SRS should be deleted");
        Assert.False(_fileSystem.FileExists(xmlA), "Profile A XML should be deleted");
        Assert.False(_registry.ValueExists(keyA, "NavPane"), "Profile A NavPane should be deleted");

        // Profile B sibling items MUST remain completely untouched
        Assert.True(_fileSystem.FileExists(srsB), "Profile B SRS must not be deleted");
        Assert.True(_fileSystem.FileExists(xmlB), "Profile B XML must not be deleted");
        Assert.True(_registry.ValueExists(keyB, "NavPane"), "Profile B NavPane must not be deleted");
    }

    [Fact]
    public void RelocateDataFile_WithRegistryPath_OnlyUpdatesTargetProfileKey_LeavesSiblingUntouched()
    {
        string storeA = @"C:\Mail\StoreA.pst";
        string storeB = @"C:\Mail\StoreB.pst";
        _fileSystem.CreateDirectory(@"C:\Mail");
        _fileSystem.WriteAllText(storeA, "Store A payload");
        _fileSystem.WriteAllText(storeB, "Store B payload");
        _fileSystem.SetAvailableFreeSpace(100L * 1024 * 1024 * 1024);

        string keyA = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA\StoreKey";
        string keyB = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileB\StoreKey";
        _registry.CreateKey(keyA);
        _registry.CreateKey(keyB);
        _registry.SetValue(keyA, "001f6700", Encoding.Unicode.GetBytes(storeA + "\0"), RegistryValueKind.Binary);
        _registry.SetValue(keyB, "001f6700", Encoding.Unicode.GetBytes(storeB + "\0"), RegistryValueKind.Binary);

        var fileInfoA = new MapiDataFileInfo(
            storeA,
            "StoreA",
            "PST Store",
            IsOst: false,
            IsPst: true,
            FileSizeBytes: 1024,
            RegistryPath: keyA,
            ExistsOnDisk: true);

        string destDir = @"D:\RelocatedStores";
        var result = _service.RelocateDataFile(fileInfoA, destDir);

        Assert.True(result.Success);
        string relocatedA = Path.Combine(destDir, "StoreA.pst");
        Assert.True(_fileSystem.FileExists(relocatedA));
        Assert.False(_fileSystem.FileExists(storeA));

        // Profile A key updated
        byte[] bytesA = (byte[])_registry.GetValue(keyA, "001f6700")!;
        Assert.Equal(relocatedA, OutlookService.DecodeMapiUnicode(bytesA));

        // Profile B sibling key and store MUST be completely unchanged
        Assert.True(_fileSystem.FileExists(storeB));
        byte[] bytesB = (byte[])_registry.GetValue(keyB, "001f6700")!;
        Assert.Equal(storeB, OutlookService.DecodeMapiUnicode(bytesB));
    }
}
