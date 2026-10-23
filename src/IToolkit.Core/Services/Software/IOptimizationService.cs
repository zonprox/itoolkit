namespace IToolkit.Core.Services.Software;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Windows Package Manager (Winget) health/repair and secured external debloat launchers.
/// </summary>
public interface IOptimizationService
{
    WingetStatus GetWingetStatus();
    bool RepairWinget();
    ProcessExecutionResult UpdateAllPackages();
    DebloatExecutionResult LaunchWin11Debloat(string? customUrl = null);
    DebloatExecutionResult LaunchBrowserDebloat(string? customUrl = null);
    DebloatExecutionResult ExecuteDebloatScript(string toolName, string scriptUrl);
}
