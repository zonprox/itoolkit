namespace IToolkit.App.Native;

using System;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class WindowsTelemetryService : ISystemTelemetryService
{
    private readonly IElevationService _elevationService;
    private readonly IFileSystemService _fileSystemService;
    private readonly INetworkService _networkService;
    private readonly IWmiService? _wmiService;
    private readonly IRegistryService? _registryService;
    private volatile string _activeTask = "Idle";

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
        INetworkService networkService,
        IWmiService? wmiService = null,
        IRegistryService? registryService = null)
    {
        _elevationService = elevationService ?? throw new ArgumentNullException(nameof(elevationService));
        _fileSystemService = fileSystemService ?? throw new ArgumentNullException(nameof(fileSystemService));
        _networkService = networkService ?? throw new ArgumentNullException(nameof(networkService));
        _wmiService = wmiService;
        _registryService = registryService;
    }

    public void SetActiveTask(string taskDescription)
    {
        _activeTask = string.IsNullOrWhiteSpace(taskDescription) ? "Idle" : taskDescription;
    }

    public TelemetrySnapshot GetSnapshot()
    {
        string osDescription = RuntimeInformation.OSDescription;
        string osBuild = Environment.OSVersion.Version.ToString();

        if (OperatingSystem.IsWindows() && _registryService != null)
        {
            string? displayVersion = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion");
            string? currentBuild = _registryService.GetValue<string>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild");
            object? ubr = _registryService.GetValue<object>(
                @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR");

            if (!string.IsNullOrEmpty(currentBuild))
            {
                osBuild = $"{displayVersion ?? "Windows"} (Build {currentBuild}.{ubr ?? 0})".Trim();
            }
        }

        bool isElevated = _elevationService.IsElevated();

        long driveFreeBytes = 0;
        long driveTotalBytes = 0;
        try
        {
            driveFreeBytes = _fileSystemService.GetAvailableFreeSpace(@"C:\");
            if (OperatingSystem.IsWindows())
            {
                var driveInfo = new DriveInfo("C");
                if (driveInfo.IsReady)
                {
                    driveTotalBytes = driveInfo.TotalSize;
                    driveFreeBytes = driveInfo.AvailableFreeSpace;
                }
            }
        }
        catch
        {
            // Retain safe defaults
        }

        long totalMemory = 16L * 1024 * 1024 * 1024;
        long usedMemory = 4L * 1024 * 1024 * 1024;
        if (OperatingSystem.IsWindows())
        {
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
        }
        else
        {
            var gcInfo = GC.GetGCMemoryInfo();
            if (gcInfo.TotalAvailableMemoryBytes > 0)
            {
                totalMemory = gcInfo.TotalAvailableMemoryBytes;
                usedMemory = gcInfo.MemoryLoadBytes > 0 ? gcInfo.MemoryLoadBytes : gcInfo.TotalCommittedBytes;
            }
        }

        double cpuPercentage = 0.0;
        if (OperatingSystem.IsWindows() && _wmiService != null)
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

        bool networkConnected = false;
        try
        {
            networkConnected = NetworkInterface.GetIsNetworkAvailable();
        }
        catch
        {
            networkConnected = false;
        }

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
            ActiveTaskDescription: _activeTask);
    }

    public Task<TelemetrySnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default)
    {
        return Task.Run(GetSnapshot, cancellationToken);
    }
}
