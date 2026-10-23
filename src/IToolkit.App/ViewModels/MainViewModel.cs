namespace IToolkit.App.ViewModels;

using System;
using System.Windows.Input;

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

    public MainViewModel(
        TelemetryHeaderViewModel telemetryHeader,
        ActivityConsoleViewModel activityConsole,
        DashboardViewModel dashboardViewModel,
        SystemHealthViewModel systemHealthViewModel,
        OfficeOutlookViewModel officeOutlookViewModel,
        ConnectivityViewModel connectivityViewModel,
        IdentityBackupViewModel identityBackupViewModel,
        SoftwareOptimizationViewModel softwareOptimizationViewModel)
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

    public ICommand NavigateCommand { get; }
    public ICommand ToggleNavRailCommand { get; }

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
