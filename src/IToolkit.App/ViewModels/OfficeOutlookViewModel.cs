namespace IToolkit.App.ViewModels;

using System;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Office;

public class OfficeOutlookViewModel : ViewModelBase
{
    private readonly IOfficeSuiteService _officeSuiteService;
    private readonly IOutlookService _outlookService;
    private readonly IDialogService? _dialogService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private bool _useOnlineC2RRepair;
    private bool _disableHardwareAcceleration;
    private MapiDataFileInfo? _selectedDataFile;
    private string _targetPstPath = @"C:\OutlookFiles\NewDefaultStore.pst";
    private string? _sourcePstPath;
    private string _relocationDestinationDir = @"D:\OutlookFiles";
    private string _backupDirectory = @"D:\OutlookBackups";
    private string _lastOfficeSummary = "Ready";
    private string _lastOutlookSummary = "Ready";

    public OfficeOutlookViewModel(
        IOfficeSuiteService officeSuiteService,
        IOutlookService outlookService,
        IActivityLogger? logger = null,
        IDialogService? dialogService = null,
        ISafetyConfirmationService? confirmationService = null)
        : base(logger)
    {
        _officeSuiteService = officeSuiteService ?? throw new ArgumentNullException(nameof(officeSuiteService));
        _outlookService = outlookService ?? throw new ArgumentNullException(nameof(outlookService));
        _dialogService = dialogService;
        _confirmationService = confirmationService;

        DataFiles = new ObservableCollection<MapiDataFileInfo>();

        // Smart Path Commands
        BrowseTargetPstCommand = new RelayCommand(BrowseTargetPst, () => IsNotBusy);
        BrowseSourcePstCommand = new RelayCommand(BrowseSourcePst, () => IsNotBusy);
        BrowseRelocationDirCommand = new RelayCommand(BrowseRelocationDir, () => IsNotBusy);
        OpenRelocationDirCommand = new RelayCommand(OpenRelocationDir, () => IsNotBusy && !string.IsNullOrWhiteSpace(RelocationDestinationDir));
        BrowseBackupDirCommand = new RelayCommand(BrowseBackupDir, () => IsNotBusy);
        OpenBackupDirCommand = new RelayCommand(OpenBackupDir, () => IsNotBusy && !string.IsNullOrWhiteSpace(BackupDirectory));

        // Commands
        RepairC2RCommand = new AsyncRelayCommand(RepairC2RAsync, () => IsNotBusy);
        RepairC2RServiceCommand = new AsyncRelayCommand(RepairC2RServiceAsync, () => IsNotBusy);
        ResetOfficeIdentityCommand = new AsyncRelayCommand(ResetOfficeIdentityAsync, () => IsNotBusy);
        ToggleHardwareAccelerationCommand = new AsyncRelayCommand(ToggleHardwareAccelerationAsync, () => IsNotBusy);
        TerminateOfficeProcessesCommand = new AsyncRelayCommand(TerminateOfficeProcessesAsync, () => IsNotBusy);
        ScrubOfficeSuiteCommand = new AsyncRelayCommand(ScrubOfficeSuiteAsync, () => IsNotBusy);

        WordQuickRepairCommand = new AsyncRelayCommand(WordQuickRepairAsync, () => IsNotBusy);
        ExcelQuickRepairCommand = new AsyncRelayCommand(ExcelQuickRepairAsync, () => IsNotBusy);
        PowerPointQuickRepairCommand = new AsyncRelayCommand(PowerPointQuickRepairAsync, () => IsNotBusy);

        QuickMailRepairCommand = new AsyncRelayCommand(QuickMailRepairAsync, () => IsNotBusy);
        Expand100GBCommand = new AsyncRelayCommand(Expand100GBAsync, () => IsNotBusy);
        DiscoverDataFilesCommand = new AsyncRelayCommand(DiscoverDataFilesAsync, () => IsNotBusy);
        RunPstPipelineCommand = new AsyncRelayCommand(RunPstPipelineAsync, () => IsNotBusy);
        RelocatePstCommand = new AsyncRelayCommand(RelocatePstAsync, () => IsNotBusy && SelectedDataFile != null);
        CompactPstCommand = new AsyncRelayCommand(CompactPstAsync, () => IsNotBusy && SelectedDataFile != null);
        BackupPstCommand = new AsyncRelayCommand(BackupPstAsync, () => IsNotBusy && SelectedDataFile != null);
    }

