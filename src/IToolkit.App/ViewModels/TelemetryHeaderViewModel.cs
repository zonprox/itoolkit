namespace IToolkit.App.ViewModels;

using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Input;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

public class TelemetryHeaderViewModel : ViewModelBase, IDisposable
{
    private readonly ISystemTelemetryService _telemetryService;
    private readonly SynchronizationContext? _uiContext;
    private Timer? _pollingTimer;

    private string _osDescription = "Windows 11 / 10 64-bit";
    private string _osBuild = "Detecting...";
    private bool _isElevated = true;
    private string _elevationBadgeText = "Administrator";
    private string _elevationBadgeBrush = "#22C55E";

    private double _cpuUsagePercentage;
    private string _cpuUsageText = "0%";
    private string _cpuBrush = "#22C55E";

    private string _memoryUsageText = "0.0 / 0.0 GB";
    private double _memoryPercentage;
    private string _memoryPercentageText = "0%";
    private string _memoryBrush = "#22C55E";

    private string _diskFreeSpaceText = "0 GB Free";
    private double _diskFreePercentage;
    private string _diskHealthBrush = "#22C55E";
    private string _diskHealthStatus = "Healthy";

    private bool _isNetworkConnected;
    private string _networkStatusText = "Checking...";
    private string _networkStatusBrush = "#64748B";

    private string _activeTaskDescription = "System Idle";
    private bool _isTaskActive;
    private string _lastUpdatedText = "Just now";

    public TelemetryHeaderViewModel(ISystemTelemetryService telemetryService)
    {
        _telemetryService = telemetryService ?? throw new ArgumentNullException(nameof(telemetryService));
        _uiContext = SynchronizationContext.Current;

        RefreshCommand = new AsyncRelayCommand(RefreshTelemetryAsync);

        StartPolling();
    }

    public string OsDescription { get => _osDescription; set => SetProperty(ref _osDescription, value); }
    public string OsBuild { get => _osBuild; set => SetProperty(ref _osBuild, value); }
    public bool IsElevated { get => _isElevated; set => SetProperty(ref _isElevated, value); }
    public string ElevationBadgeText { get => _elevationBadgeText; set => SetProperty(ref _elevationBadgeText, value); }
    public string ElevationBadgeBrush { get => _elevationBadgeBrush; set => SetProperty(ref _elevationBadgeBrush, value); }

    public double CpuUsagePercentage { get => _cpuUsagePercentage; set => SetProperty(ref _cpuUsagePercentage, value); }
    public string CpuUsageText { get => _cpuUsageText; set => SetProperty(ref _cpuUsageText, value); }
    public string CpuBrush { get => _cpuBrush; set => SetProperty(ref _cpuBrush, value); }

    public string MemoryUsageText { get => _memoryUsageText; set => SetProperty(ref _memoryUsageText, value); }
    public double MemoryPercentage { get => _memoryPercentage; set => SetProperty(ref _memoryPercentage, value); }
    public string MemoryPercentageText { get => _memoryPercentageText; set => SetProperty(ref _memoryPercentageText, value); }
    public string MemoryBrush { get => _memoryBrush; set => SetProperty(ref _memoryBrush, value); }

    public string DiskFreeSpaceText { get => _diskFreeSpaceText; set => SetProperty(ref _diskFreeSpaceText, value); }
    public double DiskFreePercentage { get => _diskFreePercentage; set => SetProperty(ref _diskFreePercentage, value); }
    public string DiskHealthBrush { get => _diskHealthBrush; set => SetProperty(ref _diskHealthBrush, value); }
    public string DiskHealthStatus { get => _diskHealthStatus; set => SetProperty(ref _diskHealthStatus, value); }

    public bool IsNetworkConnected { get => _isNetworkConnected; set => SetProperty(ref _isNetworkConnected, value); }
    public string NetworkStatusText { get => _networkStatusText; set => SetProperty(ref _networkStatusText, value); }
    public string NetworkStatusBrush { get => _networkStatusBrush; set => SetProperty(ref _networkStatusBrush, value); }

    public string ActiveTaskDescription { get => _activeTaskDescription; set => SetProperty(ref _activeTaskDescription, value); }
    public bool IsTaskActive { get => _isTaskActive; set => SetProperty(ref _isTaskActive, value); }
    public string LastUpdatedText { get => _lastUpdatedText; set => SetProperty(ref _lastUpdatedText, value); }

