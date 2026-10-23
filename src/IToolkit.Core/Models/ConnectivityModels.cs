namespace IToolkit.Core.Models;

/// <summary>
/// Point and Print policy security presets.
/// </summary>
public enum PointAndPrintPreset
{
    StrictAdminOnly,
    Compatibility
}

/// <summary>
/// Result of full network stack remediation.
/// </summary>
public record NetworkRemediationResult(
    bool DnsFlushed,
    bool DhcpRenewed,
    bool ArpCleared,
    bool WinsockReset,
    bool TcpIpReset,
    bool NlaReset,
    bool ProxyReset,
    bool Success,
    bool RequiresReboot,
    string Message = "");

/// <summary>
/// Result of SMB sharing configuration and 0x80070035/0x80070043 hardening.
/// </summary>
public record SmbConfigResult(
    bool FirewallRulesConfigured,
    bool ServicesStarted,
    bool InsecureGuestAuthEnabled,
    bool NetbiosEnabled,
    bool Success,
    string Message = "");

/// <summary>
/// Result of printer port network diagnostics across SMB, RPC, and RAW ports.
/// </summary>
public record PrinterPortDiagnosticResult(
    string Host,
    bool IsPingSuccessful,
    bool IsSmbPortOpen,
    bool IsRpcPortOpen,
    bool IsRawPortOpen,
    string DiagnosticsSummary);

/// <summary>
/// Result of Print Spooler queue purge.
/// </summary>
public record SpoolerQueueResult(
    bool SpoolerStopped,
    bool SpoolFilesPurged,
    bool SpoolerRestarted,
    int PurgedFilesCount,
    bool Success,
    string Message = "");

/// <summary>
/// Result of specific printer error remediation from the 12-item catalog.
/// </summary>
public record PrinterRemediationResult(
    string ErrorCode,
    string RemediationAction,
    bool PolicyApplied,
    bool ServicesRestarted,
    bool Success,
    string Message = "");
