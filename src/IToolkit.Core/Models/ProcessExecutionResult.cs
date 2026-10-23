namespace IToolkit.Core.Models;

/// <summary>
/// Encapsulates the execution outcome of an external process.
/// </summary>
public record ProcessExecutionResult(
    int ExitCode,
    string StandardOutput,
    string StandardError,
    bool TimedOut);
