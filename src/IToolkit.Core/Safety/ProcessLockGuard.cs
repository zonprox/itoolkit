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
    private readonly ISafetyConfirmationService? _confirmationService;
    private readonly List<string> _lastClosedProcesses = new();
    private readonly List<string> _lastRestartedProcesses = new();

    private static readonly HashSet<string> NonRestartableDaemonNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "OFFICECLICKTORUN", "MSOIA", "MSOSYNC", "spoolsv"
    };

    public static readonly TimeSpan DefaultGracefulTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromMilliseconds(200);

    public static readonly string[] OfficeProcessNames = { "OUTLOOK", "WINWORD", "EXCEL", "POWERPNT" };
    public static readonly string[] SpoolerProcessNames = { "spoolsv" };
    public static readonly string[] AppCatalogProcessNames =
    {
        "chrome", "FoxitPDFReader", "winvnc", "vncviewer", "mpc-hc64", "mpc-be64", "WinRAR", "UniKeyNT", "Zalo"
    };

    public IReadOnlyList<string> LastClosedProcesses => _lastClosedProcesses;
    public IReadOnlyList<string> LastRestartedProcesses => _lastRestartedProcesses;

    public ProcessLockGuard(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IActivityLogger? logger = null,
        ISafetyConfirmationService? confirmationService = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _logger = logger;
        _confirmationService = confirmationService;
    }

    public static string GetApplicationDisplayName(string processName)
    {
        if (string.IsNullOrWhiteSpace(processName)) return "Application";
        string norm = processName.Trim();
        if (norm.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            norm = norm[..^4];
        }

        return norm.ToUpperInvariant() switch
        {
            "OUTLOOK" => "Microsoft Outlook",
            "WINWORD" => "Microsoft Word",
            "EXCEL" => "Microsoft Excel",
            "POWERPNT" => "Microsoft PowerPoint",
            "ONENOTE" => "Microsoft OneNote",
            "MSACCESS" => "Microsoft Access",
            "MSPUB" => "Microsoft Publisher",
            "VISIO" => "Microsoft Visio",
            "WINPROJ" => "Microsoft Project",
            "TEAMS" => "Microsoft Teams",
            "ONEDRIVE" => "Microsoft OneDrive",
            "CHROME" => "Google Chrome",
            "MSEDGE" => "Microsoft Edge",
            "FOXITPDFREADER" or "FOXITREADER" => "Foxit PDF Reader",
            "UNIKEYNT" or "UNIKEY" => "UniKey",
            "WINVNC" or "VNCVIEWER" => "UltraVNC",
            "MPC-HC64" or "MPC-HC" or "MPC-BE64" => "K-Lite Codec Pack",
            "WINRAR" => "WinRAR",
            "ZALO" => "Zalo",
            _ => norm
        };
    }

    public static string FormatApplicationNames(IEnumerable<string> processNames)
    {
        if (processNames == null) return string.Empty;
        var names = processNames
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Select(GetApplicationDisplayName)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        return string.Join(", ", names);
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
            if (running != null)
            {
                list.AddRange(running);
            }
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

        foreach (var procName in activeProcesses.Select(p => p.ProcessName).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!NonRestartableDaemonNames.Contains(procName) &&
                !_lastClosedProcesses.Contains(procName, StringComparer.OrdinalIgnoreCase))
            {
                _lastClosedProcesses.Add(procName);
            }
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
        if (pendingPids.Count > 0 || IsAnyProcessRunning(targetNames))
        {
            if (forceKill)
            {
                var remainingPids = GetLockingProcesses(targetNames).Select(p => p.Id).Concat(pendingPids).Distinct().ToList();
                _logger?.LogWarning(nameof(ProcessLockGuard), $"Graceful timeout expired. Escalating to force kill for {remainingPids.Count} process(es)...");
                foreach (var pid in remainingPids)
                {
                    _processRunner.KillProcess(pid, entireProcessTree: true);
                }

                // Poll up to 1000ms for OS handle cleanup on multi-process apps (e.g. Chrome/Office)
                DateTime killWaitStart = DateTime.UtcNow;
                while (IsAnyProcessRunning(targetNames) && (DateTime.UtcNow - killWaitStart).TotalMilliseconds < 1000)
                {
                    await Task.Delay(100, cancellationToken);
                    foreach (var proc in GetLockingProcesses(targetNames))
                    {
                        _processRunner.KillProcess(proc.Id, entireProcessTree: true);
                    }
                }
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

    /// <summary>
    /// Automatically restarts applications that were running and closed prior to a fix operation.
    /// </summary>
    public IReadOnlyList<string> RestartClosedProcesses(IEnumerable<string>? fallbackProcessNames = null)
    {
        var candidates = _lastClosedProcesses.ToList();

        _lastClosedProcesses.Clear();
        _lastRestartedProcesses.Clear();

        var seenDisplayNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawName in candidates)
        {
            if (string.IsNullOrWhiteSpace(rawName)) continue;
            string procName = rawName.Trim();
            if (procName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                procName = procName[..^4];
            }

            if (NonRestartableDaemonNames.Contains(procName))
            {
                continue;
            }

            string displayName = GetApplicationDisplayName(procName);
            if (!seenDisplayNames.Add(displayName))
            {
                continue;
            }

            string exeToStart = $"{procName}.exe";
            if (_processRunner.StartProcess(exeToStart))
            {
                _lastRestartedProcesses.Add(exeToStart);
                _logger?.LogInfo(nameof(ProcessLockGuard), $"Automatically restarted '{displayName}' ({exeToStart}) after fix completion.");
            }
        }

        return _lastRestartedProcesses;
    }
}
