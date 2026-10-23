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
    PrinterPortDiagnosticResult DiagnosePrinterPortConnectivity(string host);
}
