namespace IToolkit.App.ViewModels;

using System;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Services.SystemHealth;

public class SystemHealthViewModel : ViewModelBase
{
    private readonly ISystemHealthService _systemHealthService;
    private readonly IDialogService? _dialogService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private int _selectedCleanupThresholdHours = 24;
    private bool _winSxSResetBase;
    private string? _customWimSource;
    private bool _limitSourceAccess;
    private string _lastDismStatus = "Ready";
    private string _lastSfcStatus = "Ready";
    private string _lastWindowsUpdateStatus = "Ready";
    private string _lastWindowsUpdateBlockStatus = "Ready";
    private string _lastTimeSyncStatus = "Ready";
    private string _lastWmiStatus = "Ready";
    private string _lastCleanupSummary = "Ready";
    private bool _rebootRequired;

    public SystemHealthViewModel(
        ISystemHealthService systemHealthService,
        IActivityLogger? logger = null,
        IDialogService? dialogService = null,
        ISafetyConfirmationService? confirmationService = null)
        : base(logger)
    {
        _systemHealthService = systemHealthService ?? throw new ArgumentNullException(nameof(systemHealthService));
        _dialogService = dialogService;
        _confirmationService = confirmationService;

        BrowseWimSourceCommand = new RelayCommand(BrowseWimSource, () => IsNotBusy);
        OpenWimFolderCommand = new RelayCommand(OpenWimFolder, () => IsNotBusy && !string.IsNullOrWhiteSpace(CustomWimSource));

        RunDismSfcPipelineCommand = new AsyncRelayCommand(RunDismSfcPipelineAsync, () => IsNotBusy);
        RunSfcScanCommand = new AsyncRelayCommand(RunSfcScanAsync, () => IsNotBusy);
        RunDismRestoreHealthCommand = new AsyncRelayCommand(RunDismRestoreHealthAsync, () => IsNotBusy);
        ResetWindowsUpdateCommand = new AsyncRelayCommand(ResetWindowsUpdateAsync, () => IsNotBusy);
        BlockWindowsUpdatesCommand = new AsyncRelayCommand(BlockWindowsUpdatesAsync, () => IsNotBusy);
        UnblockWindowsUpdatesCommand = new AsyncRelayCommand(UnblockWindowsUpdatesAsync, () => IsNotBusy);
        SyncSystemTimeCommand = new AsyncRelayCommand(SyncSystemTimeAsync, () => IsNotBusy);
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
        set
        {
            if (SetProperty(ref _customWimSource, value))
            {
                OpenWimFolderCommand.RaiseCanExecuteChanged();
            }
        }
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

    public string LastWindowsUpdateBlockStatus
    {
        get => _lastWindowsUpdateBlockStatus;
        set => SetProperty(ref _lastWindowsUpdateBlockStatus, value);
    }

    public string LastTimeSyncStatus
    {
        get => _lastTimeSyncStatus;
        set => SetProperty(ref _lastTimeSyncStatus, value);
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

    public IRelayCommand BrowseWimSourceCommand { get; }
    public IRelayCommand OpenWimFolderCommand { get; }
    public IAsyncRelayCommand RunDismSfcPipelineCommand { get; }
    public IAsyncRelayCommand RunSfcScanCommand { get; }
    public IAsyncRelayCommand RunDismRestoreHealthCommand { get; }
    public IAsyncRelayCommand ResetWindowsUpdateCommand { get; }
    public IAsyncRelayCommand BlockWindowsUpdatesCommand { get; }
    public IAsyncRelayCommand UnblockWindowsUpdatesCommand { get; }
    public IAsyncRelayCommand SyncSystemTimeCommand { get; }
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

    private async Task BlockWindowsUpdatesAsync()
    {
        await ExecuteAsync("Block Windows Updates (Win 10/11)", () =>
        {
            var res = _systemHealthService.BlockWindowsUpdates();
            LastWindowsUpdateBlockStatus = res.Success
                ? "Windows Updates: Blocked (Services & Policies Locked)"
                : $"Block Failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task UnblockWindowsUpdatesAsync()
    {
        await ExecuteAsync("Unblock Windows Updates (Win 10/11)", () =>
        {
            var res = _systemHealthService.UnblockWindowsUpdates();
            LastWindowsUpdateBlockStatus = res.Success
                ? "Windows Updates: Unblocked (Services & Policies Restored)"
                : $"Unblock Failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task SyncSystemTimeAsync()
    {
        await ExecuteAsync("Server Time Synchronization (W32Time)", () =>
        {
            var res = _systemHealthService.SyncSystemTime();
            LastTimeSyncStatus = res.Success
                ? "System Time: Synchronized with server."
                : $"Time Sync Failed: {res.Message}";
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

    private void BrowseWimSource()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFileDialog(
            "Select Windows Image Source",
            "WIM/ESD Files (*.wim;*.esd)|*.wim;*.esd|All Files (*.*)|*.*",
            CustomWimSource);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            CustomWimSource = selected;
        }
    }

    private void OpenWimFolder()
    {
        if (_dialogService == null || string.IsNullOrWhiteSpace(CustomWimSource)) return;
        _dialogService.OpenFolderInExplorer(CustomWimSource);
    }

    private async Task CleanWinSxSAsync()
    {
        if (WinSxSResetBase && _confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Deep WinSxS Cleanup",
                "Deep WinSxS Cleanup with /ResetBase will permanently remove superseded component versions.",
                "You will NOT be able to uninstall previous Windows updates after this operation completes. Do you wish to continue?");
            if (!confirmed)
            {
                LastCleanupSummary = "WinSxS cleanup cancelled by user.";
                Logger?.LogWarning(nameof(SystemHealthViewModel), "WinSxS cleanup with ResetBase cancelled by user.");
                return;
            }
        }

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
