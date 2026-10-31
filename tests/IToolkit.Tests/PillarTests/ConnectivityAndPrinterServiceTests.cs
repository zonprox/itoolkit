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
        _printerService = new PrinterService(_processRunner, _fileSystem, _registry, _atomicRegistry, _lockGuard, _wmi, network: _network);
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

    [Fact]
    public void ApplyPointAndPrintPreset_CreatesPreMutationRegistryBackups()
    {
        // Act
        bool result = _printerService.ApplyPointAndPrintPreset(PointAndPrintPreset.Compatibility);

        // Assert
        Assert.True(result);

        var backupFiles = _fileSystem.EnumerateFiles(
            Path.Combine(AppContext.BaseDirectory, "Backups", "Registry"),
            "*.reg",
            SearchOption.AllDirectories).ToList();

        Assert.NotEmpty(backupFiles);
        Assert.True(backupFiles.Count >= 2);
    }

    [Fact]
    public void ResetNePortBindings_CreatesPreMutationRegistryBackup()
    {
        // Arrange
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        _registry.CreateKey(portsKey);
        _registry.SetValue(portsKey, "ActiveLaserJet", "Ne01:", RegistryValueKind.String);
        _registry.SetValue(portsKey, "GhostPrinter", "Ne02:", RegistryValueKind.String);

        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", "ActiveLaserJet" } }
        });

        // Act
        int removed = _printerService.ResetNePortBindings();

        // Assert
        Assert.Equal(1, removed);
        var backupFiles = _fileSystem.EnumerateFiles(
            Path.Combine(AppContext.BaseDirectory, "Backups", "Registry"),
            "*.reg",
            SearchOption.AllDirectories).ToList();

        Assert.NotEmpty(backupFiles);
        Assert.Contains(backupFiles, f => f.Contains("PrinterPorts"));
    }

    [Fact]
    public void RemediatePrinterError_CreatesBackups_AndSurfacesBackupPaths_ForRegistryCodes()
    {
        // 1. Registry-mutating code: 0x0000011b
        var res11b = _printerService.RemediatePrinterError("0x0000011b");

        Assert.True(res11b.Success);
        Assert.NotNull(res11b.BackupPath);
        Assert.NotEmpty(res11b.BackupPaths);
        Assert.Equal(2, res11b.BackupPaths.Count);
        Assert.True(_fileSystem.FileExists(res11b.BackupPath));

        // 2. Non-registry code: 0x0000007e (DLLs / MOF only)
        var res7e = _printerService.RemediatePrinterError("0x0000007e");

        Assert.True(res7e.Success);
        Assert.Null(res7e.BackupPath);
        Assert.Empty(res7e.BackupPaths);
    }

    [Fact]
    public void RemediateRole_Server_Executes9Actions_AggregatesBackups_AndRestartsSpooler()
    {
        var result = _printerService.RemediateRole(PrinterRemediationRole.Server);

        Assert.Equal(PrinterRemediationRole.Server, result.Role);
        Assert.True(result.Success);
        Assert.True(result.SpoolerRestarted);
        Assert.Equal(9, result.ActionsExecuted.Count);
        Assert.Equal(9, result.Results.Count);
        Assert.True(result.Results.All(r => r.Success));
        Assert.NotEmpty(result.BackupPaths);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void RemediateRole_Client_Executes13Actions_AggregatesBackups_AndRestartsSpooler()
    {
        var result = _printerService.RemediateRole(PrinterRemediationRole.Client);

        Assert.Equal(PrinterRemediationRole.Client, result.Role);
        Assert.True(result.Success);
        Assert.True(result.SpoolerRestarted);
        Assert.Equal(13, result.ActionsExecuted.Count);
        Assert.Equal(13, result.Results.Count);
        Assert.True(result.Results.All(r => r.Success));
        Assert.NotEmpty(result.BackupPaths);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void RemediateRole_Both_And_RemediateAll_Execute17Actions_DeduplicatingBackups()
    {
        var resultBoth = _printerService.RemediateRole(PrinterRemediationRole.Both);
        var resultAll = _printerService.RemediateAll();

        Assert.Equal(PrinterRemediationRole.Both, resultBoth.Role);
        Assert.Equal(PrinterRemediationRole.Both, resultAll.Role);
        Assert.True(resultBoth.Success);
        Assert.True(resultAll.Success);
        Assert.Equal(17, resultBoth.ActionsExecuted.Count);
        Assert.Equal(17, resultAll.ActionsExecuted.Count);
        Assert.Equal(17, resultBoth.Results.Count);
        Assert.Equal(17, resultAll.Results.Count);
        Assert.True(resultBoth.Results.All(r => r.Success));
        Assert.True(resultAll.Results.All(r => r.Success));
        Assert.NotEmpty(resultBoth.BackupPaths);
    }

    [Fact]
    public void RemediatePrinterError_RoutesToGranularTokens()
    {
        var resRpc = _printerService.RemediatePrinterError("RpcAuthnLevel");
        Assert.True(resRpc.Success);
        Assert.Equal("RpcAuthnLevel", resRpc.ErrorCode);
        Assert.Equal(0, _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled"));

        var resAdmin = _printerService.RemediatePrinterError("PointAndPrintAdmin");
        Assert.True(resAdmin.Success);
        Assert.Equal("PointAndPrintAdmin", resAdmin.ErrorCode);
        Assert.Equal(0, _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint", "RestrictDriverInstallationToAdministrators"));

        var resPorts = _printerService.RemediatePrinterError("NePorts");
        Assert.True(resPorts.Success);
        Assert.Equal("NePorts", resPorts.ErrorCode);
    }

    [Fact]
    public void RemediatePrinterError_RoutesRoleAliases_Correctly()
    {
        var resServer = _printerService.RemediatePrinterError("AllServer");
        Assert.True(resServer.Success);
        Assert.Contains("9 actions", resServer.RemediationAction);

        var resClient = _printerService.RemediatePrinterError("AllClient");
        Assert.True(resClient.Success);
        Assert.Contains("13 actions", resClient.RemediationAction);

        var resAll = _printerService.RemediatePrinterError("AllBoth");
        Assert.True(resAll.Success);
        Assert.Contains("17 actions", resAll.RemediationAction);
    }

    [Fact]
    public void GetSupportedGranularTokens_ReturnsAllExpectedTokens()
    {
        var tokens = _printerService.GetSupportedGranularTokens();

        Assert.NotNull(tokens);
        Assert.True(tokens.Count >= 16);
        Assert.Contains("RpcAuthnLevel", tokens);
        Assert.Contains("RemoteRpcEndPoint", tokens);
        Assert.Contains("RpcProtocols", tokens);
        Assert.Contains("SpoolerHealth", tokens);
        Assert.Contains("PointAndPrintAdmin", tokens);
        Assert.Contains("PointAndPrintPrompts", tokens);
        Assert.Contains("RpcNamedPipe", tokens);
        Assert.Contains("DefaultPrinterKey", tokens);
        Assert.Contains("CopyFilesPolicy", tokens);
        Assert.Contains("SpoolerDLLs", tokens);
        Assert.Contains("DriverStoreRepair", tokens);
        Assert.Contains("SpoolerHandles", tokens);
        Assert.Contains("DriverConfig", tokens);
        Assert.Contains("ClearStalledJobs", tokens);
        Assert.Contains("SpoolerCrash", tokens);
        Assert.Contains("SpoolerQueue", tokens);
        Assert.Contains("NePorts", tokens);
        Assert.Contains("RefreshConnections", tokens);
    }

    [Fact]
    public void AuditPointAndPrintPolicy_CorrectlyIdentifies_Secure_Vs_Vulnerable_Posture()
    {
        // 1. Setup vulnerable posture
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printKey);
        _registry.SetValue(printKey, "RpcAuthnLevelPrivacyEnabled", 0, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 0, RegistryValueKind.DWord);
        _registry.SetValue(pnpKey, "NoWarningNoElevationOnInstall", 1, RegistryValueKind.DWord);

        var auditVuln = _printerService.AuditPointAndPrintPolicy();

        Assert.False(auditVuln.RpcAuthnLevelPrivacyEnabled);
        Assert.False(auditVuln.RestrictDriverInstallationToAdministrators);
        Assert.True(auditVuln.NoWarningNoElevationOnInstall);
        Assert.True(auditVuln.IsVulnerableToCVE20211678);
        Assert.True(auditVuln.IsVulnerable);
        Assert.Contains("Vulnerable", auditVuln.PostureDescription);
        Assert.True(auditVuln.Recommendations.Count >= 2);

        // 2. Setup secure posture via StrictAdminOnly preset
        _printerService.ApplyPointAndPrintPreset(PointAndPrintPreset.StrictAdminOnly);
        _registry.DeleteValue(pnpKey, "NoWarningNoElevationOnInstall");

        var auditSec = _printerService.AuditPointAndPrintPolicy();

        Assert.True(auditSec.RpcAuthnLevelPrivacyEnabled);
        Assert.True(auditSec.RestrictDriverInstallationToAdministrators);
        Assert.False(auditSec.NoWarningNoElevationOnInstall);
        Assert.False(auditSec.IsVulnerableToCVE20211678);
        Assert.False(auditSec.IsVulnerable);
        Assert.Contains("Secure", auditSec.PostureDescription);
        Assert.Empty(auditSec.Recommendations);
    }

    [Fact]
    public void GetSpoolerStatus_ReturnsCorrectDirectory_QueueMetrics_AndServiceState()
    {
        // 1. Setup simulated Spooler service via WMI
        _wmi.SetQueryResult("SELECT State, StartMode, ProcessId FROM Win32_Service WHERE Name='Spooler'", new[]
        {
            new Dictionary<string, object?>
            {
                { "State", "Running" },
                { "StartMode", "Auto" },
                { "ProcessId", 4321 }
            }
        });

        // 2. Setup spool queue directory with test files
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);

        string f1 = Path.Combine(spoolDir, "job01.spl");
        string f2 = Path.Combine(spoolDir, "job01.shd");
        string f3 = Path.Combine(spoolDir, "temp.tmp");
        string ignore = Path.Combine(spoolDir, "readme.txt");

        _fileSystem.WriteAllBytes(f1, new byte[1000]);
        _fileSystem.WriteAllBytes(f2, new byte[200]);
        _fileSystem.WriteAllBytes(f3, new byte[100]);
        _fileSystem.WriteAllBytes(ignore, new byte[50]);

        // Act
        var status = _printerService.GetSpoolerStatus();

        // Assert
        Assert.True(status.IsRunning);
        Assert.Equal("Running", status.ServiceStatus);
        Assert.Equal(4321, status.Pid);
        Assert.Equal(3, status.PendingJobFileCount);
        Assert.Equal(1300, status.TotalQueueSizeBytes);
        Assert.True(status.HasStalledJobs);
        Assert.Equal(spoolDir, status.SpoolDirectory);
    }

    [Fact]
    public void ResetPrinterConnections_HandlesReachableAndUnreachablePrinters_Correctly()
    {
        // 1. Setup discovered printers
        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", @"\\LiveServer\ColorLaserJet" } },
            new Dictionary<string, object?> { { "Name", @"\\DeadServer\OldDotMatrix" } },
            new Dictionary<string, object?> { { "Name", "Microsoft XPS Document Writer" } }
        });

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        _registry.CreateKey($@"{connKey}\,,LiveServer,MonoLaserJet");
        _registry.CreateKey($@"{connKey}\,,DeadServer,OldDotMatrix");

        // 2. Setup reachability
        _network.SetHostReachable("LiveServer", true);
        _network.SetHostReachable("DeadServer", false);
        _network.SetPortOpen("DeadServer", 445, false);

        // Act
        var result = _printerService.ResetPrinterConnections();

        // Assert
        Assert.True(result.Success);
        Assert.Equal(3, result.DiscoveredPrinters); // LiveServer\ColorLaserJet, DeadServer\OldDotMatrix, LiveServer\MonoLaserJet
        Assert.Equal(2, result.ReconnectedPrinters); // ColorLaserJet and MonoLaserJet
        Assert.Equal(1, result.RemovedStalePrinters); // OldDotMatrix
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void EnableAdapter_CallsNetworkAndProcess_ReturnsTrue()
    {
        bool result = _connectivityService.EnableAdapter("Ethernet 1");
        Assert.True(result);
        Assert.Contains("Ethernet 1", _network.EnabledAdapters);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface set interface \"Ethernet 1\" enable"));
    }

    [Fact]
    public void DisableAdapter_CallsNetworkAndProcess_ReturnsTrue()
    {
        bool result = _connectivityService.DisableAdapter("Ethernet 1");
        Assert.True(result);
        Assert.Contains("Ethernet 1", _network.DisabledAdapters);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface set interface \"Ethernet 1\" disable"));
    }

    [Fact]
    public void ReleaseRenewAdapterDhcp_CallsNetworkAndProcess_ReturnsTrue()
    {
        bool result = _connectivityService.ReleaseRenewAdapterDhcp("Ethernet 1");
        Assert.True(result);
        Assert.Contains("Ethernet 1", _network.RenewedDhcpAdapters);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("ipconfig.exe /renew \"Ethernet 1\""));
    }

    [Fact]
    public void SetAdapterIpConfiguration_StaticIp_CallsNetworkAndSetsStaticAddress()
    {
        var config = new AdapterIpConfig(false, "192.168.1.50", "255.255.255.0", "192.168.1.1");
        bool result = _connectivityService.SetAdapterIpConfiguration("Ethernet 1", config);

        Assert.True(result);
        Assert.True(_network.ConfiguredIpAdapters.ContainsKey("Ethernet 1"));
        Assert.Equal("192.168.1.50", _network.ConfiguredIpAdapters["Ethernet 1"].IpAddress);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface ipv4 set address \"Ethernet 1\" static 192.168.1.50 255.255.255.0 192.168.1.1"));
    }

    [Fact]
    public void SetAdapterIpConfiguration_Dhcp_CallsNetworkAndSetsDhcp()
    {
        var config = new AdapterIpConfig(true);
        bool result = _connectivityService.SetAdapterIpConfiguration("Ethernet 1", config);

        Assert.True(result);
        Assert.True(_network.ConfiguredIpAdapters.ContainsKey("Ethernet 1"));
        Assert.True(_network.ConfiguredIpAdapters["Ethernet 1"].UseDhcp);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface ipv4 set address \"Ethernet 1\" dhcp"));
    }

    [Fact]
    public void SetAdapterDnsConfiguration_CustomDns_CallsNetworkAndSetsDnsServers()
    {
        var config = new AdapterDnsConfig(false, "1.1.1.1", "8.8.8.8");
        bool result = _connectivityService.SetAdapterDnsConfiguration("Ethernet 1", config);

        Assert.True(result);
        Assert.True(_network.ConfiguredDnsAdapters.ContainsKey("Ethernet 1"));
        Assert.Equal("1.1.1.1", _network.ConfiguredDnsAdapters["Ethernet 1"].PreferredDns);
        Assert.Equal("8.8.8.8", _network.ConfiguredDnsAdapters["Ethernet 1"].AlternateDns);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface ipv4 set dnsservers \"Ethernet 1\" static 1.1.1.1 primary"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("interface ipv4 add dnsservers \"Ethernet 1\" 8.8.8.8 index=2"));
    }

    [Fact]
    public void SetAdapterMtu_ValidRange_SetsSubinterfaceMtu()
    {
        bool result = _connectivityService.SetAdapterMtu("Ethernet 1", 1492);

        Assert.True(result);
        Assert.True(_network.ConfiguredMtuAdapters.ContainsKey("Ethernet 1"));
        Assert.Equal(1492, _network.ConfiguredMtuAdapters["Ethernet 1"]);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("mtu=1492 store=persistent"));
    }

    [Theory]
    [InlineData(500)]
    [InlineData(10000)]
    public void SetAdapterMtu_InvalidRange_ReturnsFalse(int invalidMtu)
    {
        bool result = _connectivityService.SetAdapterMtu("Ethernet 1", invalidMtu);
        Assert.False(result);
    }

    [Fact]
    public void GetPrinters_EnumeratesDiscoveredPrintersWithAccurateAttributes()
    {
        _wmi.SetQueryResult("SELECT Name, DriverName, PortName, Default, Network, Status, ServerName, ShareName FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?>
            {
                { "Name", "HP LaserJet Pro" },
                { "DriverName", "HP Universal Printing PCL 6" },
                { "PortName", "192.168.1.150" },
                { "Default", true },
                { "Network", false },
                { "Status", "Ready" }
            }
        });

        var printers = _printerService.GetPrinters().ToList();

        Assert.Single(printers);
        var hp = printers[0];
        Assert.Equal("HP LaserJet Pro", hp.Name);
        Assert.Equal("HP Universal Printing PCL 6", hp.DriverName);
        Assert.Equal("192.168.1.150", hp.PortName);
        Assert.True(hp.IsDefault);
        Assert.False(hp.IsNetwork);
        Assert.Equal("Ready", hp.Status);
    }

    [Fact]
    public void GetPrinterJobs_ReturnsJobsForTargetPrinter()
    {
        _wmi.SetQueryResult("SELECT JobId, Document, Owner, Size, Status, TimeSubmitted FROM Win32_PrintJob WHERE Name LIKE 'HP LaserJet Pro%'", new[]
        {
            new Dictionary<string, object?>
            {
                { "JobId", 101 },
                { "Document", "Quarterly Report.pdf" },
                { "Owner", "Admin" },
                { "Size", 204800L },
                { "Status", "Printing" }
            }
        });

        var jobs = _printerService.GetPrinterJobs("HP LaserJet Pro").ToList();

        Assert.Single(jobs);
        Assert.Equal(101, jobs[0].JobId);
        Assert.Equal("Quarterly Report.pdf", jobs[0].DocumentName);
        Assert.Equal("Admin", jobs[0].Owner);
        Assert.Equal(204800L, jobs[0].SizeBytes);
    }

    [Fact]
    public void PurgePrinterQueue_PurgesJobsForTargetPrinterOnly()
    {
        bool result = _printerService.PurgePrinterQueue("HP LaserJet Pro");

        Assert.True(result);
        Assert.Contains("Win32_Printer::CancelAllJobs", _wmi.ExecutedMethods);
    }

    [Fact]
    public void PrintTestPage_ExecutesPrintUIEntryTargetingSpecifiedPrinter()
    {
        bool result = _printerService.PrintTestPage("Office Canon");

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /k /n \"Office Canon\""));
    }

    [Fact]
    public void SetDefaultPrinter_ExecutesPrintUIEntryAndUpdatesRegistry()
    {
        string winKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows";
        _registry.CreateKey(winKey);
        _registry.SetValue(winKey, "Device", "OldPrinter,winspool,Ne01:", RegistryValueKind.String);

        bool result = _printerService.SetDefaultPrinter("Office Canon");

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /y /n \"Office Canon\""));
        string currentDevice = _registry.GetValue<string>(winKey, "Device") ?? "";
        Assert.StartsWith("Office Canon,", currentDevice);
    }

    [Fact]
    public void ResetPrinterConnection_TargetsOnlySpecifiedPrinter()
    {
        _network.SetHostReachable("PrintServer", true);

        var result = _printerService.ResetPrinterConnection(@"\\PrintServer\OfficeCanon");

        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Contains(result.Details, d => d.Contains(@"\\PrintServer\OfficeCanon"));
    }

    [Fact]
    public void ResetAllPrinterConnections_ResetsAllDiscoveredNetworkPrinters()
    {
        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", @"\\ServerA\Printer1" } },
            new Dictionary<string, object?> { { "Name", @"\\ServerB\Printer2" } }
        });

        _network.SetHostReachable("ServerA", true);
        _network.SetHostReachable("ServerB", true);

        var result = _printerService.ResetAllPrinterConnections();

        Assert.True(result.Success);
        Assert.Equal(2, result.DiscoveredPrinters);
        Assert.Equal(2, result.ReconnectedPrinters);
    }
}
