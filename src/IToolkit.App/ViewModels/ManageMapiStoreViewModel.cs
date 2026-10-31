namespace IToolkit.App.ViewModels;

using System;
using System.IO;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Office;

/// <summary>
/// Dedicated ViewModel for managing a single MAPI store / PST / OST entity.
/// Encapsulates per-store lifecycle and isolated entity operations:
/// - Mailbox Maintenance & Compaction
/// - New Default PST Pipeline
/// - Data File Relocation (with 1.2x headroom & SHA-256 verification)
/// - Data File Backup (with SHA-256 manifest verification)
/// </summary>
public class ManageMapiStoreViewModel : ViewModelBase
{
    private readonly IOutlookService _outlookService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private readonly IDialogService? _dialogService;

    private string _sourcePstPath;
    private string _targetPstPath;
    private string _relocationDestinationDir;
    private string _backupDirectory;
    private string _operationStatus = "Ready";
    private bool _isStoreRelocated;

    public event Action? RequestClose;

    public ManageMapiStoreViewModel(
        MapiDataFileInfo store,
        IOutlookService outlookService,
        ISafetyConfirmationService? confirmationService = null,
        IDialogService? dialogService = null,
        IActivityLogger? logger = null,
        string? defaultRelocationDir = null,
        string? defaultBackupDir = null)
        : base(logger)
    {
        Store = store ?? throw new ArgumentNullException(nameof(store));
        _outlookService = outlookService ?? throw new ArgumentNullException(nameof(outlookService));
        _confirmationService = confirmationService;
        _dialogService = dialogService;

        _sourcePstPath = store.FilePath;
        _targetPstPath = BuildSuggestedTargetPstPath(store);
        _relocationDestinationDir = !string.IsNullOrWhiteSpace(defaultRelocationDir) ? defaultRelocationDir : @"D:\OutlookFiles";
        _backupDirectory = !string.IsNullOrWhiteSpace(defaultBackupDir) ? defaultBackupDir : @"D:\OutlookBackups";

        QuickMailRepairCommand = new AsyncRelayCommand(QuickMailRepairAsync, () => IsNotBusy);
        CompactStoreCommand = new AsyncRelayCommand(CompactStoreAsync, () => IsNotBusy);
        RelocateStoreCommand = new AsyncRelayCommand(RelocateStoreAsync, () => IsNotBusy);
        BackupStoreCommand = new AsyncRelayCommand(BackupStoreAsync, () => IsNotBusy);
        RunPipelineCommand = new AsyncRelayCommand(RunPipelineAsync, () => IsNotBusy);

        BrowseSourcePstCommand = new RelayCommand(BrowseSourcePst, () => IsNotBusy);
        BrowseTargetPstCommand = new RelayCommand(BrowseTargetPst, () => IsNotBusy);
        BrowseRelocationDirCommand = new RelayCommand(BrowseRelocationDir, () => IsNotBusy);
        OpenRelocationDirCommand = new RelayCommand(OpenRelocationDir, () => IsNotBusy && !string.IsNullOrWhiteSpace(RelocationDestinationDir));
        BrowseBackupDirCommand = new RelayCommand(BrowseBackupDir, () => IsNotBusy);
        OpenBackupDirCommand = new RelayCommand(OpenBackupDir, () => IsNotBusy && !string.IsNullOrWhiteSpace(BackupDirectory));
        CloseCommand = new RelayCommand(Close);
    }

    public MapiDataFileInfo Store { get; }

    public string DisplayName => Store.DisplayName;
    public string ProfileName => Store.ProfileName;
    public string Format => Store.Format;
    public string FileSizeFormatted => Store.FileSizeFormatted;
    public string FilePath => Store.FilePath;
    public string RegistryPath => Store.RegistryPath;
    public bool ExistsOnDisk => Store.ExistsOnDisk;
    public bool IsOst => Store.IsOst;
    public bool IsPst => Store.IsPst;

    public string HeaderSummary => $"{DisplayName}  |  Profile: {ProfileName}  |  {Format} ({FileSizeFormatted})";

    public string SourcePstPath
    {
        get => _sourcePstPath;
        set => SetProperty(ref _sourcePstPath, value);
    }

