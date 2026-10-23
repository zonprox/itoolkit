namespace IToolkit.Core.Models;

/// <summary>
/// Point-in-time snapshot of system telemetry metrics and operational state.
/// </summary>
public record TelemetrySnapshot(
    string OsDescription,
    string OsBuild,
    bool IsElevated,
    double CpuUsagePercentage,
    long MemoryUsedBytes,
    long MemoryTotalBytes,
    long SystemDriveFreeBytes,
    long SystemDriveTotalBytes,
    bool NetworkConnected,
    string ActiveTaskDescription);
