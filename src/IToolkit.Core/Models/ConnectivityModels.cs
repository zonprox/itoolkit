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
/// Operational role targeting for Print Spooler and connectivity remediation.
/// </summary>
public enum PrinterRemediationRole
{
    Client,
    Server,
    Both
}

/// <summary>
/// Result of specific printer error remediation from the 12-item catalog.
/// </summary>
public record PrinterRemediationResult(
    string ErrorCode,
    string RemediationAction,
    bool PolicyApplied,
    bool ServicesRestarted,
    bool Success,
    string Message = "",
    string? BackupPath = null,
    IReadOnlyList<string>? BackupPaths = null)
{
    public string? BackupPath { get; init; } = BackupPath ?? BackupPaths?.FirstOrDefault();
    public IReadOnlyList<string> BackupPaths { get; init; } =
        BackupPaths ?? (BackupPath != null ? new[] { BackupPath } : Array.Empty<string>());
}

/// <summary>
/// Result of role-based batch printer remediation pipeline.
/// </summary>
public record BatchPrinterRemediationResult(
    PrinterRemediationRole Role,
    IReadOnlyList<string> ActionsExecuted,
    IReadOnlyList<PrinterRemediationResult> Results,
    IReadOnlyList<string> BackupPaths,
    bool SpoolerRestarted,
    bool Success,
    string Message = "",
    int QueuePurgedCount = 0,
    int CleanedNePortsCount = 0,
    int RefreshedConnections = 0,
    int StaleRemoved = 0)
{
    public IReadOnlyList<string> FixesApplied => ActionsExecuted;
}

/// <summary>
/// Result of Point and Print policy audit, checking PrintNightmare CVE-2021-1678 posture and driver installation elevation requirements.
/// </summary>
public record PointAndPrintPolicyAuditResult(
    bool RpcAuthnLevelPrivacyEnabled,
    bool RestrictDriverInstallationToAdministrators,
    bool NoWarningNoElevationOnInstall,
    int UpdatePromptSettings,
    bool IsVulnerableToCVE20211678,
    string PostureDescription,
    IReadOnlyList<string> Recommendations)
{
    public bool IsVulnerable => IsVulnerableToCVE20211678 || !RestrictDriverInstallationToAdministrators;
    public IReadOnlyList<string> Vulnerabilities => Recommendations;
    public string Summary => PostureDescription;
}

/// <summary>
/// Status and health metrics of the Windows Print Spooler service and queue directory.
/// </summary>
public record SpoolerServiceStatus(
    bool IsRunning,
    string ServiceStatus,
    string SpoolDirectory,
    int PendingJobFileCount,
    long TotalQueueSizeBytes,
    bool HasStalledJobs,
    int? Pid = null,
    string StartupType = "Automatic",
    string Summary = "")
{
    public int QueueFileCount => PendingJobFileCount;
    public long QueueSizeBytes => TotalQueueSizeBytes;
    public string DefaultSpoolDirectory => SpoolDirectory;
}

/// <summary>
/// Result of network printer connection discovery, reachability verification, and stale connection cleanup.
/// </summary>
public record PrinterConnectionResetResult(
    int DiscoveredPrinters,
    int ReconnectedPrinters,
    int RemovedStalePrinters,
    IReadOnlyList<string> Details,
    bool Success,
    string Message = "")
{
    public int RefreshedConnections => ReconnectedPrinters;
    public int StaleRemoved => RemovedStalePrinters;
}
