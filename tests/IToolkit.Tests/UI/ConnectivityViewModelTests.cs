namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using Moq;
using Xunit;

public class ConnectivityViewModelTests
{
    private readonly Mock<IConnectivityService> _connectivityMock;
    private readonly Mock<IPrinterService> _printerMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    public ConnectivityViewModelTests()
    {
        _connectivityMock = new Mock<IConnectivityService>();
        _printerMock = new Mock<IPrinterService>();
        _loggerMock = new Mock<IActivityLogger>();

        _printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new[] { "0x0000011b", "0x00000709" });
    }

    [Fact]
    public async Task RemediateNetworkStackCommand_ExecutesAndSetsStatus()
    {
        var result = new NetworkRemediationResult(
            Success: true,
            DnsFlushed: true,
            DhcpRenewed: true,
            ArpCleared: true,
            WinsockReset: true,
            TcpIpReset: true,
            NlaReset: true,
            ProxyReset: true,
            RequiresReboot: true,
            Message: "Remediation complete"
        );

        _connectivityMock
            .Setup(s => s.RemediateNetworkStack())
            .Returns(result);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);

        Assert.Contains("Remediated: DNS flushed", vm.LastNetworkStatus);
        Assert.Contains("[Reboot Recommended]", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task FlushDnsCommand_CallsServiceAndUpdatesStatus()
    {
        _connectivityMock
            .Setup(s => s.FlushDns())
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.FlushDnsCommand.ExecuteAsync(null);

        Assert.Contains("flushed successfully", vm.LastNetworkStatus);
        _connectivityMock.Verify(s => s.FlushDns(), Times.Once);
    }

    [Fact]
    public async Task PurgeSpoolerCommand_DeletesFilesAndRestartsService()
    {
        var result = new SpoolerQueueResult(
            SpoolerStopped: true,
            SpoolFilesPurged: true,
            SpoolerRestarted: true,
            PurgedFilesCount: 8,
            Success: true,
            Message: "Spooler purged"
        );

        _printerMock
            .Setup(s => s.PurgeSpoolerQueue())
            .Returns(result);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.PurgeSpoolerCommand.ExecuteAsync(null);

        Assert.Contains("8 spool files deleted", vm.LastPrinterStatus);
        _printerMock.Verify(s => s.PurgeSpoolerQueue(), Times.Once);
    }

    [Fact]
    public async Task RemediatePrinterErrorCommand_CallsSpecificRemediation()
    {
        var remediation = new PrinterRemediationResult(
            ErrorCode: "0x0000011b",
            RemediationAction: "Set RpcAuthnLevelPrivacyEnabled to 0 in registry",
            PolicyApplied: true,
            ServicesRestarted: true,
            Success: true,
            Message: "Fix applied"
        );

        _printerMock
            .Setup(s => s.RemediatePrinterError("0x0000011b"))
            .Returns(remediation);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object)
        {
            SelectedErrorCode = "0x0000011b"
        };

        await vm.RemediatePrinterErrorCommand.ExecuteAsync(null);

        Assert.Contains("0x0000011b", vm.LastPrinterStatus);
        Assert.Contains("RpcAuthnLevelPrivacyEnabled", vm.LastPrinterStatus);
    }
}
