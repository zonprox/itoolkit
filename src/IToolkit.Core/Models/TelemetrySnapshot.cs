namespace IToolkit.Core.Models;

/// <summary>
/// Point-in-time snapshot of system telemetry metrics, hardware specifications, identity, and network configuration.
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
    string ActiveTaskDescription,
    string? ComputerName = null,
    string? DomainOrWorkgroup = null,
    string? CurrentUser = null,
    string? UserProfilePath = null,
    string? SystemUptime = null,
    string? OsArchitecture = null,
    string? CpuModelName = null,
    string? SystemManufacturerModel = null,
    string? GpuModelName = null,
    string? BiosAndSerial = null,
    string? AllDrivesSummary = null,
    string? PrimaryNetworkAdapter = null,
    string? Ipv4Address = null,
    string? DefaultGateway = null,
    string? DnsServers = null,
    string? MacAddress = null);
