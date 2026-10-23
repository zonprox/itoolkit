namespace IToolkit.Core.Models;

/// <summary>
/// Represents the result of a system operation, including status, message, and optional backup path.
/// </summary>
public record OperationResult(
    bool Success,
    string Message,
    string? BackupPath = null,
    Exception? Exception = null)
{
    public static OperationResult Succeeded(string message, string? backupPath = null)
        => new(true, message, backupPath);

    public static OperationResult Failed(string message, string? backupPath = null, Exception? exception = null)
        => new(false, message, backupPath, exception);
}
