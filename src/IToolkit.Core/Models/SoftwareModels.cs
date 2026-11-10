namespace IToolkit.Core.Models;

/// <summary>
/// App installation mechanism.
/// </summary>
public enum AppInstallMode
{
    WingetWithFallback,
    DirectOnly,
    ArchiveExtract
}

/// <summary>
/// Definition of a managed application in the 8-app enterprise catalog.
/// </summary>
public record AppCatalogItem(
    string AppId,
    string DisplayName,
    string? WingetId,
    AppInstallMode InstallMode,
    string DirectDownloadUrl,
    string SilentArguments,
    string? ShortcutName,
    string? DefaultAppType,
    IReadOnlyList<string> ConflictingProcesses);

/// <summary>
/// Result of application installation or extraction.
/// </summary>
public record AppInstallResult(
    string AppId,
    string DisplayName,
    string MethodUsed,
    bool Success,
    string Message,
    bool TempCleanedUp);

/// <summary>
/// Diagnostic status of the Windows Package Manager (winget.exe) subsystem.
/// </summary>
public record WingetStatus(
    bool IsInstalled,
    string Version,
    bool SourceListValid,
    bool Healthy,
    string Message = "");

/// <summary>
/// Result of launching an external debloat tool in isolated elevated PowerShell.
/// </summary>
public record DebloatExecutionResult(
    string ToolName,
    string ScriptUrl,
    bool SyntaxValid,
    bool ExecutionSuccess,
    int ExitCode,
    bool TempCleanedUp,
    string Output,
    string Message = "");

/// <summary>
/// A package discovered via Windows Package Manager (winget search).
/// </summary>
public record WingetPackage(
    string Name,
    string Id,
    string Version,
    string? Match,
    string Source);

/// <summary>
/// An installed application detected on the system via winget list.
/// </summary>
public record WingetInstalledApp(
    string Name,
    string Id,
    string Version,
    string? AvailableVersion,
    string Source);

/// <summary>
/// An application eligible for upgrade detected via winget list --upgrade-available.
/// </summary>
public record WingetUpdateItem(
    string Name,
    string Id,
    string InstalledVersion,
    string AvailableVersion,
    string Source);

/// <summary>
/// Structured outcome of evaluating a winget process exit code.
/// </summary>
public record WingetExitCodeResult(
    bool Success,
    string Message,
    bool RebootRequired = false,
    bool AlreadyUpToDate = false,
    bool RequiresAdmin = false,
    bool CancelledByUser = false);