    public string TargetPstPath
    {
        get => _targetPstPath;
        set => SetProperty(ref _targetPstPath, value);
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

    public string OperationStatus
    {
        get => _operationStatus;
        set => SetProperty(ref _operationStatus, value);
    }

    public bool IsStoreRelocated => _isStoreRelocated;

    public IAsyncRelayCommand QuickMailRepairCommand { get; }
    public IAsyncRelayCommand CompactStoreCommand { get; }
    public IAsyncRelayCommand RelocateStoreCommand { get; }
    public IAsyncRelayCommand RelocateSelectedPstCommand => RelocateStoreCommand;
    public IAsyncRelayCommand BackupStoreCommand { get; }
    public IAsyncRelayCommand BackupSelectedPstCommand => BackupStoreCommand;
    public IAsyncRelayCommand RunPipelineCommand { get; }
    public IAsyncRelayCommand CreateAndSetDefaultPstCommand => RunPipelineCommand;

    public IRelayCommand BrowseSourcePstCommand { get; }
    public IRelayCommand BrowseTargetPstCommand { get; }
    public IRelayCommand BrowseRelocationDirCommand { get; }
    public IRelayCommand OpenRelocationDirCommand { get; }
    public IRelayCommand BrowseBackupDirCommand { get; }
    public IRelayCommand OpenBackupDirCommand { get; }
    public IRelayCommand CloseCommand { get; }

    private void Close()
    {
        RequestClose?.Invoke();
    }

    private static string BuildSuggestedTargetPstPath(MapiDataFileInfo store)
    {
        string baseName = !string.IsNullOrWhiteSpace(store.DisplayName)
            ? Path.GetFileNameWithoutExtension(store.DisplayName)
            : Path.GetFileNameWithoutExtension(store.FilePath);
        if (string.IsNullOrWhiteSpace(baseName))
        {
            return @"C:\OutlookFiles\NewDefaultStore.pst";
        }
        foreach (char invalid in Path.GetInvalidFileNameChars())
        {
            baseName = baseName.Replace(invalid, '_');
        }
        return Path.Combine(@"C:\OutlookFiles", $"{baseName.Trim()}_NewDefaultStore.pst");
    }

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

    private async Task<bool> ConfirmSaveAppWorkBeforeFixAsync(string operationName)
    {
        if (_confirmationService == null)
        {
            return true;
        }

        bool confirmed = await _confirmationService.ConfirmAsync(
            $"Save Work Before {operationName} (Microsoft Outlook)",
            $"Please save and back up all open files and data in Microsoft Outlook before running '{operationName}' to prevent data loss.",
            $"Microsoft Outlook will be safely closed before executing '{operationName}' and automatically restarted once the fix completes. Do you want to proceed?");

        if (!confirmed)
        {
            string cancelMsg = $"{operationName} cancelled by user (save work in Microsoft Outlook first).";
            OperationStatus = cancelMsg;
            Logger?.LogWarning(nameof(ManageMapiStoreViewModel), cancelMsg);
            return false;
        }

        return true;
    }

    private async Task QuickMailRepairAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Quick Mail & Cache Repair")) return;
        await ExecuteAsync("Quick Mail & Cache Repair", () =>
        {
            string? prof = string.Equals(ProfileName, "Default", StringComparison.OrdinalIgnoreCase) ? null : ProfileName;
            var res = _outlookService.QuickMailAndCacheRepair(prof);
            OperationStatus = res.Success
                ? $"Mailbox repaired for '{DisplayName}': Outbox purged, SRS reset, RoamCache cleaned, NavPane reset."
                : $"Quick Mail Repair failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task CompactStoreAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Compact Store")) return;
        await ExecuteAsync("Compact Store", () =>
        {
            var res = _outlookService.CompactDataFile(FilePath);
            OperationStatus = res.Success ? $"Data file '{DisplayName}' compacted successfully." : $"Compact failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task RelocateStoreAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Relocate Store")) return;
        await ExecuteAsync("Relocate Store", () =>
        {
            var res = _outlookService.RelocateDataFile(Store, RelocationDestinationDir);
            if (res.Success)
            {
                _isStoreRelocated = true;
                OperationStatus = $"Relocated to '{res.DestinationPath}' with verified SHA-256.";
            }
            else
            {
                OperationStatus = $"Relocation failed: {res.Message}";
            }
            return Task.CompletedTask;
        });
    }

    private async Task BackupStoreAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("Backup Store")) return;
        await ExecuteAsync("Backup Store", () =>
        {
            var res = _outlookService.BackupDataFile(FilePath, BackupDirectory);
            OperationStatus = res.Success ? $"Store backed up with verified SHA-256: {res.BackupPath}" : $"Backup failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

    private async Task RunPipelineAsync()
    {
        if (!await ConfirmSaveAppWorkBeforeFixAsync("New Default PST Pipeline")) return;
        await ExecuteAsync("New Default PST Pipeline", () =>
        {
            var res = _outlookService.RunNewDefaultPstPipeline(TargetPstPath, SourcePstPath);
            if (res.Success)
            {
                _isStoreRelocated = true;
                OperationStatus = $"New Default PST pipeline finished: Cloned {res.FoldersClonedCount} folders, migrated {res.RulesMigratedCount} rules.";
            }
            else
            {
                OperationStatus = $"PST Pipeline failed: {res.Message}";
            }
            return Task.CompletedTask;
        });
    }
}
