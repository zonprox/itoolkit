namespace IToolkit.App.ViewModels;

using System;
using System.Threading.Tasks;
using System.Windows.Input;
using IToolkit.Core.Abstractions;

public class MainViewModel : ViewModelBase
{
    private readonly TelemetryHeaderViewModel _telemetryHeader;
    private readonly ActivityConsoleViewModel _activityConsole;

    // Pillar ViewModels
    private readonly DashboardViewModel _dashboardViewModel;
    private readonly SystemHealthViewModel _systemHealthViewModel;
    private readonly OfficeOutlookViewModel _officeOutlookViewModel;
    private readonly ConnectivityViewModel _connectivityViewModel;
    private readonly IdentityBackupViewModel _identityBackupViewModel;
    private readonly SoftwareOptimizationViewModel _softwareOptimizationViewModel;

    private ViewModelBase _currentPageViewModel;
    private string _currentPillarName = "Dashboard";
    private bool _isNavRailExpanded = true;

    private bool _isScanning;
    private double _scanProgressPercentage;
    private string _scanProgressText = "0%";
    private string _scanStatusText = "Ready";

    public MainViewModel(
        TelemetryHeaderViewModel telemetryHeader,
        ActivityConsoleViewModel activityConsole,
        DashboardViewModel dashboardViewModel,
        SystemHealthViewModel systemHealthViewModel,
        OfficeOutlookViewModel officeOutlookViewModel,
        ConnectivityViewModel connectivityViewModel,
        IdentityBackupViewModel identityBackupViewModel,
        SoftwareOptimizationViewModel softwareOptimizationViewModel,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _telemetryHeader = telemetryHeader ?? throw new ArgumentNullException(nameof(telemetryHeader));
        _activityConsole = activityConsole ?? throw new ArgumentNullException(nameof(activityConsole));

        _dashboardViewModel = dashboardViewModel ?? throw new ArgumentNullException(nameof(dashboardViewModel));
        _systemHealthViewModel = systemHealthViewModel ?? throw new ArgumentNullException(nameof(systemHealthViewModel));
        _officeOutlookViewModel = officeOutlookViewModel ?? throw new ArgumentNullException(nameof(officeOutlookViewModel));
        _connectivityViewModel = connectivityViewModel ?? throw new ArgumentNullException(nameof(connectivityViewModel));
        _identityBackupViewModel = identityBackupViewModel ?? throw new ArgumentNullException(nameof(identityBackupViewModel));
        _softwareOptimizationViewModel = softwareOptimizationViewModel ?? throw new ArgumentNullException(nameof(softwareOptimizationViewModel));

        // Default landing view is Dashboard
        _currentPageViewModel = _dashboardViewModel;

        NavigateCommand = new RelayCommand<string>(NavigateToPillar);
        ToggleNavRailCommand = new RelayCommand(() => IsNavRailExpanded = !IsNavRailExpanded);
        ScanSystemCommand = new AsyncRelayCommand(RunSystemScanAsync, () => !IsScanning);
    }

    public string AppTitle => "iToolKit";
    public string AppSubtitle => "Windows Utility Suite";

    public TelemetryHeaderViewModel TelemetryHeader => _telemetryHeader;
    public ActivityConsoleViewModel ActivityConsole => _activityConsole;

    public DashboardViewModel DashboardViewModel => _dashboardViewModel;
    public SystemHealthViewModel SystemHealthViewModel => _systemHealthViewModel;
    public OfficeOutlookViewModel OfficeOutlookViewModel => _officeOutlookViewModel;
    public ConnectivityViewModel ConnectivityViewModel => _connectivityViewModel;
    public IdentityBackupViewModel IdentityBackupViewModel => _identityBackupViewModel;
    public SoftwareOptimizationViewModel SoftwareOptimizationViewModel => _softwareOptimizationViewModel;

    public ViewModelBase CurrentPageViewModel
    {
        get => _currentPageViewModel;
        set => SetProperty(ref _currentPageViewModel, value);
    }

    public string CurrentPillarName
    {
        get => _currentPillarName;
        set => SetProperty(ref _currentPillarName, value);
    }

    public bool IsNavRailExpanded
    {
        get => _isNavRailExpanded;
        set => SetProperty(ref _isNavRailExpanded, value);
    }

