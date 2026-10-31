namespace IToolkit.Core.Services.Connectivity;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for network connectivity diagnostics and network stack remediation.
/// </summary>
public interface IConnectivityService
{
    bool FlushDns();
    bool ReleaseRenewDhcp();
    bool ClearArpAndRouteCache();
    bool ResetWinsock();
    bool ResetTcpIpStack();
    bool ResetNla();
    bool ResetProxyAndWinHttp();
    NetworkRemediationResult RemediateNetworkStack();
    SmbConfigResult ConfigureSmbSharing();
    bool RestartAdapter(string adapterName);
    bool EnableAdapter(string adapterName);
    bool DisableAdapter(string adapterName);
    bool ReleaseRenewAdapterDhcp(string adapterName);
    bool SetAdapterIpConfiguration(string adapterName, AdapterIpConfig config);
    bool SetAdapterDnsConfiguration(string adapterName, AdapterDnsConfig config);
    bool SetAdapterMtu(string adapterName, int mtu);
    PrinterPortDiagnosticResult DiagnosePrinterPortConnectivity(string host);
}
