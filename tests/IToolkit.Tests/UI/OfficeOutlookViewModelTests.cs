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
}
