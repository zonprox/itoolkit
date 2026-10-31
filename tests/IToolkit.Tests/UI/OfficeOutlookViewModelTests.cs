namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Office;
using Moq;
using Xunit;

public class OfficeOutlookViewModelTests
{
    private readonly Mock<IOfficeSuiteService> _officeSuiteMock;
    private readonly Mock<IOutlookService> _outlookMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    public OfficeOutlookViewModelTests()
    {
        _officeSuiteMock = new Mock<IOfficeSuiteService>();
        _outlookMock = new Mock<IOutlookService>();
        _loggerMock = new Mock<IActivityLogger>();
    }

    [Fact]
    public async Task RepairC2RCommand_ExecutesAndReportsExitCode()
    {
        _officeSuiteMock
            .Setup(s => s.RunClickToRunRepair(false))
            .Returns(new ProcessExecutionResult(0, "Repair OK", "", false));

        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        await vm.RepairC2RCommand.ExecuteAsync(null);

        Assert.Contains("triggered successfully", vm.LastOfficeSummary);
        _officeSuiteMock.Verify(s => s.RunClickToRunRepair(false), Times.Once);
    }

    [Fact]
    public async Task Expand100GBCommand_ExpandsRegistryLimit()
    {
        _outlookMock
            .Setup(s => s.ExpandDataFileLimitsTo100GB())
            .Returns(OperationResult.Succeeded("Expanded to 100GB"));

        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        await vm.Expand100GBCommand.ExecuteAsync(null);

        Assert.Contains("expanded to 100GB", vm.LastOutlookSummary);
    }

    [Fact]
    public async Task DiscoverDataFilesCommand_PopulatesDataFilesList()
    {
        var files = new List<MapiDataFileInfo>
        {
            new MapiDataFileInfo(@"C:\Mail\outlook.pst", "Outlook", "Default Store", false, true, 2_147_483_648, @"HKCU\Software\Microsoft\Office", true),
            new MapiDataFileInfo(@"C:\Mail\archive.ost", "Outlook", "Exchange Cache", true, false, 1_073_741_824, @"HKCU\Software\Microsoft\Office", true)
        };

        _outlookMock
            .Setup(s => s.DiscoverDataFiles())
            .Returns(files);

        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        await vm.DiscoverDataFilesCommand.ExecuteAsync(null);

        Assert.Equal(2, vm.DataFiles.Count);
        Assert.Contains("Discovered 2 PST/OST files", vm.LastOutlookSummary);
    }

    [Fact]
    public async Task RunPstPipelineCommand_ExecutesFullPipeline()
    {
        var pipelineResult = new PstPipelineResult(
            TargetPstPath: @"C:\OutlookFiles\NewDefaultStore.pst",
            SizeLimitExpanded: true,
            FoldersClonedCount: 15,
            RulesMigratedCount: 4,
            IsDefaultSet: true,
            Success: true,
            Message: "Pipeline complete"
        );

        _outlookMock
            .Setup(s => s.RunNewDefaultPstPipeline(It.IsAny<string>(), It.IsAny<string?>()))
            .Returns(pipelineResult);

        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        await vm.RunPstPipelineCommand.ExecuteAsync(null);

        Assert.Contains("New Default PST pipeline finished", vm.LastOutlookSummary);
        Assert.Contains("Cloned 15 folders", vm.LastOutlookSummary);
    }

