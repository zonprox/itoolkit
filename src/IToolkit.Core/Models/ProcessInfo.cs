namespace IToolkit.Core.Models;

/// <summary>
/// Represents metadata for an active process instance.
/// </summary>
public record ProcessInfo(
    int Id,
    string ProcessName,
    string? MainWindowTitle);
