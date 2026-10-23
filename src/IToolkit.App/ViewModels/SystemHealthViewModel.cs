namespace IToolkit.App.ViewModels;

using System;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Services.SystemHealth;

public class SystemHealthViewModel : ViewModelBase
{
    private readonly ISystemHealthService _systemHealthService;
    private int _selectedCleanupThresholdHours = 24;
    private bool _winSxSResetBase;
    private string? _customWimSource;
    private bool _limitSourceAccess;
    private string _lastDismStatus = "Ready";
    private string _lastSfcStatus = "Ready";
    private string _lastWindowsUpdateStatus = "Ready";
    private string _lastWmiStatus = "Ready";
    private string _lastCleanupSummary = "Ready";
    private bool _rebootRequired;

    public SystemHealthViewModel(ISystemHealthService systemHealthService, IActivityLogger? logger = null)
        : base(logger)
    {
        _systemHealthService = systemHealthService ?? throw new ArgumentNullException(nameof(systemHealthService));

        RunDismSfcPipelineCommand = new AsyncRelayCommand(RunDismSfcPipelineAsync, () => IsNotBusy);
        RunSfcScanCommand = new AsyncRelayCommand(RunSfcScanAsync, () => IsNotBusy);
        RunDismRestoreHealthCommand = new AsyncRelayCommand(RunDismRestoreHealthAsync, () => IsNotBusy);
        ResetWindowsUpdateCommand = new AsyncRelayCommand(ResetWindowsUpdateAsync, () => IsNotBusy);
        RepairWmiCommand = new AsyncRelayCommand(RepairWmiAsync, () => IsNotBusy);
        CleanWinSxSCommand = new AsyncRelayCommand(CleanWinSxSAsync, () => IsNotBusy);
        RunUnifiedDiskCleanupCommand = new AsyncRelayCommand(RunUnifiedDiskCleanupAsync, () => IsNotBusy);
    }

    public int SelectedCleanupThresholdHours
    {
        get => _selectedCleanupThresholdHours;
        set => SetProperty(ref _selectedCleanupThresholdHours, value);
    }

    public bool WinSxSResetBase
    {
        get => _winSxSResetBase;
        set => SetProperty(ref _winSxSResetBase, value);
    }

    public string? CustomWimSource
    {
        get => _customWimSource;
        set => SetProperty(ref _customWimSource, value);
    }

    public bool LimitSourceAccess
    {
        get => _limitSourceAccess;
        set => SetProperty(ref _limitSourceAccess, value);
    }

    public string LastDismStatus
    {
        get => _lastDismStatus;
        set => SetProperty(ref _lastDismStatus, value);
    }

    public string LastSfcStatus
    {
        get => _lastSfcStatus;
        set => SetProperty(ref _lastSfcStatus, value);
    }

    public string LastWindowsUpdateStatus
    {
        get => _lastWindowsUpdateStatus;
        set => SetProperty(ref _lastWindowsUpdateStatus, value);
    }

    public string LastWmiStatus
    {
        get => _lastWmiStatus;
        set => SetProperty(ref _lastWmiStatus, value);
    }

    public string LastCleanupSummary
    {
        get => _lastCleanupSummary;
        set => SetProperty(ref _lastCleanupSummary, value);
    }

    public bool RebootRequired
    {
        get => _rebootRequired;
        set => SetProperty(ref _rebootRequired, value);
    }

    public IAsyncRelayCommand RunDismSfcPipelineCommand { get; }
    public IAsyncRelayCommand RunSfcScanCommand { get; }
    public IAsyncRelayCommand RunDismRestoreHealthCommand { get; }
    public IAsyncRelayCommand ResetWindowsUpdateCommand { get; }
    public IAsyncRelayCommand RepairWmiCommand { get; }
    public IAsyncRelayCommand CleanWinSxSCommand { get; }
    public IAsyncRelayCommand RunUnifiedDiskCleanupCommand { get; }

    private async Task RunDismSfcPipelineAsync()
    {
        await ExecuteAsync("DISM & SFC Dual Repair Pipeline", () =>
        {
            var (dismRes, sfcRes) = _systemHealthService.RunDismSfcPipeline(CustomWimSource, LimitSourceAccess);
            LastDismStatus = dismRes.Success ? "DISM: RestoreHealth Succeeded" : $"DISM: Failed (Exit {dismRes.ExitCode})";
            LastSfcStatus = sfcRes.Success ? (sfcRes.IntegrityViolationsFound ? "SFC: Violations Repaired" : "SFC: Integrity Clean") : $"SFC: Failed (Exit {sfcRes.ExitCode})";
            RebootRequired = dismRes.NeedsReboot;
            return Task.CompletedTask;
        });
    }

    private async Task RunSfcScanAsync()
    {
        await ExecuteAsync("SFC System Integrity Scan", () =>
        {
            var res = _systemHealthService.RunSfcScan();
            LastSfcStatus = res.Success ? (res.IntegrityViolationsFound ? "SFC: Violations Repaired" : "SFC: Integrity Clean") : $"SFC: Failed (Exit {res.ExitCode})";
            return Task.CompletedTask;
        });
    }

    private async Task RunDismRestoreHealthAsync()
    {
        await ExecuteAsync("DISM RestoreHealth", () =>
        {
            var res = _systemHealthService.RunDismRestoreHealth(CustomWimSource, LimitSourceAccess);
            LastDismStatus = res.Success ? "DISM: Health Restored Successfully" : $"DISM: Failed (Exit {res.ExitCode})";
            RebootRequired = res.NeedsReboot;
            return Task.CompletedTask;
        });
    }

    private async Task ResetWindowsUpdateAsync()
    {
        await ExecuteAsync("Windows Update Components Reset", () =>
        {
            var res = _systemHealthService.ResetWindowsUpdateComponents();
            LastWindowsUpdateStatus = res.Success
                ? $"Windows Update Reset: {res.ReRegisteredDllCount} DLLs registered, services restarted."
                : $"Windows Update Reset Failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task RepairWmiAsync()
    {
        await ExecuteAsync("WMI Repository Salvage", () =>
        {
            var res = _systemHealthService.RepairWmiRepository();
            LastWmiStatus = res.Success
                ? (res.IsConsistent ? "WMI: Repository is Consistent." : "WMI: Repository Salvaged Successfully.")
                : "WMI: Repository Salvage Failed.";
            return Task.CompletedTask;
        });
    }

    private async Task CleanWinSxSAsync()
    {
        await ExecuteAsync("WinSxS Component Store Cleanup", () =>
        {
            var res = _systemHealthService.CleanWinSxS(WinSxSResetBase);
            LastCleanupSummary = res.Success ? "WinSxS: Component Store Cleaned Successfully." : $"WinSxS Cleanup Failed (Exit {res.ExitCode}).";
            return Task.CompletedTask;
        });
    }

    private async Task RunUnifiedDiskCleanupAsync()
    {
        await ExecuteAsync("Unified Disk Cleanup", () =>
        {
            var res = _systemHealthService.RunUnifiedDiskCleanup(SelectedCleanupThresholdHours);
            double mb = res.BytesReclaimed / (1024.0 * 1024.0);
            LastCleanupSummary = res.Success
                ? $"Cleanup Reclaimed {mb:F1} MB across {res.FilesDeleted} files ({res.FilesSkipped} locked/skipped)."
                : "Cleanup encountered errors during execution.";
            return Task.CompletedTask;
        });
    }
}
