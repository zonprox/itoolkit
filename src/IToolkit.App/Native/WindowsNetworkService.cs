namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class WindowsNetworkService : INetworkService
{
    private static readonly HttpClient HttpClient = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly IProcessRunner _processRunner;

    public WindowsNetworkService(IProcessRunner processRunner)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
    }

    public bool PingHost(string host, int timeoutMs = 2000)
    {
        try
        {
            using var ping = new Ping();
            var reply = ping.Send(host, timeoutMs);
            return reply.Status == IPStatus.Success;
        }
        catch { return false; }
    }

    public bool TestPort(string host, int port, int timeoutMs = 2000)
    {
        try
        {
            using var client = new TcpClient();
            using var cts = new CancellationTokenSource(timeoutMs);
            client.ConnectAsync(host, port, cts.Token).AsTask().GetAwaiter().GetResult();
            return client.Connected;
        }
        catch { return false; }
    }

    public IEnumerable<NetworkAdapterInfo> GetAdapters()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Select(nic =>
            {
                var ipProps = nic.GetIPProperties();
                var ips = ipProps.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork || a.Address.AddressFamily == AddressFamily.InterNetworkV6)
                    .Select(a => a.Address.ToString())
                    .ToList();

                return new NetworkAdapterInfo(
                    nic.Id,
                    nic.Name,
                    nic.Description,
                    nic.GetPhysicalAddress().ToString(),
                    nic.OperationalStatus.ToString(),
                    ips);
            })
            .ToList();
    }

    public bool RestartAdapter(string adapterName)
    {
        var res1 = _processRunner.Run("netsh", $"interface set interface \"{adapterName}\" disable");
        var res2 = _processRunner.Run("netsh", $"interface set interface \"{adapterName}\" enable");
        return res1.ExitCode == 0 && res2.ExitCode == 0;
    }

    public bool FlushDns() => _processRunner.Run("ipconfig", "/flushdns").ExitCode == 0;
    public bool ResetWinsock() => _processRunner.Run("netsh", "winsock reset").ExitCode == 0;
    public bool ResetTcpIp() => _processRunner.Run("netsh", "int ip reset").ExitCode == 0;
    public bool ReleaseRenewDhcp()
    {
        _processRunner.Run("ipconfig", "/release");
        return _processRunner.Run("ipconfig", "/renew").ExitCode == 0;
    }

    public bool DownloadFile(string url, string destinationPath)
    {
        try
        {
            return DownloadFileAsync(url, destinationPath).GetAwaiter().GetResult();
        }
        catch { return false; }
    }

    public async Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default)
    {
        try
        {
            var dir = Path.GetDirectoryName(destinationPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }

            using var response = await HttpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using var fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await stream.CopyToAsync(fileStream, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch { return false; }
    }

    public string DownloadString(string url)
    {
        try
        {
            return DownloadStringAsync(url).GetAwaiter().GetResult();
        }
        catch { return string.Empty; }
    }

    public async Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default)
    {
        try
        {
            return await HttpClient.GetStringAsync(url, cancellationToken).ConfigureAwait(false);
        }
        catch { return string.Empty; }
    }
}
