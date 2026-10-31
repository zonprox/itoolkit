namespace IToolkit.App.ViewModels;

using System;
using System.IO;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Identity;

/// <summary>
/// Dedicated ViewModel for managing a single LocalAccountItem entity.
/// Encapsulates per-entity lifecycle and scoped mutation operations (Unlock, ToggleEnabled, ResetPassword, RemoveAccount, Backup).
/// </summary>
public class ManageLocalAccountViewModel : ViewModelBase
{
    private readonly IIdentityService _identityService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private readonly IBackupService? _backupService;
    private readonly IDialogService? _dialogService;

    private bool _isEnabled;
    private bool _isLocked;
    private string _newPassword = string.Empty;
    private string _backupDestinationDirectory = string.Empty;
    private bool _isAccountRemoved;

    public event Action? RequestClose;

    public ManageLocalAccountViewModel(
        LocalAccountItem account,
        IIdentityService identityService,
        ISafetyConfirmationService? confirmationService = null,
        IBackupService? backupService = null,
        IDialogService? dialogService = null,
        IActivityLogger? logger = null)
        : base(logger)
    {
        Account = account ?? throw new ArgumentNullException(nameof(account));
        _identityService = identityService ?? throw new ArgumentNullException(nameof(identityService));
        _confirmationService = confirmationService;
        _backupService = backupService;
        _dialogService = dialogService;

        _isEnabled = account.IsEnabled;
        _isLocked = account.IsLocked;

        UnlockCommand = new AsyncRelayCommand(UnlockAsync, () => IsNotBusy);
        ToggleEnabledCommand = new AsyncRelayCommand(ToggleEnabledAsync, () => IsNotBusy);
        ResetPasswordCommand = new AsyncRelayCommand(ResetPasswordAsync, () => IsNotBusy && !string.IsNullOrWhiteSpace(NewPassword));
        RemoveAccountCommand = new AsyncRelayCommand(RemoveAccountAsync, () => IsNotBusy && !IsBuiltInAdmin);
        BackupUserCommand = new AsyncRelayCommand(BackupUserAsync, () => IsNotBusy);
        BrowseBackupDestinationCommand = new RelayCommand(BrowseBackupDestination);
        CloseCommand = new RelayCommand(Close);
    }

    public LocalAccountItem Account { get; }

    public string Username => Account.Username;

    public string Sid => Account.Sid;

    public bool IsAdmin => Account.IsAdmin;

    public bool IsBuiltInAdmin => Account.IsBuiltInAdmin;

