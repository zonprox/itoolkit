# Project: iToolkit Modernization (C# .NET 10+ WPF win-x64)

## Architecture
- **Target Platform**: Windows 10 (22H2+) & Windows 11 (21H2–24H2) 64-bit (`win-x64`) exclusively. Zero 32-bit (x86) or ARM legacy code.
- **Runtime & Cross-Compilation**: .NET 10.0 SDK (`net10.0` / `net10.0-windows` with `<EnableWindowsTargeting>true</EnableWindowsTargeting>`), builds and publishes on Linux without requiring live Windows GUI subsystems.
- **Solution Layout**:
  - `IToolkit.sln`: Master solution uniting core library, WPF application, and test suite.
  - `src/IToolkit.Core/` (`net10.0` class library): Domain models, platform service abstractions (`IRegistryService`, `IProcessRunner`, `IFileSystemService`, `IWmiService`, `INetworkService`, `ISystemTelemetryService`), Atomic Registry Safety Engine, Process Lock Pre-Execution Guards, Resource & Cryptographic Guards, and the 5 Operational Pillar services.
  - `src/IToolkit.App/` (`net10.0-windows` WPF executable): Fluent UI / Mica styling, real-time System Telemetry Header/Dashboard, MVVM ViewModels, 5 pillar views, docked live activity log console replacing legacy TUI console pause, Administrator elevation manifest (`app.manifest`).
  - `tests/IToolkit.Tests/` (`net10.0` xUnit test suite): Comprehensive Unit, Integration/Workflow, and Static Analysis tests (zero legacy residue, zero PowerShell shims, 100% English).
- **Packaging Pipeline**:
  - `scripts/package-and-upload.sh`: Compiles and publishes multi-file portable win-x64 `iToolKit.exe`, packages `iToolKit.zip`, computes SHA-256, and uploads to public host (`storage.to`).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Planning & Docs Overhaul | Complete rewrite of .planning/, PROJECT.md, README.md, AGENTS.md, TEST_INFRA.md | M1 | Survey 1, 2, 3 |
