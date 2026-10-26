# iToolkit Test Infrastructure & Automated Verification Framework

> **Target Platform**: Windows 10 (22H2+) & Windows 11 (21H2–24H2) 64-bit (`win-x64`)  
> **Test Framework**: xUnit (`net10.0`), FluentAssertions, Moq / In-Memory Doubles  
> **Execution Standard**: 100% Pass, 0 Failures, 0 Skipped Tests across Linux and Windows CI

---

## 1. Test Architecture Overview

The automated test infrastructure for iToolkit runs entirely on **xUnit** under **.NET 10.0 SDK** (`dotnet test IToolkit.sln`). The suite is housed in `tests/IToolkit.Tests/` and targets `net10.0`.

To enable rapid, deterministic execution on Linux development machines and automated CI pipelines, the test architecture employs a hexagonal pattern: domain services in `IToolkit.Core` interact with native Windows facilities solely through mockable interface abstractions (`IRegistryService`, `IProcessRunner`, `IFileSystemService`, `IWmiService`, `INetworkService`, `ISystemTelemetryService`). In-memory test doubles simulate all operating system behaviors, filesystem hierarchies, process lifecycles, and registry hives without requiring Windows elevation or GUI subsystems.

```
tests/IToolkit.Tests/
├── TestDoubles/                               # Mock and in-memory platform service implementations
│   ├── MockRegistryService.cs                 # In-memory hierarchical registry key/value store
│   ├── MockProcessRunner.cs                   # Simulated process runner with configurable outputs
│   ├── MockFileSystemService.cs               # In-memory virtual filesystem with lock simulation
│   ├── MockWmiService.cs                      # Pre-seeded WMI query result provider
│   ├── MockNetworkService.cs                  # Configurable network reachability mock
│   ├── MockTelemetryService.cs                # Deterministic telemetry provider
│   └── TestActivityLogger.cs                  # Captured log entry collection for assertion
│
├── Safety/                                    # Core Safety Engine Unit Tests
│   ├── AtomicRegistryEngineTests.cs           # Backup creation, rollback sentinels, auto-rollback
│   ├── ProcessLockGuardTests.cs               # CloseMainWindow, timeout, kill, lock checks
│   ├── ResourceGuardTests.cs                  # 1.2x disk space boundary analysis & exceptions
│   └── CryptographicGuardTests.cs             # SHA-256 accuracy and pre/post migration match
│
├── Services/                                  # Domain Service Unit Tests across 5 Pillars
│   ├── SystemHealthServiceTests.cs            # DISM, SFC, Windows Update, WMI, storage cleanup
│   ├── OfficeSuiteServiceTests.cs             # C2R repair, WAM token purge, HW acceleration
│   ├── WordRepairServiceTests.cs              # Normal.dotm, add-in isolation, lock files
│   ├── ExcelRepairServiceTests.cs             # XLSTART, UI cache, DDE, GDI leak audit
│   ├── PowerPointRepairServiceTests.cs        # Slide/font cache purge, resiliency keys
│   ├── OutlookServiceTests.cs                 # MAPI binary decoding, 100GB limit, PST pipeline
│   ├── ConnectivityServiceTests.cs            # TCP/IP, Winsock, DNS, DHCP, SMB guest auth
│   ├── PrinterServiceTests.cs                 # Spooler purge, NeXX ports, Point-and-Print, 12 errors
│   ├── IdentityServiceTests.cs                # Local account CRUD, SID -500 admin resolution
│   ├── DomainServiceTests.cs                  # Zero-RSAT AD reachability, join/disjoin defense
│   ├── BackupServiceTests.cs                  # Profile discovery, Robocopy, SHA-256 manifest
│   └── AppInstallerServiceTests.cs            # 8-app catalog, Winget vs direct download/cleanup
│
├── ViewModels/                                # Presentation State & Command Execution Tests
│   ├── MainViewModelTests.cs                  # Navigation state and active pillar view switching
│   ├── TelemetryViewModelTests.cs             # Telemetry snapshot binding and refresh cycles
│   └── LiveLogViewModelTests.cs               # Activity logging, filtering, and summary bar
│
└── StaticAnalysis/                            # Repository Hygiene & Compliance Assertions
    ├── ZeroLegacyResidueTests.cs              # Asserts 0 *.ps1, *.psm1, *.psd1, *.bat files
    ├── ZeroLegacyShimsTests.cs                # Asserts 0 pwsh/PowerShell/dual-hotkey references
    └── EnglishLocalizationTests.cs            # Asserts 100% English across all source, XAML, docs
```

