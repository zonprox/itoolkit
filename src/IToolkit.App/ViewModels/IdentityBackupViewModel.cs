namespace IToolkit.App.ViewModels;

using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Identity;

public class IdentityBackupViewModel : ViewModelBase
{
    private readonly IIdentityService _identityService;
    private readonly IBackupService _backupService;
    private readonly IDialogService? _dialogService;
    private readonly ISafetyConfirmationService? _confirmationService;

    private LocalAccountItem? _selectedAccount;
    private string _builtInAdminName = "Administrator (SID -500)";
    private bool _isBuiltInAdminEnabled;
    private string _newAdminPassword = string.Empty;
    private string _newAccountUsername = string.Empty;
    private string _newAccountPassword = string.Empty;
    private string? _newAccountDescription;
    private bool _newAccountIsAdmin;
    private string _domainTestName = "corp.local";
    private string _domainUserSamName = string.Empty;

    private string _backupDestinationDirectory = @"D:\UserBackups";
    private string _restoreBackupDirectory = @"D:\UserBackups";
    private string _certificateStoreName = "My";
    private string? _certificatePassword;
    private bool _includeBookmarks = true;
    private bool _includeCertificates = true;
    private bool _robocopyMirror;
    private bool _createManifest = true;

    private string _lastIdentityStatus = "Ready";
    private string _lastBackupStatus = "Ready";

    public IdentityBackupViewModel(
        IIdentityService identityService,
        IBackupService backupService,
        IActivityLogger? logger = null,
        IDialogService? dialogService = null,
        ISafetyConfirmationService? confirmationService = null)
        : base(logger)
    {
        _identityService = identityService ?? throw new ArgumentNullException(nameof(identityService));
        _backupService = backupService ?? throw new ArgumentNullException(nameof(backupService));
        _dialogService = dialogService;
        _confirmationService = confirmationService;

        Accounts = new ObservableCollection<LocalAccountItem>();

        // Smart Path Commands
        BrowseBackupDestinationCommand = new RelayCommand(BrowseBackupDestination, () => IsNotBusy);
        OpenBackupDestinationCommand = new RelayCommand(OpenBackupDestination, () => IsNotBusy && !string.IsNullOrWhiteSpace(BackupDestinationDirectory));
        BrowseRestoreBackupCommand = new RelayCommand(BrowseRestoreBackup, () => IsNotBusy);
        OpenRestoreBackupCommand = new RelayCommand(OpenRestoreBackup, () => IsNotBusy && !string.IsNullOrWhiteSpace(RestoreBackupDirectory));

        // Commands
        RefreshAccountsCommand = new AsyncRelayCommand(RefreshAccountsAsync, () => IsNotBusy);
        EnableBuiltInAdminCommand = new AsyncRelayCommand(EnableBuiltInAdminAsync, () => IsNotBusy);
        ResetAdminPasswordCommand = new AsyncRelayCommand(ResetAdminPasswordAsync, () => IsNotBusy && !string.IsNullOrWhiteSpace(NewAdminPassword));
        CreateAccountCommand = new AsyncRelayCommand(CreateAccountAsync, () => IsNotBusy && !string.IsNullOrWhiteSpace(NewAccountUsername) && !string.IsNullOrWhiteSpace(NewAccountPassword));
        UnlockAccountCommand = new AsyncRelayCommand(UnlockAccountAsync, () => IsNotBusy && SelectedAccount != null);
        ToggleAccountEnabledCommand = new AsyncRelayCommand(ToggleAccountEnabledAsync, () => IsNotBusy && SelectedAccount != null);
        RemoveAccountCommand = new AsyncRelayCommand(RemoveAccountAsync, () => IsNotBusy && SelectedAccount != null);

        TestDomainReachabilityCommand = new AsyncRelayCommand(TestDomainReachabilityAsync, () => IsNotBusy && !string.IsNullOrEmpty(DomainTestName));
        UnlockDomainUserCommand = new AsyncRelayCommand(UnlockDomainUserAsync, () => IsNotBusy && !string.IsNullOrEmpty(DomainTestName) && !string.IsNullOrEmpty(DomainUserSamName));

        ExecuteProfileBackupCommand = new AsyncRelayCommand(ExecuteProfileBackupAsync, () => IsNotBusy && !string.IsNullOrEmpty(BackupDestinationDirectory));
        ValidateBackupManifestCommand = new AsyncRelayCommand(ValidateBackupManifestAsync, () => IsNotBusy && !string.IsNullOrEmpty(RestoreBackupDirectory));
        RestoreProfileCommand = new AsyncRelayCommand(RestoreProfileAsync, () => IsNotBusy && !string.IsNullOrEmpty(RestoreBackupDirectory));
    }

