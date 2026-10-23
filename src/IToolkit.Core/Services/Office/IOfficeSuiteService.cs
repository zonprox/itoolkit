namespace IToolkit.Core.Services.Office;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Office suite diagnostics, repair, optimization, and scrubbing.
/// </summary>
public interface IOfficeSuiteService
{
    bool RepairClickToRunService();
    ProcessExecutionResult RunClickToRunRepair(bool online = false);
    OperationResult ResetOfficeIdentityCache();
    OperationResult SetHardwareAcceleration(bool disable);
    bool TerminateOfficeProcesses(TimeSpan? timeout = null);

    // Word repairs
    bool ResetWordNormalDotm();
    int DisableWordStartupAddIns();
    OperationResult ResetWordRegistryData();
    int CleanWordLockFiles(string? directory = null);
    OfficeAppRepairResult WordQuickRepair();

    // Excel repairs
    int IsolateExcelXlStart();
    bool ResetExcelUiCache();
    OperationResult RepairExcelDdeAndCalculation();
    OperationResult PurgeExcelResiliency();
    IReadOnlyList<GdiAuditResult> AuditAndMitigateGdiLeaks(int warningThreshold = 5000, int killThreshold = 8000);
    OfficeAppRepairResult ExcelQuickRepair();

    // PowerPoint repairs
    bool PurgePowerPointCache();
    OperationResult PurgePowerPointResiliency();
    OfficeAppRepairResult PowerPointQuickRepair();

    // Scrubber
    OfficeScrubResult ScrubOfficeSuiteCleanly();
}