---

## 2. 4-Tier Opaque-Box Testing Methodology

```
┌────────────────────────────────────────────────────────────────────────┐
│                        4-TIER TEST METHODOLOGY                         │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Category-Partition Testing (Equivalence Classes)              │
│  - Partition domain inputs into valid, invalid, and boundary subsets   │
│  - Isolated testing of all domain service operations and safety guards │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Boundary Value Analysis (BVA)                                 │
│  - Rigorous probing of critical numerical and structural limits        │
│  - Disk headroom multipliers (1.199x vs 1.200x), PST size limits      │
│  - Buffer lengths, null terminators, 0-byte files, MAX_PATH boundaries │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Pairwise / Combinatorial Testing                              │
│  - Combinatorial combinations of environmental & operational states    │
│  - App types x Winget states x Network reachability matrix             │
│  - OS builds x Elevation status x Service running/stopped states       │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 4: Workload & Stress Testing                                     │
│  - High-throughput asynchronous live log streaming                    │
│  - Multi-thousand file backup trees and SHA-256 manifest verification  │
│  - Rapid cancellation, simulated I/O errors, and atomic rollback checks│
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Tier 1: Category-Partition Testing
Systematically decomposes system operations into orthogonal equivalence partitions:
- **Registry Engine Partitions**:
  - Existing Key vs Non-Existent Key
  - Value Types: `REG_SZ`, `REG_DWORD`, `REG_BINARY`, `REG_MULTI_SZ`
  - Mutation Outcome: Successful modification vs Mid-stream failure triggering rollback
- **Process Lock Guard Partitions**:
  - Running Status: Unloaded vs Active GUI Window (`CloseMainWindow`) vs Headless Worker
  - Exit Behavior: Exits within timeout vs Hangs (triggering `Kill`)
  - Target Specifier: By process name (`OUTLOOK`) vs By Process ID (`PID`)
- **Account Management Partitions**:
  - Scope: Local account vs Domain user
  - Privilege: Regular user vs Built-in Administrator (SID `-500`)
  - Lockout Status: Active lockout vs Normal state
  - Deletion Target: Regular local user vs Active logged-in user vs SID `-500` Administrator (blocked)
- **Domain Service Partitions**:
  - DC Reachability: All ports open (88, 389, 445) vs DNS failure vs Firewall block
  - Disjoin Safety: Enabled local admin present (disjoin allowed) vs No local admin (disjoin aborted)

### 2.2 Tier 2: Boundary Value Analysis (BVA)
Probes critical thresholds at and immediately adjacent to boundaries:
- **1.2x Disk Space Headroom Multiplier**:
  - Free space $< \lceil \text{Required} \times 1.2 \rceil$ -> Fails pre-flight check, throws `InvalidOperationException`.
  - Free space $= \lceil \text{Required} \times 1.2 \rceil$ -> Passes pre-flight check cleanly.
  - Free space $> \lceil \text{Required} \times 1.2 \rceil$ -> Passes pre-flight check cleanly.
  - Required space $= 0$ bytes -> Passes (skips volume check).
- **Outlook PST Scaling Thresholds**:
  - File size $< 45\text{ GB}$ -> Normal status; no threshold expansion required.
  - File size $\ge 45\text{ GB}$ -> Recommends limit expansion and triggers new default PST pipeline.
  - Size policy limits: `MaxLargeFileSize = 102400` (100 GB in MB), `WarnLargeFileSize = 97280` (95 GB in MB).
- **MAPI Binary Decoding null-terminators**:
  - Unicode: Even byte offset `\0\0` boundary vs odd byte offset vs unterminated stream.
  - ANSI: Single byte `\0` boundary vs unterminated stream.
  - Empty stream (`byte[0]`) -> returns `null`.

### 2.3 Tier 3: Pairwise Combinatorial Testing
Tests multi-factor operational interactions across realistic permutations:
- **Application Installer Matrix**:
  - App Category: `{ Winget-Supported, Non-Winget }`
  - Winget Health: `{ Healthy, Corrupted, Missing }`
  - Connectivity: `{ Online, Offline, DNS-Blocked }`
  - Local State: `{ Clean, Partially-Installed, Active-Process-Lock }`
- **Office Quick Repairs**:
  - Target Application: `{ Word, Excel, PowerPoint }`
  - Process State: `{ Running, Closed }`
  - Corrupted Files: `{ Normal.dotm / XLSTART / Cache present, Missing }`
  - Registry State: `{ Normal, Corrupted/Resiliency keys present }`

### 2.4 Tier 4: Workload & Stress Testing
- **Cryptographic Manifest Workload**: Verifies recursive hashing and manifest creation on simulated directory structures containing 10,000 files with deep nesting.
- **Asynchronous Live Console Concurrency**: Emits 5,000 log events across 10 concurrent threads to ensure zero deadlocks in `ActivityLogger` and lossless streaming to the UI.
- **Fault Injection & Rollback**: Injects random filesystem exceptions during atomic registry writes and verifies 100% complete rollback to original state via imported `.reg` files.

---

## 3. Static Analysis Test Suite

Located in `tests/IToolkit.Tests/StaticAnalysis/`, these automated C# tests act as repository cleanliness and integrity gates:

### 3.1 Zero Legacy Residue Tests (`ZeroLegacyResidueTests.cs`)
```csharp
[Fact]
public void Repository_Contains_Zero_Legacy_Scripts()
{
    var repoRoot = GetRepoRoot();
    var legacyExtensions = new[] { "*.ps1", "*.psm1", "*.psd1", "*.bat" };
    var violations = legacyExtensions
        .SelectMany(ext => Directory.GetFiles(repoRoot, ext, SearchOption.AllDirectories))
        .Where(f => !f.Contains(".git") && !f.Contains(".agents"))
        .ToList();

    violations.Should().BeEmpty("all legacy PowerShell and batch scripts must be completely eliminated");
}

