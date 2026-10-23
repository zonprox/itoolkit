namespace IToolkit.Core.Abstractions;

using IToolkit.Core.Models;

/// <summary>
/// Structured sink for system activity logs, feeding both diagnostic stores and live UI consoles.
/// </summary>
public interface IActivityLogger
{
    /// <summary>
    /// Emits a structured activity log entry.
    /// </summary>
    void Log(LogLevel level, string component, string message);

    void LogDebug(string component, string message) => Log(LogLevel.Debug, component, message);
    void LogInfo(string component, string message) => Log(LogLevel.Info, component, message);
    void LogSuccess(string component, string message) => Log(LogLevel.Success, component, message);
    void LogWarning(string component, string message) => Log(LogLevel.Warning, component, message);
    void LogError(string component, string message) => Log(LogLevel.Error, component, message);

    /// <summary>
    /// Event fired whenever a new entry is logged.
    /// </summary>
    event Action<ActivityLogEntry>? EntryLogged;
}
