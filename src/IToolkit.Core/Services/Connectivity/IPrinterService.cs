namespace IToolkit.Core.Services.Connectivity;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Print Spooler management, Point &amp; Print policies, and the 12-error-code catalog.
/// </summary>
public interface IPrinterService
{
    SpoolerQueueResult PurgeSpoolerQueue();
    bool RegisterSpoolerComponents();
    int ResetNePortBindings();
    bool ApplyPointAndPrintPreset(PointAndPrintPreset preset);
    PrinterRemediationResult RemediatePrinterError(string errorCode);
    IReadOnlyList<string> GetSupportedErrorCodes();

    // Upgraded role-based batch and granular remediation methods
    BatchPrinterRemediationResult RemediateRole(PrinterRemediationRole role);
    BatchPrinterRemediationResult RemediateAll();
    PointAndPrintPolicyAuditResult AuditPointAndPrintPolicy();
    SpoolerServiceStatus GetSpoolerStatus();
    PrinterConnectionResetResult ResetPrinterConnections(bool all = true, string? printerName = null);
    IReadOnlyList<string> GetSupportedGranularTokens();
}
