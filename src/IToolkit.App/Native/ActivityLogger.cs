namespace IToolkit.App.Native;

using System;
using System.IO;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class ActivityLogger : IActivityLogger
{
    private static readonly object _lock = new();
    private readonly string _baseDirectory;

    public string LogFilePath => Path.Combine(_baseDirectory, "Logs", $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

    public event Action<ActivityLogEntry>? EntryLogged;

    public ActivityLogger(string? customBaseDirectory = null)
    {
        _baseDirectory = ResolveBaseDirectory(customBaseDirectory);
        try
        {
            string logsDir = Path.Combine(_baseDirectory, "Logs");
            Directory.CreateDirectory(logsDir);
        }
        catch
        {
            // Ignore directory creation failure in restricted environments
        }
    }

    public void Log(LogLevel level, string component, string message)
    {
        var entry = new ActivityLogEntry(DateTime.Now, level, component, message);

        lock (_lock)
        {
            try
            {
                string targetPath = Path.Combine(_baseDirectory, "Logs", $"iToolKit_{entry.Timestamp:yyyyMMdd}.log");
                string? targetDir = Path.GetDirectoryName(targetPath);
                if (!string.IsNullOrEmpty(targetDir) && !Directory.Exists(targetDir))
                {
                    Directory.CreateDirectory(targetDir);
                }

                string line = $"[{entry.Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{entry.Level.ToString().ToUpperInvariant(),-7}] [{entry.Component}] {entry.Message}{Environment.NewLine}";
                using var stream = new FileStream(targetPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                using var writer = new StreamWriter(stream);
                writer.Write(line);
            }
            catch
            {
                // Never crash on logging failure
            }
        }

        EntryLogged?.Invoke(entry);
    }

    private static string ResolveBaseDirectory(string? customBaseDirectory)
    {
        if (!string.IsNullOrWhiteSpace(customBaseDirectory))
        {
            return customBaseDirectory;
        }

        try
        {
            string? processPath = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(processPath))
            {
                string fileName = Path.GetFileName(processPath);
                string fileNameWithoutExt = Path.GetFileNameWithoutExtension(processPath);

                if (fileName.StartsWith("iToolKit", StringComparison.OrdinalIgnoreCase) ||
                    fileNameWithoutExt.StartsWith("iToolKit", StringComparison.OrdinalIgnoreCase))
                {
                    string? dir = Path.GetDirectoryName(processPath);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        return dir;
                    }
                }
            }
        }
        catch
        {
            // Fall back to AppContext.BaseDirectory in restricted environments
        }

        return AppContext.BaseDirectory;
    }
}
