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
    IReadOnlyList<string> IpAddresses);