    [Fact]
    public void UserEditPopup_IsolatesPathsAndSettingsPerEmailUser_WithoutGlobalBleed()
    {
        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        var userA = new MapiDataFileInfo(
            @"C:\Users\John\AppData\Local\Microsoft\Outlook\john@corp.pst",
            "john@corp.com",
            "Outlook Personal Folders",
            IsOst: false,
            IsPst: true,
            FileSizeBytes: 500L * 1024 * 1024,
            RegistryPath: @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\JohnProfile\9375CFF0413111d3B88A00104B2A6676\00000002",
            ExistsOnDisk: true);

        var userB = new MapiDataFileInfo(
            @"C:\Users\Alice\AppData\Local\Microsoft\Outlook\alice@corp.ost",
            "alice@corp.com",
            "Microsoft Exchange",
            IsOst: true,
            IsPst: false,
            FileSizeBytes: 2L * 1024 * 1024 * 1024,
            RegistryPath: @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\AliceProfile\9375CFF0413111d3B88A00104B2A6676\00000003",
            ExistsOnDisk: true);

        Assert.False(vm.IsUserEditPopupOpen);

        // Open Edit Popup for User A
        vm.OpenUserEditPopupForItemCommand.Execute(userA);
        Assert.True(vm.IsUserEditPopupOpen);
        Assert.Same(userA, vm.SelectedDataFile);
        Assert.Equal("PST", userA.Format);
        Assert.Equal("JohnProfile", userA.ProfileName);
        Assert.Contains("john@corp.com", vm.EditingUserHeaderSummary);
        Assert.Equal(userA.FilePath, vm.SourcePstPath);
        Assert.Contains("john@corp_NewDefaultStore.pst", vm.TargetPstPath);

        // Customize paths specifically for User A inside the popup
        vm.TargetPstPath = @"D:\JohnMail\John_2026_Default.pst";
        vm.RelocationDestinationDir = @"D:\JohnMail\Relocated";
        vm.BackupDirectory = @"E:\JohnMail\Backups";

        // Close popup and open Edit Popup for User B
        vm.CloseUserEditPopupCommand.Execute(null);
        Assert.False(vm.IsUserEditPopupOpen);

        vm.OpenUserEditPopupForItemCommand.Execute(userB);
        Assert.True(vm.IsUserEditPopupOpen);
        Assert.Same(userB, vm.SelectedDataFile);
        Assert.Equal("OST", userB.Format);
        Assert.Equal("AliceProfile", userB.ProfileName);
        Assert.Contains("alice@corp.com", vm.EditingUserHeaderSummary);
        Assert.Equal(userB.FilePath, vm.SourcePstPath);
        Assert.Contains("alice@corp_NewDefaultStore.pst", vm.TargetPstPath);
        Assert.Equal(@"D:\OutlookFiles", vm.RelocationDestinationDir);
        Assert.Equal(@"D:\OutlookBackups", vm.BackupDirectory);

        // Switch back to User A: User A's customized paths are preserved independently
        vm.OpenUserEditPopupForItemCommand.Execute(userA);
        Assert.Equal(userA.FilePath, vm.SourcePstPath);
        Assert.Equal(@"D:\JohnMail\John_2026_Default.pst", vm.TargetPstPath);
        Assert.Equal(@"D:\JohnMail\Relocated", vm.RelocationDestinationDir);
        Assert.Equal(@"E:\JohnMail\Backups", vm.BackupDirectory);
    }

    [Fact]
    public void OpenManageDialog_InitializesIsolatedDialogViewModel_WithEntityContext()
    {
        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        var storeA = new MapiDataFileInfo(
            @"C:\Users\John\Documents\Outlook Files\JohnArchive.pst",
            "John Archive",
            "Outlook Personal Folders",
            IsOst: false,
            IsPst: true,
            FileSizeBytes: 100L * 1024 * 1024,
            RegistryPath: @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\JohnProfile\StoreKey",
            ExistsOnDisk: true);

        Assert.Null(vm.CurrentManageStore);
        Assert.False(vm.IsManageStoreOpen);

        // Act: Open per-store manage dialog
        vm.OpenManageStoreCommand.Execute(storeA);

        // Assert
        Assert.True(vm.IsManageStoreOpen);
        Assert.NotNull(vm.CurrentManageStore);
        Assert.Same(storeA, vm.CurrentManageStore.Store);
        Assert.Equal("John Archive", vm.CurrentManageStore.DisplayName);
        Assert.Equal("JohnProfile", vm.CurrentManageStore.ProfileName);
        Assert.Equal("PST", vm.CurrentManageStore.Format);
        Assert.Equal(storeA.FilePath, vm.CurrentManageStore.SourcePstPath);

        // Close dialog
        vm.CurrentManageStore.CloseCommand.Execute(null);
        Assert.False(vm.IsManageStoreOpen);
        Assert.Null(vm.CurrentManageStore);
    }

