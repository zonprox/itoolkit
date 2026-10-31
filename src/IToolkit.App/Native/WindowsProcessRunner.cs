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
    private static string NormalizeProcessName(string processName)
    {
        if (string.IsNullOrWhiteSpace(processName)) return string.Empty;
        string trimmed = processName.Trim();
        return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? trimmed[..^4]
            : trimmed;
    }

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

        var syncLock = new object();
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        using var process = new Process { StartInfo = psi };
        process.OutputDataReceived += (s, e) =>
        {
            if (e.Data != null)
            {
                lock (syncLock) { stdout.AppendLine(e.Data); }
            }
        };
        process.ErrorDataReceived += (s, e) =>
        {
            if (e.Data != null)
            {
                lock (syncLock) { stderr.AppendLine(e.Data); }
            }
        };

        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            return new ProcessExecutionResult(-1, string.Empty, ex.Message, false);
        }

        bool exited = process.WaitForExit(timeoutMs);
        if (!exited)
        {
            try { process.Kill(true); } catch { }
            lock (syncLock)
            {
                return new ProcessExecutionResult(-1, stdout.ToString(), $"Process timed out after {timeoutMs}ms: {stderr}", true);
            }
        }

        process.WaitForExit(); // Flush async buffers
        lock (syncLock)
        {
            return new ProcessExecutionResult(process.ExitCode, stdout.ToString(), stderr.ToString(), false);
        }
    }

    public async Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default)
    {
        return await Task.Run(() => Run(fileName, arguments, workingDirectory, timeoutMs), cancellationToken);
    }

    public IEnumerable<ProcessInfo> GetProcessesByName(string processName)
    {
        string normalized = NormalizeProcessName(processName);
        if (string.IsNullOrEmpty(normalized)) return Array.Empty<ProcessInfo>();

        var result = new List<ProcessInfo>();
        var processes = Process.GetProcessesByName(normalized);
        foreach (var p in processes)
        {
            using (p)
            {
                try
                {
                    string title = string.Empty;
                    try { title = p.MainWindowTitle; } catch { }
                    result.Add(new ProcessInfo(p.Id, p.ProcessName, title));
                }
                catch
                {
                }
            }
        }
        return result;
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
        string normalized = NormalizeProcessName(processName);
        if (string.IsNullOrEmpty(normalized)) return true;

        var processes = Process.GetProcessesByName(normalized);
        if (processes.Length == 0) return true;

        foreach (var p in processes)
        {
            using (p)
            {
                try { p.CloseMainWindow(); } catch { }
            }
        }

        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < timeoutSeconds)
        {
            if (!IsProcessRunning(normalized)) return true;
            Thread.Sleep(200);
        }

        if (force)
        {
            foreach (var p in Process.GetProcessesByName(normalized))
            {
                using (p)
                {
                    try { p.Kill(true); } catch { }
                }
            }
        }

        return !IsProcessRunning(normalized);
    }

    public bool IsProcessRunning(string processName)
    {
        string normalized = NormalizeProcessName(processName);
        if (string.IsNullOrEmpty(normalized)) return false;

        var processes = Process.GetProcessesByName(normalized);
        foreach (var p in processes)
        {
            p.Dispose();
        }
        return processes.Length > 0;
    }

    public bool StartProcess(string fileName, string? arguments = null)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return false;

        string exeName = fileName.Trim();
        if (!exeName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            exeName += ".exe";
        }

        string resolvedFileName = ResolveExecutablePath(exeName);

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = resolvedFileName,
                Arguments = arguments ?? string.Empty,
                WorkingDirectory = System.IO.File.Exists(resolvedFileName)
                    ? (System.IO.Path.GetDirectoryName(resolvedFileName) ?? Environment.CurrentDirectory)
                    : Environment.CurrentDirectory,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Normal
            };
            using var proc = Process.Start(psi);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static string ResolveExecutablePath(string exeName)
    {
        if (System.IO.File.Exists(exeName))
        {
            return System.IO.Path.GetFullPath(exeName);
        }

        try
        {
            using var hklmKey = Microsoft.Win32.Registry.LocalMachine.OpenSubKey($@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exeName}");
            if (hklmKey?.GetValue(null) is string hklmPath && !string.IsNullOrWhiteSpace(hklmPath) && System.IO.File.Exists(hklmPath.Trim('"')))
            {
                return hklmPath.Trim('"');
            }

            using var hklmWowKey = Microsoft.Win32.Registry.LocalMachine.OpenSubKey($@"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\{exeName}");
            if (hklmWowKey?.GetValue(null) is string hklmWowPath && !string.IsNullOrWhiteSpace(hklmWowPath) && System.IO.File.Exists(hklmWowPath.Trim('"')))
            {
                return hklmWowPath.Trim('"');
            }

            using var hkcuKey = Microsoft.Win32.Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\App Paths\{exeName}");
            if (hkcuKey?.GetValue(null) is string hkcuPath && !string.IsNullOrWhiteSpace(hkcuPath) && System.IO.File.Exists(hkcuPath.Trim('"')))
            {
                return hkcuPath.Trim('"');
            }
        }
        catch
        {
        }

        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string pfx86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidatePaths =
        {
            System.IO.Path.Combine(pf, "Microsoft Office", "root", "Office16", exeName),
            System.IO.Path.Combine(pfx86, "Microsoft Office", "root", "Office16", exeName),
            System.IO.Path.Combine(pf, "Google", "Chrome", "Application", exeName),
            System.IO.Path.Combine(pfx86, "Google", "Chrome", "Application", exeName),
            System.IO.Path.Combine(pf, "Microsoft", "Edge", "Application", exeName),
            System.IO.Path.Combine(pfx86, "Microsoft", "Edge", "Application", exeName),
            System.IO.Path.Combine(pf, "Foxit Software", "Foxit PDF Reader", exeName),
            System.IO.Path.Combine(pfx86, "Foxit Software", "Foxit PDF Reader", exeName),
            System.IO.Path.Combine(pf, "WinRAR", exeName),
            System.IO.Path.Combine(pf, "UniKey", exeName),
            System.IO.Path.Combine(localAppData, "Programs", "Zalo", exeName)
        };

        foreach (var candidate in candidatePaths)
        {
            if (System.IO.File.Exists(candidate))
            {
                return candidate;
            }
        }

        return exeName;
    }
}