    public ObservableCollection<LocalAccountItem> Accounts { get; }

    public LocalAccountItem? SelectedAccount
    {
        get => _selectedAccount;
        set
        {
            if (SetProperty(ref _selectedAccount, value))
            {
                UnlockAccountCommand.RaiseCanExecuteChanged();
                ToggleAccountEnabledCommand.RaiseCanExecuteChanged();
                RemoveAccountCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BuiltInAdminName
    {
        get => _builtInAdminName;
        set => SetProperty(ref _builtInAdminName, value);
    }

    public bool IsBuiltInAdminEnabled
    {
        get => _isBuiltInAdminEnabled;
        set => SetProperty(ref _isBuiltInAdminEnabled, value);
    }

    public string NewAdminPassword
    {
        get => _newAdminPassword;
        set
        {
            if (SetProperty(ref _newAdminPassword, value))
            {
                ResetAdminPasswordCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string NewAccountUsername
    {
        get => _newAccountUsername;
        set
        {
            if (SetProperty(ref _newAccountUsername, value))
            {
                CreateAccountCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string NewAccountPassword
    {
        get => _newAccountPassword;
        set
        {
            if (SetProperty(ref _newAccountPassword, value))
            {
                CreateAccountCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string? NewAccountDescription
    {
        get => _newAccountDescription;
        set => SetProperty(ref _newAccountDescription, value);
    }

    public bool NewAccountIsAdmin
    {
        get => _newAccountIsAdmin;
        set => SetProperty(ref _newAccountIsAdmin, value);
    }

    public string DomainTestName
    {
        get => _domainTestName;
        set
        {
            if (SetProperty(ref _domainTestName, value))
            {
                TestDomainReachabilityCommand.RaiseCanExecuteChanged();
                UnlockDomainUserCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string DomainUserSamName
    {
        get => _domainUserSamName;
        set
        {
            if (SetProperty(ref _domainUserSamName, value))
            {
                UnlockDomainUserCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BackupDestinationDirectory
    {
        get => _backupDestinationDirectory;
        set
        {
            if (SetProperty(ref _backupDestinationDirectory, value))
            {
                ExecuteProfileBackupCommand.RaiseCanExecuteChanged();
                OpenBackupDestinationCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string RestoreBackupDirectory
    {
        get => _restoreBackupDirectory;
        set
        {
            if (SetProperty(ref _restoreBackupDirectory, value))
            {
                ValidateBackupManifestCommand.RaiseCanExecuteChanged();
                RestoreProfileCommand.RaiseCanExecuteChanged();
                OpenRestoreBackupCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string CertificateStoreName
    {
        get => _certificateStoreName;
        set => SetProperty(ref _certificateStoreName, value);
    }

    public string? CertificatePassword
    {
        get => _certificatePassword;
        set => SetProperty(ref _certificatePassword, value);
    }

    public bool IncludeBookmarks
    {
        get => _includeBookmarks;
        set => SetProperty(ref _includeBookmarks, value);
    }

    public bool IncludeCertificates
    {
        get => _includeCertificates;
        set => SetProperty(ref _includeCertificates, value);
    }

    public bool RobocopyMirror
    {
        get => _robocopyMirror;
        set => SetProperty(ref _robocopyMirror, value);
    }

    public bool CreateManifest
    {
        get => _createManifest;
        set => SetProperty(ref _createManifest, value);
    }

    public string LastIdentityStatus
    {
        get => _lastIdentityStatus;
        set => SetProperty(ref _lastIdentityStatus, value);
    }

    public string LastBackupStatus
    {
        get => _lastBackupStatus;
        set => SetProperty(ref _lastBackupStatus, value);
    }

    public IRelayCommand BrowseBackupDestinationCommand { get; }
    public IRelayCommand OpenBackupDestinationCommand { get; }
    public IRelayCommand BrowseRestoreBackupCommand { get; }
    public IRelayCommand OpenRestoreBackupCommand { get; }

    public IAsyncRelayCommand RefreshAccountsCommand { get; }
    public IAsyncRelayCommand EnableBuiltInAdminCommand { get; }
    public IAsyncRelayCommand ResetAdminPasswordCommand { get; }
    public IAsyncRelayCommand CreateAccountCommand { get; }
    public IAsyncRelayCommand UnlockAccountCommand { get; }
    public IAsyncRelayCommand ToggleAccountEnabledCommand { get; }
    public IAsyncRelayCommand RemoveAccountCommand { get; }

    public IAsyncRelayCommand TestDomainReachabilityCommand { get; }
    public IAsyncRelayCommand UnlockDomainUserCommand { get; }

    public IAsyncRelayCommand ExecuteProfileBackupCommand { get; }
    public IAsyncRelayCommand ValidateBackupManifestCommand { get; }
    public IAsyncRelayCommand RestoreProfileCommand { get; }

    private void BrowseBackupDestination()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFolderDialog(
            "Select User Profile Backup Destination",
            BackupDestinationDirectory);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            BackupDestinationDirectory = selected;
        }
    }

    private void OpenBackupDestination()
    {
        if (_dialogService == null || string.IsNullOrWhiteSpace(BackupDestinationDirectory)) return;
        _dialogService.OpenFolderInExplorer(BackupDestinationDirectory);
    }

    private void BrowseRestoreBackup()
    {
        if (_dialogService == null) return;
        string? selected = _dialogService.ShowOpenFolderDialog(
            "Select User Profile Backup Source",
            RestoreBackupDirectory);
        if (!string.IsNullOrWhiteSpace(selected))
        {
            RestoreBackupDirectory = selected;
        }
    }

    private void OpenRestoreBackup()
    {
        if (_dialogService == null || string.IsNullOrWhiteSpace(RestoreBackupDirectory)) return;
        _dialogService.OpenFolderInExplorer(RestoreBackupDirectory);
    }

    public void AutoDetectDomain()
    {
        DomainTestName = DetectDomain();
    }

    public static string DetectDomain()
    {
        try
        {
            string? domain = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().DomainName;
            if (!string.IsNullOrWhiteSpace(domain))
            {
                return domain;
            }

            string? userDomain = Environment.UserDomainName;
            if (!string.IsNullOrWhiteSpace(userDomain))
            {
                return userDomain;
            }

            return "corp.local";
        }
        catch
        {
            return "corp.local";
        }
    }

    public async Task RefreshAccountsAsync() => await ExecuteAsync("Query Local Accounts", () =>
    {
        RefreshAccountsCore();
        LastIdentityStatus = $"Loaded {Accounts.Count} local user accounts.";
        return Task.CompletedTask;
    });

    public async Task ScanIdentityAsync()
    {
        try
        {
            IsBusy = true;
            StatusMessage = "Scanning local user accounts, Built-in Administrator, and profile paths...";
            Logger?.LogInfo(nameof(IdentityBackupViewModel), "Scanning local user accounts, Built-in Administrator, and profile paths...");
            var (accounts, admin, profileMap) = await Task.Run(() =>
            {
                var accs = _identityService.GetLocalAccounts() ?? Array.Empty<LocalAccountItem>();
                LocalAccountItem? builtIn = null;
                foreach (var a in accs)
                {
                    if (a.IsBuiltInAdmin)
                    {
                        builtIn = a;
                        break;
                    }
                }
                builtIn ??= _identityService.GetBuiltInAdministrator();
                UserProfileMap? map = null;
                try { map = _backupService.GetUserProfileMap(); } catch { }
                return (accs, builtIn, map);
            });

            Accounts.Clear();
            foreach (var acc in accounts)
            {
                Accounts.Add(acc);
            }

            if (SelectedAccount == null && Accounts.Count > 0)
            {
                SelectedAccount = Accounts[0];
            }

            if (admin != null)
            {
                BuiltInAdminName = $"{admin.Username} ({admin.Sid})";
                IsBuiltInAdminEnabled = admin.IsEnabled;
            }

            AutoDetectDomain();

            LastIdentityStatus = $"Loaded {Accounts.Count} local user accounts (Built-in Admin: {(IsBuiltInAdminEnabled ? "Enabled" : "Disabled")}).";
            if (profileMap != null)
            {
                LastBackupStatus = $"Active profile mapped: {profileMap.Username} ({profileMap.ProfilePath})";
            }
            StatusMessage = LastIdentityStatus;
            Logger?.LogInfo(nameof(IdentityBackupViewModel), LastIdentityStatus);
        }
        catch (Exception ex)
        {
            LastIdentityStatus = $"Account scan failed: {ex.Message}";
            StatusMessage = LastIdentityStatus;
            Logger?.LogError(nameof(IdentityBackupViewModel), LastIdentityStatus);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void RefreshAccountsCore()
    {
        var accounts = _identityService.GetLocalAccounts() ?? Array.Empty<LocalAccountItem>();
        Accounts.Clear();
        foreach (var acc in accounts)
        {
            Accounts.Add(acc);
        }

        if (SelectedAccount == null && Accounts.Count > 0)
        {
            SelectedAccount = Accounts[0];
        }

        var admin = _identityService.GetBuiltInAdministrator();
        if (admin != null)
        {
            BuiltInAdminName = $"{admin.Username} ({admin.Sid})";
            IsBuiltInAdminEnabled = admin.IsEnabled;
        }
    }

    private async Task EnableBuiltInAdminAsync() => await ExecuteAsync("Enable Built-in Administrator", () =>
    {
        bool ok = _identityService.EnableBuiltInAdministrator();
        RefreshAccountsCore();
        LastIdentityStatus = ok ? "Built-in Administrator account enabled successfully." : "Failed to enable Administrator.";
        return Task.CompletedTask;
    });

    private async Task ResetAdminPasswordAsync() => await ExecuteAsync("Reset Administrator Password", () =>
    {
        bool ok = _identityService.ResetBuiltInAdministratorPassword(NewAdminPassword);
        LastIdentityStatus = ok ? "Administrator password reset successfully." : "Failed to reset password.";
        NewAdminPassword = string.Empty;
        return Task.CompletedTask;
    });

    private async Task CreateAccountAsync() => await ExecuteAsync($"Create Local Account '{NewAccountUsername}'", () =>
    {
        string username = NewAccountUsername;
        bool ok = _identityService.CreateLocalAccount(username, NewAccountPassword, NewAccountDescription, NewAccountIsAdmin);
        RefreshAccountsCore();
        LastIdentityStatus = ok ? $"Account '{username}' created successfully." : "Failed to create account.";
        NewAccountUsername = string.Empty;
        NewAccountPassword = string.Empty;
        return Task.CompletedTask;
    });

    private async Task UnlockAccountAsync() => await ExecuteAsync($"Unlock Account '{SelectedAccount?.Username}'", () =>
    {
        if (SelectedAccount == null) return Task.CompletedTask;
        string username = SelectedAccount.Username;
        bool ok = _identityService.UnlockLocalAccount(username);
        RefreshAccountsCore();
        LastIdentityStatus = ok ? $"Account '{username}' unlocked." : "Failed to unlock account.";
        return Task.CompletedTask;
    });

    private async Task ToggleAccountEnabledAsync() => await ExecuteAsync($"Toggle Enabled '{SelectedAccount?.Username}'", () =>
    {
        if (SelectedAccount == null) return Task.CompletedTask;
        string username = SelectedAccount.Username;
        bool targetState = !SelectedAccount.IsEnabled;
        bool ok = _identityService.SetAccountEnabled(username, targetState);
        RefreshAccountsCore();
        LastIdentityStatus = ok ? $"Account '{username}' state set to {(targetState ? "Enabled" : "Disabled")}." : "Failed to change state.";
        return Task.CompletedTask;
    });

    private async Task RemoveAccountAsync()
    {
        if (SelectedAccount == null) return;
        string username = SelectedAccount.Username;
        string sid = SelectedAccount.Sid;

        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Account Deletion",
                $"Are you sure you want to permanently delete local user account '{username}'?",
                $"Account SID: {sid}. This account and its credentials will be permanently removed from SAM. This action cannot be undone.");
            if (!confirmed)
            {
                LastIdentityStatus = $"Account removal of '{username}' cancelled by user.";
                Logger?.LogWarning(nameof(IdentityBackupViewModel), $"Account removal of '{username}' was cancelled by user.");
                return;
            }
        }

        await ExecuteAsync($"Remove Account '{username}'", () =>
        {
            bool ok = _identityService.RemoveLocalAccount(username, sid);
            RefreshAccountsCore();
            LastIdentityStatus = ok ? $"Account '{username}' removed." : "Failed to remove account.";
            return Task.CompletedTask;
        });
    }

    private async Task TestDomainReachabilityAsync() => await ExecuteAsync($"Test Domain '{DomainTestName}'", () =>
    {
        var res = _identityService.TestDomainReachability(DomainTestName);
        LastIdentityStatus = res.IsReachable
            ? $"Domain '{res.Domain}' reachable (DNS: OK, Kerberos 88: OK, LDAP 389: OK, SMB 445: OK)."
            : $"Domain '{res.Domain}' unreachable: {res.DiagnosticsSummary}";
        return Task.CompletedTask;
    });

    private async Task UnlockDomainUserAsync() => await ExecuteAsync($"Unlock Domain User '{DomainUserSamName}'", () =>
    {
        bool ok = _identityService.UnlockDomainUser(DomainTestName, DomainUserSamName);
        LastIdentityStatus = ok ? $"Domain user '{DomainUserSamName}' unlocked successfully." : $"Failed to unlock '{DomainUserSamName}'.";
        return Task.CompletedTask;
    });

    private async Task ExecuteProfileBackupAsync()
    {
        if (RobocopyMirror && _confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Robocopy Mirror (/MIR) & Save Open Applications",
                $"Robocopy Mirror mode will purge any files or folders in '{BackupDestinationDirectory}' that do not exist in the source profile. Please save and back up work in Microsoft Outlook, Microsoft Word, Microsoft Excel, Microsoft PowerPoint, Google Chrome, and Microsoft Edge before continuing.",
                "Active Office and Browser applications will be safely closed before backup and automatically restarted afterward. Files present in the destination but missing from the current user profile will be permanently deleted. Do you wish to continue?");
            if (!confirmed)
            {
                LastBackupStatus = "Profile backup cancelled by user (Mirror confirmation declined).";
                Logger?.LogWarning(nameof(IdentityBackupViewModel), "Robocopy Mirror backup was cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("User Profile Backup Pipeline", () =>
        {
            var profileMap = _backupService.GetUserProfileMap();
            var syncRes = _backupService.RunRobocopySync(profileMap.ProfilePath, BackupDestinationDirectory, RobocopyMirror);

            if (IncludeBookmarks)
            {
                _backupService.ExportBrowserBookmarks(BackupDestinationDirectory);
            }
            if (IncludeCertificates)
            {
                _backupService.ExportCertificates(CertificateStoreName, BackupDestinationDirectory, CertificatePassword);
            }

            if (CreateManifest)
            {
                string manifestPath = Path.Combine(BackupDestinationDirectory, "iToolKit_Backup_Manifest.json");
                _backupService.CreateBackupManifest(BackupDestinationDirectory, manifestPath);
            }

            LastBackupStatus = syncRes.IsSuccess
                ? $"Profile backup completed successfully to '{BackupDestinationDirectory}'."
                : $"Robocopy sync exited with code {syncRes.ExitCode}.";
            return Task.CompletedTask;
        });
    }

    private async Task ValidateBackupManifestAsync() => await ExecuteAsync("Validate Backup Manifest", () =>
    {
        string manifestPath = Path.Combine(RestoreBackupDirectory, "iToolKit_Backup_Manifest.json");
        var res = _backupService.ValidateBackupManifest(RestoreBackupDirectory, manifestPath);
        LastBackupStatus = res.IsIntact
            ? $"Manifest Validated: {res.MatchedCount} files intact, 0 missing, 0 corrupt."
            : $"Integrity Check Failed: {res.MissingCount} missing, {res.CorruptedCount} corrupt files.";
        return Task.CompletedTask;
    });

    private async Task RestoreProfileAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Profile Restore & Save Open Applications",
                $"Restoring profile data will overwrite current user files from '{RestoreBackupDirectory}'. Please save and back up work in Microsoft Outlook, Microsoft Word, Microsoft Excel, Microsoft PowerPoint, Google Chrome, and Microsoft Edge before continuing.",
                "Active Office and Browser applications will be safely closed before restore and automatically restarted afterward. Existing files in your profile folders may be overwritten by restored files. Do you wish to continue?");
            if (!confirmed)
            {
                LastBackupStatus = "Profile restore cancelled by user.";
                Logger?.LogWarning(nameof(IdentityBackupViewModel), "Profile restore was cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Restore Profile Data", () =>
        {
            string manifestPath = Path.Combine(RestoreBackupDirectory, "iToolKit_Backup_Manifest.json");
            var res = _backupService.RestoreProfileData(RestoreBackupDirectory, manifestPath);
            LastBackupStatus = res.Success
                ? $"Profile restored: {res.FilesRestored} files restored after manifest validation."
                : $"Restore failed: {res.Message}";
            return Task.CompletedTask;
        });
    }
}
