namespace IToolkit.App.ViewModels;

using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;

public class AppItemViewModel : ViewModelBase
{
    private bool _isSelected;
    private string _status = "Ready";

    public AppCatalogItem Item { get; }

    public AppItemViewModel(AppCatalogItem item, Action onInstall)
    {
        Item = item;
        InstallCommand = new RelayCommand(onInstall);
    }

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public IRelayCommand InstallCommand { get; }
}

public class SoftwareOptimizationViewModel : ViewModelBase
{
    private readonly IAppInstallerService _appInstallerService;
    private readonly IOptimizationService _optimizationService;

    private bool _createDesktopShortcutsOnInstall = true;
    private string _customDebloatScriptUrl = string.Empty;
    private string _lastSoftwareStatus = "Ready";
    private string _wingetVersionText = "Not Checked";

    public SoftwareOptimizationViewModel(
        IAppInstallerService appInstallerService,
        IOptimizationService optimizationService,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _appInstallerService = appInstallerService ?? throw new ArgumentNullException(nameof(appInstallerService));
        _optimizationService = optimizationService ?? throw new ArgumentNullException(nameof(optimizationService));

        CatalogApps = new ObservableCollection<AppItemViewModel>();

        // Commands
        SelectAllCommand = new RelayCommand(() => SetAllSelection(true));
        DeselectAllCommand = new RelayCommand(() => SetAllSelection(false));
        BatchInstallCommand = new AsyncRelayCommand(BatchInstallAsync, () => IsNotBusy);

        SetDefaultBrowserCommand = new AsyncRelayCommand(SetDefaultBrowserAsync, () => IsNotBusy);
        SetDefaultPdfViewerCommand = new AsyncRelayCommand(SetDefaultPdfViewerAsync, () => IsNotBusy);
        ConfigureUblockPolicyCommand = new AsyncRelayCommand(ConfigureUblockPolicyAsync, () => IsNotBusy);

        CheckWingetStatusCommand = new AsyncRelayCommand(CheckWingetStatusAsync, () => IsNotBusy);
        RepairWingetCommand = new AsyncRelayCommand(RepairWingetAsync, () => IsNotBusy);
        UpgradeAllPackagesCommand = new AsyncRelayCommand(UpgradeAllPackagesAsync, () => IsNotBusy);

        LaunchWin11DebloatCommand = new AsyncRelayCommand(LaunchWin11DebloatAsync, () => IsNotBusy);
        LaunchBrowserDebloatCommand = new AsyncRelayCommand(LaunchBrowserDebloatAsync, () => IsNotBusy);
        LaunchChrisTitusWinUtilCommand = new AsyncRelayCommand(LaunchChrisTitusWinUtilAsync, () => IsNotBusy);
        LaunchSophiaScriptCommand = new AsyncRelayCommand(LaunchSophiaScriptAsync, () => IsNotBusy);
        ExecuteCustomDebloatCommand = new AsyncRelayCommand(ExecuteCustomDebloatAsync, () => IsNotBusy && !string.IsNullOrEmpty(CustomDebloatScriptUrl));

        LoadCatalog();
    }

    public ObservableCollection<AppItemViewModel> CatalogApps { get; }

    public bool CreateDesktopShortcutsOnInstall
    {
        get => _createDesktopShortcutsOnInstall;
        set => SetProperty(ref _createDesktopShortcutsOnInstall, value);
    }

