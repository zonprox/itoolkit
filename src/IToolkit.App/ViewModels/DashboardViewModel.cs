namespace IToolkit.App.ViewModels;

using System;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;

public class DashboardViewModel : ViewModelBase
{
    private readonly ISystemHealthService _systemHealth;
    private readonly IOfficeSuiteService _officeSuite;
    private readonly IOutlookService _outlook;
    private readonly IConnectivityService _connectivity;
    private readonly IBackupService _backup;
    private readonly IOptimizationService _optimization;

    private string _systemHealthStatus = "Ready";
    private string _officeStatus = "Ready";
    private string _networkStatus = "Ready";
    private string _backupStatus = "Ready";
    private string _softwareStatus = "Ready";

    public DashboardViewModel(
        ISystemHealthService systemHealth,
        IOfficeSuiteService officeSuite,
        IOutlookService outlook,
        IConnectivityService connectivity,
        IBackupService backup,
        IOptimizationService optimization,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _systemHealth = systemHealth ?? throw new ArgumentNullException(nameof(systemHealth));
        _officeSuite = officeSuite ?? throw new ArgumentNullException(nameof(officeSuite));
        _outlook = outlook ?? throw new ArgumentNullException(nameof(outlook));
        _connectivity = connectivity ?? throw new ArgumentNullException(nameof(connectivity));
        _backup = backup ?? throw new ArgumentNullException(nameof(backup));
        _optimization = optimization ?? throw new ArgumentNullException(nameof(optimization));

        QuickSystemRepairCommand = new AsyncRelayCommand(QuickSystemRepairAsync, () => IsNotBusy);
        QuickMailRepairCommand = new AsyncRelayCommand(QuickMailRepairAsync, () => IsNotBusy);
        QuickNetworkResetCommand = new AsyncRelayCommand(QuickNetworkResetAsync, () => IsNotBusy);
        QuickDiskCleanupCommand = new AsyncRelayCommand(QuickDiskCleanupAsync, () => IsNotBusy);
        QuickSoftwareUpgradeCommand = new AsyncRelayCommand(QuickSoftwareUpgradeAsync, () => IsNotBusy);
        QuickProfileBackupCommand = new AsyncRelayCommand(QuickProfileBackupAsync, () => IsNotBusy);
    }

    public string SystemHealthStatus { get => _systemHealthStatus; set => SetProperty(ref _systemHealthStatus, value); }
    public string OfficeStatus { get => _officeStatus; set => SetProperty(ref _officeStatus, value); }
    public string NetworkStatus { get => _networkStatus; set => SetProperty(ref _networkStatus, value); }
    public string BackupStatus { get => _backupStatus; set => SetProperty(ref _backupStatus, value); }
    public string SoftwareStatus { get => _softwareStatus; set => SetProperty(ref _softwareStatus, value); }

    public IAsyncRelayCommand QuickSystemRepairCommand { get; }
    public IAsyncRelayCommand QuickMailRepairCommand { get; }
    public IAsyncRelayCommand QuickNetworkResetCommand { get; }
    public IAsyncRelayCommand QuickDiskCleanupCommand { get; }
    public IAsyncRelayCommand QuickSoftwareUpgradeCommand { get; }
    public IAsyncRelayCommand QuickProfileBackupCommand { get; }

    private async Task QuickSystemRepairAsync() => await ExecuteAsync("Quick System Repair (DISM & SFC)", () =>
    {
        var (dismRes, sfcRes) = _systemHealth.RunDismSfcPipeline();
        SystemHealthStatus = dismRes.Success && sfcRes.Success ? "System image and files healthy" : "Issues detected during repair";
        return Task.CompletedTask;
    });

    private async Task QuickMailRepairAsync() => await ExecuteAsync("Quick Outlook Mail Repair", () =>
    {
        var res = _outlook.QuickMailAndCacheRepair();
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
