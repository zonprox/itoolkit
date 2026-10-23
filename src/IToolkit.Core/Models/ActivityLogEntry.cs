namespace IToolkit.Core.Models;

/// <summary>
/// Represents a structured log entry emitted by toolkit services and components.
/// </summary>
public record ActivityLogEntry(
    DateTime Timestamp,
    LogLevel Level,
    string Component,
    string Message);
