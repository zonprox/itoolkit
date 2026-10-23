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
        IActivityLogger? logger = null)
        : base(logger)
    {
        _identityService = identityService ?? throw new ArgumentNullException(nameof(identityService));
        _backupService = backupService ?? throw new ArgumentNullException(nameof(backupService));

        Accounts = new ObservableCollection<LocalAccountItem>();

        // Commands
        RefreshAccountsCommand = new AsyncRelayCommand(RefreshAccountsAsync, () => IsNotBusy);
        EnableBuiltInAdminCommand = new AsyncRelayCommand(EnableBuiltInAdminAsync, () => IsNotBusy);
        ResetAdminPasswordCommand = new AsyncRelayCommand(ResetAdminPasswordAsync, () => IsNotBusy && !string.IsNullOrEmpty(NewAdminPassword));
        CreateAccountCommand = new AsyncRelayCommand(CreateAccountAsync, () => IsNotBusy && !string.IsNullOrEmpty(NewAccountUsername) && !string.IsNullOrEmpty(NewAccountPassword));
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

    public async Task RefreshAccountsAsync() => await ExecuteAsync("Query Local Accounts", () =>
    {
        RefreshAccountsCore();
        LastIdentityStatus = $"Loaded {Accounts.Count} local user accounts.";
        return Task.CompletedTask;
    });

    private void RefreshAccountsCore()
    {
        var accounts = _identityService.GetLocalAccounts();
        Accounts.Clear();
        foreach (var acc in accounts)
        {
            Accounts.Add(acc);
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

    private async Task RemoveAccountAsync() => await ExecuteAsync($"Remove Account '{SelectedAccount?.Username}'", () =>
    {
        if (SelectedAccount == null) return Task.CompletedTask;
        string username = SelectedAccount.Username;
        string sid = SelectedAccount.Sid;
        bool ok = _identityService.RemoveLocalAccount(username, sid);
        RefreshAccountsCore();
        LastIdentityStatus = ok ? $"Account '{username}' removed." : "Failed to remove account.";
        return Task.CompletedTask;
    });

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

    private async Task ExecuteProfileBackupAsync() => await ExecuteAsync("User Profile Backup Pipeline", () =>
    {
        if (IncludeBookmarks)
        {
            _backupService.ExportBrowserBookmarks(BackupDestinationDirectory);
        }
        if (IncludeCertificates)
        {
            _backupService.ExportCertificates(CertificateStoreName, BackupDestinationDirectory, CertificatePassword);
        }

        var profileMap = _backupService.GetUserProfileMap();
        var syncRes = _backupService.RunRobocopySync(profileMap.ProfilePath, BackupDestinationDirectory, RobocopyMirror);

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

    private async Task ValidateBackupManifestAsync() => await ExecuteAsync("Validate Backup Manifest", () =>
    {
        string manifestPath = Path.Combine(RestoreBackupDirectory, "iToolKit_Backup_Manifest.json");
        var res = _backupService.ValidateBackupManifest(RestoreBackupDirectory, manifestPath);
        LastBackupStatus = res.IsIntact
            ? $"Manifest Validated: {res.MatchedCount} files intact, 0 missing, 0 corrupt."
            : $"Integrity Check Failed: {res.MissingCount} missing, {res.CorruptedCount} corrupt files.";
        return Task.CompletedTask;
    });

    private async Task RestoreProfileAsync() => await ExecuteAsync("Restore Profile Data", () =>
    {
        string manifestPath = Path.Combine(RestoreBackupDirectory, "iToolKit_Backup_Manifest.json");
        var res = _backupService.RestoreProfileData(RestoreBackupDirectory, manifestPath);
        LastBackupStatus = res.Success
            ? $"Profile restored: {res.FilesRestored} files restored after manifest validation."
            : $"Restore failed: {res.Message}";
        return Task.CompletedTask;
    });
}
