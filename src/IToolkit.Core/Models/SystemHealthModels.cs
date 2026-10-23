namespace IToolkit.Core.Models;

/// <summary>
/// Result of DISM health scan, check, or restore operations.
/// </summary>
public record DismScanResult(
    bool Success,
    int ExitCode,
    bool NeedsReboot,
    string Output,
    string ErrorOutput = "")
{
    public static DismScanResult Successful(string output, bool rebootRequired = false) =>
        new(true, rebootRequired ? 3010 : 0, rebootRequired, output);

    public static DismScanResult Failed(int exitCode, string output, string error = "") =>
        new(false, exitCode, false, output, error);
}

/// <summary>
/// Result of System File Checker (SFC) scannow execution.
/// </summary>
public record SfcScanResult(
    bool Success,
    int ExitCode,
    bool IntegrityViolationsFound,
    bool SuccessfullyRepaired,
    string Output,
    string ErrorOutput = "")
{
    public static SfcScanResult Clean(string output) =>
        new(true, 0, false, false, output);

    public static SfcScanResult Repaired(string output) =>
        new(true, 1, true, true, output);

    public static SfcScanResult Failed(int exitCode, string output, string error = "") =>
        new(false, exitCode, true, false, output, error);
}

/// <summary>
/// Result of WinSxS component store cleanup.
/// </summary>
public record ComponentCleanupResult(
    bool Success,
    int ExitCode,
    string Output,
    string ErrorOutput = "");

/// <summary>
/// Result of multi-target storage cleanup (WinSxS, WU Cache, Delivery Optimization, Logs, Temp).
/// </summary>
public record StorageCleanupResult(
    bool Success,
    long BytesReclaimed,
    int FilesDeleted,
    int FilesSkipped,
    IReadOnlyList<string> CleanedTargets,
    IReadOnlyList<string> Errors);

/// <summary>
/// Result of Windows Update component reset pipeline.
/// </summary>
public record WindowsUpdateResetResult(
    bool Success,
    IReadOnlyList<string> StoppedServices,
    IReadOnlyList<string> RenamedDirectories,
    int ReRegisteredDllCount,
    IReadOnlyList<string> RestartedServices,
    string Message = "");

/// <summary>
/// Result of WMI repository verification and salvage/repair.
/// </summary>
public record WmiRepairResult(
    bool Success,
    bool IsConsistent,
    bool Salvaged,
    bool Reset,
    string Output);