    public ObservableCollection<MapiDataFileInfo> DataFiles { get; }

    public MapiDataFileInfo? SelectedDataFile
    {
        get => _selectedDataFile;
        set
        {
            if (SetProperty(ref _selectedDataFile, value))
            {
                if (value != null && !string.IsNullOrWhiteSpace(value.FilePath))
                {
                    SourcePstPath = value.FilePath;
                }
                RelocatePstCommand.RaiseCanExecuteChanged();
                CompactPstCommand.RaiseCanExecuteChanged();
                BackupPstCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool UseOnlineC2RRepair
    {
        get => _useOnlineC2RRepair;
        set => SetProperty(ref _useOnlineC2RRepair, value);
    }

    public bool DisableHardwareAcceleration
    {
        get => _disableHardwareAcceleration;
        set => SetProperty(ref _disableHardwareAcceleration, value);
    }

    public string TargetPstPath
    {
        get => _targetPstPath;
        set => SetProperty(ref _targetPstPath, value);
    }

    public string? SourcePstPath
    {
        get => _sourcePstPath;
        set => SetProperty(ref _sourcePstPath, value);
    }

    public string RelocationDestinationDir
    {
        get => _relocationDestinationDir;
        set
        {
            if (SetProperty(ref _relocationDestinationDir, value))
            {
                OpenRelocationDirCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BackupDirectory
    {
        get => _backupDirectory;
        set
        {
            if (SetProperty(ref _backupDirectory, value))
            {
                OpenBackupDirCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string LastOfficeSummary
    {
        get => _lastOfficeSummary;
        set => SetProperty(ref _lastOfficeSummary, value);
    }

    public string LastOutlookSummary
    {
        get => _lastOutlookSummary;
        set => SetProperty(ref _lastOutlookSummary, value);
    }

    public IRelayCommand BrowseTargetPstCommand { get; }
    public IRelayCommand BrowseSourcePstCommand { get; }
    public IRelayCommand BrowseRelocationDirCommand { get; }
    public IRelayCommand OpenRelocationDirCommand { get; }
    public IRelayCommand BrowseBackupDirCommand { get; }
    public IRelayCommand OpenBackupDirCommand { get; }

    public IAsyncRelayCommand RepairC2RCommand { get; }
    public IAsyncRelayCommand RepairC2RServiceCommand { get; }
    public IAsyncRelayCommand ResetOfficeIdentityCommand { get; }
    public IAsyncRelayCommand ToggleHardwareAccelerationCommand { get; }
    public IAsyncRelayCommand TerminateOfficeProcessesCommand { get; }
    public IAsyncRelayCommand ScrubOfficeSuiteCommand { get; }

    public IAsyncRelayCommand WordQuickRepairCommand { get; }
    public IAsyncRelayCommand ExcelQuickRepairCommand { get; }
    public IAsyncRelayCommand PowerPointQuickRepairCommand { get; }

    public IAsyncRelayCommand QuickMailRepairCommand { get; }
    public IAsyncRelayCommand Expand100GBCommand { get; }
    public IAsyncRelayCommand DiscoverDataFilesCommand { get; }
    public IAsyncRelayCommand RunPstPipelineCommand { get; }
    public IAsyncRelayCommand CreateAndSetDefaultPstCommand => RunPstPipelineCommand;
    public IAsyncRelayCommand RelocatePstCommand { get; }
    public IAsyncRelayCommand RelocateSelectedPstCommand => RelocatePstCommand;
    public IAsyncRelayCommand CompactPstCommand { get; }
    public IAsyncRelayCommand CompactSelectedPstCommand => CompactPstCommand;
    public IAsyncRelayCommand BackupPstCommand { get; }
    public IAsyncRelayCommand BackupSelectedPstCommand => BackupPstCommand;

    private void BrowseTargetPst()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowSaveFileDialog(
            "Select Target PST Destination",
            "Outlook Data Files (*.pst)|*.pst|All Files (*.*)|*.*",
            "NewDefaultStore.pst",
            TargetPstPath);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            TargetPstPath = selected;
        }
    }

    private void BrowseSourcePst()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFileDialog(
            "Select Source PST File",
            "Outlook Data Files (*.pst)|*.pst|All Files (*.*)|*.*",
            SourcePstPath);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            SourcePstPath = selected;
        }
    }

    private void BrowseRelocationDir()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFolderDialog(
            "Select PST Relocation Target Directory",
            RelocationDestinationDir);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            RelocationDestinationDir = selected;
        }
    }

    private void OpenRelocationDir()
    {
        if (_dialogService == null || string.IsNullOrWhiteSpace(RelocationDestinationDir)) return;
        _dialogService.OpenFolderInExplorer(RelocationDestinationDir);
    }

    private void BrowseBackupDir()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFolderDialog(
            "Select PST Backup Directory",
            BackupDirectory);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            BackupDirectory = selected;
        }
    }

    private void OpenBackupDir()
    {
        if (_dialogService == null || string.IsNullOrWhiteSpace(BackupDirectory)) return;
        _dialogService.OpenFolderInExplorer(BackupDirectory);
    }

    private async Task<bool> ConfirmSaveAppWorkBeforeFixAsync(string operationName, string applicationName, bool isOutlookTarget = false)
    {
        if (_confirmationService == null)
        {
            return true;
        }

        bool confirmed = await _confirmationService.ConfirmAsync(
            $"Save Work Before {operationName} ({applicationName})",
            $"Please save and back up all open files and data in {applicationName} before running '{operationName}' to prevent data loss.",
            $"{applicationName} will be safely closed before executing '{operationName}' and automatically restarted once the fix completes. Do you want to proceed?");

        if (!confirmed)
        {
            string cancelMsg = $"{operationName} cancelled by user (save work in {applicationName} first).";
            if (isOutlookTarget)
            {
                LastOutlookSummary = cancelMsg;
            }
            else
            {
                LastOfficeSummary = cancelMsg;
            }
            Logger?.LogWarning(nameof(OfficeOutlookViewModel), cancelMsg);
            return false;
        }

        return true;
    }

    private async Task RepairC2RAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Office Click-to-Run Repair", "Microsoft Office (Word, Excel, PowerPoint, Outlook)")) return;
        await ExecuteAsync("Office Click-to-Run Repair", () =>
        {
            var res = _officeSuiteService.RunClickToRunRepair(UseOnlineC2RRepair);
            LastOfficeSummary = res.ExitCode == 0 ? "C2R Repair triggered successfully." : $"C2R Repair failed (Exit {res.ExitCode}).";
            return Task.CompletedTask;
        });
    }