    public bool IsEnabled
    {
        get => _isEnabled;
        set
        {
            if (SetProperty(ref _isEnabled, value))
            {
                ToggleEnabledCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool IsLocked
    {
        get => _isLocked;
        set
        {
            if (SetProperty(ref _isLocked, value))
            {
                UnlockCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string NewPassword
    {
        get => _newPassword;
        set
        {
            if (SetProperty(ref _newPassword, value))
            {
                ResetPasswordCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BackupDestinationDirectory
    {
        get => _backupDestinationDirectory;
        set => SetProperty(ref _backupDestinationDirectory, value);
    }

    public bool IsAccountRemoved
    {
        get => _isAccountRemoved;
        private set => SetProperty(ref _isAccountRemoved, value);
    }

    public IAsyncRelayCommand UnlockCommand { get; }

    public IAsyncRelayCommand ToggleEnabledCommand { get; }

    public IAsyncRelayCommand ResetPasswordCommand { get; }

    public IAsyncRelayCommand RemoveAccountCommand { get; }

    public IAsyncRelayCommand BackupUserCommand { get; }

    public IRelayCommand BrowseBackupDestinationCommand { get; }

    public IRelayCommand CloseCommand { get; }

    private async Task UnlockAsync() => await ExecuteAsync($"Unlock Account '{Username}'", () =>
    {
        Logger?.LogInfo(nameof(ManageLocalAccountViewModel), $"Unlocking targeted account '{Username}'...");
        bool ok = _identityService.UnlockLocalAccount(Username);
        if (ok)
        {
            IsLocked = false;
            StatusMessage = $"Account '{Username}' unlocked successfully.";
            Logger?.LogSuccess(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        else
        {
            StatusMessage = $"Failed to unlock account '{Username}'.";
            Logger?.LogError(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        return Task.CompletedTask;
    });

    private async Task ToggleEnabledAsync() => await ExecuteAsync($"Toggle Enabled '{Username}'", () =>
    {
        bool targetState = !IsEnabled;
        Logger?.LogInfo(nameof(ManageLocalAccountViewModel), $"Setting targeted account '{Username}' active={targetState}...");
        bool ok = _identityService.SetAccountEnabled(Username, targetState);
        if (ok)
        {
            IsEnabled = targetState;
            StatusMessage = $"Account '{Username}' {(targetState ? "enabled" : "disabled")} successfully.";
            Logger?.LogSuccess(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        else
        {
            StatusMessage = $"Failed to change state for account '{Username}'.";
            Logger?.LogError(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        return Task.CompletedTask;
    });

    private async Task ResetPasswordAsync() => await ExecuteAsync($"Reset Password for '{Username}'", () =>
    {
        if (string.IsNullOrWhiteSpace(NewPassword))
        {
            return Task.CompletedTask;
        }

        Logger?.LogInfo(nameof(ManageLocalAccountViewModel), $"Resetting password for targeted account '{Username}'...");
        bool ok = _identityService.ResetUserPassword(Username, NewPassword);
        if (ok)
        {
            NewPassword = string.Empty;
            StatusMessage = $"Password for '{Username}' reset successfully.";
            Logger?.LogSuccess(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        else
        {
            StatusMessage = $"Failed to reset password for '{Username}'.";
            Logger?.LogError(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        return Task.CompletedTask;
    });

    private async Task RemoveAccountAsync()
    {
        if (IsBuiltInAdmin)
        {
            StatusMessage = "Cannot delete built-in Administrator account (SID -500).";
            Logger?.LogWarning(nameof(ManageLocalAccountViewModel), StatusMessage);
            return;
        }

        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Account Deletion",
                $"Are you sure you want to permanently delete local user account '{Username}'?",
                $"Account SID: {Sid}. This account and its credentials will be permanently removed from SAM. This action cannot be undone.");
            if (!confirmed)
            {
                StatusMessage = $"Account removal of '{Username}' cancelled by user.";
                Logger?.LogWarning(nameof(ManageLocalAccountViewModel), StatusMessage);
                return;
            }
        }

        await ExecuteAsync($"Remove Account '{Username}'", () =>
        {
            Logger?.LogInfo(nameof(ManageLocalAccountViewModel), $"Deleting targeted account '{Username}' (SID: {Sid})...");
            bool ok = _identityService.RemoveLocalAccount(Username, Sid);
            if (ok)
            {
                IsAccountRemoved = true;
                StatusMessage = $"Account '{Username}' removed successfully.";
                Logger?.LogSuccess(nameof(ManageLocalAccountViewModel), StatusMessage);
                RequestClose?.Invoke();
            }
            else
            {
                StatusMessage = $"Failed to remove account '{Username}'.";
                Logger?.LogError(nameof(ManageLocalAccountViewModel), StatusMessage);
            }
            return Task.CompletedTask;
        });
    }

    private async Task BackupUserAsync() => await ExecuteAsync($"Backup Profile for '{Username}'", () =>
    {
        if (_backupService == null)
        {
            StatusMessage = "Backup service is unavailable.";
            Logger?.LogWarning(nameof(ManageLocalAccountViewModel), StatusMessage);
            return Task.CompletedTask;
        }

        Logger?.LogInfo(nameof(ManageLocalAccountViewModel), $"Initiating targeted profile backup for user '{Username}'...");
        var map = _backupService.GetUserProfileMap(Username);

        string destination = !string.IsNullOrWhiteSpace(BackupDestinationDirectory)
            ? BackupDestinationDirectory
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iToolKit", "Backups", Username);

        var syncRes = _backupService.RunRobocopySync(map.ProfilePath, destination, false);
        if (syncRes.IsSuccess)
        {
            StatusMessage = $"Profile backup for '{Username}' completed successfully to '{destination}'.";
            Logger?.LogSuccess(nameof(ManageLocalAccountViewModel), StatusMessage);
        }
        else
        {
            StatusMessage = $"Profile backup for '{Username}' exited with code {syncRes.ExitCode}.";
            Logger?.LogError(nameof(ManageLocalAccountViewModel), StatusMessage);
        }

        return Task.CompletedTask;
    });

    private void BrowseBackupDestination()
    {
        if (_dialogService == null) return;
        var folder = _dialogService.ShowOpenFolderDialog($"Select Backup Folder for '{Username}'", BackupDestinationDirectory);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            BackupDestinationDirectory = folder;
        }
    }

    private void Close()
    {
        RequestClose?.Invoke();
    }
}
