# IToolkit — PowerShell IT Support & Administration Toolkit

**IToolkit** is a modular, lightweight, terminal-based PowerShell administration and diagnostics toolkit designed for Windows 10 and Windows 11. It provides system administrators, desktop support technicians, and IT engineers with rapid diagnostics, repair, profile migration, and account management capabilities.

---

## Key Features

- **Pure PowerShell Engine**: Built with pure PowerShell compatible with both Windows PowerShell 5.1 (.NET Framework 4.8) and PowerShell 7+ Core (.NET 8+). Zero external third-party binary dependencies.
- **Automatic Self-Elevation**: Launchers detect administrative privileges on startup and request UAC elevation automatically.
- **100% Offline Production Code**: Zero telemetry, zero external network calls during standard diagnostics, and strictly local-only runtime execution.
- **Atomic Safety & Rollback**: Automatic `.reg` backup files saved prior to modifying registry entries; SHA-256 checksums verified before deleting migrated files.
- **Enterprise TUI Menu**: Keyboard-driven interactive console interface with colored status indicators (`[OK]`, `[WARN]`, `[FAIL]`) and mandatory confirmation prompts for destructive operations.

---

## Target Environment Requirements

| Component | Supported Scope |
|---|---|
| **Operating System** | Windows 10 (22H2+) & Windows 11 (21H2, 22H2, 23H2, 24H2) ONLY. (Legacy Windows 7/8/XP strictly excluded). |
| **Microsoft Office** | Microsoft Office 2016, Office 2019, Office 2021, and Office 2024 (Office 16.0 ClickToRun / LTSC). Legacy Office 2010/2013 strictly disallowed. |
| **PowerShell Version** | Windows PowerShell 5.1 (standard in Windows 10/11) or PowerShell 7.0+. |
| **Privileges** | Local Administrator privileges (required for system diagnostics, registry repair, and spooler resets). |

---

## Quick Start

### Option 1: Batch Launcher (Recommended for Desktop Technicians)
1. Extract `IToolkit.zip` to your desired folder (e.g. `C:\IToolkit`).
2. Double-click `Run-IToolkit.bat` (or right-click and choose **Run as administrator**).
3. If not already elevated, Windows UAC will prompt for Administrator consent and re-launch automatically.

### Option 2: PowerShell Console
Open an elevated PowerShell console and run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\Start-IToolkit.ps1
```

---

## Module Overview

### 1. Outlook & PST Management (`Modules/Outlook`)
- Discover PST and OST files across profiles and disk drives.
- Safely relocate oversized data files with disk space validation and SHA-256 checksum verification.
- Re-map MAPI profile registry entries to new storage locations.
- Expand Unicode PST size limit registry policies (`MaxLargeFileSize` / `WarnLargeFileSize` >30GB / up to 50GB).
- Launch profile management compaction guidance.
- Backup and restore PST files with cryptographic validation.

### 2. Office & Excel Troubleshooting (`Modules/Office`)
- Toggle hardware graphics acceleration (`DisableHardwareAcceleration`) to resolve Excel rendering crashes.
- Reset corrupted Excel UI and printer cache files (`Excel16.xlb`, `XLSTART`).
- Clean Office document cache (`OfficeFileCache`) and temporary Web Add-in files (`Wef`).
- Audit and disable problematic COM add-ins; clear the Excel `DisabledItems` resiliency list.
- Audit GDI and User handle usage to identify and terminate leaking Excel processes.
- Invoke Microsoft Office ClickToRun Quick Repair or Online Repair.

### 3. Printers & Spooler Repair (`Modules/Printers`)
- Inspect print spooler service state and queue backlog (`.SPL` / `.SHD` files).
- Stop spooler, purge corrupt print queues, and safely restart the service.
- Re-register print spooler DLLs, restore RPCSS dependencies, and recompile MOF subsystem.
- Reset corrupted virtual `NeXX:` printer port bindings to eliminate Excel print preview freezes.
- Audit and remediate Point and Print / PrintNightmare policy restrictions (`RpcAuthnLevelPrivacyEnabled`).
- Diagnose network printer connectivity (SMB 445, RPC 135, RAW 9100).

### 4. User Profile Backup & Migration (`Modules/Backup`)
- Discover standard user profile directories (Desktop, Documents, Downloads, Pictures, Favorites) with OneDrive redirection detection.
- Export Chromium bookmarks (Google Chrome and Microsoft Edge) to structured JSON.
- Export personal certificates from `Cert:\CurrentUser\My` (PFX format).
- High-performance multi-threaded Robocopy synchronization engine (`/MT:16 /ZB /XJ`).
- Generate and verify SHA-256 backup integrity manifests (`IToolkit_Backup_Manifest.json`).
- Restore user profile data categories with integrity validation.

### 5. Accounts & Domain Administration (`Modules/Accounts`)
- Local account CRUD: list, create, unlock, enable, and disable local accounts.
- Zero-RSAT domain user administration via .NET `AccountManagement`.
- Activate built-in Administrator account (SID `-500`) and safely reset administrative passwords.
- Pre-flight domain reachability validator (DNS, Kerberos 88, LDAP 389, SMB 445).
- Universal CIM-based domain join.
- Safe domain disjoin with mandatory local administrator lockout prevention.

### 6. External Tools & Quick Launchers (`Modules/ExternalTools`)
- Pre-flight internet connectivity validation before contacting external hosts.
- Quick launcher for **Windows 11 / 10 Debloat** (`Win11Debloat`).
- Quick launcher for **Chris Titus Tech Windows Utility** (`WinUtil`).
- Mandatory user confirmation prompts and `-WhatIf` dry-run support.

---

## Architecture & Safety Guarantees

- **Registry Safety Engine**: Every mutating registry modification automatically generates a rollback `.reg` file in `Backups/`.
- **Pre-Flight Resource Checks**: Ensures destination drives have at least 1.2x free space before initiating data file transfers.
- **Process Lock Management**: Inspects locking processes (e.g. `OUTLOOK.EXE`, `EXCEL.EXE`) and attempts graceful termination before accessing data files.
- **Enterprise Logging**: All actions and diagnostics are logged in structured format to console and timestamped logs in `Logs/IToolkit_YYYYMMDD.log`.

---

## License & Distribution

(c) 2026 IToolkit Team. Enterprise IT Administration. All rights reserved.
Distributed as clean standalone package with zero telemetry.
