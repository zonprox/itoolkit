namespace IToolkit.App.ViewModels;

using System;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;

public class DashboardViewModel : ViewModelBase, IDisposable
{
    private readonly ISystemHealthService _systemHealth;
    private readonly IOfficeSuiteService _officeSuite;
    private readonly IOutlookService _outlook;
    private readonly IConnectivityService _connectivity;
    private readonly IBackupService _backup;
    private readonly IOptimizationService _optimization;
    private readonly ISystemTelemetryService? _telemetryService;
    private readonly SynchronizationContext? _uiContext;
    private Timer? _pollingTimer;

    private string _systemHealthStatus = "Ready";
    private string _officeStatus = "Ready";
    private string _networkStatus = "Ready";
    private string _backupStatus = "Ready";
    private string _softwareStatus = "Ready";

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
    private string _lastUpdatedText = "Just now";

    private string _computerName = Environment.MachineName;
    private string _domainOrWorkgroup = $"{Environment.UserDomainName} (Workgroup / Domain)";
    private string _currentUser = $"{Environment.UserDomainName}\\{Environment.UserName}";
    private string _userProfilePath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private string _systemUptime = "00h 00m 00s";
    private string _osArchitecture = Environment.Is64BitOperatingSystem ? "X64 (64-bit OS)" : "X86 (32-bit OS)";
    private string _cpuModelName = $"{Environment.ProcessorCount} Logical Processors";
    private string _systemManufacturerModel = "Standard PC / Workstation";
    private string _gpuModelName = "Standard Display Adapter";
    private string _biosAndSerial = "UEFI / Standard BIOS";
    private string _allDrivesSummary = "C: Storage Ready";
    private string _primaryNetworkAdapter = "Detecting network adapter...";
    private string _ipv4Address = "N/A";
    private string _defaultGateway = "N/A";
    private string _dnsServers = "N/A";
    private string _macAddress = "N/A";

    public DashboardViewModel(
        ISystemHealthService systemHealth,
        IOfficeSuiteService officeSuite,
        IOutlookService outlook,
        IConnectivityService connectivity,
        IBackupService backup,
        IOptimizationService optimization,
        IActivityLogger? logger = null)
        : this(systemHealth, officeSuite, outlook, connectivity, backup, optimization, null, logger)
    {
    }

    public DashboardViewModel(
        ISystemHealthService systemHealth,
        IOfficeSuiteService officeSuite,
        IOutlookService outlook,
        IConnectivityService connectivity,
        IBackupService backup,
        IOptimizationService optimization,
        ISystemTelemetryService? telemetryService,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _systemHealth = systemHealth ?? throw new ArgumentNullException(nameof(systemHealth));
        _officeSuite = officeSuite ?? throw new ArgumentNullException(nameof(officeSuite));
        _outlook = outlook ?? throw new ArgumentNullException(nameof(outlook));
        _connectivity = connectivity ?? throw new ArgumentNullException(nameof(connectivity));
        _backup = backup ?? throw new ArgumentNullException(nameof(backup));
        _optimization = optimization ?? throw new ArgumentNullException(nameof(optimization));
        _telemetryService = telemetryService;
        _uiContext = SynchronizationContext.Current;

        RefreshTelemetryCommand = new AsyncRelayCommand(RefreshTelemetryAsync);

        QuickSystemRepairCommand = new AsyncRelayCommand(QuickSystemRepairAsync, () => IsNotBusy);
        QuickMailRepairCommand = new AsyncRelayCommand(QuickMailRepairAsync, () => IsNotBusy);
        QuickNetworkResetCommand = new AsyncRelayCommand(QuickNetworkResetAsync, () => IsNotBusy);
        QuickDiskCleanupCommand = new AsyncRelayCommand(QuickDiskCleanupAsync, () => IsNotBusy);
        QuickSoftwareUpgradeCommand = new AsyncRelayCommand(QuickSoftwareUpgradeAsync, () => IsNotBusy);
        QuickProfileBackupCommand = new AsyncRelayCommand(QuickProfileBackupAsync, () => IsNotBusy);

        if (_telemetryService != null)
        {
            StartPolling();
        }
    }

