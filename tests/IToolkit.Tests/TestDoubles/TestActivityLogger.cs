namespace IToolkit.Tests.TestDoubles;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Thread-safe in-memory activity logger test double capturing all logged entries for verification.
/// </summary>
public class TestActivityLogger : IActivityLogger
{
    private readonly ConcurrentQueue<ActivityLogEntry> _entries = new();

    public event Action<ActivityLogEntry>? EntryLogged;

    public IReadOnlyList<ActivityLogEntry> CapturedEntries => _entries.ToArray();

    public void Log(LogLevel level, string component, string message)
    {
        var entry = new ActivityLogEntry(DateTime.UtcNow, level, component, message);
        _entries.Enqueue(entry);
        EntryLogged?.Invoke(entry);
    }

    public void LogInfo(string component, string message) => Log(LogLevel.Info, component, message);
    public void LogWarning(string component, string message) => Log(LogLevel.Warning, component, message);
    public void LogError(string component, string message) => Log(LogLevel.Error, component, message);
    public void LogSuccess(string component, string message) => Log(LogLevel.Success, component, message);
    public void LogDebug(string component, string message) => Log(LogLevel.Debug, component, message);
}
