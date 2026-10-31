namespace IToolkit.Tests.WorkflowSeparation;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Comprehensive E2E test suite validating architectural and workflow separation
/// between global system-wide fixes and per-entity operations in Module 3 (Connectivity & Hardware).
/// Tiers:
///  - Tier 1: Feature Coverage (Isolated Happy Path)
///  - Tier 2: Boundary & Corner Cases (Invalid names, shell escaping, invalid error codes)
///  - Tier 3: Non-Interference (Adapter A vs Adapter B, Network stack vs Spooler)
///  - Tier 4: Real-World Scenarios (End-to-End Network & Printer Administrator Lifecycles)
/// </summary>
public class ConnectivityWorkflowSeparationE2ETests
{
    private readonly MockNetworkService _network;
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly MockWmiService _wmi;
    private readonly TestActivityLogger _logger;
    private readonly ConnectivityService _connectivityService;
    private readonly PrinterService _printerService;

    public ConnectivityWorkflowSeparationE2ETests()
    {
        _network = new MockNetworkService();
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _wmi = new MockWmiService();
        _logger = new TestActivityLogger();

        _connectivityService = new ConnectivityService(
            _network,
            _processRunner,
            _registry,
            _atomicRegistry,
            _logger);

        _printerService = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            _logger,
            _network);
    }

    #region Tier 1: Feature Coverage (Isolated Happy Path)

    [Fact]
    public void Tier1_Global_RemediateNetworkStack_ExecutesFullPipelineWithoutAdapterTargeting()
    {
        // Act: Execute global parameterless remediation
        var result = _connectivityService.RemediateNetworkStack();

        // Assert
        Assert.True(result.Success);
        Assert.True(result.RequiresReboot);
        Assert.True(result.DnsFlushed);
        Assert.True(result.DhcpRenewed);
        Assert.True(result.WinsockReset);
        Assert.True(result.TcpIpReset);
        Assert.True(result.ProxyReset);

        Assert.True(_network.DnsFlushed);
        Assert.True(_network.WinsockReset);
        Assert.True(_network.TcpIpReset);
        Assert.True(_network.DhcpRenewed);

        // Verifies no specific adapter was singled out for restart during global stack reset
        Assert.Empty(_network.RestartedAdapters);
    }

    [Fact]
    public void Tier1_Global_PurgeSpoolerQueue_PurgesSpoolDirectoryAndRestartsSpooler()
    {
        // Arrange: seed spool directory with old jobs
        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string spoolDir = Path.Combine(systemRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);
        _fileSystem.WriteAllText(Path.Combine(spoolDir, "FP00001.SHD"), "header data");
        _fileSystem.WriteAllText(Path.Combine(spoolDir, "FP00001.SPL"), "spool data");

        // Act
        var result = _printerService.PurgeSpoolerQueue();

        // Assert
        Assert.True(result.Success);
        Assert.True(result.SpoolerStopped);
        Assert.True(result.SpoolerRestarted);
        Assert.Equal(2, result.PurgedFilesCount);

        Assert.False(_fileSystem.FileExists(Path.Combine(spoolDir, "FP00001.SHD")));
        Assert.False(_fileSystem.FileExists(Path.Combine(spoolDir, "FP00001.SPL")));
    }

    [Fact]
    public void Tier1_Global_ApplyPointAndPrintPreset_SetsRegistrySecurityPolicies()
    {
        // Act: Apply Strict Admin Only preset
        bool result = _printerService.ApplyPointAndPrintPreset(PointAndPrintPreset.StrictAdminOnly);

        // Assert
        Assert.True(result);
        string policyKey = @"HKLM\Software\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        Assert.Equal(1, _registry.GetValue<int>(policyKey, "RestrictDriverInstallationToAdministrators"));
    }

    [Fact]
    public void Tier1_PerEntity_RestartAdapter_TargetsOnlyDesignatedAdapterByName()
    {
        // Act
        bool result = _connectivityService.RestartAdapter("Ethernet 1");

        // Assert
        Assert.True(result);
        Assert.Single(_network.RestartedAdapters);
        Assert.Equal("Ethernet 1", _network.RestartedAdapters[0]);
    }

    [Fact]
    public void Tier1_PerEntity_ResetPrinterConnections_TargetsOnlySpecifiedPrinter()
    {
        // Arrange
        string targetPrinter = @"\\PrintServer\OfficeCanon";
        _network.SetHostReachable("PrintServer", true);

        // Act
        var result = _printerService.ResetPrinterConnections(all: false, printerName: targetPrinter);

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Contains(result.Details, d => d.Contains(targetPrinter, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Tier1_PerEntity_DiagnosePrinterPortConnectivity_TestsDesignatedHost()
    {
        // Arrange
        string host = "192.168.1.150";
        _network.SetHostReachable(host, true);
        _network.SetPortOpen(host, 445, true);
        _network.SetPortOpen(host, 135, true);
        _network.SetPortOpen(host, 9100, true);

        // Act
        var result = _connectivityService.DiagnosePrinterPortConnectivity(host);

        // Assert
        Assert.True(result.IsPingSuccessful);
        Assert.True(result.IsSmbPortOpen);
        Assert.True(result.IsRpcPortOpen);
        Assert.True(result.IsRawPortOpen);
        Assert.Equal(host, result.Host);
    }

    [Fact]
    public void Tier1_PerEntity_ConfigureAdapterIp_ConfiguresOnlyTargetAdapter()
    {
        var config = new AdapterIpConfig(false, "192.168.1.75", "255.255.255.0", "192.168.1.1");

        bool result = _connectivityService.SetAdapterIpConfiguration("Ethernet 1", config);

        Assert.True(result);
        Assert.True(_network.ConfiguredIpAdapters.ContainsKey("Ethernet 1"));
        Assert.Equal("192.168.1.75", _network.ConfiguredIpAdapters["Ethernet 1"].IpAddress);
        Assert.False(_network.ConfiguredIpAdapters.ContainsKey("Wi-Fi"));
    }

    [Fact]
    public void Tier1_PerEntity_PurgePrinterQueue_PurgesOnlyTargetPrinterQueue()
    {
        bool result = _printerService.PurgePrinterQueue("Office Canon");

        Assert.True(result);
        Assert.Contains("Win32_Printer::CancelAllJobs", _wmi.ExecutedMethods);
    }

    #endregion

    #region Tier 2: Boundary & Corner Cases

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("\t")]
    public void Tier2_Boundary_InvalidAdapterNames_ReturnsFalseGracefully(string invalidAdapter)
    {
        var netMock = new Mock<INetworkService>();
        netMock.Setup(n => n.RestartAdapter(It.Is<string>(s => string.IsNullOrWhiteSpace(s)))).Returns(false);

        var service = new ConnectivityService(netMock.Object, _processRunner, _registry, _atomicRegistry, _logger);

        // Act
        bool result = service.RestartAdapter(invalidAdapter);

        // Assert
        Assert.False(result);
    }

    [Fact]
    public void Tier2_Boundary_AdapterNameWithSpacesAndBrackets_HandledSafely()
    {
        // Arrange
        string complexAdapter = "Ethernet (LAN) #2 [Intel I219-V]";

        // Act
        bool result = _connectivityService.RestartAdapter(complexAdapter);

        // Assert
        Assert.True(result);
        Assert.Single(_network.RestartedAdapters);
        Assert.Equal(complexAdapter, _network.RestartedAdapters[0]);
    }

    [Fact]
    public void Tier2_Boundary_RemediateEmptyPrinterErrorCode_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError(""));
        Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError("   "));
    }

    [Theory]
    [InlineData("0xUNKNOWN")]
    [InlineData("NOT_AN_ERROR")]
    public void Tier2_Boundary_RemediateUnknownPrinterErrorCode_FailsGracefully(string invalidCode)
    {
        // Act
        var result = _printerService.RemediatePrinterError(invalidCode);

        // Assert
        Assert.False(result.Success);
        Assert.Equal("Unknown error code", result.RemediationAction);
    }

    [Fact]
    public void Tier2_Boundary_DiagnoseUnreachableHost_ReturnsNonReachableResult()
    {
        // Arrange
        string unreachableHost = "10.254.254.254";
        _network.SetHostReachable(unreachableHost, false);

        // Act
        var result = _connectivityService.DiagnosePrinterPortConnectivity(unreachableHost);

        // Assert
        Assert.False(result.IsPingSuccessful);
    }

    #endregion

    #region Tier 3: Cross-Feature Combinations & Non-Interference

    [Fact]
    public void Tier3_NonInterference_RestartingAdapterA_DoesNotRestartAdapterB()
    {
        // Act: Restart Ethernet 1
        bool result = _connectivityService.RestartAdapter("Ethernet 1");

        // Assert
        Assert.True(result);
        Assert.Contains("Ethernet 1", _network.RestartedAdapters);
        Assert.DoesNotContain("Wi-Fi", _network.RestartedAdapters);
        Assert.DoesNotContain("vEthernet (Default Switch)", _network.RestartedAdapters);
    }

    [Fact]
    public void Tier3_NonInterference_GlobalNetworkStackReset_DoesNotPurgeSpoolerOrTouchPrinters()
    {
        // Arrange: seed spool directory with pending jobs
        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string spoolDir = Path.Combine(systemRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);
        string pendingJob = Path.Combine(spoolDir, "FP00099.SPL");
        _fileSystem.WriteAllText(pendingJob, "Important invoice print job");

        // Act: Run full network stack remediation
        var result = _connectivityService.RemediateNetworkStack();

        // Assert
        Assert.True(result.Success);

        // Print spool directory must NOT be touched by network stack fixes
        Assert.True(_fileSystem.FileExists(pendingJob));
        Assert.Equal("Important invoice print job", _fileSystem.ReadAllText(pendingJob));
    }

    [Fact]
    public void Tier3_NonInterference_PurgingSpoolerQueue_DoesNotRestartAdaptersOrFlushDns()
    {
        // Act: Run global spooler purge
        var result = _printerService.PurgeSpoolerQueue();

        // Assert
        Assert.True(result.Success);

        // Network stack must remain untouched
        Assert.Empty(_network.RestartedAdapters);
        Assert.False(_network.DnsFlushed);
        Assert.False(_network.WinsockReset);
    }

    [Fact]
    public void Tier3_NonInterference_ResettingPrinterA_DoesNotAlterPrinterB()
    {
        // Arrange: Printer A is reachable, Printer B is untouched
        string printerA = @"\\Print1\Canon";
        string printerB = @"\\Print2\HP";

        _network.SetHostReachable("Print1", true);

        // Act: Reset Printer A only
        var result = _printerService.ResetPrinterConnections(all: false, printerName: printerA);

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Contains(result.Details, d => d.Contains(printerA, StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(result.Details, d => d.Contains(printerB, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Tier3_NonInterference_ConfiguringIpOnAdapterA_DoesNotModifyAdapterB()
    {
        var configA = new AdapterIpConfig(false, "192.168.1.10", "255.255.255.0", "192.168.1.1");
        _connectivityService.SetAdapterIpConfiguration("Ethernet 1", configA);

        Assert.True(_network.ConfiguredIpAdapters.ContainsKey("Ethernet 1"));
        Assert.False(_network.ConfiguredIpAdapters.ContainsKey("Wi-Fi"));
    }

    [Fact]
    public void Tier3_NonInterference_PurgingPrinterAQueue_DoesNotPurgePrinterBQueue()
    {
        bool result = _printerService.PurgePrinterQueue("HP LaserJet");

        Assert.True(result);
        Assert.Contains("Win32_Printer::CancelAllJobs", _wmi.ExecutedMethods);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("Canon Office"));
    }

    #endregion

    #region Tier 4: Real-World Scenarios (End-to-End Admin Lifecycles)

    [Fact]
    public async Task Tier4_RealWorld_FullConnectivityLifecycle_TroubleshootAdapter_RemediateStack_MaintainPrinter()
    {
        // Arrange ViewModel with mocked services
        var connMock = new Mock<IConnectivityService>();
        var netMock = new Mock<INetworkService>();
        var printerMock = new Mock<IPrinterService>();

        var adapters = new List<NetworkAdapterInfo>
        {
            new("eth0", "Ethernet 1", "Intel Gigabit", "00-11-22-33-44-55", "Up", ["192.168.1.50"]),
            new("wlan0", "Wi-Fi", "Intel Wi-Fi 6E", "66-77-88-99-AA-BB", "Up", ["10.0.0.100"])
        };

        netMock.Setup(n => n.GetAdapters()).Returns(adapters);
        connMock.Setup(c => c.RestartAdapter("Ethernet 1")).Returns(true);
        connMock.Setup(c => c.FlushDns()).Returns(true);
        printerMock.Setup(p => p.PurgeSpoolerQueue()).Returns(new SpoolerQueueResult(true, true, true, 0, true));

        var vm = new ConnectivityViewModel(connMock.Object, printerMock.Object, _logger, netMock.Object);
        await vm.RefreshAdaptersCommand.ExecuteAsync(null);

        Assert.Equal(2, vm.AvailableAdapters.Count);

        // Step 1: Admin selects Ethernet 1 and restarts it
        vm.SelectedAdapter = vm.AvailableAdapters.First(a => a.Name == "Ethernet 1");
        Assert.True(vm.RestartAdapterCommand.CanExecute(null));
        await vm.RestartAdapterCommand.ExecuteAsync(null);

        connMock.Verify(c => c.RestartAdapter("Ethernet 1"), Times.Once);
        connMock.Verify(c => c.RestartAdapter("Wi-Fi"), Times.Never);

        // Step 2: Corporate DNS issue occurs -> Admin executes Flush DNS
        Assert.True(vm.FlushDnsCommand.CanExecute(null));
        await vm.FlushDnsCommand.ExecuteAsync(null);

        connMock.Verify(c => c.FlushDns(), Times.Once);

        // Step 3: Stuck print spooler issue -> Admin executes Spooler Purge
        Assert.True(vm.PurgeSpoolerCommand.CanExecute(null));
        await vm.PurgeSpoolerCommand.ExecuteAsync(null);

        printerMock.Verify(p => p.PurgeSpoolerQueue(), Times.Once);
    }

    [Fact]
    public async Task Tier4_RealWorld_ModalPopupWorkflows_PerAdapterAndPerPrinter_ExecuteEndToEnd()
    {
        var connMock = new Mock<IConnectivityService>();
        var netMock = new Mock<INetworkService>();
        var printerMock = new Mock<IPrinterService>();

        var adapters = new List<NetworkAdapterInfo>
        {
            new("eth0", "Ethernet 1", "Intel Gigabit", "00-11-22-33-44-55", "Up", ["192.168.1.50"], false, "255.255.255.0", "192.168.1.1", ["1.1.1.1"], 1500)
        };
        var printers = new List<PrinterInfo>
        {
            new("HP LaserJet Pro", "HP PCL6", "192.168.1.150", true, false, "Ready", 1)
        };

        netMock.Setup(n => n.GetAdapters()).Returns(adapters);
        printerMock.Setup(p => p.GetPrinters()).Returns(printers);
        connMock.Setup(c => c.SetAdapterIpConfiguration("Ethernet 1", It.IsAny<AdapterIpConfig>())).Returns(true);
        connMock.Setup(c => c.SetAdapterMtu("Ethernet 1", 1492)).Returns(true);
        printerMock.Setup(p => p.PrintTestPage("HP LaserJet Pro")).Returns(true);
        printerMock.Setup(p => p.PurgePrinterQueue("HP LaserJet Pro")).Returns(true);

        var vm = new ConnectivityViewModel(connMock.Object, printerMock.Object, _logger, netMock.Object);
        await vm.RefreshAdaptersCommand.ExecuteAsync(null);
        await vm.RefreshPrintersCommand.ExecuteAsync(null);

        // 1. Open Adapter Popup via row item
        vm.OpenAdapterEditPopupForItemCommand.Execute(vm.AvailableAdapters[0]);
        Assert.True(vm.IsAdapterEditPopupOpen);
        Assert.Equal("Ethernet 1", vm.SelectedEditingAdapter?.Name);

        // Modify MTU & IP in popup
        vm.AdapterMtu = 1492;
        await vm.SetAdapterMtuCommand.ExecuteAsync(null);
        connMock.Verify(c => c.SetAdapterMtu("Ethernet 1", 1492), Times.Once);

        vm.AdapterStaticIp = "192.168.1.99";
        await vm.SaveAdapterIpConfigCommand.ExecuteAsync(null);
        connMock.Verify(c => c.SetAdapterIpConfiguration("Ethernet 1", It.Is<AdapterIpConfig>(cfg => cfg.IpAddress == "192.168.1.99")), Times.Once);

        // Close Adapter Popup
        vm.CloseAdapterEditPopupCommand.Execute(null);
        Assert.False(vm.IsAdapterEditPopupOpen);

        // 2. Open Printer Popup via row item
        vm.OpenPrinterEditPopupForItemCommand.Execute(vm.AvailablePrinters[0]);
        Assert.True(vm.IsPrinterEditPopupOpen);
        Assert.Equal("HP LaserJet Pro", vm.SelectedEditingPrinter?.Name);

        // Execute test print & queue purge in popup
        await vm.PrintTestPageCommand.ExecuteAsync(null);
        printerMock.Verify(p => p.PrintTestPage("HP LaserJet Pro"), Times.Once);

        await vm.PurgeTargetPrinterQueueCommand.ExecuteAsync(null);
        printerMock.Verify(p => p.PurgePrinterQueue("HP LaserJet Pro"), Times.Once);

        // Close Printer Popup
        vm.ClosePrinterEditPopupCommand.Execute(null);
        Assert.False(vm.IsPrinterEditPopupOpen);
    }

    #endregion
}
