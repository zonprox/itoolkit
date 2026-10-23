namespace IToolkit.Core.Models;

/// <summary>
/// Office desktop application identifiers.
/// </summary>
public enum OfficeAppType
{
    Common,
    Word,
    Excel,
    PowerPoint,
    Outlook
}

/// <summary>
/// Result of application-specific repair (Word, Excel, PowerPoint).
/// </summary>
public record OfficeAppRepairResult(
    string AppName,
    bool NormalDotmReset,
    int AddInsDisabledCount,
    bool RegistryReset,
    int LocksRemovedCount,
    bool Success,
    string Message = "");

/// <summary>
/// Result of GDI handle audit and leak mitigation for Excel.
/// </summary>
public record GdiAuditResult(
    int ProcessId,
    string ProcessName,
    int GdiHandleCount,
    bool Flagged,
    bool Terminated,
    string Message = "");

/// <summary>
/// Metadata for an Outlook PST or OST data file decoded from MAPI profile binary registry keys.
/// </summary>
public record MapiDataFileInfo(
    string FilePath,
    string DisplayName,
    string ProviderName,
    bool IsOst,
    bool IsPst,
    long FileSizeBytes,
    string RegistryPath,
    bool ExistsOnDisk);

/// <summary>
/// Result of Quick Mail & Cache Repair (Outbox, SRS, RoamCache preserving autocomplete, NavPane).
/// </summary>
public record QuickMailRepairResult(
    bool StuckOutboxCleared,
    bool SrsReset,
    bool RoamCacheCleaned,
    bool AutocompletePreserved,
    bool NavPaneReset,
    bool Success,
    string Message = "");

/// <summary>
/// Result of the Bundled New Default PST pipeline (100GB expansion, PST creation, hierarchy clone, rules migration).
/// </summary>
public record PstPipelineResult(
    string TargetPstPath,
    bool SizeLimitExpanded,
    int FoldersClonedCount,
    int RulesMigratedCount,
    bool IsDefaultSet,
    bool Success,
    string Message = "");

/// <summary>
/// Result of Outlook data file relocation with 1.2x headroom and SHA-256 validation.
/// </summary>
public record DataFileRelocationResult(
    string SourcePath,
    string DestinationPath,
    long FileSizeBytes,
    bool Sha256Matched,
    bool SymlinkCreated,
    bool RegistryUpdated,
    bool Success,
    string Message = "");

/// <summary>
/// Result of Office suite scrub / clean uninstall.
/// </summary>
public record OfficeScrubResult(
    int ProcessesTerminated,
    int ServicesStopped,
    int TasksRemoved,
    bool RegistryCleaned,
    int FilesDeleted,
    bool Success,
    string Message = "");