    public string SystemHealthStatus { get => _systemHealthStatus; set => SetProperty(ref _systemHealthStatus, value); }
    public string OfficeStatus { get => _officeStatus; set => SetProperty(ref _officeStatus, value); }
    public string NetworkStatus { get => _networkStatus; set => SetProperty(ref _networkStatus, value); }
    public string BackupStatus { get => _backupStatus; set => SetProperty(ref _backupStatus, value); }
    public string SoftwareStatus { get => _softwareStatus; set => SetProperty(ref _softwareStatus, value); }

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
    public string LastUpdatedText { get => _lastUpdatedText; set => SetProperty(ref _lastUpdatedText, value); }

    public string ComputerName { get => _computerName; set => SetProperty(ref _computerName, value); }
    public string DomainOrWorkgroup { get => _domainOrWorkgroup; set => SetProperty(ref _domainOrWorkgroup, value); }
    public string CurrentUser { get => _currentUser; set => SetProperty(ref _currentUser, value); }
    public string UserProfilePath { get => _userProfilePath; set => SetProperty(ref _userProfilePath, value); }
    public string SystemUptime { get => _systemUptime; set => SetProperty(ref _systemUptime, value); }
    public string OsArchitecture { get => _osArchitecture; set => SetProperty(ref _osArchitecture, value); }
    public string CpuModelName { get => _cpuModelName; set => SetProperty(ref _cpuModelName, value); }
    public string SystemManufacturerModel { get => _systemManufacturerModel; set => SetProperty(ref _systemManufacturerModel, value); }
    public string GpuModelName { get => _gpuModelName; set => SetProperty(ref _gpuModelName, value); }
    public string BiosAndSerial { get => _biosAndSerial; set => SetProperty(ref _biosAndSerial, value); }
    public string AllDrivesSummary { get => _allDrivesSummary; set => SetProperty(ref _allDrivesSummary, value); }
    public string PrimaryNetworkAdapter { get => _primaryNetworkAdapter; set => SetProperty(ref _primaryNetworkAdapter, value); }
    public string Ipv4Address { get => _ipv4Address; set => SetProperty(ref _ipv4Address, value); }
    public string DefaultGateway { get => _defaultGateway; set => SetProperty(ref _defaultGateway, value); }
    public string DnsServers { get => _dnsServers; set => SetProperty(ref _dnsServers, value); }
    public string MacAddress { get => _macAddress; set => SetProperty(ref _macAddress, value); }

    public IAsyncRelayCommand RefreshTelemetryCommand { get; }

    public IAsyncRelayCommand QuickSystemRepairCommand { get; }
    public IAsyncRelayCommand QuickMailRepairCommand { get; }
    public IAsyncRelayCommand QuickNetworkResetCommand { get; }
    public IAsyncRelayCommand QuickDiskCleanupCommand { get; }
    public IAsyncRelayCommand QuickSoftwareUpgradeCommand { get; }
    public IAsyncRelayCommand QuickProfileBackupCommand { get; }

