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

    [Fact]
    public async Task RemediateAllPrintersCommand_ExecutesBatchAndUpdatesStatus_WithBackupCountAndActions()
    {
        var batchResult = new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Both,
            ActionsExecuted: new[] { "RpcAuthnLevel", "SpoolerHealth", "ClearStalledJobs" },
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: new[] { "C:\\Backups\\print_backup.reg" },
            SpoolerRestarted: true,
            Success: true,
            Message: "Full remediation successful",
            QueuePurgedCount: 3,
            CleanedNePortsCount: 2
        );

        _printerMock
            .Setup(p => p.RemediateAll())
            .Returns(batchResult);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateAll(), Times.Once);
        Assert.Contains("Remediate All completed", vm.LastPrinterStatus);
        Assert.Contains("3 action(s)", vm.LastPrinterStatus);
        Assert.Contains("1 backup(s)", vm.LastPrinterStatus);
        Assert.Contains("3 queue job(s)", vm.LastPrinterStatus);
        Assert.Contains("2 Ne port(s)", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogSuccess(nameof(ConnectivityViewModel), It.Is<string>(s => s.Contains("Remediate All completed"))), Times.Once);
    }

    [Fact]
    public async Task RemediateAllPrintersCommand_WhenCancelledByUser_DoesNotCallService()
    {
        var confirmMock = new Mock<ISafetyConfirmationService>();
        confirmMock
            .Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(false);

        var vm = new ConnectivityViewModel(
            _connectivityMock.Object,
            _printerMock.Object,
            _loggerMock.Object,
            confirmationService: confirmMock.Object);

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateAll(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogWarning(nameof(ConnectivityViewModel), It.Is<string>(s => s.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RemediateClientBatchCommand_CallsServiceAndUpdatesStatus()
    {
        var batchResult = new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Client,
            ActionsExecuted: new[] { "PointAndPrintAdmin", "SpoolerQueue", "NePorts" },
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: new[] { "C:\\Backups\\client_backup.reg" },
            SpoolerRestarted: true,
            Success: true,
            Message: "Client batch applied"
        );

        _printerMock
            .Setup(p => p.RemediateRole(PrinterRemediationRole.Client))
            .Returns(batchResult);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RemediateClientBatchCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateRole(PrinterRemediationRole.Client), Times.Once);
        Assert.Contains("Client Batch completed", vm.LastPrinterStatus);
        Assert.Contains("PointAndPrintAdmin", vm.LastPrinterStatus);
        Assert.Contains("1 backup(s)", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task RemediateServerBatchCommand_CallsServiceAndUpdatesStatus()
    {
        var batchResult = new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Server,
            ActionsExecuted: new[] { "RpcAuthnLevel", "RemoteRpcEndPoint" },
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: new[] { "C:\\Backups\\server_backup.reg" },
            SpoolerRestarted: true,
            Success: true,
            Message: "Server batch applied"
        );

        _printerMock
            .Setup(p => p.RemediateRole(PrinterRemediationRole.Server))
            .Returns(batchResult);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RemediateServerBatchCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateRole(PrinterRemediationRole.Server), Times.Once);
        Assert.Contains("Server Batch completed", vm.LastPrinterStatus);
        Assert.Contains("RpcAuthnLevel", vm.LastPrinterStatus);
        Assert.Contains("1 backup(s)", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task AuditPointAndPrintPolicyCommand_CallsAuditAndReportsPosture()
    {
        var auditResult = new PointAndPrintPolicyAuditResult(
            RpcAuthnLevelPrivacyEnabled: false,
            RestrictDriverInstallationToAdministrators: true,
            NoWarningNoElevationOnInstall: false,
            UpdatePromptSettings: 0,
            IsVulnerableToCVE20211678: true,
            PostureDescription: "Vulnerable to CVE-2021-1678 RPC bypass",
            Recommendations: new[] { "Enable RpcAuthnLevelPrivacyEnabled" }
        );

        _printerMock
            .Setup(p => p.AuditPointAndPrintPolicy())
            .Returns(auditResult);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.AuditPointAndPrintPolicyCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.AuditPointAndPrintPolicy(), Times.Once);
        Assert.Contains("CVE-2021-1678=Vulnerable", vm.LastPrinterStatus);
        Assert.Contains("Posture=Vulnerable", vm.LastPrinterStatus);
        Assert.Contains("RpcAuthn=Disabled", vm.LastPrinterStatus);
        Assert.Contains("RestrictAdmin=Enabled", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogWarning(nameof(ConnectivityViewModel), It.Is<string>(s => s.Contains("CVE-2021-1678=Vulnerable"))), Times.Once);
    }

    [Fact]
    public async Task RefreshPrinterConnectionsCommand_CallsServiceAndUpdatesStatus()
    {
        var resetResult = new PrinterConnectionResetResult(
            DiscoveredPrinters: 4,
            ReconnectedPrinters: 3,
            RemovedStalePrinters: 1,
            Details: new[] { "Reconnected \\\\server\\printer1" },
            Success: true,
            Message: "Connections refreshed"
        );

        _printerMock
            .Setup(p => p.ResetPrinterConnections(true, null))
            .Returns(resetResult);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RefreshPrinterConnectionsCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.ResetPrinterConnections(true, null), Times.Once);
        Assert.Contains("3 reconnected", vm.LastPrinterStatus);
        Assert.Contains("1 stale removed", vm.LastPrinterStatus);
        Assert.Contains("4 discovered", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task InspectSpoolerStatusCommand_CallsServiceAndReportsQueueMetrics()
    {
        var spoolerStatus = new SpoolerServiceStatus(
            IsRunning: true,
            ServiceStatus: "Running",
            SpoolDirectory: "C:\\Windows\\System32\\spool\\PRINTERS",
            PendingJobFileCount: 5,
            TotalQueueSizeBytes: 20480,
            HasStalledJobs: true,
            Pid: 1234,
            StartupType: "Automatic",
            Summary: "Spooler active"
        );

        _printerMock
            .Setup(p => p.GetSpoolerStatus())
            .Returns(spoolerStatus);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.InspectSpoolerStatusCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.GetSpoolerStatus(), Times.Once);
        Assert.Contains("Running", vm.LastPrinterStatus);
        Assert.Contains("PID 1234", vm.LastPrinterStatus);
        Assert.Contains("5 file(s)", vm.LastPrinterStatus);
        Assert.Contains("20480 bytes", vm.LastPrinterStatus);
        Assert.Contains("[Stalled Jobs Detected]", vm.LastPrinterStatus);
    }
}
