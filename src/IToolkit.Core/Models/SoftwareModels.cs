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
