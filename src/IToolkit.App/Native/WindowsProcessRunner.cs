namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class WindowsProcessRunner : IProcessRunner
{
    public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        using var process = new Process { StartInfo = psi };
        process.OutputDataReceived += (s, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (s, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        bool exited = process.WaitForExit(timeoutMs);
        if (!exited)
        {
            try { process.Kill(true); } catch { }
            return new ProcessExecutionResult(-1, stdout.ToString(), $"Process timed out after {timeoutMs}ms: {stderr}", true);
        }

        process.WaitForExit(); // Flush async buffers
        return new ProcessExecutionResult(process.ExitCode, stdout.ToString(), stderr.ToString(), false);
    }

    public async Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default)
    {
        return await Task.Run(() => Run(fileName, arguments, workingDirectory, timeoutMs), cancellationToken);
    }

    public IEnumerable<ProcessInfo> GetProcessesByName(string processName)
    {
        return Process.GetProcessesByName(processName)
            .Select(p => new ProcessInfo(p.Id, p.ProcessName, p.MainWindowTitle))
            .ToList();
    }

    public bool CloseMainWindow(int processId)
    {
        try
        {
            using var p = Process.GetProcessById(processId);
            return p.CloseMainWindow();
        }
        catch { return false; }
    }

    public bool WaitForExit(int processId, TimeSpan timeout)
    {
        try
        {
            using var p = Process.GetProcessById(processId);
            return p.WaitForExit((int)timeout.TotalMilliseconds);
        }
        catch { return true; }
    }

    public bool KillProcess(int processId, bool entireProcessTree = true)
    {
        try
        {
            using var p = Process.GetProcessById(processId);
            p.Kill(entireProcessTree);
            return true;
        }
        catch { return false; }
    }

    public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true)
    {
        var processes = Process.GetProcessesByName(processName);
        if (processes.Length == 0) return true;

        foreach (var p in processes)
        {
            try { p.CloseMainWindow(); } catch { }
        }

        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < timeoutSeconds)
        {
            if (Process.GetProcessesByName(processName).Length == 0) return true;
            Thread.Sleep(200);
        }

        if (force)
        {
            foreach (var p in Process.GetProcessesByName(processName))
            {
                try { p.Kill(true); } catch { }
            }
        }

        return Process.GetProcessesByName(processName).Length == 0;
    }

    public bool IsProcessRunning(string processName)
    {
        return Process.GetProcessesByName(processName).Length > 0;
    }
}