| 2 | Pure win-x64 Architecture | Strictly target 64-bit Windows 10/11; purge all x86/ARM legacy clutter | M1, M2 | User Directive |
| 3 | Administrator Elevation Manifest | app.manifest requireAdministrator & runtime elevation check | M2 | Survey 2 |
| 4 | Atomic Registry Engine | Pre-mutation .reg backup to Backups/Registry/, automatic rollback, [-KeyPath] sentinels | M2 | Survey 2 |
| 5 | Process Lock Pre-Execution Guards | Graceful close + timeout + force kill for Office/locking processes before mutations | M2 | Survey 2 |
| 6 | Resource & Crypto Guards | >= 1.2x free disk space check, SHA-256 hash calculation & verification before cleanup | M2 | Survey 2 |
| 7 | Platform Abstractions | IRegistryService, IProcessRunner, IFileSystemService, IWmiService, INetworkService, ISystemTelemetryService | M2 | Survey 2 |
| 8 | Pillar 1 — DISM & SFC Combo | Automated DISM + SFC dual repair pipeline & SFC scan | M3 | Survey 1 |
| 9 | Pillar 1 — Windows Update & WMI | Reset WU components (35 DLLs, 4 services) & WMI repository /salvagerepository | M3 | Survey 1 |
| 10 | Pillar 1 — Unified Disk Cleanup | WinSxS, WU cache, Delivery Optimization, system logs, temp caches (>24h threshold) | M3 | Survey 1 |
| 11 | Pillar 2 — Office Click-to-Run & WAM | C2R service repair/scrubber, WAM/OneAuth token cache reset, HW acceleration toggle | M3 | Survey 1 |
| 12 | Pillar 2 — Word/Excel/PowerPoint Repairs | Normal.dotm, add-in isolation, XLSTART/UI cache/DDE, GDI leakers, font/slide cache, Quick Repairs | M3 | Survey 1 |
| 13 | Pillar 2 — Outlook MAPI & Limit Expansion | Binary registry decoding (UTF-16LE/ANSI), Outbox purge, 100GB limit registry expansion | M3 | Survey 1 |
| 14 | Pillar 2 — Automated PST Pipeline | Bundled PST creation, folder cloning, rule migration, data file context operations | M3 | Survey 1 |
| 15 | Pillar 3 — Network Remediation | TCP/IP, Winsock, DNS, DHCP, ARP, NLA, Proxy reset, SMB hardening (InsecureGuestAuth=1) | M3 | Survey 1 |
| 16 | Pillar 3 — Printer Subsystem Remediation | Print Spooler queue/service/DLL/MOF/RPCSS, NeXX: port reset, Point & Print policies, 12 error codes | M3 | Survey 1 |
| 17 | Pillar 4 — Local & Domain Identity | Local account CRUD, SID -500 Admin enablement, zero-RSAT domain user unlock, safe domain disjoin | M3 | Survey 1 |
| 18 | Pillar 4 — User Profile & Robocopy Backup | Profile discovery (OneDrive redirection), Chrome/Edge bookmarks, PFX certs, Robocopy sync, SHA-256 manifest & restore | M3 | Survey 1 |
| 19 | Pillar 5 — 8-App Installer Catalog | Winget-first vs non-Winget direct download/extraction for 8 canonical apps | M3 | Survey 1 |
| 20 | Pillar 5 — Desktop, Policies & Debloat | Shortcuts, default apps/Chrome policies, Winget repair, external debloat tool launchers | M3 | Survey 1 |
| 21 | Modern WPF Fluent UI / Mica Dashboard | Windows 11 Mica/Fluent UI shell, real-time telemetry header (OS, CPU, RAM, Disk, Net, Admin) | M4 | Survey 2 |
| 22 | Live Activity Log Console | Docked real-time log stream replacing legacy console pause, showing progress and final status | M4 | Survey 2 |
| 23 | 5 Pillar Navigation Views | Responsive UI cards and action triggers for all 5 operational pillars | M4 | Survey 2 |
| 24 | Comprehensive Unit & Workflow Tests | Mocked platform tests for all core safety engines and 5 pillars passing 100% | M5 | Survey 3 |
| 25 | Static Analysis Zero-Residue Tests | C# tests asserting zero *.ps1/*.bat files, zero legacy shims/aliases, 100% English | M5 | Survey 3 |
| 26 | Clean-Slate Repository Purge | Removal of 1,098 legacy files (Modules/, Tests/, Build/, TestLogs/, *.log, *.reg, stale zip) | M6 | Survey 3 |
| 27 | Packaging Pipeline & Public Upload | Updated scripts/package-and-upload.sh producing multi-file portable win-x64 application, IToolkit.zip, upload, live URL & SHA-256 | M6 | Survey 3 |
| 28 | Git Stage, Commit & Remote Push | Clean commit with English message and push to origin/main with clean working tree | M6 | Survey 3 |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Planning & Documentation Overhaul | Rewrite .planning/, PROJECT.md, README.md, AGENTS.md, TEST_INFRA.md | None | DONE |
| 2 | Native C# Solution & Core Safety Engine | Solution setup, net10.0 Core, safety abstractions, atomic registry, process locks, elevation | M1 | DONE |
| 3 | 5 Core Operational Pillars Implementation | Pure C# implementation of all 5 pillar domain services for win-x64 | M2 | DONE |
| 4 | Modern Fluent UI / Mica WPF Application | net10.0-windows WPF GUI (iToolKit.exe), telemetry dashboard header, MVVM, docked activity console | M2, M3 | DONE |
| 5 | Testing Track: E2E, Integration & Static Analysis | Complete test suite (Tiers 1-4), static analysis zero-residue assertions, iToolKit naming consistency, TEST_READY.md | M2, M3 | IN_PROGRESS |
| 6 | Clean-Slate Purge, Build, Package, Upload & Push | Delete legacy files, win-x64 multi-file portable build (iToolKit.exe), package iToolKit.zip, upload to cloud, git push | M4, M5 | PLANNED |

