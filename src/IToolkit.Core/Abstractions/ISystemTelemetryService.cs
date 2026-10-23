namespace IToolkit.Core.Abstractions;

using IToolkit.Core.Models;

/// <summary>
/// Abstraction for querying real-time system hardware, OS metrics, and operational status.
/// </summary>
public interface ISystemTelemetryService
{
    /// <summary>
    /// Synchronously retrieves a current snapshot of system metrics.
    /// </summary>
    TelemetrySnapshot GetSnapshot();

    /// <summary>
    /// Asynchronously retrieves a current snapshot of system metrics.
    /// </summary>
    Task<TelemetrySnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default);
}
