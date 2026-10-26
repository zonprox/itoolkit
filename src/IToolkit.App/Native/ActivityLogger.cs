namespace IToolkit.App.Native;

using System;
using System.IO;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class ActivityLogger : IActivityLogger
{
    private static readonly object _lock = new();

    public string LogFilePath => Path.Combine(AppContext.BaseDirectory, "Logs", $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

    public event Action<ActivityLogEntry>? EntryLogged;

    public ActivityLogger()
    {
        try
        {
            string logsDir = Path.Combine(AppContext.BaseDirectory, "Logs");
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
                string targetPath = Path.Combine(AppContext.BaseDirectory, "Logs", $"iToolKit_{entry.Timestamp:yyyyMMdd}.log");
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
}
