# Project: IToolkit Winget Integration & Dedicated App Management

## Architecture
- **Layer 1: Platform & Abstraction (`IToolkit.Core`)**
  - `IProcessRunner` / `IFileSystemService` / `IRegistryService` / `ProcessLockGuard`
  - `WingetCliParser`: Robust dynamic offset table parser slicing variable columnar output (`Name`, `Id`, `Version`, `Available`, `Source`, `Match`) and error code translator (`0`, `3010`, `0x8A15002B`, `0x8A150014`, `0x8A150019`, `1223`).
  - `IAppInstallerService` & `AppInstallerService`: Upgraded service supporting existing 8-app enterprise catalog with strict backward compatibility, plus comprehensive Winget package search, installed software listing, update detection, package installation, per-app upgrade, and silent uninstallation.
  - Data records: `WingetPackage`, `WingetInstalledApp`, `WingetUpdateItem`, `AppCatalogItem`, `AppInstallResult`, `WingetStatus`.
- **Layer 2: Presentation & Shell (`IToolkit.App`)**
  - Framework: .NET 10 WPF (`net10.0-windows`), x64 single-file, zero 3rd-party UI libraries, Fluent Design theme (`App.xaml`).
  - In-house MVVM: `ViewModelBase`, `RelayCommand`, `AsyncRelayCommand`.
  - Shell: `MainWindow.xaml` Left Slim Navigation Rail, adding dedicated top-level "App Management" pillar (`AppManagementViewModel` / `AppManagementView.xaml`).
  - View Layout: 3-tab layout:
    1. "Search & Discover": Search input, live winget query results grid, install action with progress.
    2. "Installed Applications": Installed app inventory, filter, versions, uninstall action with `ISafetyConfirmationService`.
    3. "Available Updates": Available updates grid, per-app update action, and "Upgrade All" batch trigger.
  - Dependency Injection: Registered as singleton in `ServiceRegistration.cs`.
- **Layer 3: Verification & Automated Tests (`IToolkit.Tests`)**
  - Unit & mock tests for `WingetCliParser`, `AppInstallerService` winget methods, and `AppManagementViewModel`.
  - Regression testing guaranteeing all 1,120 existing tests continue to pass.
  - Real-world integration test harness on Windows host testing `7zip.7zip` lifecycle (search -> install -> verify -> uninstall -> assert pre-test clean state).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Winget Output & Error Parser | Parse dynamic fixed-width tables and decode `0x8A15xxxx`, `3010`, `1223` exit codes | M1 | Survey 2 |
| 2 | Winget Search Query | Non-interactive package discovery via `winget search <query> --source winget` | M1 | Survey 1, 2 |
| 3 | Installed Applications Inventory | List installed packages from ARP & Winget via `winget list --disable-interactivity` | M1 | Survey 1, 2 |
| 4 | Available Updates Detection | Query upgradable packages via `winget list --upgrade-available` | M1 | Survey 1, 2 |
| 5 | Single Package Installation | Install winget package unattended via `--id <id> --exact --source winget --silent` | M1 | Survey 1, 2 |
| 6 | Single Package Upgrade | Upgrade specific package via `winget upgrade --id <id> --exact --silent` | M1 | Survey 1, 2 |
| 7 | Package Uninstallation | Silent uninstallation via `winget uninstall --id <id> --exact --silent` | M1 | Survey 1, 2 |
| 8 | Backward Compatibility Guard | Keep existing 8-app catalog, batch install sequencing, and 1,120 unit tests intact | M1 | Survey 1 |
| 9 | AppManagementViewModel | MVVM ViewModel managing search, installed list, updates, commands, and busy states | M2 | Survey 3 |
| 10 | AppManagementView (3-Tab UI) | Search & Discover, Installed Apps, Available Updates tabs using Fluent styles | M2 | Survey 3 |
| 11 | NavRail & Shell Integration | Add "App Management" NavRail item, DataTemplate in MainWindow.xaml, and DI registration | M2 | Survey 3 |
| 12 | Real-World Host Verification | Live Windows verification of search, install, detect, uninstall using `7zip.7zip` | M3 | Survey 1, 2 |
| 13 | Pre-Test State Restoration | Guarantee complete uninstallation of test app and cleanup of any temporary artifacts | M3 | Survey 1, 2 |
| 14 | E2E Testing Suite (Tiers 1-4) | Comprehensive test cases covering features, boundaries, combinations, workflows | M4 | E2E Track |
| 15 | Adversarial Hardening (Tier 5) | White-box stress testing, edge-case validation, code coverage hardening | M4 | Final Gate |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Core Winget Engine & Models | `WingetCliParser`, models, `IAppInstallerService` extension methods, exit code mapping, unit tests | none | DONE |
| M2 | Dedicated App Management UI | `AppManagementViewModel`, `AppManagementView.xaml`, `MainWindow` NavRail integration, DI registration | M1 | DONE |
| M3 | Real-World Windows Verification & Cleanup | Real-world execution with `7zip.7zip`, installation check, uninstallation, and pre-test state cleanup | M1, M2 | DONE |
| M4 | Final E2E Test Suite & Adversarial Hardening | Pass 100% of E2E tests (Tiers 1-4), adversarial test generation (Tier 5), code hardening | M1, M2, M3 | DONE |