    public ICommand RefreshCommand { get; }

    public void StartPolling(int intervalMs = 2500)
    {
        StopPolling();
        _pollingTimer = new Timer(async _ => await RefreshTelemetryAsync(), null, 0, intervalMs);
    }

    public void StopPolling()
    {
        Interlocked.Exchange(ref _pollingTimer, null)?.Dispose();
    }

    public void Dispose()
    {
        StopPolling();
        GC.SuppressFinalize(this);
    }

    public async Task RefreshTelemetryAsync()
    {
        try
        {
            var snapshot = await _telemetryService.GetSnapshotAsync();
            UpdateFromSnapshot(snapshot);
        }
        catch
        {
            // Suppress background poll errors
        }
    }

    public void UpdateFromSnapshot(TelemetrySnapshot snapshot)
    {
        void Apply()
        {
            OsDescription = snapshot.OsDescription;
            OsBuild = snapshot.OsBuild;
            IsElevated = snapshot.IsElevated;

            ElevationBadgeText = snapshot.IsElevated ? "Administrator" : "Standard User";
            ElevationBadgeBrush = snapshot.IsElevated ? "#22C55E" : "#EAB308";

            CpuUsagePercentage = Math.Clamp(snapshot.CpuUsagePercentage, 0, 100);
            CpuUsageText = $"{CpuUsagePercentage:F0}%";
            CpuBrush = CpuUsagePercentage > 85 ? "#EF4444" : CpuUsagePercentage > 60 ? "#EAB308" : "#22C55E";

            double usedGb = snapshot.MemoryUsedBytes / (1024.0 * 1024 * 1024);
            double totalGb = snapshot.MemoryTotalBytes / (1024.0 * 1024 * 1024);
            MemoryPercentage = totalGb > 0 ? Math.Clamp((usedGb / totalGb) * 100, 0, 100) : 0;
            MemoryUsageText = $"{usedGb:F1} / {totalGb:F1} GB";
            MemoryPercentageText = $"{MemoryPercentage:F0}%";
            MemoryBrush = MemoryPercentage > 85 ? "#EF4444" : MemoryPercentage > 70 ? "#EAB308" : "#22C55E";

            double freeDiskGb = snapshot.SystemDriveFreeBytes / (1024.0 * 1024 * 1024);
            double totalDiskGb = snapshot.SystemDriveTotalBytes / (1024.0 * 1024 * 1024);
            DiskFreeSpaceText = totalDiskGb > 0 ? $"{freeDiskGb:F1} GB Free of {totalDiskGb:F0} GB" : $"{freeDiskGb:F1} GB Free";
            DiskFreePercentage = totalDiskGb > 0 ? Math.Clamp((freeDiskGb / totalDiskGb) * 100, 0, 100) : 50;

            if (freeDiskGb < 10)
            {
                DiskHealthBrush = "#EF4444";
                DiskHealthStatus = "Critical";
            }
            else if (freeDiskGb < 25)
            {
                DiskHealthBrush = "#EAB308";
                DiskHealthStatus = "Warning";
            }
            else
            {
                DiskHealthBrush = "#22C55E";
                DiskHealthStatus = "Healthy";
            }

            IsNetworkConnected = snapshot.NetworkConnected;
            NetworkStatusText = snapshot.NetworkConnected ? "Connected" : "Offline";
            NetworkStatusBrush = snapshot.NetworkConnected ? "#22C55E" : "#EF4444";

            if (!IsTaskActive || !string.Equals(snapshot.ActiveTaskDescription, "Idle", StringComparison.OrdinalIgnoreCase))
            {
                ActiveTaskDescription = snapshot.ActiveTaskDescription;
                IsTaskActive = !string.Equals(snapshot.ActiveTaskDescription, "Idle", StringComparison.OrdinalIgnoreCase);
            }
            LastUpdatedText = DateTime.Now.ToString("HH:mm:ss");
        }

        if (_uiContext != null && SynchronizationContext.Current != _uiContext)
        {
            _uiContext.Post(_ => Apply(), null);
        }
        else
        {
            Apply();
        }
    }
}
