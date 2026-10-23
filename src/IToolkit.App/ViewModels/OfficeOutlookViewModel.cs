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
        IActivityLogger? logger = null)
        : base(logger)
    {
        _officeSuiteService = officeSuiteService ?? throw new ArgumentNullException(nameof(officeSuiteService));
        _outlookService = outlookService ?? throw new ArgumentNullException(nameof(outlookService));

        DataFiles = new ObservableCollection<MapiDataFileInfo>();

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
        set => SetProperty(ref _relocationDestinationDir, value);
    }

    public string BackupDirectory
    {
        get => _backupDirectory;
        set => SetProperty(ref _backupDirectory, value);
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
    public IAsyncRelayCommand RelocatePstCommand { get; }
    public IAsyncRelayCommand CompactPstCommand { get; }
    public IAsyncRelayCommand BackupPstCommand { get; }

    private async Task RepairC2RAsync() => await ExecuteAsync("Office Click-to-Run Repair", () =>
    {
        var res = _officeSuiteService.RunClickToRunRepair(UseOnlineC2RRepair);
        LastOfficeSummary = res.ExitCode == 0 ? "C2R Repair triggered successfully." : $"C2R Repair failed (Exit {res.ExitCode}).";
        return Task.CompletedTask;
    });

    private async Task RepairC2RServiceAsync() => await ExecuteAsync("Repair Click-to-Run Service", () =>
    {
        bool ok = _officeSuiteService.RepairClickToRunService();
        LastOfficeSummary = ok ? "Click-to-Run service configuration and state repaired." : "Click-to-Run service repair failed.";
        return Task.CompletedTask;
    });

    private async Task ResetOfficeIdentityAsync() => await ExecuteAsync("Reset Office Identity & WAM Tokens", () =>
    {
        var res = _officeSuiteService.ResetOfficeIdentityCache();
        LastOfficeSummary = res.Success ? "Office Identity & OneAuth token caches purged." : $"Reset failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task ToggleHardwareAccelerationAsync() => await ExecuteAsync("Toggle Hardware Acceleration", () =>
    {
        var res = _officeSuiteService.SetHardwareAcceleration(DisableHardwareAcceleration);
        LastOfficeSummary = res.Success ? $"Hardware Acceleration set to: {(DisableHardwareAcceleration ? "Disabled" : "Enabled")}." : $"Toggle failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task TerminateOfficeProcessesAsync() => await ExecuteAsync("Terminate Office Processes", () =>
    {
        bool ok = _officeSuiteService.TerminateOfficeProcesses();
        LastOfficeSummary = ok ? "All running Office processes terminated safely." : "Failed to terminate some Office processes.";
        return Task.CompletedTask;
    });

    private async Task ScrubOfficeSuiteAsync() => await ExecuteAsync("Scrub Office Suite", () =>
    {
        var res = _officeSuiteService.ScrubOfficeSuiteCleanly();
        LastOfficeSummary = res.Success ? "Office suite scrubber completed successfully." : $"Scrubber failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task WordQuickRepairAsync() => await ExecuteAsync("Word Quick Repair", () =>
    {
        var res = _officeSuiteService.WordQuickRepair();
        LastOfficeSummary = res.Success ? $"Word Repaired: Normal.dotm reset, {res.AddInsDisabledCount} add-ins isolated, locks cleaned." : "Word Repair encountered issues.";
        return Task.CompletedTask;
    });

    private async Task ExcelQuickRepairAsync() => await ExecuteAsync("Excel Quick Repair", () =>
    {
        var res = _officeSuiteService.ExcelQuickRepair();
        LastOfficeSummary = res.Success ? "Excel Repaired: XLSTART isolated, UI cache cleared, DDE/resiliency reset." : "Excel Repair encountered issues.";
        return Task.CompletedTask;
    });

    private async Task PowerPointQuickRepairAsync() => await ExecuteAsync("PowerPoint Quick Repair", () =>
    {
        var res = _officeSuiteService.PowerPointQuickRepair();
        LastOfficeSummary = res.Success ? "PowerPoint Repaired: Font/slide cache cleared, resiliency purged." : "PowerPoint Repair encountered issues.";
        return Task.CompletedTask;
    });

    private async Task QuickMailRepairAsync() => await ExecuteAsync("Quick Mail & Cache Repair", () =>
    {
        var res = _outlookService.QuickMailAndCacheRepair();
        LastOfficeSummary = res.Success
            ? "Mailbox repaired: Outbox purged, SRS reset, RoamCache cleaned (AutoComplete preserved), NavPane reset."
            : $"Quick Mail Repair failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task Expand100GBAsync() => await ExecuteAsync("Expand PST/OST Limit to 100GB", () =>
    {
        var res = _outlookService.ExpandDataFileLimitsTo100GB();
        LastOutlookSummary = res.Success ? "Registry MaxLargeFileSize expanded to 100GB (102400 MB)." : $"Expansion failed: {res.Message}";
        return Task.CompletedTask;
    });

    public async Task DiscoverDataFilesAsync() => await ExecuteAsync("Discover Outlook Data Files", () =>
    {
        var files = _outlookService.DiscoverDataFiles();
        DataFiles.Clear();
        foreach (var file in files)
        {
            DataFiles.Add(file);
        }
        LastOutlookSummary = $"Discovered {files.Count} PST/OST files in MAPI profiles.";
        return Task.CompletedTask;
    });

    private async Task RunPstPipelineAsync() => await ExecuteAsync("New Default PST Pipeline", () =>
    {
        var res = _outlookService.RunNewDefaultPstPipeline(TargetPstPath, SourcePstPath);
        LastOutlookSummary = res.Success
            ? $"New Default PST pipeline finished: Cloned {res.FoldersClonedCount} folders, migrated {res.RulesMigratedCount} rules."
            : $"PST Pipeline failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task RelocatePstAsync() => await ExecuteAsync("Relocate PST Data File", () =>
    {
        if (SelectedDataFile == null) return Task.CompletedTask;
        var res = _outlookService.RelocateDataFile(SelectedDataFile.FilePath, RelocationDestinationDir);
        LastOutlookSummary = res.Success
            ? $"Relocated to '{res.DestinationPath}' with verified SHA-256 and symlink."
            : $"Relocation failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task CompactPstAsync() => await ExecuteAsync("Compact PST Data File", () =>
    {
        if (SelectedDataFile == null) return Task.CompletedTask;
        var res = _outlookService.CompactDataFile(SelectedDataFile.FilePath);
        LastOutlookSummary = res.Success ? "Data file compacted successfully." : $"Compact failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task BackupPstAsync() => await ExecuteAsync("Backup PST Data File", () =>
    {
        if (SelectedDataFile == null) return Task.CompletedTask;
        var res = _outlookService.BackupDataFile(SelectedDataFile.FilePath, BackupDirectory);
        LastOutlookSummary = res.Success ? $"PST backed up with verified SHA-256: {res.BackupPath}" : $"Backup failed: {res.Message}";
        return Task.CompletedTask;
    });
}
