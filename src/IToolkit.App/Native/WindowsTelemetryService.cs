namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class WindowsTelemetryService : ISystemTelemetryService
{
    private readonly IElevationService _elevationService;
    private readonly IFileSystemService _fileSystemService;
    private readonly IWmiService? _wmiService;
    private readonly IRegistryService? _registryService;
    private volatile string _activeTask = "Idle";

    private readonly object _staticSpecLock = new();
    private bool _staticSpecsInitialized;
    private string _cachedDomainOrWorkgroup = string.Empty;
    private string _cachedCpuModelName = string.Empty;
    private string _cachedSystemManufacturerModel = string.Empty;
    private string _cachedGpuModelName = string.Empty;
    private string _cachedBiosAndSerial = string.Empty;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private class MEMORYSTATUSEX
    {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

    public WindowsTelemetryService(
        IElevationService elevationService,
        IFileSystemService fileSystemService,
        IWmiService? wmiService = null,
        IRegistryService? registryService = null)
    {
        _elevationService = elevationService ?? throw new ArgumentNullException(nameof(elevationService));
        _fileSystemService = fileSystemService ?? throw new ArgumentNullException(nameof(fileSystemService));
        _wmiService = wmiService;
        _registryService = registryService;
    }

    public void SetActiveTask(string taskDescription)
    {
        _activeTask = string.IsNullOrWhiteSpace(taskDescription) ? "Idle" : taskDescription;
    }

    public TelemetrySnapshot GetSnapshot()
    {
        EnsureStaticSpecsLoaded();

        string osDescription = RuntimeInformation.OSDescription;
        string osBuild = Environment.OSVersion.Version.ToString();

        if (_registryService != null)
        {
            string? productName = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "ProductName");
            string? editionId = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "EditionID");
            string? displayVersion = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion");
            string? currentBuild = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild");
            object? ubr = _registryService.GetValue<object>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR");

            if (!string.IsNullOrEmpty(currentBuild))
            {
                osBuild = $"{displayVersion ?? "Windows"} (Build {currentBuild}.{ubr ?? 0})".Trim();
                if (!string.IsNullOrWhiteSpace(productName))
                {
                    if (int.TryParse(currentBuild, out int buildNum) && buildNum >= 22000 && productName.Contains("Windows 10", StringComparison.OrdinalIgnoreCase))
                    {
                        productName = productName.Replace("Windows 10", "Windows 11", StringComparison.OrdinalIgnoreCase);
                    }
                    osDescription = !string.IsNullOrWhiteSpace(editionId) && !productName.Contains(editionId, StringComparison.OrdinalIgnoreCase)
                        ? $"{productName} ({editionId})"
                        : productName;
                }
            }
        }

        bool isElevated = _elevationService.IsElevated();

        long driveFreeBytes = 0;
        long driveTotalBytes = 0;
        var driveSummaries = new List<string>();
        try
        {
            driveFreeBytes = _fileSystemService.GetAvailableFreeSpace(@"C:\");
            foreach (var d in DriveInfo.GetDrives())
            {
                if (!d.IsReady || d.DriveType != DriveType.Fixed) continue;

                if (d.Name.StartsWith("C", StringComparison.OrdinalIgnoreCase))
                {
                    driveTotalBytes = d.TotalSize;
                    driveFreeBytes = d.AvailableFreeSpace;
                }

                double freeGb = d.AvailableFreeSpace / (1024.0 * 1024 * 1024);
                double totalGb = d.TotalSize / (1024.0 * 1024 * 1024);
                string label = string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.DriveFormat : $"{d.VolumeLabel}, {d.DriveFormat}";
                driveSummaries.Add($"{d.Name.TrimEnd('\\')} {freeGb:F1}/{totalGb:F0} GB free ({label})");
            }
        }
        catch
        {
            // Retain safe defaults
        }

        string allDrivesSummary = driveSummaries.Count > 0
            ? string.Join(" | ", driveSummaries)
            : "C: Storage Ready";

        long totalMemory = 16L * 1024 * 1024 * 1024;
        long usedMemory = 4L * 1024 * 1024 * 1024;
        try
        {
            var memStatus = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(memStatus))
            {
                totalMemory = (long)memStatus.ullTotalPhys;
                usedMemory = (long)(memStatus.ullTotalPhys - memStatus.ullAvailPhys);
            }
        }
        catch
        {
            var gcInfo = GC.GetGCMemoryInfo();
            if (gcInfo.TotalAvailableMemoryBytes > 0)
            {
                totalMemory = gcInfo.TotalAvailableMemoryBytes;
                usedMemory = gcInfo.MemoryLoadBytes > 0 ? gcInfo.MemoryLoadBytes : gcInfo.TotalCommittedBytes;
            }
        }

        double cpuPercentage = 0.0;
        if (_wmiService != null)
        {
            try
            {
                var cpuData = _wmiService.QueryFirst("SELECT LoadPercentage FROM Win32_Processor");
                if (cpuData != null && cpuData.TryGetValue("LoadPercentage", out var load) && load != null)
                {
                    cpuPercentage = Convert.ToDouble(load);
                }
            }
            catch
            {
                cpuPercentage = 0.0;
            }
        }

        var (networkConnected, adapterText, ipv4Text, gatewayText, dnsText, macText) = CollectNetworkDetails();

        string computerName = Environment.MachineName;
        string currentUser = $"{Environment.UserDomainName}\\{Environment.UserName}";
        string userProfilePath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string osArch = $"{RuntimeInformation.OSArchitecture} ({(Environment.Is64BitOperatingSystem ? "64-bit OS" : "32-bit OS")})";

        TimeSpan up = TimeSpan.FromMilliseconds(Environment.TickCount64);
        string uptimeText = up.Days > 0
            ? $"{up.Days}d {up.Hours:D2}h {up.Minutes:D2}m"
            : $"{up.Hours:D2}h {up.Minutes:D2}m {up.Seconds:D2}s";

        return new TelemetrySnapshot(
            OsDescription: osDescription,
            OsBuild: osBuild,
            IsElevated: isElevated,
            CpuUsagePercentage: cpuPercentage,
            MemoryUsedBytes: usedMemory,
            MemoryTotalBytes: totalMemory,
            SystemDriveFreeBytes: driveFreeBytes,
            SystemDriveTotalBytes: driveTotalBytes,
            NetworkConnected: networkConnected,
            ActiveTaskDescription: _activeTask,
            ComputerName: computerName,
            DomainOrWorkgroup: _cachedDomainOrWorkgroup,
            CurrentUser: currentUser,
            UserProfilePath: userProfilePath,
            SystemUptime: uptimeText,
            OsArchitecture: osArch,
            CpuModelName: _cachedCpuModelName,
            SystemManufacturerModel: _cachedSystemManufacturerModel,
            GpuModelName: _cachedGpuModelName,
            BiosAndSerial: _cachedBiosAndSerial,
            AllDrivesSummary: allDrivesSummary,
            PrimaryNetworkAdapter: adapterText,
            Ipv4Address: ipv4Text,
            DefaultGateway: gatewayText,
            DnsServers: dnsText,
            MacAddress: macText);
    }

    private void EnsureStaticSpecsLoaded()
    {
        if (_staticSpecsInitialized) return;
        lock (_staticSpecLock)
        {
            if (_staticSpecsInitialized) return;

            string cpuName = _registryService?.GetValue<string>(
                @"HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString")?.Trim() ?? string.Empty;
            int cores = Environment.ProcessorCount;
            int logical = Environment.ProcessorCount;

            string sysMfg = _registryService?.GetValue<string>(
                @"HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemManufacturer")?.Trim() ?? string.Empty;
            string sysProd = _registryService?.GetValue<string>(
                @"HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName")?.Trim() ?? string.Empty;
            string biosVer = _registryService?.GetValue<string>(
                @"HKLM\HARDWARE\DESCRIPTION\System\BIOS", "BIOSVersion")?.Trim() ?? string.Empty;
            string serialNum = string.Empty;
            string domainText = string.Empty;
            string gpuName = string.Empty;

            if (_wmiService != null)
            {
                try
                {
                    var cpuRow = _wmiService.QueryFirst("SELECT Name, NumberOfCores, NumberOfLogicalProcessors FROM Win32_Processor");
                    if (cpuRow != null)
                    {
                        if (cpuRow.TryGetValue("Name", out var wmiCpuName) && wmiCpuName is string sCpu && !string.IsNullOrWhiteSpace(sCpu))
                        {
                            cpuName = sCpu.Trim();
                        }
                        if (cpuRow.TryGetValue("NumberOfCores", out var nCores) && nCores != null)
                        {
                            cores = Convert.ToInt32(nCores);
                        }
                        if (cpuRow.TryGetValue("NumberOfLogicalProcessors", out var nLog) && nLog != null)
                        {
                            logical = Convert.ToInt32(nLog);
                        }
                    }
                }
                catch { }

                try
                {
                    var csRow = _wmiService.QueryFirst("SELECT Manufacturer, Model, Domain, PartOfDomain, Workgroup FROM Win32_ComputerSystem");
                    if (csRow != null)
                    {
                        if (csRow.TryGetValue("Manufacturer", out var mfg) && mfg is string sMfg && !string.IsNullOrWhiteSpace(sMfg))
                        {
                            sysMfg = sMfg.Trim();
                        }
                        if (csRow.TryGetValue("Model", out var mdl) && mdl is string sMdl && !string.IsNullOrWhiteSpace(sMdl))
                        {
                            sysProd = sMdl.Trim();
                        }
                        bool partOfDomain = csRow.TryGetValue("PartOfDomain", out var pod) && pod is bool bPod && bPod;
                        string dom = csRow.TryGetValue("Domain", out var dVal) && dVal is string sDom ? sDom.Trim() : string.Empty;
                        if (!string.IsNullOrWhiteSpace(dom))
                        {
                            domainText = partOfDomain ? $"{dom} (Domain Joined)" : $"{dom} (Workgroup)";
                        }
                    }
                }
                catch { }

                try
                {
                    var biosRow = _wmiService.QueryFirst("SELECT SMBIOSBIOSVersion, SerialNumber FROM Win32_BIOS");
                    if (biosRow != null)
                    {
                        if (biosRow.TryGetValue("SMBIOSBIOSVersion", out var bVer) && bVer is string sbVer && !string.IsNullOrWhiteSpace(sbVer))
                        {
                            biosVer = sbVer.Trim();
                        }
                        if (biosRow.TryGetValue("SerialNumber", out var sNum) && sNum is string ssNum && !string.IsNullOrWhiteSpace(ssNum))
                        {
                            serialNum = ssNum.Trim();
                        }
                    }
                }
                catch { }

                try
                {
                    var gpuRow = _wmiService.QueryFirst("SELECT Name FROM Win32_VideoController");
                    if (gpuRow != null && gpuRow.TryGetValue("Name", out var gName) && gName is string sgName && !string.IsNullOrWhiteSpace(sgName))
                    {
                        gpuName = sgName.Trim();
                    }
                }
                catch { }
            }

            if (string.IsNullOrWhiteSpace(domainText))
            {
                try
                {
                    string ipDomain = IPGlobalProperties.GetIPGlobalProperties().DomainName;
                    domainText = !string.IsNullOrWhiteSpace(ipDomain)
                        ? $"{ipDomain} (Domain)"
                        : $"{Environment.UserDomainName} (Workgroup / Local)";
                }
                catch
                {
                    domainText = Environment.UserDomainName;
                }
            }

            _cachedDomainOrWorkgroup = domainText;
            _cachedCpuModelName = !string.IsNullOrWhiteSpace(cpuName)
                ? $"{cpuName} ({cores}C / {logical}T)"
                : $"{logical}-Core Processor ({RuntimeInformation.ProcessArchitecture})";

            string combinedModel = $"{sysMfg} {sysProd}".Trim();
            _cachedSystemManufacturerModel = !string.IsNullOrWhiteSpace(combinedModel) ? combinedModel : "Standard PC / Workstation";
            _cachedGpuModelName = !string.IsNullOrWhiteSpace(gpuName) ? gpuName : "Standard Display Adapter";

            if (!string.IsNullOrWhiteSpace(biosVer) && !string.IsNullOrWhiteSpace(serialNum))
            {
                _cachedBiosAndSerial = $"BIOS {biosVer} | S/N: {serialNum}";
            }
            else if (!string.IsNullOrWhiteSpace(biosVer))
            {
                _cachedBiosAndSerial = $"BIOS {biosVer}";
            }
            else if (!string.IsNullOrWhiteSpace(serialNum))
            {
                _cachedBiosAndSerial = $"S/N: {serialNum}";
            }
            else
            {
                _cachedBiosAndSerial = "UEFI / Standard BIOS";
            }

            _staticSpecsInitialized = true;
        }
    }

    private static (bool Connected, string AdapterText, string Ipv4Text, string GatewayText, string DnsText, string MacText) CollectNetworkDetails()
    {
        try
        {
            bool connected = NetworkInterface.GetIsNetworkAvailable();
            var activeNic = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up &&
                            n.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                            n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Count > 0)
                .ThenByDescending(n => n.Speed)
                .FirstOrDefault();

            if (activeNic == null)
            {
                return (connected, "No Active Adapter", "N/A", "N/A", "N/A", "N/A");
            }

            var ipProps = activeNic.GetIPProperties();
            var ipv4Uni = ipProps.UnicastAddresses
                .FirstOrDefault(u => u.Address.AddressFamily == AddressFamily.InterNetwork);

            string ipv4Text = ipv4Uni != null
                ? $"{ipv4Uni.Address} /{ ipv4Uni.PrefixLength}"
                : "No IPv4 Assigned";

            var gw = ipProps.GatewayAddresses
                .Select(g => g.Address)
                .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(System.Net.IPAddress.Any));
            string gatewayText = gw?.ToString() ?? "None";

            var dnsList = ipProps.DnsAddresses
                .Where(d => d.AddressFamily == AddressFamily.InterNetwork)
                .Select(d => d.ToString())
                .Take(3)
                .ToList();
            string dnsText = dnsList.Count > 0 ? string.Join(", ", dnsList) : "Automatic / None";

            byte[] macBytes = activeNic.GetPhysicalAddress().GetAddressBytes();
            string macText = macBytes.Length > 0
                ? string.Join(":", macBytes.Select(b => b.ToString("X2")))
                : "N/A";

            double speedMbps = activeNic.Speed > 0 ? activeNic.Speed / 1_000_000.0 : 0;
            string speedLabel = speedMbps >= 1000
                ? $"{speedMbps / 1000.0:F1} Gbps"
                : speedMbps > 0
                    ? $"{speedMbps:F0} Mbps"
                    : activeNic.NetworkInterfaceType.ToString();

            string adapterText = $"{activeNic.Name} - {activeNic.Description} ({speedLabel})";
            return (true, adapterText, ipv4Text, gatewayText, dnsText, macText);
        }
        catch
        {
            return (false, "Unknown Adapter", "N/A", "N/A", "N/A", "N/A");
        }
    }

    public Task<TelemetrySnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default)
    {
        return Task.Run(GetSnapshot, cancellationToken);
    }
}