    public bool IsScanning
    {
        get => _isScanning;
        set
        {
            if (SetProperty(ref _isScanning, value))
            {
                ScanSystemCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public double ScanProgressPercentage
    {
        get => _scanProgressPercentage;
        set => SetProperty(ref _scanProgressPercentage, value);
    }

    public string ScanProgressText
    {
        get => _scanProgressText;
        set => SetProperty(ref _scanProgressText, value);
    }

    public string ScanStatusText
    {
        get => _scanStatusText;
        set => SetProperty(ref _scanStatusText, value);
    }

    public ICommand NavigateCommand { get; }
    public ICommand ToggleNavRailCommand { get; }
    public IAsyncRelayCommand ScanSystemCommand { get; }

    public async Task RunSystemScanAsync()
    {
        if (IsScanning) return;

        try
        {
            IsScanning = true;
            SetScanProgress(15, "Scanning hardware telemetry, OS build, and storage health...");
            Logger?.LogInfo("SystemScan", "Starting full-system diagnostic scan across all pillars...");

            // Step 1: System Telemetry & Storage Health
            await _telemetryHeader.RefreshTelemetryAsync();
            _dashboardViewModel.SystemHealthStatus = $"Drive C: {_telemetryHeader.DiskFreeSpaceText} ({_telemetryHeader.DiskHealthStatus})";
            _dashboardViewModel.NetworkStatus = $"Network: {_telemetryHeader.NetworkStatusText}";
            _systemHealthViewModel.StatusMessage = $"System Ready - {_telemetryHeader.OsDescription} ({_telemetryHeader.OsBuild}) | Drive C: {_telemetryHeader.DiskFreeSpaceText}";
            await _connectivityViewModel.RefreshAdaptersAsync();
            _connectivityViewModel.LastNetworkStatus = $"Network {_telemetryHeader.NetworkStatusText}";
            _connectivityViewModel.StatusMessage = $"Network {_telemetryHeader.NetworkStatusText} - {_connectivityViewModel.SupportedErrorCodes.Count} printer error codes ready.";

            // Step 2: Local Accounts, SID-500 Admin & User Profile Map
            SetScanProgress(45, "Scanning local user accounts, SID -500 Administrator, and profile paths...");
            await _identityBackupViewModel.ScanIdentityAsync();
            _dashboardViewModel.BackupStatus = $"Accounts: {_identityBackupViewModel.Accounts.Count} local | Admin: {(_identityBackupViewModel.IsBuiltInAdminEnabled ? "Enabled" : "Disabled")}";

            // Step 3: Office & Outlook MAPI Data Files (PST/OST)
            SetScanProgress(75, "Scanning MAPI profiles for Outlook PST/OST data stores...");
            await _officeOutlookViewModel.ScanOutlookDataFilesAsync();
            _dashboardViewModel.OfficeStatus = $"MAPI Stores: {_officeOutlookViewModel.DataFiles.Count} PST/OST file(s) discovered";

            // Step 4: Windows Package Manager (Winget) & Software Catalog
            SetScanProgress(90, "Checking Windows Package Manager (Winget) subsystem and catalog...");
            await _softwareOptimizationViewModel.ScanSoftwareStatusAsync();
            _dashboardViewModel.SoftwareStatus = $"Winget: {_softwareOptimizationViewModel.WingetVersionText}";

            // Complete
            SetScanProgress(100, "Full system scan completed.");
            string summary = $"System scan complete: {_identityBackupViewModel.Accounts.Count} local accounts, {_officeOutlookViewModel.DataFiles.Count} MAPI stores, Winget {_softwareOptimizationViewModel.WingetVersionText}.";
            _dashboardViewModel.StatusMessage = summary;
            _telemetryHeader.ActiveTaskDescription = "System Ready";
            _telemetryHeader.IsTaskActive = false;
            Logger?.LogSuccess("SystemScan", summary);
        }
        catch (Exception ex)
        {
            ScanStatusText = $"System scan encountered an error: {ex.Message}";
            _telemetryHeader.ActiveTaskDescription = "Scan Error";
            _telemetryHeader.IsTaskActive = false;
            Logger?.LogError("SystemScan", ScanStatusText);
        }
        finally
        {
            IsScanning = false;
        }
    }

    private void SetScanProgress(double percentage, string status)
    {
        ScanProgressPercentage = percentage;
        ScanProgressText = $"{percentage:F0}%";
        ScanStatusText = status;
        _telemetryHeader.IsTaskActive = true;
        _telemetryHeader.ActiveTaskDescription = $"Scanning ({percentage:F0}%)...";
        _dashboardViewModel.StatusMessage = status;
    }

    public void NavigateToPillar(string? pillarName)
    {
        if (string.IsNullOrWhiteSpace(pillarName)) return;

        CurrentPillarName = pillarName;
        CurrentPageViewModel = pillarName switch
        {
            "Dashboard" => _dashboardViewModel,
            "SystemHealth" => _systemHealthViewModel,
            "OfficeOutlook" => _officeOutlookViewModel,
            "Connectivity" => _connectivityViewModel,
            "IdentityBackup" => _identityBackupViewModel,
            "SoftwareOptimization" => _softwareOptimizationViewModel,
            _ => _dashboardViewModel
        };
    }
}
