namespace IToolkit.Tests.PillarTests;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class ConnectivityAndPrinterServiceTests
{
    private readonly MockNetworkService _network;
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly MockWmiService _wmi;
    private readonly ConnectivityService _connectivityService;
    private readonly PrinterService _printerService;

    public ConnectivityAndPrinterServiceTests()
    {
        _network = new MockNetworkService();
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _wmi = new MockWmiService();

        _connectivityService = new ConnectivityService(_network, _processRunner, _registry, _atomicRegistry);
        _printerService = new PrinterService(_processRunner, _fileSystem, _registry, _atomicRegistry, _lockGuard, _wmi);
    }

    [Fact]
    public void RemediateNetworkStack_ExecutesAllIndividualResets_AndReportsSuccess()
    {
        var result = _connectivityService.RemediateNetworkStack();

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
    }

    [Fact]
    public void ConfigureSmbSharing_ConfiguresFirewall_Services_AndGuestAuth()
    {
        var result = _connectivityService.ConfigureSmbSharing();

        Assert.True(result.Success);
        Assert.True(result.InsecureGuestAuthEnabled);
        Assert.True(result.NetbiosEnabled);

        // Verify LanmanWorkstation keys
        var guestAuth = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters", "AllowInsecureGuestAuth");
        var signing = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters", "RequireSecuritySignature");
        Assert.Equal(1, guestAuth);
        Assert.Equal(0, signing);

        // Verify NetBIOS key
        var netbios = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters", "NetbiosOptions");
        Assert.Equal(1, netbios);

        // Verify services were started
        foreach (var svc in ConnectivityService.SmbServices)
        {
            Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains($"net start {svc}"));
        }
    }

    [Fact]
    public void DiagnosePrinterPortConnectivity_TestsPingAndPorts_445_135_9100()
    {
        string host = "192.168.1.200";
        _network.SetHostReachable(host, true);
        _network.SetPortOpen(host, 445, true);
        _network.SetPortOpen(host, 135, true);
        _network.SetPortOpen(host, 9100, false);

        var result = _connectivityService.DiagnosePrinterPortConnectivity(host);

        Assert.Equal(host, result.Host);
        Assert.True(result.IsPingSuccessful);
        Assert.True(result.IsSmbPortOpen);
        Assert.True(result.IsRpcPortOpen);
        Assert.False(result.IsRawPortOpen);
        Assert.Contains("RAW:9100=CLOSED", result.DiagnosticsSummary);
    }

    [Fact]
    public void PurgeSpoolerQueue_StopsSpooler_DeletesFiles_AndRestarts()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);

        string stuckShd = Path.Combine(spoolDir, "FP0001.SHD");
        string stuckSpl = Path.Combine(spoolDir, "FP0001.SPL");
        _fileSystem.WriteAllText(stuckShd, "shd");
        _fileSystem.WriteAllText(stuckSpl, "spl");

        var result = _printerService.PurgeSpoolerQueue();

        Assert.True(result.Success);
        Assert.Equal(2, result.PurgedFilesCount);
        Assert.False(_fileSystem.FileExists(stuckShd));
        Assert.False(_fileSystem.FileExists(stuckSpl));

        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net stop spooler"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void RegisterSpoolerComponents_RegistersDlls_Mof_AndServiceDependency()
    {
        bool result = _printerService.RegisterSpoolerComponents();

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("prntvpt.dll"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("prnprov.mof"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("sc.exe config spooler depend= RPCSS"));
    }

    [Fact]
    public void ResetNePortBindings_DeletesOrphanedPorts_ForMissingPrinters()
    {
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        _registry.CreateKey(portsKey);
        _registry.SetValue(portsKey, "ActiveLaserJet", "Ne01:", RegistryValueKind.String);
        _registry.SetValue(portsKey, "GhostPrinter", "Ne02:", RegistryValueKind.String);

        // Tell WMI that only ActiveLaserJet exists
        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", "ActiveLaserJet" } }
        });

        int removed = _printerService.ResetNePortBindings();

        Assert.Equal(1, removed);
        Assert.True(_registry.ValueExists(portsKey, "ActiveLaserJet"));
        Assert.False(_registry.ValueExists(portsKey, "GhostPrinter"));
    }

    [Theory]
    [InlineData(PointAndPrintPreset.StrictAdminOnly, 1, 1)]
    [InlineData(PointAndPrintPreset.Compatibility, 0, 0)]
    public void ApplyPointAndPrintPreset_SetsSecurityKeysProperly(PointAndPrintPreset preset, int expectedRpc, int expectedAdmin)
    {
        bool result = _printerService.ApplyPointAndPrintPreset(preset);

        Assert.True(result);

        var rpc = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled");
        var admin = _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint", "RestrictDriverInstallationToAdministrators");

        Assert.Equal(expectedRpc, rpc);
        Assert.Equal(expectedAdmin, admin);
    }

    [Theory]
    [InlineData("0x0000011b")]
    [InlineData("0x00000709")]
    [InlineData("0x0000007c")]
    [InlineData("0x0000007e")]
    [InlineData("0x00000bcb")]
    [InlineData("0x00000002")]
    [InlineData("0x00000006")]
    [InlineData("0x00000057")]
    [InlineData("0x000003e3")]
    [InlineData("SpoolerCrash")]
    [InlineData("NePortConflict")]
    [InlineData("RefreshConnections")]
    public void RemediatePrinterError_RemediatesAll12CatalogCodes(string errorCode)
    {
        var result = _printerService.RemediatePrinterError(errorCode);

        Assert.True(result.Success);
        Assert.True(result.PolicyApplied);
        Assert.Equal(errorCode, result.ErrorCode);
    }
}
