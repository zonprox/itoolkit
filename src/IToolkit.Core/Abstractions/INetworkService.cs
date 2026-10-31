namespace IToolkit.Core.Abstractions;

using IToolkit.Core.Models;

/// <summary>
/// Abstraction for network diagnostics, adapter management, and network stack remediation.
/// </summary>
public interface INetworkService
{
    /// <summary>
    /// Sends an ICMP echo request to the specified target host.
    /// </summary>
    bool PingHost(string host, int timeoutMs = 2000);

    /// <summary>
    /// Tests TCP connectivity to a specific port on the target host.
    /// </summary>
    bool TestPort(string host, int port, int timeoutMs = 2000);

    /// <summary>
    /// Enumerates network adapters on the local system.
    /// </summary>
    IEnumerable<NetworkAdapterInfo> GetAdapters();

    /// <summary>
    /// Disables and re-enables a specified network adapter.
    /// </summary>
    bool RestartAdapter(string adapterName);

    /// <summary>
    /// Enables a specified network adapter.
    /// </summary>
    bool EnableAdapter(string adapterName) => false;

    /// <summary>
    /// Disables a specified network adapter.
    /// </summary>
    bool DisableAdapter(string adapterName) => false;

    /// <summary>
    /// Releases and renews DHCP lease specifically for a designated network adapter.
    /// </summary>
    bool ReleaseRenewAdapterDhcp(string adapterName) => false;

    /// <summary>
    /// Configures IPv4 addressing (DHCP or static IP) for a specific network adapter.
    /// </summary>
    bool SetAdapterIpConfiguration(string adapterName, AdapterIpConfig config) => false;

    /// <summary>
    /// Configures DNS server addresses (DHCP or static DNS) for a specific network adapter.
    /// </summary>
    bool SetAdapterDnsConfiguration(string adapterName, AdapterDnsConfig config) => false;

    /// <summary>
    /// Sets maximum transmission unit (MTU) for a specific network adapter.
    /// </summary>
    bool SetAdapterMtu(string adapterName, int mtu) => false;

    /// <summary>
    /// Flushes the local DNS client resolver cache.
    /// </summary>
    bool FlushDns();

    /// <summary>
    /// Resets the Winsock catalog to a clean state.
    /// </summary>
    bool ResetWinsock();

    /// <summary>
    /// Resets TCP/IP stack configuration.
    /// </summary>
    bool ResetTcpIp();

    /// <summary>
    /// Releases and renews IPv4/IPv6 leases across active DHCP interfaces.
    /// </summary>
    bool ReleaseRenewDhcp();

    /// <summary>
    /// Downloads a remote file from the specified URL to the local destination path.
    /// </summary>
    bool DownloadFile(string url, string destinationPath);

    /// <summary>
    /// Asynchronously downloads a remote file from the specified URL to the local destination path.
    /// </summary>
    Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default);

    /// <summary>
    /// Downloads the contents of a remote URL as a string.
    /// </summary>
    string DownloadString(string url);

    /// <summary>
    /// Asynchronously downloads the contents of a remote URL as a string.
    /// </summary>
    Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default);
}
