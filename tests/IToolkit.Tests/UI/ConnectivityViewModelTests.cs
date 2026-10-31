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

    [Fact]
    public void OpenAdapterEditPopupCommand_PopulatesAdapterStateAndOpensPopup()
    {
        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" }, false, "255.255.255.0", "192.168.1.1", new[] { "1.1.1.1", "8.8.8.8" }, 1492);
        vm.AvailableAdapters.Add(adapter);
        vm.SelectedAdapter = adapter;

        vm.OpenAdapterEditPopupCommand.Execute(null);

        Assert.True(vm.IsAdapterEditPopupOpen);
        Assert.NotNull(vm.SelectedEditingAdapter);
        Assert.Equal("Ethernet 1", vm.SelectedEditingAdapter.Name);
        Assert.False(vm.AdapterUseDhcpIp);
        Assert.Equal("192.168.1.100", vm.AdapterStaticIp);
        Assert.Equal("255.255.255.0", vm.AdapterSubnetMask);
        Assert.Equal("192.168.1.1", vm.AdapterDefaultGateway);
        Assert.Equal("1.1.1.1", vm.AdapterPreferredDns);
        Assert.Equal("8.8.8.8", vm.AdapterAlternateDns);
        Assert.Equal(1492, vm.AdapterMtu);
    }

    [Fact]
    public void OpenAdapterEditPopupForItemCommand_PopulatesItemStateAndOpensPopup()
    {
        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("wlan0", "Wi-Fi", "Intel Wi-Fi", "66-77-88-99-AA-BB", "Up", new[] { "10.0.0.50" }, true);

        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        Assert.True(vm.IsAdapterEditPopupOpen);
        Assert.Equal("Wi-Fi", vm.SelectedEditingAdapter?.Name);
        Assert.True(vm.AdapterUseDhcpIp);
    }

    [Fact]
    public void CloseAdapterEditPopupCommand_ClosesPopupAndClearsSelection()
    {
        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);
        Assert.True(vm.IsAdapterEditPopupOpen);

        vm.CloseAdapterEditPopupCommand.Execute(null);

        Assert.False(vm.IsAdapterEditPopupOpen);
        Assert.Null(vm.SelectedEditingAdapter);
    }

    [Fact]
    public async Task SaveAdapterIpConfigCommand_InvokesServiceWithConfig()
    {
        _connectivityMock
            .Setup(c => c.SetAdapterIpConfiguration("Ethernet 1", It.IsAny<AdapterIpConfig>()))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        vm.AdapterUseDhcpIp = false;
        vm.AdapterStaticIp = "192.168.1.200";
        vm.AdapterSubnetMask = "255.255.255.0";
        vm.AdapterDefaultGateway = "192.168.1.1";

        await vm.SaveAdapterIpConfigCommand.ExecuteAsync(null);

        _connectivityMock.Verify(c => c.SetAdapterIpConfiguration("Ethernet 1", It.Is<AdapterIpConfig>(cfg => !cfg.UseDhcp && cfg.IpAddress == "192.168.1.200")), Times.Once);
        Assert.Contains("IP configuration for 'Ethernet 1' updated successfully", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task SaveAdapterDnsConfigCommand_InvokesServiceWithConfig()
    {
        _connectivityMock
            .Setup(c => c.SetAdapterDnsConfiguration("Ethernet 1", It.IsAny<AdapterDnsConfig>()))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        vm.AdapterUseDhcpDns = false;
        vm.AdapterPreferredDns = "1.1.1.1";
        vm.AdapterAlternateDns = "8.8.8.8";

        await vm.SaveAdapterDnsConfigCommand.ExecuteAsync(null);

        _connectivityMock.Verify(c => c.SetAdapterDnsConfiguration("Ethernet 1", It.Is<AdapterDnsConfig>(cfg => !cfg.UseDhcp && cfg.PreferredDns == "1.1.1.1" && cfg.AlternateDns == "8.8.8.8")), Times.Once);
        Assert.Contains("DNS configuration for 'Ethernet 1' updated successfully", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task SetAdapterMtuCommand_InvokesServiceWithMtu()
    {
        _connectivityMock
            .Setup(c => c.SetAdapterMtu("Ethernet 1", 1492))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        vm.AdapterMtu = 1492;
        await vm.SetAdapterMtuCommand.ExecuteAsync(null);

        _connectivityMock.Verify(c => c.SetAdapterMtu("Ethernet 1", 1492), Times.Once);
        Assert.Contains("MTU for 'Ethernet 1' set to 1492", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task ToggleAdapterEnableCommand_DisablesUpAdapter()
    {
        _connectivityMock
            .Setup(c => c.DisableAdapter("Ethernet 1"))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        await vm.ToggleAdapterEnableCommand.ExecuteAsync(null);

        _connectivityMock.Verify(c => c.DisableAdapter("Ethernet 1"), Times.Once);
        Assert.Contains("disabled successfully", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task RenewAdapterDhcpCommand_InvokesServiceForTargetAdapter()
    {
        _connectivityMock
            .Setup(c => c.ReleaseRenewAdapterDhcp("Ethernet 1"))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var adapter = new NetworkAdapterInfo("eth0", "Ethernet 1", "Intel Adapter", "00-11-22-33-44-55", "Up", new[] { "192.168.1.100" });
        vm.OpenAdapterEditPopupForItemCommand.Execute(adapter);

        await vm.RenewAdapterDhcpCommand.ExecuteAsync(null);

        _connectivityMock.Verify(c => c.ReleaseRenewAdapterDhcp("Ethernet 1"), Times.Once);
        Assert.Contains("DHCP lease for 'Ethernet 1' renewed successfully", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task RefreshPrintersCommand_PopulatesAvailablePrinters()
    {
        var printers = new List<PrinterInfo>
        {
            new("Canon Office", "Canon Driver", "USB001", true, false, "Ready", 0),
            new("HP LaserJet", "HP Driver", "192.168.1.50", false, true, "Ready", 2)
        };

        _printerMock.Setup(p => p.GetPrinters()).Returns(printers);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);

        await vm.RefreshPrintersCommand.ExecuteAsync(null);

        Assert.Equal(2, vm.AvailablePrinters.Count);
        Assert.Equal("Canon Office", vm.SelectedPrinter?.Name);
        Assert.Contains("Discovered 2 installed printer(s)", vm.LastPrinterStatus);
    }

    [Fact]
    public void OpenPrinterEditPopupCommand_PopulatesPrinterStateAndOpensPopup()
    {
        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo("HP LaserJet", "HP Driver", "192.168.1.50", false, true, "Ready", 1);
        vm.AvailablePrinters.Add(printer);
        vm.SelectedPrinter = printer;

        vm.OpenPrinterEditPopupCommand.Execute(null);

        Assert.True(vm.IsPrinterEditPopupOpen);
        Assert.Equal("HP LaserJet", vm.SelectedEditingPrinter?.Name);
    }

    [Fact]
    public void ClosePrinterEditPopupCommand_ClosesPopupAndClearsSelection()
    {
        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo("HP LaserJet", "HP Driver", "192.168.1.50", false, true, "Ready", 1);
        vm.OpenPrinterEditPopupForItemCommand.Execute(printer);
        Assert.True(vm.IsPrinterEditPopupOpen);

        vm.ClosePrinterEditPopupCommand.Execute(null);

        Assert.False(vm.IsPrinterEditPopupOpen);
        Assert.Null(vm.SelectedEditingPrinter);
    }

    [Fact]
    public async Task PrintTestPageCommand_InvokesServiceForTargetPrinter()
    {
        _printerMock
            .Setup(p => p.PrintTestPage("Office Canon"))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo("Office Canon", "Canon Driver", "USB001", true, false, "Ready", 0);
        vm.OpenPrinterEditPopupForItemCommand.Execute(printer);

        await vm.PrintTestPageCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.PrintTestPage("Office Canon"), Times.Once);
        Assert.Contains("Test page sent to printer 'Office Canon' successfully", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task PurgeTargetPrinterQueueCommand_InvokesServiceForTargetPrinter()
    {
        _printerMock
            .Setup(p => p.PurgePrinterQueue("Office Canon"))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo("Office Canon", "Canon Driver", "USB001", true, false, "Ready", 3);
        vm.OpenPrinterEditPopupForItemCommand.Execute(printer);

        await vm.PurgeTargetPrinterQueueCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.PurgePrinterQueue("Office Canon"), Times.Once);
        Assert.Contains("Print queue for printer 'Office Canon' purged successfully", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task SetAsDefaultPrinterCommand_InvokesServiceForTargetPrinter()
    {
        _printerMock
            .Setup(p => p.SetDefaultPrinter("Office Canon"))
            .Returns(true);

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo("Office Canon", "Canon Driver", "USB001", false, false, "Ready", 0);
        vm.OpenPrinterEditPopupForItemCommand.Execute(printer);

        await vm.SetAsDefaultPrinterCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.SetDefaultPrinter("Office Canon"), Times.Once);
        Assert.Contains("Printer 'Office Canon' set as default successfully", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task ResetTargetPrinterConnectionCommand_InvokesServiceForTargetPrinter()
    {
        _printerMock
            .Setup(p => p.ResetPrinterConnection(@"\\Server\Canon"))
            .Returns(new PrinterConnectionResetResult(1, 1, 0, new[] { "Reconnected" }, true));

        var vm = new ConnectivityViewModel(_connectivityMock.Object, _printerMock.Object, _loggerMock.Object);
        var printer = new PrinterInfo(@"\\Server\Canon", "Canon Driver", "NetPort", false, true, "Ready", 0);
        vm.OpenPrinterEditPopupForItemCommand.Execute(printer);

        await vm.ResetTargetPrinterConnectionCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.ResetPrinterConnection(@"\\Server\Canon"), Times.Once);
        Assert.Contains(@"Reset connection for '\\Server\Canon'", vm.LastPrinterStatus);
    }
}
