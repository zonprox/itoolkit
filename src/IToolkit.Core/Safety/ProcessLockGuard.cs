namespace IToolkit.Core.Safety;

using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Probes for process locks, enforces graceful-first termination with configurable timeout,
/// escalates to force kill when necessary, and confirms lock release.
/// </summary>
public class ProcessLockGuard
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IActivityLogger? _logger;

    public static readonly TimeSpan DefaultGracefulTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromMilliseconds(200);

    public static readonly string[] OfficeProcessNames = { "OUTLOOK", "WINWORD", "EXCEL", "POWERPNT" };
    public static readonly string[] SpoolerProcessNames = { "spoolsv" };
    public static readonly string[] AppCatalogProcessNames =
    {
        "chrome", "FoxitPDFReader", "winvnc", "vncviewer", "mpc-hc64", "mpc-be64", "WinRAR", "UniKeyNT", "Zalo"
    };

    public ProcessLockGuard(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _logger = logger;
    }

    /// <summary>
    /// Enumerates all active processes matching any of the specified process names.
    /// </summary>
    public IReadOnlyList<ProcessInfo> GetLockingProcesses(IEnumerable<string> processNames)
    {
        ArgumentNullException.ThrowIfNull(processNames);

        var list = new List<ProcessInfo>();
        foreach (var name in processNames)
        {
            var running = _processRunner.GetProcessesByName(name);
            list.AddRange(running);
        }
        return list;
    }

    /// <summary>
    /// Checks whether any instance of the specified process names is currently active.
    /// </summary>
    public bool IsAnyProcessRunning(IEnumerable<string> processNames)
    {
        ArgumentNullException.ThrowIfNull(processNames);
        return processNames.Any(name => _processRunner.IsProcessRunning(name));
    }

    /// <summary>
    /// Checks whether a specific physical file is currently locked by any process handle.
    /// </summary>
    public bool IsFileLocked(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        return _fileSystem.IsFileLocked(filePath);
    }

    /// <summary>
    /// Ensures all matching processes are closed, attempting graceful window closure first
    /// before escalating to force kill after timeout.
    /// </summary>
    public async Task<bool> EnsureProcessesClosedAsync(
        IEnumerable<string> processNames,
        TimeSpan? timeout = null,
        bool forceKill = true,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(processNames);

        var targetNames = processNames.ToList();
        var timeoutLimit = timeout ?? DefaultGracefulTimeout;
        var activeProcesses = GetLockingProcesses(targetNames);

        if (activeProcesses.Count == 0)
        {
            return true;
        }

        _logger?.LogInfo(nameof(ProcessLockGuard), $"Detected {activeProcesses.Count} locking process(es): {string.Join(", ", activeProcesses.Select(p => $"{p.ProcessName}:{p.Id}"))}");

        // Phase 1: Request graceful closure for all locking processes
        foreach (var proc in activeProcesses)
        {
            _logger?.LogInfo(nameof(ProcessLockGuard), $"Requesting graceful close for {proc.ProcessName} (PID {proc.Id})...");
            _processRunner.CloseMainWindow(proc.Id);
        }

        // Phase 2: Poll for exit until timeout
        DateTime startTime = DateTime.UtcNow;
        var pendingPids = activeProcesses.Select(p => p.Id).ToHashSet();

        while (pendingPids.Count > 0 && (DateTime.UtcNow - startTime) < timeoutLimit)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var currentActive = GetLockingProcesses(targetNames);
            var currentPids = currentActive.Select(p => p.Id).ToHashSet();
            pendingPids.RemoveWhere(pid => !currentPids.Contains(pid));

            if (pendingPids.Count == 0)
            {
                break;
            }

            await Task.Delay(DefaultPollInterval, cancellationToken);
        }

        // Phase 3: Force kill escalation if still running and forceKill is true
        if (pendingPids.Count > 0)
        {
            if (forceKill)
            {
                _logger?.LogWarning(nameof(ProcessLockGuard), $"Graceful timeout expired. Escalating to force kill for {pendingPids.Count} process(es)...");
                foreach (var pid in pendingPids)
                {
                    _processRunner.KillProcess(pid, entireProcessTree: true);
                }

                // Brief post-kill verification
                await Task.Delay(100, cancellationToken);
            }
            else
            {
                _logger?.LogError(nameof(ProcessLockGuard), $"Graceful timeout expired and force kill is disabled. {pendingPids.Count} process(es) remain active.");
                return false;
            }
        }

        // Phase 4: Lock release confirmation
        bool allReleased = !IsAnyProcessRunning(targetNames);
        if (allReleased)
        {
            _logger?.LogSuccess(nameof(ProcessLockGuard), "Confirmed all locking processes have released their handles.");
        }
        else
        {
            _logger?.LogError(nameof(ProcessLockGuard), "Failed to release process locks; processes are still running.");
        }

        return allReleased;
    }

    /// <summary>
    /// Synchronously ensures all matching processes are closed with graceful-first escalation.
    /// </summary>
    public bool EnsureProcessesClosed(
        IEnumerable<string> processNames,
        TimeSpan? timeout = null,
        bool forceKill = true)
    {
        return EnsureProcessesClosedAsync(processNames, timeout, forceKill).GetAwaiter().GetResult();
    }
}
