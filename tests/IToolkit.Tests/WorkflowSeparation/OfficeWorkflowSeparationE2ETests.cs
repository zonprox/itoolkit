namespace IToolkit.Tests.WorkflowSeparation;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Comprehensive E2E test suite validating architectural and workflow separation
/// between global system-wide fixes and per-entity operations in Module 2 (Office & Outlook).
/// Tiers:
///  - Tier 1: Feature Coverage (Isolated Happy Path)
///  - Tier 2: Boundary & Corner Cases (Headroom checks, hash mismatches, non-existent files)
///  - Tier 3: Non-Interference (Store A vs Store B, Global policy vs physical stores)
///  - Tier 4: Real-World Scenarios (End-to-End Mail Store Administrator Lifecycle)
/// </summary>
public class OfficeWorkflowSeparationE2ETests
{
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockProcessRunner _processRunner;
    private readonly ProcessLockGuard _lockGuard;
    private readonly ResourceGuard _resourceGuard;
    private readonly MockOutlookComService _outlookCom;
    private readonly TestActivityLogger _logger;
    private readonly OutlookService _outlookService;
    private readonly OfficeSuiteService _officeSuiteService;

    public OfficeWorkflowSeparationE2ETests()
    {
        _registry = new MockRegistryService();
        _fileSystem = new MockFileSystemService();
        _processRunner = new MockProcessRunner();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _resourceGuard = new ResourceGuard(_fileSystem);
        _outlookCom = new MockOutlookComService();
        _logger = new TestActivityLogger();

        _outlookService = new OutlookService(
            _registry,
            _atomicRegistry,
            _fileSystem,
            _lockGuard,
            _resourceGuard,
            _outlookCom,
            _logger);

        _officeSuiteService = new OfficeSuiteService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _logger);
    }

    #region Tier 1: Feature Coverage (Isolated Happy Path)

    [Fact]
    public void Tier1_Global_ExpandDataFileLimitsTo100GB_SetsRegistryPolicy()
    {
        // Act: Apply global 100GB limit policy
        var result = _outlookService.ExpandDataFileLimitsTo100GB();

        // Assert
        Assert.True(result.Success);

        // Verify HKCU policies for both PST and OST are set to 100GB (102400 MB)
        long expectedMaxMb = 100L * 1024; // 102400
        long expectedWarnMb = (long)(expectedMaxMb * 0.95); // 97280

        Assert.Equal(expectedMaxMb, _registry.GetValue<long>(@"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST", "MaxLargeFileSize"));
        Assert.Equal(expectedWarnMb, _registry.GetValue<long>(@"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST", "WarnLargeFileSize"));
        Assert.Equal(expectedMaxMb, _registry.GetValue<long>(@"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\OST", "MaxLargeFileSize"));
        Assert.Equal(expectedWarnMb, _registry.GetValue<long>(@"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\OST", "WarnLargeFileSize"));
    }

    [Fact]
    public void Tier1_Global_RepairGlobalMailSettings_SetsOptionsWithoutMutatingProfiles()
    {
        // Arrange
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string srsFile = Path.Combine(appData, "Microsoft", "Outlook", "DefaultProfile.srs");
        _fileSystem.CreateDirectory(Path.GetDirectoryName(srsFile)!);
        _fileSystem.WriteAllText(srsFile, "SRS Data");

        // Act
        var result = _outlookService.RepairGlobalMailSettings();

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail", "Send Mail Immediately"));
        Assert.True(_fileSystem.FileExists(srsFile), "Global mail settings fix must not wipe profile SRS files");
    }

    [Fact]
    public void Tier1_Global_ResetOfficeIdentityCache_PurgesRegistryAndCacheDirs()
    {
        // Arrange: seed identity registry and local app data cache
        string identityKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity";
        _registry.SetValue(identityKey, "Version", 1, Microsoft.Win32.RegistryValueKind.DWord);
        _registry.SetValue(Path.Combine(identityKey, "Identities"), "Count", 2, Microsoft.Win32.RegistryValueKind.DWord);

        // Act
        var result = _officeSuiteService.ResetOfficeIdentityCache();

        // Assert
        Assert.True(result.Success);
        Assert.False(_registry.KeyExists(Path.Combine(identityKey, "Identities")));
    }

    [Fact]
    public void Tier1_Global_WordExcelPowerPoint_QuickRepairs_ExecuteInIsolation()
    {
        // Act
        var wordRes = _officeSuiteService.WordQuickRepair();
        var excelRes = _officeSuiteService.ExcelQuickRepair();
        var pptRes = _officeSuiteService.PowerPointQuickRepair();

        // Assert
        Assert.True(wordRes.Success);
        Assert.True(excelRes.Success);
        Assert.True(pptRes.Success);
        Assert.Equal("Word", wordRes.AppName);
        Assert.Equal("Excel", excelRes.AppName);
        Assert.Equal("PowerPoint", pptRes.AppName);
    }

    [Fact]
    public void Tier1_PerEntity_BackupDataFile_BacksUpDesignatedFileWithSha256()
    {
        // Arrange
        string sourcePst = @"C:\Mail\Alice.pst";
        string backupDir = @"D:\OutlookBackups";
        string content = "Alice Mailbox Data 2026";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(sourcePst)!);
        _fileSystem.WriteAllText(sourcePst, content);

        // Act
        var result = _outlookService.BackupDataFile(sourcePst, backupDir);

        // Assert
        Assert.True(result.Success);
        string targetBackup = Path.Combine(backupDir, "Alice.pst");
        string targetSha = Path.Combine(backupDir, "Alice.pst.sha256");

        Assert.True(_fileSystem.FileExists(targetBackup));
        Assert.True(_fileSystem.FileExists(targetSha));

        string actualHash = _fileSystem.ComputeSha256(targetBackup);
        string recordedHash = _fileSystem.ReadAllText(targetSha);
        Assert.Contains(actualHash, recordedHash, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Tier1_PerEntity_CompactDataFile_InvokesComForDesignatedPathOnly()
    {
        // Arrange
        string storePath = @"C:\OutlookFiles\Alice.pst";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(storePath)!);
        _fileSystem.WriteAllText(storePath, "Store Content for Compacting");

        var comMock = new Mock<IOutlookComService>();
        comMock.Setup(c => c.CompactStore(It.IsAny<string>())).Returns(true);

        var scopedService = new OutlookService(
            _registry,
            _atomicRegistry,
            _fileSystem,
            _lockGuard,
            _resourceGuard,
            comMock.Object,
            _logger);

        // Act
        var result = scopedService.CompactDataFile(storePath);

        // Assert
        Assert.True(result.Success);
        comMock.Verify(c => c.CompactStore(storePath), Times.Once);
    }

    [Fact]
    public void Tier1_PerEntity_RelocateDataFile_MovesDesignatedStoreAndUpdatesRegistry()
    {
        // Arrange
        string sourcePst = @"C:\Outlook\Alice.pst";
        string destDir = @"D:\OutlookStores";
        string payload = "Alice's Primary Data Store";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(sourcePst)!);
        _fileSystem.WriteAllText(sourcePst, payload);
        string expectedSha = _fileSystem.ComputeSha256(sourcePst);

        string profileKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\StoreKey";
        byte[] unicodeBytes = Encoding.Unicode.GetBytes(sourcePst + "\0");
        _registry.SetValue(profileKey, "001f6700", unicodeBytes, Microsoft.Win32.RegistryValueKind.Binary);

        // Act
        var result = _outlookService.RelocateDataFile(sourcePst, destDir);

        // Assert
        Assert.True(result.Success);
        Assert.True(result.Sha256Matched);
        Assert.True(result.RegistryUpdated);

        string relocatedPst = Path.Combine(destDir, "Alice.pst");
        Assert.True(_fileSystem.FileExists(relocatedPst));
        Assert.False(_fileSystem.FileExists(sourcePst));
        Assert.Equal(expectedSha, _fileSystem.ComputeSha256(relocatedPst));

        // Verify registry updated to new path
        byte[] updatedBytes = (byte[])_registry.GetValue(profileKey, "001f6700")!;
        Assert.Equal(relocatedPst, OutlookService.DecodeMapiUnicode(updatedBytes));
    }

    [Fact]
    public void Tier1_PerEntity_QuickMailAndCacheRepair_TargetsDesignatedProfile()
    {
        // Arrange: seed profile SRS and NavPane
        string targetProfile = "ExecutiveProfile";
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string srsFile = Path.Combine(appData, "Microsoft", "Outlook", $"{targetProfile}.srs");
        _fileSystem.CreateDirectory(Path.GetDirectoryName(srsFile)!);
        _fileSystem.WriteAllText(srsFile, "SRS data");

        // Act
        var result = _outlookService.QuickMailAndCacheRepair(targetProfile);

        // Assert
        Assert.True(result.Success);
        Assert.True(result.SrsReset);
        Assert.False(_fileSystem.FileExists(srsFile));
    }

    #endregion

    #region Tier 2: Boundary & Corner Cases

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("\t")]
    public void Tier2_Boundary_InvalidOrNonExistentStorePaths_ReturnsFailureGracefully(string invalidPath)
    {
        // Act & Assert: RelocateDataFile throws FileNotFoundException on missing file
        Assert.Throws<FileNotFoundException>(() => _outlookService.RelocateDataFile(invalidPath, @"D:\Stores"));

        // BackupDataFile and CompactDataFile return structured failed OperationResult
        var backupRes = _outlookService.BackupDataFile(invalidPath, @"D:\Backups");
        var compactRes = _outlookService.CompactDataFile(invalidPath);

        Assert.False(backupRes.Success);
        Assert.False(compactRes.Success);
    }

    [Fact]
    public void Tier2_Boundary_RestoreDataFile_MismatchedSha256_RejectsRestoration()
    {
        // Arrange
        string backupPath = @"D:\Backups\Corrupt.pst";
        string targetPath = @"C:\Restored\Corrupt.pst";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(backupPath)!);
        _fileSystem.WriteAllText(backupPath, "Real Content");

        string bogusExpectedSha = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";

        // Act
        var result = _outlookService.RestoreDataFile(backupPath, targetPath, bogusExpectedSha);

        // Assert
        Assert.False(result.Success);
        Assert.Contains("Pre-restore verification failed", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(_fileSystem.FileExists(targetPath));
    }

    [Fact]
    public void Tier2_Boundary_RelocateDataFile_InsufficientHeadroom_FailsGracefully()
    {
        // Arrange: 1024 bytes file requiring 1.2x headroom (1228 bytes), but only 500 bytes free space
        string sourcePst = @"C:\Mail\GiantArchive.pst";
        string destDir = @"D:\SmallDrive";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(sourcePst)!);

        byte[] fakeData = new byte[1024];
        _fileSystem.WriteAllBytes(sourcePst, fakeData);

        // Set available free space on mock filesystem to 500 bytes
        _fileSystem.SetAvailableFreeSpace(500);

        // Act & Assert: ResourceGuard throws InvalidOperationException when disk headroom check fails
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _outlookService.RelocateDataFile(sourcePst, destDir));

        Assert.Contains("Insufficient disk space", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.True(_fileSystem.FileExists(sourcePst)); // Original file remains untouched
    }

    [Fact]
    public void Tier2_Boundary_SpecialCharactersAndSpacesInStorePath_HandledSafely()
    {
        // Arrange
        string sourcePst = @"C:\Outlook Stores\O'Connor (Archive) [2026].pst";
        string destDir = @"D:\Relocated Stores\Archive Vault";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(sourcePst)!);
        _fileSystem.WriteAllText(sourcePst, "Special characters mailbox payload");
        string expectedSha = _fileSystem.ComputeSha256(sourcePst);

        // Act
        var result = _outlookService.RelocateDataFile(sourcePst, destDir);

        // Assert
        Assert.True(result.Success);
        string relocatedFile = Path.Combine(destDir, "O'Connor (Archive) [2026].pst");
        Assert.True(_fileSystem.FileExists(relocatedFile));
        Assert.Equal(expectedSha, _fileSystem.ComputeSha256(relocatedFile));
    }

    #endregion

    #region Tier 3: Cross-Feature Combinations & Non-Interference

    [Fact]
    public void Tier3_NonInterference_RelocatingStoreA_DoesNotMoveOrMutateStoreB()
    {
        // Arrange
        string storeA = @"C:\Mail\Alice.pst";
        string storeB = @"C:\Mail\Bob.pst";
        string destDir = @"D:\RelocatedAlice";

        _fileSystem.CreateDirectory(@"C:\Mail");
        _fileSystem.WriteAllText(storeA, "Alice's Private Emails");
        _fileSystem.WriteAllText(storeB, "Bob's Confidential Vault");

        string originalBobHash = _fileSystem.ComputeSha256(storeB);

        // Act: Relocate Store A only
        var result = _outlookService.RelocateDataFile(storeA, destDir);

        // Assert
        Assert.True(result.Success);

        // Store A moved
        Assert.False(_fileSystem.FileExists(storeA));
        Assert.True(_fileSystem.FileExists(Path.Combine(destDir, "Alice.pst")));

        // Store B remains completely untouched at original location with identical content
        Assert.True(_fileSystem.FileExists(storeB));
        Assert.Equal(originalBobHash, _fileSystem.ComputeSha256(storeB));
        Assert.False(_fileSystem.FileExists(Path.Combine(destDir, "Bob.pst")));
    }

    [Fact]
    public void Tier3_NonInterference_CompactingStoreA_DoesNotCompactStoreB()
    {
        // Arrange
        string storeA = @"C:\Mail\Alice.pst";
        string storeB = @"C:\Mail\Bob.pst";
        _fileSystem.CreateDirectory(@"C:\Mail");
        _fileSystem.WriteAllText(storeA, "Alice Data");
        _fileSystem.WriteAllText(storeB, "Bob Data");

        var comMock = new Mock<IOutlookComService>();
        comMock.Setup(c => c.CompactStore(It.IsAny<string>())).Returns(true);

        var scopedService = new OutlookService(
            _registry,
            _atomicRegistry,
            _fileSystem,
            _lockGuard,
            _resourceGuard,
            comMock.Object,
            _logger);

        // Act
        var result = scopedService.CompactDataFile(storeA);

        // Assert
        Assert.True(result.Success);
        comMock.Verify(c => c.CompactStore(storeA), Times.Once);
        comMock.Verify(c => c.CompactStore(storeB), Times.Never);
    }

    [Fact]
    public void Tier3_NonInterference_GlobalLimitExpansion_DoesNotAlterStoreFilesOnDisk()
    {
        // Arrange
        string storeA = @"C:\Mail\UserStore.pst";
        _fileSystem.CreateDirectory(@"C:\Mail");
        _fileSystem.WriteAllText(storeA, "Existing PST Data");
        string initialHash = _fileSystem.ComputeSha256(storeA);

        // Act: Run global 100GB limit expansion
        var result = _outlookService.ExpandDataFileLimitsTo100GB();

        // Assert
        Assert.True(result.Success);

        // Registry updated
        Assert.True(_registry.KeyExists(@"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST"));

        // Physical store on disk must NOT be modified
        Assert.True(_fileSystem.FileExists(storeA));
        Assert.Equal(initialHash, _fileSystem.ComputeSha256(storeA));
    }

    [Fact]
    public void Tier3_NonInterference_GlobalScrubOrC2RRepair_DoesNotMutateUserPstArchives()
    {
        // Arrange
        string archiveStore = @"D:\OutlookArchives\History2025.pst";
        _fileSystem.CreateDirectory(Path.GetDirectoryName(archiveStore)!);
        _fileSystem.WriteAllText(archiveStore, "Archived historical mail");
        string archiveHash = _fileSystem.ComputeSha256(archiveStore);

        // Act: Run global Word/Excel/C2R repairs
        var c2rRes = _officeSuiteService.RepairClickToRunService();
        var wordRes = _officeSuiteService.WordQuickRepair();
        var excelRes = _officeSuiteService.ExcelQuickRepair();

        // Assert
        Assert.True(c2rRes);
        Assert.True(wordRes.Success);
        Assert.True(excelRes.Success);

        // Archive PST must remain intact
        Assert.True(_fileSystem.FileExists(archiveStore));
        Assert.Equal(archiveHash, _fileSystem.ComputeSha256(archiveStore));
    }

    [Fact]
    public void Tier3_NonInterference_QuickMailRepair_TargetProfile_DoesNotMutateSiblingProfile()
    {
        // Arrange: seed profile A and profile B SRS and NavPane
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string outlookDir = Path.Combine(appData, "Microsoft", "Outlook");
        _fileSystem.CreateDirectory(outlookDir);

        string srsA = Path.Combine(outlookDir, "ProfileA.srs");
        string srsB = Path.Combine(outlookDir, "ProfileB.srs");
        string xmlA = Path.Combine(outlookDir, "ProfileA.xml");
        string xmlB = Path.Combine(outlookDir, "ProfileB.xml");

        _fileSystem.WriteAllText(srsA, "SRS A");
        _fileSystem.WriteAllText(srsB, "SRS B");
        _fileSystem.WriteAllText(xmlA, "<XmlA/>");
        _fileSystem.WriteAllText(xmlB, "<XmlB/>");

        string keyA = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA";
        string keyB = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileB";
        _registry.CreateKey(keyA);
        _registry.CreateKey(keyB);
        _registry.SetValue(keyA, "NavPane", new byte[] { 1 }, Microsoft.Win32.RegistryValueKind.Binary);
        _registry.SetValue(keyB, "NavPane", new byte[] { 2 }, Microsoft.Win32.RegistryValueKind.Binary);

        // Act: Target Profile A
        var result = _outlookService.QuickMailAndCacheRepair("ProfileA");

        // Assert
        Assert.True(result.Success);
        Assert.False(_fileSystem.FileExists(srsA));
        Assert.False(_fileSystem.FileExists(xmlA));
        Assert.False(_registry.ValueExists(keyA, "NavPane"));

        // Profile B must remain untouched
        Assert.True(_fileSystem.FileExists(srsB));
        Assert.True(_fileSystem.FileExists(xmlB));
        Assert.True(_registry.ValueExists(keyB, "NavPane"));
    }

    [Fact]
    public void Tier3_NonInterference_RelocateDataFile_ScopedRegistryPath_DoesNotMutateSiblingProfileKey()
    {
        // Arrange
        string storeA = @"C:\Mail\StoreA.pst";
        string storeB = @"C:\Mail\StoreB.pst";
        _fileSystem.CreateDirectory(@"C:\Mail");
        _fileSystem.WriteAllText(storeA, "Data A");
        _fileSystem.WriteAllText(storeB, "Data B");

        string keyA = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileA\StoreKey";
        string keyB = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\ProfileB\StoreKey";
        _registry.CreateKey(keyA);
        _registry.CreateKey(keyB);
        _registry.SetValue(keyA, "001f6700", Encoding.Unicode.GetBytes(storeA + "\0"), Microsoft.Win32.RegistryValueKind.Binary);
        _registry.SetValue(keyB, "001f6700", Encoding.Unicode.GetBytes(storeB + "\0"), Microsoft.Win32.RegistryValueKind.Binary);

        var fileInfoA = new MapiDataFileInfo(
            storeA,
            "StoreA",
            "PST",
            false,
            true,
            1024,
            keyA,
            true);

        string destDir = @"D:\TargetDir";

        // Act
        var result = _outlookService.RelocateDataFile(fileInfoA, destDir);

        // Assert
        Assert.True(result.Success);
        string relocatedA = Path.Combine(destDir, "StoreA.pst");
        Assert.True(_fileSystem.FileExists(relocatedA));
        Assert.False(_fileSystem.FileExists(storeA));

        // Key A updated
        byte[] bytesA = (byte[])_registry.GetValue(keyA, "001f6700")!;
        Assert.Equal(relocatedA, OutlookService.DecodeMapiUnicode(bytesA));

        // Key B sibling must remain untouched
        Assert.True(_fileSystem.FileExists(storeB));
        byte[] bytesB = (byte[])_registry.GetValue(keyB, "001f6700")!;
        Assert.Equal(storeB, OutlookService.DecodeMapiUnicode(bytesB));
    }

    #endregion

    #region Tier 4: Real-World Scenarios (End-to-End Admin Lifecycles)

    [Fact]
    public void Tier4_RealWorld_FullMailboxLifecycle_Discover_Relocate_GlobalExpand_BackupRestore()
    {
        // Step 1: Discover Stores in Registry
        string profileKey1 = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Default\Store1";
        string profileKey2 = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Default\Store2";
        string executivePst = @"C:\Users\CEO\Documents\Outlook Files\Executive.pst";
        string sharedSalesPst = @"C:\Users\CEO\Documents\Outlook Files\SharedSales.pst";

        _fileSystem.CreateDirectory(Path.GetDirectoryName(executivePst)!);
        _fileSystem.WriteAllText(executivePst, "Executive Confidential Communications 2026");
        _fileSystem.WriteAllText(sharedSalesPst, "Shared Sales Leads 2026");

        _registry.SetValue(profileKey1, "001f6700", Encoding.Unicode.GetBytes(executivePst + "\0"), Microsoft.Win32.RegistryValueKind.Binary);
        _registry.SetValue(profileKey2, "001f6700", Encoding.Unicode.GetBytes(sharedSalesPst + "\0"), Microsoft.Win32.RegistryValueKind.Binary);

        var discoveredStores = _outlookService.DiscoverDataFiles();
        Assert.Contains(discoveredStores, s => s.FilePath.Equals(executivePst, StringComparison.OrdinalIgnoreCase));
        Assert.Contains(discoveredStores, s => s.FilePath.Equals(sharedSalesPst, StringComparison.OrdinalIgnoreCase));

        // Step 2: Relocate Executive PST to Dedicated Fast SSD volume
        string fastSsdDir = @"E:\HighSpeedStores";
        var relocateResult = _outlookService.RelocateDataFile(executivePst, fastSsdDir);
        Assert.True(relocateResult.Success);
        string relocatedExecutivePst = Path.Combine(fastSsdDir, "Executive.pst");
        Assert.True(_fileSystem.FileExists(relocatedExecutivePst));
        Assert.False(_fileSystem.FileExists(executivePst));

        // SharedSales PST must remain at original location
        Assert.True(_fileSystem.FileExists(sharedSalesPst));

        // Step 3: Apply Global 100GB Expansion Policy
        var expandResult = _outlookService.ExpandDataFileLimitsTo100GB();
        Assert.True(expandResult.Success);

        // Step 4: Perform Verified Backup of Executive PST
        string backupDir = @"Z:\EnterpriseBackups";
        var backupResult = _outlookService.BackupDataFile(relocatedExecutivePst, backupDir);
        Assert.True(backupResult.Success);

        string backupFile = Path.Combine(backupDir, "Executive.pst");
        string backupHash = _fileSystem.ComputeSha256(backupFile);

        // Step 5: Test Disaster Recovery Restoration
        string disasterRecoveryTarget = @"E:\RecoveredStores\Executive_Restored.pst";
        var restoreResult = _outlookService.RestoreDataFile(backupFile, disasterRecoveryTarget, backupHash);
        Assert.True(restoreResult.Success);
        Assert.True(_fileSystem.FileExists(disasterRecoveryTarget));
        Assert.Equal(backupHash, _fileSystem.ComputeSha256(disasterRecoveryTarget));
    }

    #endregion
}