    public string CustomDebloatScriptUrl
    {
        get => _customDebloatScriptUrl;
        set
        {
            if (SetProperty(ref _customDebloatScriptUrl, value))
            {
                ExecuteCustomDebloatCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string LastSoftwareStatus
    {
        get => _lastSoftwareStatus;
        set => SetProperty(ref _lastSoftwareStatus, value);
    }

    public string WingetVersionText
    {
        get => _wingetVersionText;
        set => SetProperty(ref _wingetVersionText, value);
    }

    public IRelayCommand SelectAllCommand { get; }
    public IRelayCommand DeselectAllCommand { get; }
    public IAsyncRelayCommand BatchInstallCommand { get; }

    public IAsyncRelayCommand SetDefaultBrowserCommand { get; }
    public IAsyncRelayCommand SetDefaultPdfViewerCommand { get; }
    public IAsyncRelayCommand ConfigureUblockPolicyCommand { get; }

    public IAsyncRelayCommand CheckWingetStatusCommand { get; }
    public IAsyncRelayCommand RepairWingetCommand { get; }
    public IAsyncRelayCommand UpgradeAllPackagesCommand { get; }

    public IAsyncRelayCommand LaunchWin11DebloatCommand { get; }
    public IAsyncRelayCommand LaunchBrowserDebloatCommand { get; }
    public IAsyncRelayCommand LaunchChrisTitusWinUtilCommand { get; }
    public IAsyncRelayCommand LaunchSophiaScriptCommand { get; }
    public IAsyncRelayCommand ExecuteCustomDebloatCommand { get; }

    public void LoadCatalog()
    {
        CatalogApps.Clear();
        var catalog = _appInstallerService.GetCatalog();
        foreach (var item in catalog)
        {
            CatalogApps.Add(new AppItemViewModel(item, () => InstallSingleApp(item.AppId)));
        }
    }

    private void SetAllSelection(bool isSelected)
    {
        foreach (var app in CatalogApps)
        {
            app.IsSelected = isSelected;
        }
    }

    private async void InstallSingleApp(string appId)
    {
        await ExecuteAsync($"Install '{appId}'", () =>
        {
            var appVm = CatalogApps.FirstOrDefault(a => a.Item.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase));
            if (appVm != null) appVm.Status = "Installing...";

            try
            {
                var res = _appInstallerService.InstallApplication(appId);
                if (appVm != null) appVm.Status = res.Success ? "Installed" : "Failed";
                LastSoftwareStatus = $"{res.DisplayName}: {(res.Success ? "Installed successfully" : res.Message)}.";
            }
            catch (Exception ex)
            {
                if (appVm != null) appVm.Status = "Failed";
                string name = appVm?.Item.DisplayName ?? appId;
                LastSoftwareStatus = $"{name}: Installation failed: {ex.Message}";
                throw;
            }

            return Task.CompletedTask;
        });
    }

    private async Task BatchInstallAsync()
    {
        var selected = CatalogApps.Where(a => a.IsSelected).Select(a => a.Item.AppId).ToList();
        if (selected.Count == 0)
        {
            LastSoftwareStatus = "No applications selected for installation.";
            return;
        }

        await ExecuteAsync($"Batch Install ({selected.Count} Apps)", () =>
        {
            int failureCount = 0;
            string? lastError = null;

            foreach (var appId in selected)
            {
                var appVm = CatalogApps.FirstOrDefault(a => a.Item.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase));
                if (appVm != null) appVm.Status = "Installing...";

                try
                {
                    var res = _appInstallerService.InstallApplication(appId);
                    if (appVm != null) appVm.Status = res.Success ? "Installed" : "Failed";
                    if (!res.Success)
                    {
                        failureCount++;
                        lastError = $"{res.DisplayName}: {res.Message}";
                        LastSoftwareStatus = $"{res.DisplayName}: {res.Message}";
                    }
                }
                catch (Exception ex)
                {
                    failureCount++;
                    if (appVm != null) appVm.Status = "Failed";
                    string name = appVm?.Item.DisplayName ?? appId;
                    lastError = $"{name}: {ex.Message}";
                    LastSoftwareStatus = $"{name}: Installation failed: {ex.Message}";
                    Logger?.LogError(nameof(SoftwareOptimizationViewModel), $"Batch install failed for '{appId}': {ex.Message}");
                }
            }

            LastSoftwareStatus = failureCount == 0
                ? $"Batch installation finished for {selected.Count} applications."
                : $"Batch installation finished with {failureCount} failure(s). Last error: {lastError}";

            return Task.CompletedTask;
        });
    }

    private async Task SetDefaultBrowserAsync() => await ExecuteAsync("Set Default Browser (Chrome)", () =>
    {
        bool ok = _appInstallerService.SetDefaultBrowser("chrome.exe");
        LastSoftwareStatus = ok ? "Default browser set to Google Chrome." : "Failed to set default browser.";
        return Task.CompletedTask;
    });

    private async Task SetDefaultPdfViewerAsync() => await ExecuteAsync("Set Default PDF Viewer (Foxit)", () =>
    {
        bool ok = _appInstallerService.SetDefaultPdfViewer("FoxitPDFReader.exe");
        LastSoftwareStatus = ok ? "Default PDF viewer set to Foxit PDF Reader." : "Failed to set default PDF viewer.";
        return Task.CompletedTask;
    });

    private async Task ConfigureUblockPolicyAsync() => await ExecuteAsync("Configure uBlock Origin Policy", () =>
    {
        bool ok = _appInstallerService.ConfigureUblockOriginLitePolicy();
        LastSoftwareStatus = ok ? "uBlock Origin Lite enterprise extension policy configured." : "Failed to configure policy.";
        return Task.CompletedTask;
    });

    private async Task CheckWingetStatusAsync() => await ExecuteAsync("Check Winget Status", () =>
    {
        var status = _optimizationService.GetWingetStatus();
        WingetVersionText = status.IsInstalled ? $"v{status.Version} ({(status.Healthy ? "Healthy" : "Issues Detected")})" : "Not Installed";
        LastSoftwareStatus = status.Message;
        return Task.CompletedTask;
    });

    private async Task RepairWingetAsync() => await ExecuteAsync("Repair Winget Subsystem", () =>
    {
        bool ok = _optimizationService.RepairWinget();
        LastSoftwareStatus = ok ? "Winget sources reset and repaired." : "Failed to repair Winget sources.";
        return Task.CompletedTask;
    });

    private async Task UpgradeAllPackagesAsync() => await ExecuteAsync("Upgrade All Packages", () =>
    {
        var res = _optimizationService.UpdateAllPackages();
        LastSoftwareStatus = res.ExitCode == 0 ? "All Winget packages upgraded successfully." : $"Winget upgrade exited with code {res.ExitCode}.";
        return Task.CompletedTask;
    });

    private async Task LaunchWin11DebloatAsync() => await ExecuteAsync("Launch Win11Debloat", () =>
    {
        var res = _optimizationService.LaunchWin11Debloat();
        LastSoftwareStatus = res.ExecutionSuccess ? "Win11Debloat executed successfully." : $"Win11Debloat failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task LaunchBrowserDebloatAsync() => await ExecuteAsync("Launch BrowserDebloat", () =>
    {
        var res = _optimizationService.LaunchBrowserDebloat();
        LastSoftwareStatus = res.ExecutionSuccess ? "BrowserDebloat executed successfully." : $"BrowserDebloat failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task LaunchChrisTitusWinUtilAsync() => await ExecuteAsync("Launch Chris Titus WinUtil", () =>
    {
        var res = _optimizationService.ExecuteDebloatScript("ChrisTitusWinUtil", "https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/winutil.ps1");
        LastSoftwareStatus = res.ExecutionSuccess ? "Chris Titus WinUtil executed successfully." : $"WinUtil failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task LaunchSophiaScriptAsync() => await ExecuteAsync("Launch Sophia Script", () =>
    {
        var res = _optimizationService.ExecuteDebloatScript("SophiaScript", "https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/master/Sophia.ps1");
        LastSoftwareStatus = res.ExecutionSuccess ? "Sophia Script executed successfully." : $"Sophia Script failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task ExecuteCustomDebloatAsync() => await ExecuteAsync("Execute Custom Debloat Script", () =>
    {
        var res = _optimizationService.ExecuteDebloatScript("CustomDebloat", CustomDebloatScriptUrl);
        LastSoftwareStatus = res.ExecutionSuccess ? "Custom script executed successfully." : $"Custom script failed: {res.Message}";
        return Task.CompletedTask;
    });
}
