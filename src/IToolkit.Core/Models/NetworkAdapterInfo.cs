namespace IToolkit.Core.Models;

/// <summary>
/// Contains operational status and configuration for a network interface adapter.
/// </summary>
public record NetworkAdapterInfo(
    string Id,
    string Name,
    string Description,
    string MacAddress,
    string Status,
    IReadOnlyList<string> IpAddresses,
    bool DhcpEnabled = true,
    string? SubnetMask = null,
    string? DefaultGateway = null,
    IReadOnlyList<string>? DnsServers = null,
    int? Mtu = null,
    long SpeedBitsPerSecond = 0,
    bool IsPhysical = true);

/// <summary>
/// IP configuration settings for a specific network adapter.
/// </summary>
public record AdapterIpConfig(
    bool UseDhcp,
    string? IpAddress = null,
    string? SubnetMask = null,
    string? DefaultGateway = null);

/// <summary>
/// DNS configuration settings for a specific network adapter.
/// </summary>
public record AdapterDnsConfig(
    bool UseDhcp,
    string? PreferredDns = null,
    string? AlternateDns = null);

