namespace IToolkit.App.Native;

using System;
using System.IO;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class ActivityLogger : IActivityLogger
{
    private readonly object _lock = new();
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
            // Directory creation failure fallback
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
                File.AppendAllText(_logFilePath, line);
            }
            catch
            {
                // Never crash on logging failure
            }
        }

        DispatchEntryLogged(entry);
    }

    private void DispatchEntryLogged(ActivityLogEntry entry)
    {
        try
        {
            var appType = Type.GetType("System.Windows.Application, PresentationFramework");
            var currentApp = appType?.GetProperty("Current")?.GetValue(null);
            if (currentApp != null)
            {
                var dispatcherProp = appType?.GetProperty("Dispatcher")?.GetValue(currentApp);
                if (dispatcherProp != null)
                {
                    var checkAccessMethod = dispatcherProp.GetType().GetMethod("CheckAccess");
                    bool hasAccess = (bool)(checkAccessMethod?.Invoke(dispatcherProp, null) ?? true);
                    if (!hasAccess)
                    {
                        var beginInvokeMethod = dispatcherProp.GetType().GetMethod("BeginInvoke", new[] { typeof(Delegate) });
                        beginInvokeMethod?.Invoke(dispatcherProp, new object[] { new Action(() => EntryLogged?.Invoke(entry)) });
                        return;
                    }
                }
            }
        }
        catch
        {
            // Fallback to direct invocation if Dispatcher reflection fails
        }

        EntryLogged?.Invoke(entry);
    }
}