    private async Task RepairC2RServiceAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Repair Click-to-Run Service", "Microsoft Office (Word, Excel, PowerPoint, Outlook)")) return;
        await ExecuteAsync("Repair Click-to-Run Service", () =>
        {
            bool ok = _officeSuiteService.RepairClickToRunService();
            LastOfficeSummary = ok ? "Click-to-Run service configuration and state repaired." : "Click-to-Run service repair failed.";
            return Task.CompletedTask;
        });
    }

    private async Task ResetOfficeIdentityAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Reset Office Identity & WAM Tokens", "Microsoft Office (Word, Excel, PowerPoint, Outlook)")) return;
        await ExecuteAsync("Reset Office Identity & WAM Tokens", () =>
        {
            var res = _officeSuiteService.ResetOfficeIdentityCache();
            LastOfficeSummary = res.Success ? "Office Identity & OneAuth token caches purged." : $"Reset failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task ToggleHardwareAccelerationAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Toggle Hardware Acceleration", "Microsoft Office (Word, Excel, PowerPoint, Outlook)")) return;
        await ExecuteAsync("Toggle Hardware Acceleration", () =>
        {
            var res = _officeSuiteService.SetHardwareAcceleration(DisableHardwareAcceleration);
            LastOfficeSummary = res.Success ? $"Hardware Acceleration set to: {(DisableHardwareAcceleration ? "Disabled" : "Enabled")}." : $"Toggle failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task TerminateOfficeProcessesAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Terminate Office Processes", "Microsoft Office (Word, Excel, PowerPoint, Outlook)")) return;
        await ExecuteAsync("Terminate Office Processes", () =>
        {
            bool ok = _officeSuiteService.TerminateOfficeProcesses();
            LastOfficeSummary = ok ? "All running Office processes terminated safely." : "Failed to terminate some Office processes.";
            return Task.CompletedTask;
        });
    }

    private async Task ScrubOfficeSuiteAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Office Suite Scrub",
                "Scrub Office Suite will completely remove all Microsoft Office and Microsoft 365 installations, settings, and license tokens from this system.",
                "This operation cannot be undone. Are you sure you want to proceed?");
            if (!confirmed)
            {
                LastOfficeSummary = "Office scrub cancelled by user.";
                Logger?.LogWarning(nameof(OfficeOutlookViewModel), "Office suite scrubber was cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Scrub Office Suite", () =>
        {
            var res = _officeSuiteService.ScrubOfficeSuiteCleanly();
            LastOfficeSummary = res.Success ? "Office suite scrubber completed successfully." : $"Scrubber failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task WordQuickRepairAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Word Quick Repair", "Microsoft Word")) return;
        await ExecuteAsync("Word Quick Repair", () =>
        {
            var res = _officeSuiteService.WordQuickRepair();
            LastOfficeSummary = res.Success ? $"Word Repaired: Normal.dotm reset, {res.AddInsDisabledCount} add-ins isolated, locks cleaned." : "Word Repair encountered issues.";
            return Task.CompletedTask;
        });
    }

    private async Task ExcelQuickRepairAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Excel Quick Repair", "Microsoft Excel")) return;
        await ExecuteAsync("Excel Quick Repair", () =>
        {
            var res = _officeSuiteService.ExcelQuickRepair();
            LastOfficeSummary = res.Success ? "Excel Repaired: XLSTART isolated, UI cache cleared, DDE/resiliency reset." : "Excel Repair encountered issues.";
            return Task.CompletedTask;
        });
    }

    private async Task PowerPointQuickRepairAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("PowerPoint Quick Repair", "Microsoft PowerPoint")) return;
        await ExecuteAsync("PowerPoint Quick Repair", () =>
        {
            var res = _officeSuiteService.PowerPointQuickRepair();
            LastOfficeSummary = res.Success ? "PowerPoint Repaired: Font/slide cache cleared, resiliency purged." : "PowerPoint Repair encountered issues.";
            return Task.CompletedTask;
        });
    }

    private async Task QuickMailRepairAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Quick Mail & Cache Repair", "Microsoft Outlook")) return;
        await ExecuteAsync("Quick Mail & Cache Repair", () =>
        {
            var res = _outlookService.QuickMailAndCacheRepair();
            LastOfficeSummary = res.Success
                ? "Mailbox repaired: Outbox purged, SRS reset, RoamCache cleaned (AutoComplete preserved), NavPane reset."
                : $"Quick Mail Repair failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task Expand100GBAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Expand PST/OST Limit to 100GB", "Microsoft Outlook", isOutlookTarget: true)) return;
        await ExecuteAsync("Expand PST/OST Limit to 100GB", () =>
        {
            var res = _outlookService.ExpandDataFileLimitsTo100GB();
            LastOutlookSummary = res.Success ? "Registry MaxLargeFileSize expanded to 100GB (102400 MB)." : $"Expansion failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    public async Task DiscoverDataFilesAsync() => await ExecuteAsync("Discover Outlook Data Files", () =>
    {
        RefreshDataFilesCore();
        return Task.CompletedTask;
    });

    public async Task ScanOutlookDataFilesAsync()
    {
        try
        {
            IsBusy = true;
            StatusMessage = "Scanning MAPI profiles for Outlook PST/OST data files...";
            Logger?.LogInfo(nameof(OfficeOutlookViewModel), "Scanning MAPI profiles for Outlook PST/OST data files...");
            var files = await Task.Run(() => _outlookService.DiscoverDataFiles() ?? Array.Empty<MapiDataFileInfo>());
            ApplyDiscoveredDataFiles(files);
            Logger?.LogInfo(nameof(OfficeOutlookViewModel), LastOutlookSummary);
        }
        catch (Exception ex)
        {
            LastOutlookSummary = $"MAPI scan failed: {ex.Message}";
            StatusMessage = LastOutlookSummary;
            Logger?.LogError(nameof(OfficeOutlookViewModel), LastOutlookSummary);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void RefreshDataFilesCore()
    {
        var files = _outlookService.DiscoverDataFiles() ?? Array.Empty<MapiDataFileInfo>();
        ApplyDiscoveredDataFiles(files);
    }

    private void ApplyDiscoveredDataFiles(System.Collections.Generic.IReadOnlyList<MapiDataFileInfo> files)
    {
        string? previousPath = SelectedDataFile?.FilePath;
        DataFiles.Clear();
        MapiDataFileInfo? matched = null;
        foreach (var file in files)
        {
            DataFiles.Add(file);
            if (!string.IsNullOrEmpty(previousPath) &&
                string.Equals(file.FilePath, previousPath, StringComparison.OrdinalIgnoreCase))
            {
                matched = file;
            }
        }

        if (matched != null)
        {
            SelectedDataFile = matched;
        }
        else if (DataFiles.Count > 0)
        {
            SelectedDataFile = DataFiles[0];
        }
        else
        {
            SelectedDataFile = null;
        }

        LastOutlookSummary = $"Discovered {DataFiles.Count} PST/OST files in MAPI profiles.";
        StatusMessage = LastOutlookSummary;
    }

    private async Task RunPstPipelineAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("New Default PST Pipeline", "Microsoft Outlook", isOutlookTarget: true)) return;
        await ExecuteAsync("New Default PST Pipeline", () =>
        {
            var res = _outlookService.RunNewDefaultPstPipeline(TargetPstPath, SourcePstPath);
            RefreshDataFilesCore();
            if (res.Success)
            {
                foreach (var item in DataFiles)
                {
                    if (string.Equals(item.FilePath, TargetPstPath, StringComparison.OrdinalIgnoreCase))
                    {
                        SelectedDataFile = item;
                        break;
                    }
                }
            }
            LastOutlookSummary = res.Success
                ? $"New Default PST pipeline finished: Cloned {res.FoldersClonedCount} folders, migrated {res.RulesMigratedCount} rules."
                : $"PST Pipeline failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task RelocatePstAsync()
    {
        if (SelectedDataFile == null) return;
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Relocate PST Data File", "Microsoft Outlook", isOutlookTarget: true)) return;
        await ExecuteAsync("Relocate PST Data File", () =>
        {
            if (SelectedDataFile == null) return Task.CompletedTask;
            var res = _outlookService.RelocateDataFile(SelectedDataFile.FilePath, RelocationDestinationDir);
            RefreshDataFilesCore();
            if (res.Success)
            {
                foreach (var item in DataFiles)
                {
                    if (string.Equals(item.FilePath, res.DestinationPath, StringComparison.OrdinalIgnoreCase))
                    {
                        SelectedDataFile = item;
                        break;
                    }
                }
            }
            LastOutlookSummary = res.Success
                ? $"Relocated to '{res.DestinationPath}' with verified SHA-256 and symlink."
                : $"Relocation failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task CompactPstAsync()
    {
        if (SelectedDataFile == null) return;
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Compact PST Data File", "Microsoft Outlook", isOutlookTarget: true)) return;
        await ExecuteAsync("Compact PST Data File", () =>
        {
            if (SelectedDataFile == null) return Task.CompletedTask;
            var res = _outlookService.CompactDataFile(SelectedDataFile.FilePath);
            LastOutlookSummary = res.Success ? "Data file compacted successfully." : $"Compact failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task BackupPstAsync()
    {
        if (SelectedDataFile == null) return;
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Backup PST Data File", "Microsoft Outlook", isOutlookTarget: true)) return;
        await ExecuteAsync("Backup PST Data File", () =>
        {
            if (SelectedDataFile == null) return Task.CompletedTask;
            var res = _outlookService.BackupDataFile(SelectedDataFile.FilePath, BackupDirectory);
            LastOutlookSummary = res.Success ? $"PST backed up with verified SHA-256: {res.BackupPath}" : $"Backup failed: {res.Message}";
            return Task.CompletedTask;
        });
    }
}