    public void StartPolling(int intervalMs = 2500)
    {
        if (intervalMs <= 0) intervalMs = 2500;
        StopPolling();
        if (_telemetryService != null)
        {
            _pollingTimer = new Timer(async _ => await RefreshTelemetryAsync(), null, 0, intervalMs);
        }
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
        if (_telemetryService == null) return;
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

    public void UpdateFromSnapshot(TelemetrySnapshot? snapshot)
    {
        if (snapshot == null) return;

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
            ActiveTaskDescription = snapshot.ActiveTaskDescription;
            LastUpdatedText = DateTime.Now.ToString("HH:mm:ss");

            if (!string.IsNullOrWhiteSpace(snapshot.ComputerName)) ComputerName = snapshot.ComputerName;
            if (!string.IsNullOrWhiteSpace(snapshot.DomainOrWorkgroup)) DomainOrWorkgroup = snapshot.DomainOrWorkgroup;
            if (!string.IsNullOrWhiteSpace(snapshot.CurrentUser)) CurrentUser = snapshot.CurrentUser;
            if (!string.IsNullOrWhiteSpace(snapshot.UserProfilePath)) UserProfilePath = snapshot.UserProfilePath;
            if (!string.IsNullOrWhiteSpace(snapshot.SystemUptime)) SystemUptime = snapshot.SystemUptime;
            if (!string.IsNullOrWhiteSpace(snapshot.OsArchitecture)) OsArchitecture = snapshot.OsArchitecture;
            if (!string.IsNullOrWhiteSpace(snapshot.CpuModelName)) CpuModelName = snapshot.CpuModelName;
            if (!string.IsNullOrWhiteSpace(snapshot.SystemManufacturerModel)) SystemManufacturerModel = snapshot.SystemManufacturerModel;
            if (!string.IsNullOrWhiteSpace(snapshot.GpuModelName)) GpuModelName = snapshot.GpuModelName;
            if (!string.IsNullOrWhiteSpace(snapshot.BiosAndSerial)) BiosAndSerial = snapshot.BiosAndSerial;
            if (!string.IsNullOrWhiteSpace(snapshot.AllDrivesSummary)) AllDrivesSummary = snapshot.AllDrivesSummary;
            if (!string.IsNullOrWhiteSpace(snapshot.PrimaryNetworkAdapter)) PrimaryNetworkAdapter = snapshot.PrimaryNetworkAdapter;
            if (!string.IsNullOrWhiteSpace(snapshot.Ipv4Address)) Ipv4Address = snapshot.Ipv4Address;
            if (!string.IsNullOrWhiteSpace(snapshot.DefaultGateway)) DefaultGateway = snapshot.DefaultGateway;
            if (!string.IsNullOrWhiteSpace(snapshot.DnsServers)) DnsServers = snapshot.DnsServers;
            if (!string.IsNullOrWhiteSpace(snapshot.MacAddress)) MacAddress = snapshot.MacAddress;
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

    private async Task QuickSystemRepairAsync() => await ExecuteAsync("Quick System Repair (DISM & SFC)", () =>
    {
        var (dismRes, sfcRes) = _systemHealth.RunDismSfcPipeline();
        SystemHealthStatus = dismRes.Success && sfcRes.Success ? "System image and files healthy" : "Issues detected during repair";
        return Task.CompletedTask;
    });

    private async Task QuickMailRepairAsync() => await ExecuteAsync("Quick Outlook Mail Repair", () =>
    {
        var res = _outlook.RepairGlobalMailSettings();
        OfficeStatus = res.Success ? "Mailbox cache and outbox clean" : "Mail repair reported issues";
        return Task.CompletedTask;
    });

    private async Task QuickNetworkResetAsync() => await ExecuteAsync("Quick Network Reset", () =>
    {
        var res = _connectivity.RemediateNetworkStack();
        NetworkStatus = res.Success ? "Network stack reset and ready" : "Network remediation reported issues";
        return Task.CompletedTask;
    });

    private async Task QuickDiskCleanupAsync() => await ExecuteAsync("Quick Unified Disk Cleanup", () =>
    {
        var res = _systemHealth.RunUnifiedDiskCleanup(24);
        double mb = res.BytesReclaimed / (1024.0 * 1024.0);
        SystemHealthStatus = $"Reclaimed {mb:F1} MB temp and cache space";
        return Task.CompletedTask;
    });

    private async Task QuickSoftwareUpgradeAsync() => await ExecuteAsync("Upgrade Software Packages", () =>
    {
        var res = _optimization.UpdateAllPackages();
        SoftwareStatus = res.ExitCode == 0 ? "All Winget packages up-to-date" : $"Upgrade exited with code {res.ExitCode}";
        return Task.CompletedTask;
    });

    private async Task QuickProfileBackupAsync() => await ExecuteAsync("Quick Profile Backup", () =>
    {
        var profileMap = _backup.GetUserProfileMap();
        string dest = System.IO.Path.Combine(@"D:\UserBackups", Environment.UserName);
        var syncRes = _backup.RunRobocopySync(profileMap.ProfilePath, dest, false);
        BackupStatus = syncRes.IsSuccess ? $"Profile backed up to {dest}" : $"Backup completed with exit {syncRes.ExitCode}";
        return Task.CompletedTask;
    });
}