    [Fact]
    public async Task ManageDialog_RelocateAction_UsesDialogDestination_AndScopedEntity()
    {
        var storeA = new MapiDataFileInfo(
            @"C:\Users\John\Documents\Outlook Files\John.pst",
            "John Mailbox",
            "Personal Folders",
            IsOst: false,
            IsPst: true,
            FileSizeBytes: 200L * 1024 * 1024,
            RegistryPath: @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\JohnProfile\StoreKey",
            ExistsOnDisk: true);

        string relocateDest = @"E:\DedicatedFastStorage";
        _outlookMock
            .Setup(s => s.RelocateDataFile(storeA, relocateDest))
            .Returns(new DataFileRelocationResult(
                storeA.FilePath,
                Path.Combine(relocateDest, "John.pst"),
                storeA.FileSizeBytes,
                true,
                false,
                true,
                true,
                "Relocation successful"));

        var dialogVm = new ManageMapiStoreViewModel(
            storeA,
            _outlookMock.Object,
            null,
            null,
            _loggerMock.Object);

        dialogVm.RelocationDestinationDir = relocateDest;

        // Act
        await dialogVm.RelocateStoreCommand.ExecuteAsync(null);

        // Assert
        _outlookMock.Verify(s => s.RelocateDataFile(storeA, relocateDest), Times.Once);
        Assert.True(dialogVm.IsStoreRelocated);
        Assert.Contains("Relocated to", dialogVm.OperationStatus);
    }

    [Fact]
    public async Task ManageDialog_QuickMailRepair_TargetsOwningProfile()
    {
        var storeA = new MapiDataFileInfo(
            @"C:\Users\John\AppData\Local\Microsoft\Outlook\john.ost",
            "john@corp.com",
            "Exchange Store",
            IsOst: true,
            IsPst: false,
            FileSizeBytes: 500L * 1024 * 1024,
            RegistryPath: @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\CorporateProfile\StoreKey",
            ExistsOnDisk: true);

        _outlookMock
            .Setup(s => s.QuickMailAndCacheRepair("CorporateProfile"))
            .Returns(new QuickMailRepairResult(true, true, true, true, true, true, "Mailbox repaired"));

        var dialogVm = new ManageMapiStoreViewModel(
            storeA,
            _outlookMock.Object,
            null,
            null,
            _loggerMock.Object);

        // Act
        await dialogVm.QuickMailRepairCommand.ExecuteAsync(null);

        // Assert: Scoped exclusively to store's profile
        _outlookMock.Verify(s => s.QuickMailAndCacheRepair("CorporateProfile"), Times.Once);
        Assert.Contains("Mailbox repaired", dialogVm.OperationStatus);
    }

    [Fact]
    public void GlobalRelocationDestinationDir_WhenUpdatedOutsidePopup_UpdatesDefaultDirForSubsequentFiles()
    {
        var vm = new OfficeOutlookViewModel(_officeSuiteMock.Object, _outlookMock.Object, _loggerMock.Object);

        var file1 = new MapiDataFileInfo(@"C:\Mail\1.pst", "File 1", "PST", false, true, 1024, "", true);
        var file2 = new MapiDataFileInfo(@"C:\Mail\2.pst", "File 2", "PST", false, true, 2048, "", true);

        vm.DataFiles.Add(file1);
        vm.DataFiles.Add(file2);

        // Initial selection
        vm.SelectedDataFile = file1;
        Assert.Equal(@"D:\OutlookFiles", vm.RelocationDestinationDir);

        // Change relocation destination globally outside popup
        string customRelocation = @"Z:\EnterpriseShare\Outlook";
        vm.RelocationDestinationDir = customRelocation;
        Assert.Equal(customRelocation, vm.RelocationDestinationDir);

        // Switch selection to file2: MUST NOT revert to "D:\OutlookFiles"
        vm.SelectedDataFile = file2;
        Assert.Equal(customRelocation, vm.RelocationDestinationDir);
    }
}
