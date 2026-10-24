# iToolKit — Native Windows Desktop Administration Suite

[![Target](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(win--x64)-blue.svg)](#system-requirements)
[![Framework](https://img.shields.io/badge/.NET-10.0%20LTS-purple.svg)](#development--compilation)
[![UI](https://img.shields.io/badge/UI-Fluent%20%2F%20Mica%20WPF-0078D7.svg)](#user-interface)
[![License](https://img.shields.io/badge/Language-100%25%20English-success.svg)](#license--standards)

**iToolKit** is a high-performance, 100% native C# desktop application built on **.NET 10.0 LTS** and **WPF** (Windows Presentation Foundation) with native Windows 10/11 Fluent Design (`ThemeMode="System"`). Engineered specifically for IT administrators, system support engineers, and helpdesk technicians, iToolKit provides unified endpoint remediation, system diagnostics, automated application provisioning, and data protection across **64-bit Windows 10 (22H2+) and Windows 11 (21H2–24H2)**.

---

## Key Highlights

- **100% Native Compiled C# Engine**: Zero legacy PowerShell or batch script dependencies. All logic, registry engines, and repairs execute as compiled native code.
- **Strictly 64-bit (`win-x64`) Architecture**: Optimized exclusively for modern 64-bit Windows 10/11 endpoints; zero 32-bit (x86) or ARM legacy clutter.
- **Fluent UI & Windows 11 Mica Experience**: Native Mica backdrop with dark-mode integration, Segoe UI Variable typography, and responsive MVVM architecture.
- **Real-Time System Telemetry Dashboard**: Live header monitoring OS build, Administrator elevation status, CPU utilization, RAM consumption, and system drive health.
- **Docked Live Activity Console**: Real-time monospace terminal console streaming detailed command execution logs and progress with visual completion summaries.
- **Atomic Registry Safety Engine**: Automatic pre-mutation `.reg` backups in `Backups/Registry/`, reversible rollback deletion sentinels (`[-KeyPath]`), and automatic rollback on failure.
- **Process Lock Pre-Execution Guards**: Graceful shutdown protocol and exclusive lock verification for conflicting applications (`OUTLOOK`, `WINWORD`, `EXCEL`, `POWERPNT`, `spoolsv`, `chrome`) before performing state-mutating repairs.
- **Resource & Cryptographic Guards**: Mandatory `>= 1.2x` free disk space validation and pre/post SHA-256 cryptographic checksum matching before data migration or source cleanup.

---

## The 5 Core Operational Pillars

```
┌────────────────────────────────────────────────────────────────────────┐
│                        iToolkit Operational Pillars                    │
├──────────────────┬──────────────────┬──────────────────┬───────────────┤
│ 🛡️ System Health │ 💼 Office Suite   │ 🖧 Connectivity  │ 👤 Identity   │
│    & Maintenance │    & Outlook     │    & Printers    │    & Backup   │
├──────────────────┴──────────────────┴──────────────────┴───────────────┤
│                 📦 Software Deployment & OS Optimization               │
└────────────────────────────────────────────────────────────────────────┘
```

### Pillar 1 — System Health & Maintenance
- **Automated DISM + SFC Combo**: Sequential repair pipeline running DISM `RestoreHealth` followed by SFC `/scannow` to fix component store corruption before drawing clean system files.
- **SFC Integrity Scan**: Standalone system file verification scan with output stream analysis.
- **DISM RestoreHealth**: Online Windows Component Store repair with optional `/Source` support.
- **Reset Windows Update Components**: Safely halts servicing daemons (`wuauserv`, `cryptSvc`, `bits`, `msiserver`), clears or renames `SoftwareDistribution` and `catroot2`, re-registers 35 core DLLs via `regsvr32.exe`, and restarts services.
- **WMI Repository Repair**: Diagnoses consistency via `winmgmt /verifyrepository`, salavages schema via `/salvagerepository`, and resets corrupt repositories via `/resetrepository`.
- **Unified Storage Cleanup**: Multi-target cleaner purging superseded WinSxS components (`StartComponentCleanup /ResetBase`), Windows Update download cache, Delivery Optimization chunks, crash dumps (`MEMORY.DMP`, minidumps), and temporary caches (`> 24h` age filter).

### Pillar 2 — Office & Outlook Productivity Suite
- **Office Common**:
  - Click-to-Run (C2R) service validation, cache cleanup, and Quick/Online repairs via `OfficeClickToRun.exe`.
  - Microsoft 365 / Entra ID WAM and OneAuth identity token cache purge (resolving login loops and error `0x80090016`).
  - Suite-wide hardware acceleration toggle (`DisableHardwareAcceleration = 1`) across Word, Excel, PowerPoint, and Common Graphics.
  - Terminate all Office processes across 32 executable signatures.
  - Native Clean Uninstaller & Scrubber: 6-phase removal of processes, services, tasks, registry hives, license tokens, and guarded filesystem roots.
- **Word, Excel & PowerPoint Diagnostics & Repairs**:
  - *Word*: `Normal.dotm` backup and reset, startup add-in isolation (`.disabled`), registry Data/Options reset, orphaned lock file cleanup (`~$*.docx`), and composite `WordQuickRepair`.
  - *Excel*: `XLSTART` isolation, UI cache reset (`Excel16.xlb`, `Excel.officeUI`), DDE (`IgnoreRemoteRequests = 0`) and calculation mode reset, Resiliency keys cleanup, GDI handle leak audit (`GetGuiResources`) and termination, and composite `ExcelQuickRepair`.
  - *PowerPoint*: Slide and font cache purge, Resiliency cleanup, slide show hardware acceleration disablement, and composite `PowerPointQuickRepair`.
- **Outlook & PST/OST Management**:
  - MAPI profile binary registry decoding: Extracts PST/OST paths from Unicode (`001f6700`) and ANSI (`001e6700`) null-terminated binary properties.
  - Quick Mail & Cache Repair: Stuck Outbox email purge, Send/Receive Settings (`.srs`) reset, RoamCache cleanup **strictly preserving `Stream_Autocomplete_*.dat`**, and `/resetnavpane` navigation reset.
  - 100GB PST/OST Limit Expansion: Sets `MaxLargeFileSize = 102400` and `WarnLargeFileSize = 97280` in user and policy registry hives.
  - Bundled New Default PST Pipeline: Automated workflow that applies 100GB limits, creates a new PST store, clones folder hierarchies, remaps Outlook message rules, and sets default delivery store.
  - Data File Context Operations: Compaction, 100GB limit expansion, Backup with SHA-256 verification, Relocation with 1.2x disk headroom check, and Safe Deletion.

### Pillar 3 — Network Connectivity & Print Subsystem
- **Network Remediation**:
  - Automated one-click remediation: Sequential execution of DNS cache flush (`/flushdns`), DHCP lease release and renew, ARP and route cache deletion, Winsock catalog reset, TCP/IP stack reset, and Network Location Awareness (NLA) restart.
  - WinHTTP & System Proxy Reset: Resets system proxy via `netsh winhttp reset proxy` and clears user proxy overrides (`ProxyEnable = 0`).
  - SMB Hardening & Error 0x80070035/0x80070043 Resolution: Enables Network Discovery and File Sharing firewall groups, starts FDResPub, SSDPSRV, and UPnP services, enables NetBIOS over TCP/IP, and configures LanmanWorkstation parameters (`AllowInsecureGuestAuth = 1`, `RequireSecuritySignature = 0`).
  - Network Adapter Cycling: Programmatic disable and re-enable of network adapters via NetAdapter CIM APIs.
- **Print Spooler & Printer Remediation**:
  - Stuck Print Job Purge: Stops `Spooler` service, forces `spoolsv.exe` termination if hung, purges `.SHD` and `.SPL` files from `%SystemRoot%\System32\spool\PRINTERS`, and restarts spooler.
  - Component Registration: Re-registers `printui.dll`, `prntvpt.dll`, compiles `prnprov.mof`, and enforces service dependency on `RPCSS`.
  - Stale `NeXX:` Port Binding Reset: Cleans orphaned virtual printer port properties in `HKCU:\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts` to resolve Office print dialog hangs.
  - Point-and-Print Remediation (PrintNightmare): Configures `RpcAuthnLevelPrivacyEnabled` and `RestrictDriverInstallationToAdministrators` for either StrictAdminOnly or Compatibility modes.
  - 12-Item Printer Error Catalog: Targeted remediations for `0x0000011b`, `0x00000709`, `0x0000007c`, `0x0000007e`, `0x00000bcb`, `0x00000002`, `0x00000006`, `0x00000057`, `0x000003e3`, `SpoolerCrash`, `NePortConflict`, and `RefreshConnections`.
  - Network Printer Port Probes: Probes TCP 445 (SMB), 135 (RPC), and 9100 (RAW JetDirect) for diagnostic verification.

### Pillar 4 — Identity, Access & Data Protection
- **Local Account Administration**:
  - Enumeration of local accounts with status (enabled, locked, password required).
  - Language-Agnostic Built-in Administrator Activation: Resolves account by SID suffix `-(?:500)$` regardless of localized OS language name, enabling account and resetting password.
  - Account Unlock: Clears lockout flags on local accounts.
  - Account Deletion Safety Guardrails: Enforces non-bypassable blocks against deleting the built-in Administrator (SID `-500`) or the currently logged-in user account. Deletes SAM account, profile directory, and `ProfileList` registry subkey.
- **Zero-RSAT Active Directory & Domain Operations**:
  - Domain Reachability Pre-Flight: Resolves SRV `_ldap._tcp.dc._msdcs.<Domain>` and verifies ports 88 (Kerberos), 389 (LDAP), and 445 (SMB).
  - Domain Account Management: Uses .NET `System.DirectoryServices.AccountManagement` for direct DC communication without requiring RSAT tools.
  - CIM Domain Join: Joins domain via `Win32_ComputerSystem.JoinDomainOrWorkgroup`.
  - Domain Disjoin & Critical Lockout Defense: Prior to disjoining a workstation from a domain, verifies that an enabled local administrator (SID `-500` or named `Administrator`) exists; immediately aborts disjoin if no local administrator is active, preventing workstation lockout.
- **User Profile & Data Protection**:
  - User Profile Discovery: Maps shell folders and detects OneDrive folder redirection.
  - Chromium Bookmark JSON Extraction: Extracts `Bookmarks` from Chrome and Edge user profiles with SHA-256 verification.
  - X.509 Certificate Management: Exports public (`.cer`) and private (`.pfx` password-protected) certificates across LocalMachine and CurrentUser stores.
  - Multi-Threaded Robocopy Synchronization: Executes `robocopy.exe /E /MT:16 /COPY:DAT /R:2 /W:2 /XJ /ZB /NP` with bitmask exit code analysis (`< 8` success).
  - Cryptographic Backup Manifest (`IToolkit_Backup_Manifest.json`): Generates recursive file catalog with exact byte sizes and SHA-256 hashes, with automatic integrity verification during profile restore.

### Pillar 5 — Software Deployment & OS Optimization
- **Enterprise 8-Application Catalog**:
  - Managed Applications: `UniKey`, `UltraVNC`, `K-Lite Codec Pack`, `Google Chrome`, `Visual C++ Redistributable AIO`, `Foxit PDF Reader`, `Zalo`, `WinRAR`.
  - Dual Deployment Strategy:
    - *Winget-Supported Apps* (`Chrome`, `FoxitReader`, `KLiteCodec`, `WinRAR`): Install via official Winget package ID with direct CDN fallback.
    - *Non-Winget Apps* (`UniKey`, `VCRedistAIO`, `Zalo`, `UltraVNC`): Set `WingetId = null`, download official installers directly to `%TEMP%`, execute silent installation or archive extraction, and automatically clean up temporary installer files.
  - Dependency Sequencing: When installing `All`, automatically sequences `VCRedistAIO` to position 1.
  - Process Conflict Guard: Audits and closes conflicting running executables before installer execution.
- **Desktop Shortcuts & Policy Management**:
  - Desktop Shortcuts: Creates `.lnk` shell links on Desktop and Start Menu, removing obsolete non-standard shortcuts.
  - Default Handlers: Registers Chrome as default browser and Foxit as default PDF viewer.
  - Chrome Enterprise Extension Policy: Configures `ExtensionInstallForcelist` to enforce silent deployment of **uBlock Origin Lite** (`ddkjiahejlhfcafbddmgiahcphecmpfh`).
- **Windows Package Manager (Winget) Infrastructure**:
  - Diagnostic health audit of `winget.exe` in PATH and execution aliases.
  - Autonomous self-repair: PATH repair, source cache reset (`winget source reset --force`), and AppX package re-registration.
  - Batch silent upgrades (`winget upgrade --all --silent --accept-package-agreements`).
- **External Debloat Tool Launchers**:
  - Supports `Win11Debloat` (`https://debloat.raphi.re/`) and `BrowserDebloat` (`https://debloat.yashg.dev/install.ps1`).
  - Strict security boundaries: Pre-flight internet check, HTTPS enforcement, whitelisted domains, and isolated execution without confirmation prompts.

---

## System Requirements

| Specification | Requirement |
|---|---|
| **Operating System** | Windows 10 (22H2+) or Windows 11 (21H2, 22H2, 23H2, 24H2) 64-bit (`win-x64`) ONLY. |
| **Architecture** | 64-bit (`x64`) strictly. (32-bit x86 and ARM architectures are not supported). |
| **Privileges** | Local Administrator privileges (mandatory `requireAdministrator` manifest and startup verification). |
| **Runtime** | .NET 10.0 LTS Desktop Runtime (included in self-contained release builds). |

---

## Development & Compilation

### 1. Prerequisites
- **.NET 10.0 LTS SDK** (v10.0.400 or higher)

### 2. Build the Solution
```powershell
dotnet build IToolkit.sln -c Release
```

### 3. Run Automated Tests
```powershell
dotnet test IToolkit.sln -c Release
```
All unit, workflow, and static analysis tests run deterministically with 0 failures and 0 skipped tests.

### 4. Publish Self-Contained Release
```powershell
dotnet publish src/IToolkit.App/IToolkit.App.csproj -c Release -r win-x64 --self-contained true
```

---

## User Interface & Safety Guarantees

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│  IToolkit v2.0  [🛡️ Elevated: Administrator]              Windows 11 Pro 23H2 (22631)   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│  ⚡ CPU: 12%  |  🧠 RAM: 5.8 / 16.0 GB (36%)  |  💾 C: 192 GB Free  |  🌐 Connected    │
├───────────────┬────────────────────────────────────────────────────────────────────────┤
│ NAVIGATION    │ ACTIVE PILLAR VIEW AREA                                                │
│               │                                                                        │
│ 🛡️ System      │  [DISM + SFC Combo Repair]   [SFC Integrity Scan]  [DISM Restore]      │
│   Health      │                                                                        │
│               │  [Reset Windows Update]       [Repair WMI Repository]                  │
│ 💼 Office &   │                                                                        │
│   Outlook     │  [Unified Storage Cleanup (WinSxS, WU Cache, Temp)]                   │
│               │                                                                        │
│ 🖧 Connectivity│  ────────────────────────────────────────────────────────────────────  │
│   & Printers  │  Target Volume: C:\          Component Store: Cleanable                │
│               │  Action Status: Ready                                                  │
│ 👤 Identity   │                                                                        │
│   & Backup    │                                                                        │
│               │                                                                        │
│ 📦 Software & │                                                                        │
│   Install     │                                                                        │
├───────────────┴────────────────────────────────────────────────────────────────────────┤
│ ▼ LIVE EXECUTION CONSOLE & ACTIVITY LOG                             [Clear] [Copy] 📌 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ [13:30:01 INFO  Core] Starting Unified Storage Cleanup...                              │
│ [13:30:02 INFO  Health] Running DISM StartComponentCleanup with ResetBase...           │
│ [13:30:15 SUCC  Health] DISM completed successfully. Reclaimed 2,140 MB disk space.    │
│ [13:30:18 SUCC  Core] Operation finished with exit code 0. Status: Completed.          │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Live Activity Console**: Completely replaces legacy console pause prompts by docking directly into the application window, streaming real-time status output, exit codes, and timestamps.
- **Transactional Rollback**: Any interrupted or failed registry operation is immediately rolled back using automatically staged `.reg` dumps.

---

## License & Standards

- **Language Standard**: 100% English across all user interfaces, source code, manifests, comments, logs, and documentation.
- **Enterprise Grade**: Zero third-party telemetry; strictly local diagnostic execution.
- (c) 2026 iToolkit Team. All rights reserved.
