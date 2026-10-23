namespace IToolkit.Tests.TestDoubles;

using System.IO.Compression;
using System.Text;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// In-memory test double for INetworkService.
/// </summary>
public class MockNetworkService : INetworkService
{
    private readonly HashSet<string> _reachableHosts = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _openPorts = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<NetworkAdapterInfo> _adapters = new();
    private readonly Dictionary<string, byte[]> _simulatedDownloads = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _simulatedStringDownloads = new(StringComparer.OrdinalIgnoreCase);
    private IFileSystemService? _fileSystem;

    public MockNetworkService(IFileSystemService? fileSystem = null)
    {
        _fileSystem = fileSystem;
    }

    public List<string> TestedHosts { get; } = new();
    public List<string> TestedPorts { get; } = new();
    public List<string> RestartedAdapters { get; } = new();
    public bool DnsFlushed { get; private set; }
    public bool WinsockReset { get; private set; }
    public bool TcpIpReset { get; private set; }
    public bool DhcpRenewed { get; private set; }

    public bool IsInternetAvailable
    {
        get => _reachableHosts.Contains("1.1.1.1") || _reachableHosts.Contains("github.com");
        set
        {
            if (value)
            {
                _reachableHosts.Add("1.1.1.1");
                _reachableHosts.Add("github.com");
            }
            else
            {
                _reachableHosts.Remove("1.1.1.1");
                _reachableHosts.Remove("github.com");
            }
        }
    }

    public void SetFileSystem(IFileSystemService fileSystem) => _fileSystem = fileSystem;

    public void SetSimulatedDownload(string url, byte[] data) => _simulatedDownloads[url] = data;

    public void SetSimulatedDownload(string url, string text) => _simulatedStringDownloads[url] = text;

    public void SetHostReachable(string host, bool reachable = true)
    {
        if (reachable) _reachableHosts.Add(host);
        else _reachableHosts.Remove(host);
    }

    public void SetHostResolvable(string host, bool resolvable = true) => SetHostReachable(host, resolvable);

    public void SetPortOpen(string host, int port, bool open = true)
    {
        string key = $"{host}:{port}";
        if (open) _openPorts.Add(key);
        else _openPorts.Remove(key);
    }

    public void AddAdapter(string id, string name, string description, string macAddress, string status, IReadOnlyList<string>? ipAddresses = null)
    {
        _adapters.Add(new NetworkAdapterInfo(id, name, description, macAddress, status, ipAddresses ?? Array.Empty<string>()));
    }

    public bool PingHost(string host, int timeoutMs = 2000)
    {
        TestedHosts.Add(host);
        return _reachableHosts.Contains(host);
    }

    public bool TestPort(string host, int port, int timeoutMs = 2000)
    {
        TestedPorts.Add($"{host}:{port}");
        return _openPorts.Contains($"{host}:{port}");
    }

    public IEnumerable<NetworkAdapterInfo> GetAdapters()
    {
        return _adapters.ToList();
    }

    public bool RestartAdapter(string adapterName)
    {
        RestartedAdapters.Add(adapterName);
        return true;
    }

    public bool FlushDns()
    {
        DnsFlushed = true;
        return true;
    }

    public bool ResetWinsock()
    {
        WinsockReset = true;
        return true;
    }

    public bool ResetTcpIp()
    {
        TcpIpReset = true;
        return true;
    }

    public bool ReleaseRenewDhcp()
    {
        DhcpRenewed = true;
        return true;
    }

    public bool DownloadFile(string url, string destinationPath)
    {
        TestedHosts.Add(url);
        byte[] payload;
        if (_simulatedDownloads.TryGetValue(url, out var data))
        {
            payload = data;
        }
        else if (url.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || url.Contains("unikey", StringComparison.OrdinalIgnoreCase))
        {
            using var mem = new MemoryStream();
            using (var zip = new ZipArchive(mem, ZipArchiveMode.Create, true))
            {
                var entry = zip.CreateEntry("UniKeyNT.exe");
                using var entryStream = entry.Open();
                byte[] stubExe = Encoding.ASCII.GetBytes("MZ_SIMULATED_UNIKEY_EXE");
                entryStream.Write(stubExe, 0, stubExe.Length);
            }
            payload = mem.ToArray();
        }
        else
        {
            payload = Encoding.ASCII.GetBytes("MZ_SIMULATED_SETUP_EXECUTABLE");
        }

        if (_fileSystem != null)
        {
            _fileSystem.WriteAllBytes(destinationPath, payload);
        }
        else
        {
            try
            {
                string? dir = Path.GetDirectoryName(destinationPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.WriteAllBytes(destinationPath, payload);
            }
            catch
            {
                // In simulated environments without local disk paths
            }
        }
        return true;
    }

    public Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default) =>
        Task.FromResult(DownloadFile(url, destinationPath));

    public string DownloadString(string url)
    {
        TestedHosts.Add(url);
        if (_simulatedStringDownloads.TryGetValue(url, out var content))
        {
            return content;
        }
        return $"# Genuine debloat script for {url}\r\nWrite-Output \"Optimization completed successfully.\"\r\n";
    }

    public Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default) =>
        Task.FromResult(DownloadString(url));
}
