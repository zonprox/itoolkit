namespace IToolkit.Core.Abstractions;

using IToolkit.Core.Models;

/// <summary>
/// Abstraction for process management, execution, and lifecycle control.
/// </summary>
public interface IProcessRunner
{
    /// <summary>
    /// Synchronously executes an external executable and captures its output and exit code.
    /// </summary>
    ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000);

    /// <summary>
    /// Asynchronously executes an external executable and captures its output and exit code.
    /// </summary>
    Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default);

    /// <summary>
    /// Enumerates active processes matching the specified process name (without .exe extension).
    /// </summary>
    IEnumerable<ProcessInfo> GetProcessesByName(string processName);

    /// <summary>
    /// Sends a graceful close request to the main window of the specified process.
    /// </summary>
    bool CloseMainWindow(int processId);

    /// <summary>
    /// Waits up to the specified timeout for a process to terminate.
    /// </summary>
    bool WaitForExit(int processId, TimeSpan timeout);

    /// <summary>
    /// Immediately terminates a process, optionally killing the entire child process tree.
    /// </summary>
    bool KillProcess(int processId, bool entireProcessTree = true);

    /// <summary>
    /// Convenience helper to stop all instances of a process with graceful-first escalation to kill.
    /// </summary>
    bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true);

    /// <summary>
    /// Checks if at least one instance of the named process is running.
    /// </summary>
    bool IsProcessRunning(string processName);
}