## Interface Contracts
### `IToolkit.Core.Models.SoftwareModels`
```csharp
public record WingetPackage(
    string Name,
    string Id,
    string Version,
    string? Match,
    string Source);

public record WingetInstalledApp(
    string Name,
    string Id,
    string Version,
    string? AvailableVersion,
    string Source);

public record WingetUpdateItem(
    string Name,
    string Id,
    string InstalledVersion,
    string AvailableVersion,
    string Source);
```

### `IToolkit.Core.Services.Software.IAppInstallerService`
```csharp
public interface IAppInstallerService
{
    // Existing 8-app catalog methods (strictly preserved)
    IReadOnlyList<AppCatalogItem> GetCatalog();
    AppCatalogItem? GetApp(string appId);
    AppInstallResult InstallApplication(string appId);
    IReadOnlyList<AppInstallResult> InstallBatch(IEnumerable<string> appIds);
    bool CreateDesktopShortcut(string shortcutName, string targetPath, string? arguments = null);
    bool SetDefaultBrowser(string browserExecutable = "chrome.exe");
    bool SetDefaultPdfViewer(string pdfExecutable = "FoxitPDFReader.exe");
    bool ConfigureUblockOriginLitePolicy();

    // New Winget Subsystem Capabilities
    Task<IReadOnlyList<WingetPackage>> SearchPackagesAsync(string query, CancellationToken ct = default);
    Task<IReadOnlyList<WingetInstalledApp>> GetInstalledApplicationsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<WingetUpdateItem>> GetAvailableUpdatesAsync(CancellationToken ct = default);
    Task<AppInstallResult> InstallWingetPackageAsync(string packageId, CancellationToken ct = default);
    Task<AppInstallResult> UpgradeWingetPackageAsync(string packageId, CancellationToken ct = default);
    Task<AppInstallResult> UninstallWingetPackageAsync(string packageId, CancellationToken ct = default);
}
```

### `IToolkit.App.ViewModels.AppManagementViewModel`
```csharp
public class AppManagementViewModel : ViewModelBase
{
    public ObservableCollection<WingetPackageViewModel> SearchResults { get; }
    public ObservableCollection<InstalledAppViewModel> InstalledApps { get; }
    public ObservableCollection<AppUpdateViewModel> AvailableUpdates { get; }

    public string SearchQuery { get; set; }
    public string InstalledFilterQuery { get; set; }

    public IAsyncRelayCommand SearchAppsCommand { get; }
    public IAsyncRelayCommand RefreshInstalledCommand { get; }
    public IAsyncRelayCommand CheckUpdatesCommand { get; }
    public IAsyncRelayCommand<WingetPackageViewModel> InstallAppCommand { get; }
    public IAsyncRelayCommand<InstalledAppViewModel> UninstallAppCommand { get; }
    public IAsyncRelayCommand<AppUpdateViewModel> UpdateAppCommand { get; }
    public IAsyncRelayCommand UpgradeAllAppsCommand { get; }
}
```

## Code Layout
- `src/IToolkit.Core/Models/SoftwareModels.cs` — Winget models & records
- `src/IToolkit.Core/Services/Software/WingetCliParser.cs` — Dynamic table & exit code parser
- `src/IToolkit.Core/Services/Software/IAppInstallerService.cs` — Upgraded service interface
- `src/IToolkit.Core/Services/Software/AppInstallerService.cs` — Core implementation
- `src/IToolkit.App/ViewModels/AppManagementViewModel.cs` — ViewModel
- `src/IToolkit.App/Views/AppManagementView.xaml` & `.xaml.cs` — View
- `src/IToolkit.App/MainWindow.xaml` & `MainViewModel.cs` — Navigation integration
- `src/IToolkit.App/ServiceRegistration.cs` — DI registration
- `tests/IToolkit.Tests/Software/WingetCliParserTests.cs` — Parser unit tests
- `tests/IToolkit.Tests/Software/WingetAppInstallerServiceTests.cs` — Service unit tests
- `tests/IToolkit.Tests/UI/AppManagementViewModelTests.cs` — ViewModel tests
- `tests/IToolkit.Tests/Integration/WingetRealWorldVerificationTests.cs` — Real Windows integration & cleanup verification tests