## Code Layout
```
/home/user/projects/itoolkit/
├── IToolkit.sln
├── src/
│   ├── IToolkit.Core/
│   │   ├── IToolkit.Core.csproj (net10.0)
│   │   ├── Abstractions/ (IRegistryService, IProcessRunner, IFileSystemService, IWmiService, INetworkService, ISystemTelemetryService, IActivityLogger)
│   │   ├── Safety/ (AtomicRegistryEngine, ProcessLockGuard, ResourceGuard, CryptographicGuard, ElevationGuard)
│   │   ├── Models/ (Domain records, DTOs, Catalog items, Manifests)
│   │   ├── Services/
│   │   │   ├── SystemHealth/ (SystemHealthService, StorageCleanupService)
│   │   │   ├── Office/ (OfficeSuiteService, WordRepairService, ExcelRepairService, PowerPointRepairService, OutlookService)
│   │   │   ├── Connectivity/ (ConnectivityService, PrinterService)
│   │   │   ├── Identity/ (LocalAccountService, DomainService, ProfileDiscoveryService, BookmarkExportService, CertificateService, BackupService)
│   │   │   └── Software/ (AppInstallerService, WingetService, ShortcutService, PolicyService, DebloatService)
│   │   ├── Mvvm/ (ObservableObject, RelayCommand, AsyncRelayCommand)
│   │   ├── ViewModels/ (MainViewModel, TelemetryHeaderViewModel, LiveLogViewModel, Pillar ViewModels)
│   │   └── Utilities/ (MapiBinaryDecoder, SidResolver, RegistryPathNormalizer)
│   └── IToolkit.App/
│       ├── IToolkit.App.csproj (net10.0-windows)
│       ├── app.manifest (requireAdministrator)
│       ├── App.xaml / App.xaml.cs
│       ├── MainWindow.xaml / MainWindow.xaml.cs
│       ├── Native/ (WindowsRegistryService, WindowsProcessRunner, WindowsFileSystemService, WindowsWmiService, WindowsNetworkService, WindowsTelemetryService, ActivityLogger)
│       ├── Views/ (Pillar views, TelemetryHeaderControl, LiveLogConsoleControl)
│       └── Styles/ (Fluent UI / Mica themes, typography, colors, control templates)
├── tests/
│   └── IToolkit.Tests/
│       ├── IToolkit.Tests.csproj (net10.0)
│       ├── TestDoubles/ (MockRegistryService, MockProcessRunner, MockFileSystemService, MockWmiService, MockNetworkService, MockTelemetryService, TestActivityLogger)
│       ├── Safety/ (AtomicRegistryEngineTests, ProcessLockGuardTests, ResourceGuardTests, CryptographicGuardTests)
│       ├── Services/ (SystemHealthServiceTests, OfficeSuiteServiceTests, ConnectivityServiceTests, IdentityServiceTests, AppInstallerServiceTests)
│       ├── ViewModels/ (MainViewModelTests, TelemetryViewModelTests, LiveLogViewModelTests)
│       └── StaticAnalysis/ (ZeroLegacyResidueTests, ZeroLegacyShimsTests, EnglishLocalizationTests)
├── scripts/
│   └── package-and-upload.sh (modernized bash script for dotnet publish & upload)
├── .planning/
│   └── codebase/ (ARCHITECTURE.md, CONVENTIONS.md, STACK.md, STRUCTURE.md, TESTING.md, ROADMAP.md, CONCERNS.md, INTEGRATIONS.md)
├── PROJECT.md
├── README.md
├── AGENTS.md
├── TEST_INFRA.md
└── TEST_READY.md
```