[Fact]
public void Repository_Contains_Zero_Legacy_Directories()
{
    var repoRoot = GetRepoRoot();
    var prohibitedDirs = new[] { "Modules", "Build", "TestLogs" };
    foreach (var dir in prohibitedDirs)
    {
        Directory.Exists(Path.Combine(repoRoot, dir)).Should().BeFalse($"directory '{dir}' must not exist");
    }
}
```

### 3.2 Zero Legacy Shims & Aliases Tests (`ZeroLegacyShimsTests.cs`)
- Scans all `.cs`, `.xaml`, `.sh`, and `.json` files.
- Asserts zero occurrences of `pwsh`, `powershell`, `powershell.exe`, or `System.Management.Automation`.
- Asserts zero occurrences of legacy dual-hotkey routing (e.g. numeric menu keys 17..21 or 10..16) or old TUI submenu names.

### 3.3 100% English Localization Tests (`EnglishLocalizationTests.cs`)
- Scans all source code, documentation, and build files.
- Verifies that all identifiers, comments, string literals, and documentation contain strictly English text, asserting zero non-English characters outside standard punctuation and symbols.

---

## 4. Verification Commands

All test runs are executed via the standard .NET CLI:

```bash
# 1. Run Complete Automated Test Suite (100% Pass, 0 Failures)
dotnet test IToolkit.sln

# 2. Run Unit Tests Only
dotnet test tests/IToolkit.Tests --filter Category=Unit

# 3. Run Pillar Workflow Tests Only
dotnet test tests/IToolkit.Tests --filter Category=Workflow

# 4. Run Static Analysis Gates Only
dotnet test tests/IToolkit.Tests --filter Category=StaticAnalysis

# 5. Build Release Configuration (0 Warnings, 0 Errors)
dotnet build IToolkit.sln -c Release
```
