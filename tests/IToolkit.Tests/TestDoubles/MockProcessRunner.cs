namespace IToolkit.Tests.TestDoubles;

using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// In-memory test double for IProcessRunner enabling deterministic process lifecycle and execution tests.
/// </summary>
public class MockProcessRunner : IProcessRunner
{
    public class SimulatedProcess
    {
        public ProcessInfo Info { get; set; }
        public bool ExitsOnCloseMainWindow { get; set; } = true;
        public bool CloseRequested { get; set; }
        public bool KillRequested { get; set; }

        public SimulatedProcess(int id, string name, string? title = null, bool exitsOnClose = true)
        {
            Info = new ProcessInfo(id, name, title);
            ExitsOnCloseMainWindow = exitsOnClose;
        }
    }

    private readonly List<SimulatedProcess> _processes = new();
    private readonly Dictionary<string, ProcessExecutionResult> _commandResults = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<SimulatedProcess> SimulatedProcesses => _processes;
    public List<string> ExecutedCommands { get; } = new();
    public List<string> StartedProcesses { get; } = new();

    public void AddProcess(int id, string name, string? title = null, bool exitsOnClose = true)
    {
        _processes.Add(new SimulatedProcess(id, name, title, exitsOnClose));
    }

    public void SetCommandResult(string commandLine, ProcessExecutionResult result)
    {
        _commandResults[commandLine] = result;
    }

    public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
    {
        string cmd = $"{fileName} {arguments}".Trim();
        ExecutedCommands.Add(cmd);

        if (_commandResults.TryGetValue(cmd, out var result))
        {
            return result;
        }

        foreach (var kvp in _commandResults)
        {
            if (cmd.StartsWith(kvp.Key, StringComparison.OrdinalIgnoreCase))
            {
                return kvp.Value;
            }
        }

        return new ProcessExecutionResult(0, "Mock execution succeeded.", string.Empty, false);
    }

    public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default)
    {
        return Task.FromResult(Run(fileName, arguments, workingDirectory, timeoutMs));
    }

    public IEnumerable<ProcessInfo> GetProcessesByName(string processName)
    {
        return _processes
            .Where(p => p.Info.ProcessName.Equals(processName, StringComparison.OrdinalIgnoreCase))
            .Select(p => p.Info)
            .ToList();
    }

    public bool CloseMainWindow(int processId)
    {
        var proc = _processes.FirstOrDefault(p => p.Info.Id == processId);
        if (proc != null)
        {
            proc.CloseRequested = true;
            if (proc.ExitsOnCloseMainWindow)
            {
                _processes.Remove(proc);
            }
            return true;
        }
        return false;
    }

    public bool WaitForExit(int processId, TimeSpan timeout)
    {
        return !_processes.Any(p => p.Info.Id == processId);
    }

    public bool KillProcess(int processId, bool entireProcessTree = true)
    {
        var proc = _processes.FirstOrDefault(p => p.Info.Id == processId);
        if (proc != null)
        {
            proc.KillRequested = true;
            _processes.Remove(proc);
            return true;
        }
        return false;
    }

    public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true)
    {
        var matching = GetProcessesByName(processName).ToList();
        if (matching.Count == 0) return true;

        foreach (var p in matching)
        {
            CloseMainWindow(p.Id);
        }

        if (force)
        {
            var remaining = GetProcessesByName(processName).ToList();
            foreach (var p in remaining)
            {
                KillProcess(p.Id);
            }
        }

        return !IsProcessRunning(processName);
    }

    public bool IsProcessRunning(string processName)
    {
        return _processes.Any(p => p.Info.ProcessName.Equals(processName, StringComparison.OrdinalIgnoreCase));
    }

    public bool StartProcess(string fileName, string? arguments = null)
    {
        string cmd = string.IsNullOrWhiteSpace(arguments) ? fileName : $"{fileName} {arguments}".Trim();
        StartedProcesses.Add(cmd);
        return true;
    }
}
