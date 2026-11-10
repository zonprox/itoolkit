namespace IToolkit.App.ViewModels;

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;

/// <summary>
/// Presentation item for an application discovered via winget search.
/// </summary>
public class WingetPackageViewModel : ViewModelBase
{
    private string _status = "Available";
    private bool _isInstalling;

    public WingetPackage Package { get; }

    public WingetPackageViewModel(WingetPackage package, Func<Task>? onInstall = null)
    {
        Package = package ?? throw new ArgumentNullException(nameof(package));
        InstallCommand = new AsyncRelayCommand(
            async () =>
            {
                if (onInstall != null)
                {
                    await onInstall();
                }
            },
            () => !IsInstalling);
    }

    public string Name => Package.Name;
    public string Id => Package.Id;
    public string Version => Package.Version;
    public string? Match => Package.Match;
    public string Source => Package.Source;

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public bool IsInstalling
    {
        get => _isInstalling;
        set
        {
            if (SetProperty(ref _isInstalling, value))
            {
                InstallCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public IAsyncRelayCommand InstallCommand { get; }
}

/// <summary>
/// Presentation item for an installed application detected via winget list.
/// </summary>
public class InstalledAppViewModel : ViewModelBase
{
    private string _status = "Installed";
    private bool _isUninstalling;

    public WingetInstalledApp App { get; }

    public InstalledAppViewModel(WingetInstalledApp app, Func<Task>? onUninstall = null)
    {
        App = app ?? throw new ArgumentNullException(nameof(app));
        UninstallCommand = new AsyncRelayCommand(
            async () =>
            {
                if (onUninstall != null)
                {
                    await onUninstall();
                }
            },
            () => !IsUninstalling);
    }

    public string Name => App.Name;
    public string Id => App.Id;
    public string Version => App.Version;
    public string? AvailableVersion => App.AvailableVersion;
    public string Source => App.Source;
    public bool HasUpdate => !string.IsNullOrWhiteSpace(App.AvailableVersion);

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public bool IsUninstalling
    {
        get => _isUninstalling;
        set
        {
            if (SetProperty(ref _isUninstalling, value))
            {
                UninstallCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public IAsyncRelayCommand UninstallCommand { get; }
}

/// <summary>
/// Presentation item for an available package update detected via winget list --upgrade-available.
/// </summary>
public class AppUpdateViewModel : ViewModelBase
{
    private string _status = "Update Available";
    private bool _isUpdating;

    public WingetUpdateItem UpdateItem { get; }

    public AppUpdateViewModel(WingetUpdateItem updateItem, Func<Task>? onUpdate = null)
    {
        UpdateItem = updateItem ?? throw new ArgumentNullException(nameof(updateItem));
        UpdateCommand = new AsyncRelayCommand(
            async () =>
            {
                if (onUpdate != null)
                {
                    await onUpdate();
                }
            },
            () => !IsUpdating);
    }

    public string Name => UpdateItem.Name;
    public string Id => UpdateItem.Id;
    public string InstalledVersion => UpdateItem.InstalledVersion;
    public string AvailableVersion => UpdateItem.AvailableVersion;
    public string Source => UpdateItem.Source;

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public bool IsUpdating
    {
        get => _isUpdating;
        set
        {
            if (SetProperty(ref _isUpdating, value))
            {
                UpdateCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public IAsyncRelayCommand UpdateCommand { get; }
}

/// <summary>
/// Dedicated ViewModel managing application lifecycle: winget discovery, installed inventory, and package updates.
/// </summary>
public class AppManagementViewModel : ViewModelBase
{
    private readonly IAppInstallerService _appInstallerService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private readonly List<InstalledAppViewModel> _allInstalledApps = new();

    private string _searchQuery = string.Empty;
    private string _installedFilterQuery = string.Empty;

    private bool _isSearching;
    private bool _isLoadingInstalled;
    private bool _isCheckingUpdates;
    private double _operationProgress;
    private string _operationProgressText = string.Empty;

    private string _searchStatusText = "Enter a keyword and click Search to discover applications.";
    private string _installedStatusText = "Click Refresh to load installed system applications.";
    private string _updatesStatusText = "Click Check for Updates to scan for available package updates.";

    public AppManagementViewModel(
        IAppInstallerService appInstallerService,
        ISafetyConfirmationService? confirmationService = null,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _appInstallerService = appInstallerService ?? throw new ArgumentNullException(nameof(appInstallerService));
        _confirmationService = confirmationService;

        SearchResults = new ObservableCollection<WingetPackageViewModel>();
        InstalledApps = new ObservableCollection<InstalledAppViewModel>();
        AvailableUpdates = new ObservableCollection<AppUpdateViewModel>();

        SearchAppsCommand = new AsyncRelayCommand(SearchAppsAsync, () => IsNotBusy && !IsSearching);
        RefreshInstalledCommand = new AsyncRelayCommand(RefreshInstalledAsync, () => IsNotBusy && !IsLoadingInstalled);
        CheckUpdatesCommand = new AsyncRelayCommand(CheckUpdatesAsync, () => IsNotBusy && !IsCheckingUpdates);

        InstallAppCommand = new AsyncRelayCommand<WingetPackageViewModel>(InstallAppAsync, p => p != null && !p.IsInstalling && IsNotBusy);
        UninstallAppCommand = new AsyncRelayCommand<InstalledAppViewModel>(UninstallAppAsync, a => a != null && !a.IsUninstalling && IsNotBusy);
        UpdateAppCommand = new AsyncRelayCommand<AppUpdateViewModel>(UpdateAppAsync, u => u != null && !u.IsUpdating && IsNotBusy);

        UpgradeAllAppsCommand = new AsyncRelayCommand(UpgradeAllAppsAsync, () => IsNotBusy && AvailableUpdates.Count > 0);
        ClearSearchCommand = new RelayCommand(ClearSearch);
    }

    public ObservableCollection<WingetPackageViewModel> SearchResults { get; }
    public ObservableCollection<InstalledAppViewModel> InstalledApps { get; }
    public ObservableCollection<AppUpdateViewModel> AvailableUpdates { get; }

    public string SearchQuery
    {
        get => _searchQuery;
        set => SetProperty(ref _searchQuery, value);
    }

    public string InstalledFilterQuery
    {
        get => _installedFilterQuery;
        set
        {
            if (SetProperty(ref _installedFilterQuery, value))
            {
                ApplyInstalledFilter();
            }
        }
    }

    public bool IsSearching
    {
        get => _isSearching;
        set
        {
            if (SetProperty(ref _isSearching, value))
            {
                SearchAppsCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool IsLoadingInstalled
    {
        get => _isLoadingInstalled;
        set
        {
            if (SetProperty(ref _isLoadingInstalled, value))
            {
                RefreshInstalledCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool IsCheckingUpdates
    {
        get => _isCheckingUpdates;
        set
        {
            if (SetProperty(ref _isCheckingUpdates, value))
            {
                CheckUpdatesCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public double OperationProgress
    {
        get => _operationProgress;
        set => SetProperty(ref _operationProgress, value);
    }

    public string OperationProgressText
    {
        get => _operationProgressText;
        set => SetProperty(ref _operationProgressText, value);
    }

    public string SearchStatusText
    {
        get => _searchStatusText;
        set => SetProperty(ref _searchStatusText, value);
    }

    public string InstalledStatusText
    {
        get => _installedStatusText;
        set => SetProperty(ref _installedStatusText, value);
    }

    public string UpdatesStatusText
    {
        get => _updatesStatusText;
        set => SetProperty(ref _updatesStatusText, value);
    }

    public IAsyncRelayCommand SearchAppsCommand { get; }
    public IAsyncRelayCommand RefreshInstalledCommand { get; }
    public IAsyncRelayCommand CheckUpdatesCommand { get; }
    public IAsyncRelayCommand<WingetPackageViewModel> InstallAppCommand { get; }
    public IAsyncRelayCommand<InstalledAppViewModel> UninstallAppCommand { get; }
    public IAsyncRelayCommand<AppUpdateViewModel> UpdateAppCommand { get; }
    public IAsyncRelayCommand UpgradeAllAppsCommand { get; }
    public IRelayCommand ClearSearchCommand { get; }

    public async Task SearchAppsAsync()
    {
        if (string.IsNullOrWhiteSpace(SearchQuery))
        {
            SearchStatusText = "Please enter a valid application name or package ID.";
            return;
        }

        string query = SearchQuery.Trim();
        IsSearching = true;

        await ExecuteAsync($"Search Packages ({query})", async () =>
        {
            SearchStatusText = $"Searching Windows Package Manager for '{query}'...";
            var packages = await _appInstallerService.SearchPackagesAsync(query);

            SearchResults.Clear();
            foreach (var package in packages)
            {
                WingetPackageViewModel vm = null!;
                vm = new WingetPackageViewModel(package, async () => await InstallAppAsync(package.Id, package.Name, vm));
                SearchResults.Add(vm);
            }

            SearchStatusText = SearchResults.Count > 0
                ? $"Found {SearchResults.Count} package(s) matching '{query}'."
                : $"No packages found matching '{query}'.";
        });

        IsSearching = false;
    }

    public void ClearSearch()
    {
        SearchQuery = string.Empty;
        SearchResults.Clear();
        SearchStatusText = "Search cleared. Enter a keyword to search.";
    }

    public async Task RefreshInstalledAsync()
    {
        IsLoadingInstalled = true;

        await ExecuteAsync("Refresh Installed Applications", async () =>
        {
            InstalledStatusText = "Querying installed applications from Windows Package Manager...";
            var apps = await _appInstallerService.GetInstalledApplicationsAsync();

            _allInstalledApps.Clear();
            foreach (var app in apps)
            {
                InstalledAppViewModel vm = null!;
                vm = new InstalledAppViewModel(app, async () => await UninstallAppAsync(app.Id, app.Name, vm));
                _allInstalledApps.Add(vm);
            }

            ApplyInstalledFilter();
        });

        IsLoadingInstalled = false;
    }

    public void ApplyInstalledFilter()
    {
        InstalledApps.Clear();

        IEnumerable<InstalledAppViewModel> filtered = _allInstalledApps;
        if (!string.IsNullOrWhiteSpace(InstalledFilterQuery))
        {
            string filter = InstalledFilterQuery.Trim();
            filtered = _allInstalledApps.Where(a =>
                (a.Name?.Contains(filter, StringComparison.OrdinalIgnoreCase) ?? false) ||
                (a.Id?.Contains(filter, StringComparison.OrdinalIgnoreCase) ?? false) ||
                (a.Source?.Contains(filter, StringComparison.OrdinalIgnoreCase) ?? false));
        }

        foreach (var item in filtered)
        {
            InstalledApps.Add(item);
        }

        if (string.IsNullOrWhiteSpace(InstalledFilterQuery))
        {
            InstalledStatusText = $"Loaded {_allInstalledApps.Count} installed application(s).";
        }
        else
        {
            InstalledStatusText = $"Showing {InstalledApps.Count} of {_allInstalledApps.Count} installed application(s).";
        }
    }

    public async Task CheckUpdatesAsync()
    {
        IsCheckingUpdates = true;

        await ExecuteAsync("Check Available Updates", async () =>
        {
            UpdatesStatusText = "Scanning for available package updates...";
            var updates = await _appInstallerService.GetAvailableUpdatesAsync();

            AvailableUpdates.Clear();
            foreach (var update in updates)
            {
                AppUpdateViewModel vm = null!;
                vm = new AppUpdateViewModel(update, async () => await UpdateAppAsync(update.Id, update.Name, vm));
                AvailableUpdates.Add(vm);
            }

            UpdatesStatusText = AvailableUpdates.Count > 0
                ? $"Found {AvailableUpdates.Count} available package update(s)."
                : "All installed applications are up to date.";

            UpgradeAllAppsCommand.RaiseCanExecuteChanged();
        });

        IsCheckingUpdates = false;
    }

    public async Task InstallAppAsync(WingetPackageViewModel? packageVm)
    {
        if (packageVm == null) return;
        await InstallAppAsync(packageVm.Id, packageVm.Name, packageVm);
    }

    public async Task InstallAppAsync(string packageId, string displayName = "", WingetPackageViewModel? packageVm = null)
    {
        if (string.IsNullOrWhiteSpace(packageId)) return;

        var targetVm = packageVm ?? SearchResults.FirstOrDefault(p => string.Equals(p.Id, packageId, StringComparison.OrdinalIgnoreCase));
        if (targetVm != null)
        {
            targetVm.IsInstalling = true;
            targetVm.Status = "Installing...";
        }

        string appName = string.IsNullOrEmpty(displayName) ? (targetVm?.Name ?? packageId) : displayName;
        OperationProgress = 15;
        OperationProgressText = $"Installing {appName}...";

        try
        {
            await ExecuteAsync($"Install {appName}", async () =>
            {
                try
                {
                    var result = await _appInstallerService.InstallWingetPackageAsync(packageId);
                    if (result != null && result.Success)
                    {
                        if (targetVm != null) targetVm.Status = "Installed";
                        StatusMessage = $"Successfully installed {appName}.";
                        OperationProgress = 100;
                        OperationProgressText = "Installation complete.";
                    }
                    else
                    {
                        if (targetVm != null) targetVm.Status = $"Failed: {result?.Message ?? "Unknown error"}";
                        StatusMessage = $"Installation failed for {appName}: {result?.Message ?? "Unknown error"}";
                        OperationProgress = 0;
                        OperationProgressText = "Installation failed.";
                    }
                }
                catch (Exception ex)
                {
                    if (targetVm != null) targetVm.Status = $"Failed: {ex.Message}";
                    OperationProgress = 0;
                    OperationProgressText = "Installation failed.";
                    throw;
                }
            });
        }
        finally
        {
            if (targetVm != null)
            {
                targetVm.IsInstalling = false;
            }
        }
    }

    public async Task UninstallAppAsync(InstalledAppViewModel? appVm)
    {
        if (appVm == null) return;
        await UninstallAppAsync(appVm.Id, appVm.Name, appVm);
    }

    public async Task UninstallAppAsync(string packageId, string displayName = "", InstalledAppViewModel? appVm = null)
    {
        if (string.IsNullOrWhiteSpace(packageId)) return;

        var targetVm = appVm
            ?? _allInstalledApps.FirstOrDefault(a => string.Equals(a.Id, packageId, StringComparison.OrdinalIgnoreCase))
            ?? InstalledApps.FirstOrDefault(a => string.Equals(a.Id, packageId, StringComparison.OrdinalIgnoreCase));
        string appName = string.IsNullOrEmpty(displayName) ? (targetVm?.Name ?? packageId) : displayName;

        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                $"Uninstall {appName}",
                $"Are you sure you want to uninstall '{appName}' ({packageId})?",
                "Uninstalling will permanently remove this software and its configurations. Ensure all work is saved.");

            if (!confirmed)
            {
                Logger?.LogInfo(nameof(AppManagementViewModel), $"Uninstallation of '{appName}' was cancelled by user.");
                return;
            }
        }

        if (targetVm != null)
        {
            targetVm.IsUninstalling = true;
            targetVm.Status = "Uninstalling...";
        }

        OperationProgress = 20;
        OperationProgressText = $"Uninstalling {appName}...";

        try
        {
            await ExecuteAsync($"Uninstall {appName}", async () =>
            {
                try
                {
                    var result = await _appInstallerService.UninstallWingetPackageAsync(packageId);
                    if (result != null && result.Success)
                    {
                        if (targetVm != null)
                        {
                            targetVm.Status = "Uninstalled";
                            _allInstalledApps.Remove(targetVm);
                            InstalledApps.Remove(targetVm);
                        }

                        _allInstalledApps.RemoveAll(a => string.Equals(a.Id, packageId, StringComparison.OrdinalIgnoreCase));
                        var uiItem = InstalledApps.FirstOrDefault(a => string.Equals(a.Id, packageId, StringComparison.OrdinalIgnoreCase));
                        if (uiItem != null)
                        {
                            InstalledApps.Remove(uiItem);
                        }

                        var matchingUpdate = AvailableUpdates.FirstOrDefault(u => string.Equals(u.Id, packageId, StringComparison.OrdinalIgnoreCase));
                        if (matchingUpdate != null)
                        {
                            AvailableUpdates.Remove(matchingUpdate);
                            UpdatesStatusText = AvailableUpdates.Count > 0
                                ? $"Found {AvailableUpdates.Count} available package update(s)."
                                : "All installed applications are up to date.";
                            UpgradeAllAppsCommand.RaiseCanExecuteChanged();
                        }

                        StatusMessage = $"Successfully uninstalled {appName}.";
                        OperationProgress = 100;
                        OperationProgressText = "Uninstallation complete.";
                        InstalledStatusText = string.IsNullOrWhiteSpace(InstalledFilterQuery)
                            ? $"Loaded {_allInstalledApps.Count} installed application(s)."
                            : $"Showing {InstalledApps.Count} of {_allInstalledApps.Count} installed application(s).";
                    }
                    else
                    {
                        if (targetVm != null) targetVm.Status = $"Failed: {result?.Message ?? "Unknown error"}";
                        StatusMessage = $"Failed to uninstall {appName}: {result?.Message ?? "Unknown error"}";
                        OperationProgress = 0;
                        OperationProgressText = "Uninstallation failed.";
                    }
                }
                catch (Exception ex)
                {
                    if (targetVm != null) targetVm.Status = $"Failed: {ex.Message}";
                    OperationProgress = 0;
                    OperationProgressText = "Uninstallation failed.";
                    throw;
                }
            });
        }
        finally
        {
            if (targetVm != null)
            {
                targetVm.IsUninstalling = false;
            }
        }
    }

    public async Task UpdateAppAsync(AppUpdateViewModel? updateVm)
    {
        if (updateVm == null) return;
        await UpdateAppAsync(updateVm.Id, updateVm.Name, updateVm);
    }

    public async Task UpdateAppAsync(string packageId, string displayName = "", AppUpdateViewModel? updateVm = null)
    {
        if (string.IsNullOrWhiteSpace(packageId)) return;

        var targetVm = updateVm ?? AvailableUpdates.FirstOrDefault(u => string.Equals(u.Id, packageId, StringComparison.OrdinalIgnoreCase));
        string appName = string.IsNullOrEmpty(displayName) ? (targetVm?.Name ?? packageId) : displayName;

        if (targetVm != null)
        {
            targetVm.IsUpdating = true;
            targetVm.Status = "Updating...";
        }

        OperationProgress = 25;
        OperationProgressText = $"Updating {appName}...";

        try
        {
            await ExecuteAsync($"Update {appName}", async () =>
            {
                try
                {
                    var result = await _appInstallerService.UpgradeWingetPackageAsync(packageId);
                    if (result != null && result.Success)
                    {
                        if (targetVm != null)
                        {
                            targetVm.Status = "Updated";
                            AvailableUpdates.Remove(targetVm);
                        }

                        var uiItem = AvailableUpdates.FirstOrDefault(u => string.Equals(u.Id, packageId, StringComparison.OrdinalIgnoreCase));
                        if (uiItem != null)
                        {
                            AvailableUpdates.Remove(uiItem);
                        }

                        StatusMessage = $"Successfully updated {appName}.";
                        OperationProgress = 100;
                        OperationProgressText = "Update complete.";
                        UpdatesStatusText = AvailableUpdates.Count > 0
                            ? $"Found {AvailableUpdates.Count} available package update(s)."
                            : "All installed applications are up to date.";
                        UpgradeAllAppsCommand.RaiseCanExecuteChanged();
                    }
                    else
                    {
                        if (targetVm != null) targetVm.Status = $"Failed: {result?.Message ?? "Unknown error"}";
                        StatusMessage = $"Failed to update {appName}: {result?.Message ?? "Unknown error"}";
                        OperationProgress = 0;
                        OperationProgressText = "Update failed.";
                    }
                }
                catch (Exception ex)
                {
                    if (targetVm != null) targetVm.Status = $"Failed: {ex.Message}";
                    OperationProgress = 0;
                    OperationProgressText = "Update failed.";
                    throw;
                }
            });
        }
        finally
        {
            if (targetVm != null)
            {
                targetVm.IsUpdating = false;
            }
        }
    }

    public async Task UpgradeAllAppsAsync()
    {
        if (AvailableUpdates.Count == 0)
        {
            UpdatesStatusText = "No available updates to install.";
            return;
        }

        await ExecuteAsync("Upgrade All Applications", async () =>
        {
            var itemsToUpdate = AvailableUpdates.ToList();
            int total = itemsToUpdate.Count;
            int current = 0;
            int successful = 0;
            Exception? firstException = null;

            foreach (var item in itemsToUpdate)
            {
                current++;
                OperationProgress = ((double)current / total) * 100;
                OperationProgressText = $"Updating ({current}/{total}): {item.Name}...";

                try
                {
                    item.IsUpdating = true;
                    item.Status = "Updating...";

                    var result = await _appInstallerService.UpgradeWingetPackageAsync(item.Id);
                    if (result != null && result.Success)
                    {
                        successful++;
                        item.Status = "Updated";
                        AvailableUpdates.Remove(item);
                    }
                    else
                    {
                        item.Status = $"Failed: {result?.Message ?? "Unknown error"}";
                    }
                }
                catch (Exception ex)
                {
                    firstException ??= ex;
                    item.Status = $"Failed: {ex.Message}";
                    Logger?.LogWarning(nameof(AppManagementViewModel), $"Failed updating {item.Name} ({item.Id}): {ex.Message}");
                }
                finally
                {
                    item.IsUpdating = false;
                }
            }

            OperationProgress = 100;
            OperationProgressText = "Batch update completed.";
            UpdatesStatusText = $"Batch upgrade finished: {successful} of {total} package(s) updated.";
            UpgradeAllAppsCommand.RaiseCanExecuteChanged();

            if (firstException != null)
            {
                throw firstException;
            }
        });
    }
}
