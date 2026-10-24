namespace IToolkit.App.Native;

using System;
using System.IO;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class ActivityLogger : IActivityLogger
{
    private static readonly object _lock = new();
    private readonly string _logFilePath;

    public string LogFilePath => _logFilePath;

    public event Action<ActivityLogEntry>? EntryLogged;

    public ActivityLogger()
    {
        string logsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iToolKit", "Logs");
        try
        {
            Directory.CreateDirectory(logsDir);
        }
        catch
        {
            // Ignore directory creation failure in restricted environments
        }
        string dateStamp = DateTime.Now.ToString("yyyyMMdd");
        _logFilePath = Path.Combine(logsDir, $"iToolKit_{dateStamp}.log");
    }

    public void Log(LogLevel level, string component, string message)
    {
        var entry = new ActivityLogEntry(DateTime.Now, level, component, message);

        lock (_lock)
        {
            try
            {
                string line = $"[{entry.Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{entry.Level.ToString().ToUpperInvariant(),-7}] [{entry.Component}] {entry.Message}{Environment.NewLine}";
                using var stream = new FileStream(_logFilePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
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
