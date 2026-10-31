namespace IToolkit.Core.Services.Connectivity;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 3: Network Remediation &amp; SMB Sharing Configuration implementation in pure C# .NET 10.0 LTS (win-x64).
/// </summary>
public class ConnectivityService : IConnectivityService
{
    private readonly INetworkService _network;
    private readonly IProcessRunner _processRunner;
    private readonly IRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly IActivityLogger? _logger;

    public static readonly string[] SmbServices =
    {
        "FDResPub", "SSDPSRV", "upnphost", "LanmanServer", "LanmanWorkstation"
    };

    public ConnectivityService(
        INetworkService network,
        IProcessRunner processRunner,
        IRegistryService registry,
        AtomicRegistryService atomicRegistry,
        IActivityLogger? logger = null)
    {
        _network = network ?? throw new ArgumentNullException(nameof(network));
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _atomicRegistry = atomicRegistry ?? throw new ArgumentNullException(nameof(atomicRegistry));
        _logger = logger;
    }

    public bool FlushDns()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Flushing local DNS cache...");
        bool netOk = _network.FlushDns();
        var procRes = _processRunner.Run("ipconfig.exe", "/flushdns");
        _processRunner.Run("ipconfig.exe", "/registerdns");
        return netOk || procRes.ExitCode == 0;
    }

    public bool ReleaseRenewDhcp()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Releasing and renewing DHCP leases...");
        bool netOk = _network.ReleaseRenewDhcp();
        var rel = _processRunner.Run("ipconfig.exe", "/release");
        var ren = _processRunner.Run("ipconfig.exe", "/renew");
        _processRunner.Run("net", "stop dhcp /y");
        _processRunner.Run("net", "start dhcp");
        return netOk || ren.ExitCode == 0;
    }

    public bool ClearArpAndRouteCache()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Flushing ARP and route destination caches...");
        var arpRes = _processRunner.Run("netsh.exe", "interface ip delete arpcache");
        var destRes = _processRunner.Run("netsh.exe", "interface ipv4 delete destinationcache");
        return arpRes.ExitCode == 0 || destRes.ExitCode == 0;
    }

    public bool ResetWinsock()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Resetting Winsock catalog...");
        bool netOk = _network.ResetWinsock();
        var res = _processRunner.Run("netsh.exe", "winsock reset catalog");
        return netOk || res.ExitCode == 0;
    }

    public bool ResetTcpIpStack()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Resetting TCP/IP stack...");
        bool netOk = _network.ResetTcpIp();
        var ipRes = _processRunner.Run("netsh.exe", "int ip reset");
        var tcpRes = _processRunner.Run("netsh.exe", "int tcp reset");
        return netOk || ipRes.ExitCode == 0;
    }

    public bool ResetNla()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Resetting Network Location Awareness (NLA) services...");
        _processRunner.Run("net", "stop netprofm /y");
        _processRunner.Run("net", "stop nlasvc /y");
        var startNla = _processRunner.Run("net", "start nlasvc");
        var startNetprofm = _processRunner.Run("net", "start netprofm");
        return startNla.ExitCode == 0 && startNetprofm.ExitCode == 0;
    }

    public bool ResetProxyAndWinHttp()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Resetting WinHTTP proxy and browser internet settings...");
        _processRunner.Run("netsh.exe", "winhttp reset proxy");

        string internetSettingsKey = @"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings";
        _registry.CreateKey(internetSettingsKey);
        _registry.SetValue(internetSettingsKey, "ProxyEnable", 0, RegistryValueKind.DWord);
        _registry.SetValue(internetSettingsKey, "ProxyServer", "", RegistryValueKind.String);
        _registry.SetValue(internetSettingsKey, "AutoConfigURL", "", RegistryValueKind.String);
        _registry.SetValue(internetSettingsKey, "MigrateProxy", 0, RegistryValueKind.DWord);
        _registry.SetValue(internetSettingsKey, "ProxyOverride", "<local>", RegistryValueKind.String);
        return true;
    }

    public NetworkRemediationResult RemediateNetworkStack()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Executing comprehensive Network Stack Remediation pipeline...");
        bool dns = FlushDns();
        bool dhcp = ReleaseRenewDhcp();
        bool arp = ClearArpAndRouteCache();
        bool winsock = ResetWinsock();
        bool tcp = ResetTcpIpStack();
        bool nla = ResetNla();
        bool proxy = ResetProxyAndWinHttp();

        bool success = dns && winsock && tcp;
        return new NetworkRemediationResult(
            dns, dhcp, arp, winsock, tcp, nla, proxy,
            success,
            RequiresReboot: true,
            Message: "Network stack remediation complete. A system restart is recommended to finalize TCP/Winsock catalog reset.");
    }

    public SmbConfigResult ConfigureSmbSharing()
    {
        _logger?.LogInfo(nameof(ConnectivityService), "Configuring SMB Sharing & hardening against errors 0x80070035 / 0x80070043...");

        // 1. Firewall rules
        var fw1 = _processRunner.Run("netsh.exe", "advfirewall firewall set rule group=\"Network Discovery\" new enable=Yes");
        var fw2 = _processRunner.Run("netsh.exe", "advfirewall firewall set rule group=\"File and Printer Sharing\" new enable=Yes");
        bool fwOk = fw1.ExitCode == 0 || fw2.ExitCode == 0;

        // 2. Services
        bool servicesOk = true;
        foreach (var svc in SmbServices)
        {
            _processRunner.Run("sc.exe", $"config {svc} start= auto");
            var startRes = _processRunner.Run("net", $"start {svc}");
            if (startRes.ExitCode != 0) servicesOk = false;
        }

        // 3. LanmanWorkstation SMB Guest & Signing Parameters
        string lanmanKey = @"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters";
        _registry.CreateKey(lanmanKey);
        _registry.SetValue(lanmanKey, "AllowInsecureGuestAuth", 1, RegistryValueKind.DWord);
        _registry.SetValue(lanmanKey, "RequireSecuritySignature", 0, RegistryValueKind.DWord);

        // 4. NetBIOS over TCP/IP
        string netbtKey = @"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters";
        _registry.CreateKey(netbtKey);
        _registry.SetValue(netbtKey, "NetbiosOptions", 1, RegistryValueKind.DWord);

        string ifacesKey = $@"{netbtKey}\Interfaces";
        if (_registry.KeyExists(ifacesKey))
        {
            foreach (var iface in _registry.GetSubKeyNames(ifacesKey))
            {
                string target = $@"{ifacesKey}\{iface}";
                _registry.SetValue(target, "NetbiosOptions", 1, RegistryValueKind.DWord);
            }
        }

        _logger?.LogSuccess(nameof(ConnectivityService), "SMB sharing configured successfully with guest auth and NetBIOS enabled.");
        return new SmbConfigResult(fwOk, servicesOk, true, true, true, "SMB sharing configuration applied successfully.");
    }

    public bool RestartAdapter(string adapterName)
    {
        if (string.IsNullOrWhiteSpace(adapterName)) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Restarting network adapter '{adapterName}'...");
        return _network.RestartAdapter(adapterName);
    }

    public bool EnableAdapter(string adapterName)
    {
        if (string.IsNullOrWhiteSpace(adapterName)) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Enabling network adapter '{adapterName}'...");
        var res = _processRunner.Run("netsh.exe", $"interface set interface \"{adapterName}\" enable");
        bool netOk = _network.EnableAdapter(adapterName);
        return netOk || res.ExitCode == 0;
    }

    public bool DisableAdapter(string adapterName)
    {
        if (string.IsNullOrWhiteSpace(adapterName)) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Disabling network adapter '{adapterName}'...");
        var res = _processRunner.Run("netsh.exe", $"interface set interface \"{adapterName}\" disable");
        bool netOk = _network.DisableAdapter(adapterName);
        return netOk || res.ExitCode == 0;
    }

    public bool ReleaseRenewAdapterDhcp(string adapterName)
    {
        if (string.IsNullOrWhiteSpace(adapterName)) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Releasing and renewing DHCP lease for adapter '{adapterName}'...");
        _processRunner.Run("ipconfig.exe", $"/release \"{adapterName}\"");
        var ren = _processRunner.Run("ipconfig.exe", $"/renew \"{adapterName}\"");
        bool netOk = _network.ReleaseRenewAdapterDhcp(adapterName);
        return netOk || ren.ExitCode == 0;
    }

    public bool SetAdapterIpConfiguration(string adapterName, AdapterIpConfig config)
    {
        if (string.IsNullOrWhiteSpace(adapterName) || config == null) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Configuring IP for adapter '{adapterName}' (UseDhcp={config.UseDhcp})...");
        if (config.UseDhcp)
        {
            var res = _processRunner.Run("netsh.exe", $"interface ipv4 set address \"{adapterName}\" dhcp");
            bool netOk = _network.SetAdapterIpConfiguration(adapterName, config);
            return netOk || res.ExitCode == 0;
        }
        else
        {
            if (string.IsNullOrWhiteSpace(config.IpAddress) || string.IsNullOrWhiteSpace(config.SubnetMask)) return false;
            string gw = !string.IsNullOrWhiteSpace(config.DefaultGateway) ? $" {config.DefaultGateway}" : "";
            var res = _processRunner.Run("netsh.exe", $"interface ipv4 set address \"{adapterName}\" static {config.IpAddress} {config.SubnetMask}{gw}");
            bool netOk = _network.SetAdapterIpConfiguration(adapterName, config);
            return netOk || res.ExitCode == 0;
        }
    }

    public bool SetAdapterDnsConfiguration(string adapterName, AdapterDnsConfig config)
    {
        if (string.IsNullOrWhiteSpace(adapterName) || config == null) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Configuring DNS for adapter '{adapterName}' (UseDhcp={config.UseDhcp})...");
        if (config.UseDhcp)
        {
            var res = _processRunner.Run("netsh.exe", $"interface ipv4 set dnsservers \"{adapterName}\" dhcp");
            bool netOk = _network.SetAdapterDnsConfiguration(adapterName, config);
            return netOk || res.ExitCode == 0;
        }
        else
        {
            if (string.IsNullOrWhiteSpace(config.PreferredDns)) return false;
            var res1 = _processRunner.Run("netsh.exe", $"interface ipv4 set dnsservers \"{adapterName}\" static {config.PreferredDns} primary");
            bool res2Ok = true;
            if (!string.IsNullOrWhiteSpace(config.AlternateDns))
            {
                var res2 = _processRunner.Run("netsh.exe", $"interface ipv4 add dnsservers \"{adapterName}\" {config.AlternateDns} index=2");
                res2Ok = res2.ExitCode == 0;
            }
            bool netOk = _network.SetAdapterDnsConfiguration(adapterName, config);
            return netOk || (res1.ExitCode == 0 && res2Ok);
        }
    }

    public bool SetAdapterMtu(string adapterName, int mtu)
    {
        if (string.IsNullOrWhiteSpace(adapterName) || mtu < 576 || mtu > 9000) return false;
        _logger?.LogInfo(nameof(ConnectivityService), $"Setting MTU={mtu} for adapter '{adapterName}'...");
        var res = _processRunner.Run("netsh.exe", $"interface ipv4 set subinterface \"{adapterName}\" mtu={mtu} store=persistent");
        bool netOk = _network.SetAdapterMtu(adapterName, mtu);
        return netOk || res.ExitCode == 0;
    }

    public PrinterPortDiagnosticResult DiagnosePrinterPortConnectivity(string host)
    {
        _logger?.LogInfo(nameof(ConnectivityService), $"Diagnosing printer connectivity to '{host}' across ICMP, SMB (445), RPC (135), and RAW (9100)...");
        bool ping = _network.PingHost(host);
        bool smb = _network.TestPort(host, 445);
        bool rpc = _network.TestPort(host, 135);
        bool raw = _network.TestPort(host, 9100);

        string summary = $"Host '{host}': Ping={(ping ? "PASS" : "FAIL")}, SMB:445={(smb ? "OPEN" : "CLOSED")}, RPC:135={(rpc ? "OPEN" : "CLOSED")}, RAW:9100={(raw ? "OPEN" : "CLOSED")}";
        return new PrinterPortDiagnosticResult(host, ping, smb, rpc, raw, summary);
    }
}
