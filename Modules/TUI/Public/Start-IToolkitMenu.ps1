if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

if (-not (Get-Command -Name 'Get-ToolkitTelemetryData' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path $headerScript) {
        . $headerScript
    }
}

function Get-MainSystemInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
    $telemetry = Get-ToolkitTelemetryData

    # 1. OS & Build
    $lines.Add("OS & Build     : $($telemetry.OSDisplay) | $($telemetry.Architecture)")

    # 2. Hardware Model
    $lines.Add("Hardware Model : $($telemetry.HardwareDisplay)")

    # 3. Hardware / CPU & RAM
    $lines.Add("Processor & RAM: $($telemetry.CPUDisplay) | $($telemetry.RAMDisplay)")

    # 4. Storage Space
    $lines.Add("Storage Space  : $($telemetry.StorageDisplay)")

    # 5. Network & Domain
    $domain = "WORKGROUP"
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $domain = $env:USERDNSDOMAIN
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
        $domain = $env:USERDOMAIN
    }
    $lines.Add("Network Status : IPv4: $($telemetry.ActiveIPv4) | Domain/Workgroup: $domain")

    # 6. Security & Elevation
    $adminStr = "Standard User [Non-Elevated]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Administrator [Elevated - Full Access]"
            }
        }
        catch {
            $null = $_
        }
    }
    $psVer = $PSVersionTable.PSVersion.ToString()
    $lines.Add("Security & Env : $adminStr | PowerShell $psVer")

    # 7. User & Host
    $hostName = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $hostName = [System.Environment]::MachineName
    }
    $userName = $env:USERNAME
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = [System.Environment]::UserName
    }
    $userDomain = $env:USERDOMAIN
    $fullUser = $userName
    if (-not [string]::IsNullOrWhiteSpace($userDomain) -and $userDomain -ne $hostName) {
        $fullUser = "$userDomain\$userName"
    }
    $lines.Add("User & Host    : $fullUser | Host: $hostName")

    # 8. User Profile
    $profPath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profPath)) {
        $profPath = [System.Environment]::GetFolderPath('UserProfile')
    }
    if ([string]::IsNullOrWhiteSpace($profPath)) {
        $profPath = $env:HOME
    }
    $profName = ''
    if (-not [string]::IsNullOrWhiteSpace($profPath)) {
        try {
            $profName = Split-Path -Path $profPath -Leaf
        }
        catch {
            $profName = ''
        }
    }
    $profDisplay = $profPath
    if (-not [string]::IsNullOrWhiteSpace($profName) -and $profName -ne $userName -and -not [string]::IsNullOrWhiteSpace($profPath)) {
        $profDisplay = "$profName ($profPath)"
    }
    if ([string]::IsNullOrWhiteSpace($profDisplay)) {
        $profDisplay = 'Default Profile'
    }
    $lines.Add("User Profile   : $profDisplay")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-MainSystemInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-MainSystemInfoLines' -Value (Get-Command -Name 'Get-MainSystemInfoLines').ScriptBlock
}

function Write-ToolkitMenuDivider {
    param([int]$Width = 0)
    if ($Width -le 0) {
        if (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue) {
            $Width = Get-ToolkitLayoutWidth
        }
        else {
            $Width = 78
        }
    }
    Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
}

if (Get-Command -Name 'Write-ToolkitMenuDivider' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Write-ToolkitMenuDivider' -Value (Get-Command -Name 'Write-ToolkitMenuDivider').ScriptBlock
}

# Helper: Wait for user acknowledge and prompt before returning
function Wait-UserAcknowledge {
    try {
        if ([Console]::IsInputRedirected) {
            return
        }
    }
    catch {
        $null = $_
    }

    Write-Host ""
    Write-ToolkitMenuDivider
    Write-Host "  Press [Enter] to return to menu..." -ForegroundColor Cyan
    try {
        $ack = Read-Host
        if ($null -eq $ack) {
            return
        }
    }
    catch {
        $null = $_
    }
}

# Diagnostic Telemetry & Context Collectors for Submenus

function Get-OutlookContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # Priority: Call Get-OutlookSystemContext if available
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($null -ne $ctx) {
                $runningBadge = if ($ctx.IsRunning) { "Running (PID: $($ctx.ProcessId)) [BLOCKED]" } else { "Stopped [SAFE]" }
                $lines.Add("Outlook State  : $runningBadge")
                $prof = if ($ctx.DefaultProfile) { "$($ctx.DefaultProfile)" } else { "Outlook (Default)" }
                if ($ctx.OfficeVersion -and $ctx.OfficeVersion -ne 'None') {
                    $prof += " (Office $($ctx.OfficeVersion))"
                }
                $lines.Add("Default Profile: $prof")
                $thresh = if ($ctx.ThresholdPolicy -and $ctx.ThresholdPolicy.Description) {
                    $ctx.ThresholdPolicy.Description
                } elseif ($ctx.ThresholdPolicy -and $ctx.ThresholdPolicy.IsExpanded) {
                    "Expanded (>30GB / 100GB limit enabled)"
                } else {
                    "Default limit (~50 GB threshold)"
                }
                $lines.Add("PST Policy     : $thresh")
                $dfCount = if ($ctx.DataFiles) { $ctx.DataFiles.Count } else { 0 }
                $lines.Add("Data Files     : $dfCount Data File(s) Detected [READY]")
                return $lines.ToArray()
            }
        }
        catch {
            $null = $_
        }
    }

    # Safe fallback probe
    $procStatus = "Stopped [SAFE]"
    try {
        $p = Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue
        if ($null -ne $p) {
            $procStatus = "Running (PID: $($p.Id)) [BLOCKED]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Outlook State  : $procStatus")

    $profile = "Outlook (Default / Not Configured)"
    try {
        if (Test-Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
            $val = (Get-ItemProperty 'HKCU:\Software\Microsoft\Office\16.0\Outlook' -ErrorAction SilentlyContinue).DefaultProfile
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $profile = "$val (Office 16.0 / 365)"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Default Profile: $profile")

    $policyStatus = "Default limit (~50 GB threshold)"
    try {
        if (Test-Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST') {
            $val = (Get-ItemProperty 'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST' -ErrorAction SilentlyContinue).MaxLargeFileSize
            if ($null -ne $val -and $val -ge 102400) {
                $policyStatus = "Expanded (>30GB / 100GB limit enabled)"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("PST Policy     : $policyStatus")

    $fileInfo = "PST/OST Discovery Ready [READY]"
    try {
        if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
            $found = Find-OutlookDataFiles -Scope Registry
            if ($null -ne $found -and $found.Count -gt 0) {
                $fileInfo = "$($found.Count) Data File(s) Detected [READY]"
            }
            else {
                $fileInfo = "0 Data Files Detected [READY]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Data Files     : $fileInfo")

    return $lines.ToArray()
}

function Get-OfficeContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Office Product
    $officeVer = "Office 16.0 (Standard Desktop / LTSC)"
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') {
            $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($null -ne $c2r) {
                $verNum = $c2r.VersionToReport
                $arch = $c2r.Platform
                $prod = $c2r.ProductReleaseIds
                $officeVer = "Microsoft Office ClickToRun v$verNum [$arch] ($prod) [READY]"
            }
        }
        elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot') {
            $officeVer = "Microsoft Office 16.0 Desktop (MSI / Volume LTSC) [READY]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Office Product : $officeVer")

    # 2. Graphics Acceleration
    $accelStatus = "Enabled [DEFAULT]"
    try {
        $regPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
        if (Test-Path $regPath) {
            $val = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DisableHardwareAcceleration
            if ($val -eq 1) {
                $accelStatus = "Disabled [SAFE]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Graphics Acceleration : $accelStatus")

    # 3. Excel Process
    $excelStatus = "Stopped [SAFE]"
    try {
        $procs = Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue
        if ($null -ne $procs) {
            $pCount = $procs.Count
            $pids = ($procs | ForEach-Object { $_.Id }) -join ', '
            $excelStatus = "Running ($pCount instance; PID: $pids) [WARN]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Excel Process  : $excelStatus")

    # 4. Excel UI Cache
    $cacheStatus = "Clean [READY]"
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $xlb15 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel15.xlb'
            $xlb16 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel16.xlb'
            if ((Test-Path $xlb15) -or (Test-Path $xlb16)) {
                $cacheStatus = "Cache Present (Excel16.xlb found) [WARN]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Excel UI Cache : $cacheStatus")

    return $lines.ToArray()
}

function Get-PrintersContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Spooler Service Status
    $spoolerStatus = "Spooler Service: Unknown [WARN]"
    try {
        $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $badge = if ($svc.Status -eq 'Running') { '[READY]' } else { '[FAIL]' }
            $spoolerStatus = "Spooler Service: $($svc.Status) (Startup: $($svc.StartType)) $badge"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Spooler Status : $spoolerStatus")

    # 2. Print Queue Jobs
    $queueInfo = "0 Pending Jobs in Spool Folder [CLEAN]"
    try {
        $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $spoolDir) {
            $shdFiles = Get-ChildItem -Path $spoolDir -Filter '*.SHD' -ErrorAction SilentlyContinue
            if ($null -ne $shdFiles -and $shdFiles.Count -gt 0) {
                $queueInfo = "$($shdFiles.Count) Stuck Job(s) Queued in Spool Directory [WARN]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Print Queue    : $queueInfo")

    # 3. Point & Print Policy
    $rpcPolicy = "Default / Unrestricted [WARN]"
    try {
        $regP = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
        if (Test-Path $regP) {
            $val = (Get-ItemProperty $regP -ErrorAction SilentlyContinue).RestrictDriverInstallationToAdministrators
            if ($val -eq 1) {
                $rpcPolicy = "StrictAdminOnly [SAFE]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("RPC Policy     : $rpcPolicy")

    return $lines.ToArray()
}

function Get-BackupContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Target Profile
    $profPath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profPath)) {
        $profPath = [System.Environment]::GetFolderPath('UserProfile')
    }
    $lines.Add("Target Profile : $profPath [READY]")

    # 2. Storage Free Space
    $freeSpace = "Drive Space Available [READY]"
    try {
        $telemetry = Get-ToolkitTelemetryData
        if ($null -ne $telemetry -and -not [string]::IsNullOrWhiteSpace($telemetry.StorageDisplay)) {
            $freeSpace = "$($telemetry.StorageDisplay) [READY]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Storage Target : $freeSpace")

    # 3. Backup Scope
    $lines.Add("Backup Scope   : Desktop, Documents, Downloads, Bookmarks, Certificates [READY]")

    return $lines.ToArray()
}

function Get-AccountsContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Current User
    $currUser = "$env:USERDOMAIN\$env:USERNAME"
    $lines.Add("Current User   : $currUser")

    # 2. Privilege Level
    $adminStr = "Standard User [WARN]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Local Administrator [ELEVATED]"
            }
        }
        catch {
            $null = $_
        }
    }
    $lines.Add("Privilege Level: $adminStr")

    # 3. Domain Status
    $domStatus = "Workgroup Mode ($env:USERDOMAIN) [READY]"
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $domStatus = "Active Directory Domain ($env:USERDNSDOMAIN) [READY]"
    }
    $lines.Add("Domain Status  : $domStatus")

    # 4. Built-in Administrator
    $lines.Add("Built-in Administrator : Active (SID -500) Management Available [READY]")

    return $lines.ToArray()
}

function Get-ExternalToolsContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Internet Status
    $netStatus = "Checking Connectivity..."
    try {
        if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
            $isOnline = Test-InternetConnectivity
            if ($isOnline) {
                $netStatus = "ONLINE [READY]"
            }
            else {
                $netStatus = "OFFLINE [BLOCKED]"
            }
        }
        else {
            $netStatus = "ONLINE [READY]"
        }
    }
    catch {
        $netStatus = "OFFLINE [BLOCKED]"
    }
    $lines.Add("Internet Check : $netStatus")

    # 2. Integrated Launchers
    $lines.Add("Tool 1         : Browser Debloat (Chrome & Chromium cleanup & debloat) [READY]")
    $lines.Add("Tool 2         : Win11Debloat (Windows 11 bloatware & telemetry purge) [READY]")

    return $lines.ToArray()
}

function Get-WindowsRepairContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. OS & Architecture
    $telemetry = Get-ToolkitTelemetryData
    $lines.Add("OS & Build     : $($telemetry.OSDisplay) | $($telemetry.Architecture)")

    # 2. Elevation Status
    $adminStr = "Standard User [WARN: Non-Elevated]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Administrator [ELEVATED - Full Access]"
            }
        }
        catch { $null = $_ }
    }
    $lines.Add("Elevation State: $adminStr")

    # 3. Component Store & System Root
    $sysDir = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $lines.Add("System Root    : $sysDir | Component Store [ONLINE]")

    # 4. Repair Subsystems
    $lines.Add("Repair Tools   : SFC, DISM, Windows Update, Network Stack, WMI [READY]")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-WindowsRepairContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-WindowsRepairContextInfoLines' -Value (Get-Command -Name 'Get-WindowsRepairContextInfoLines').ScriptBlock
}

function Get-AppInstallerContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Desktop Location & Current User
    $currentUser = if ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopPath)) { $desktopPath = "$env:USERPROFILE\Desktop" }
    $lines.Add("Current User   : $currentUser | Desktop: $desktopPath")

    # 2. Package Manager & Installation Engine
    $hasWinget = [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)
    $pmStr = if ($hasWinget) { "winget [READY]" } else { "Direct HTTPS Installer [READY]" }
    $lines.Add("Deploy Engine  : $pmStr")

    # 3. Installed Apps Overview
    $chromeStat = "[MISSING]"
    $foxitStat = "[MISSING]"
    $unikeyStat = "[MISSING]"
    $zaloStat = "[MISSING]"
    if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
        try {
            $apps = Get-ToolkitInstalledApplication
            $chrome = $apps | Where-Object { $_.AppName -eq 'Chrome' }
            if ($chrome -and $chrome.Installed) { $chromeStat = "[INSTALLED]" }
            $foxit = $apps | Where-Object { $_.AppName -eq 'FoxitReader' }
            if ($foxit -and $foxit.Installed) { $foxitStat = "[INSTALLED]" }
            $unikey = $apps | Where-Object { $_.AppName -eq 'UniKey' }
            if ($unikey -and $unikey.Installed) { $unikeyStat = "[INSTALLED]" }
            $zalo = $apps | Where-Object { $_.AppName -eq 'Zalo' }
            if ($zalo -and $zalo.Installed) { $zaloStat = "[INSTALLED]" }
        } catch {
            $null = $_
        }
    }
    $lines.Add("App Status     : Chrome $chromeStat | Foxit $foxitStat | UniKey $unikeyStat | Zalo $zaloStat")
    $lines.Add("Catalog Targets: UniKey, UltraVNC, K-Lite, Chrome, VCRedist, Foxit, Zalo [READY]")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-AppInstallerContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-AppInstallerContextInfoLines' -Value (Get-Command -Name 'Get-AppInstallerContextInfoLines').ScriptBlock
}

function Start-IToolkitMenu {
<#
.SYNOPSIS
    Launches the interactive keyboard-driven main console menu for IToolkit with Tri-Panel UI/UX.
.DESCRIPTION
    Main console menu engine orchestrating category navigation across all toolkit modules
    using the standardized Tri-Panel layout (Header Banner, Concise Action Matrix, Details & Prerequisites
    Panel, and Live Contextual Status & Telemetry Panel):
    1. Outlook & PST
    2. Office & Excel
    3. Network & Printers
    4. User Profile Backup
    5. Account Admin
    6. External Tools
    R. Refresh Screen
    Q. Exit Console
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately (used for automated testing).
.PARAMETER NonInteractive
    Switch to run in headless automation mode: renders menu once and returns cleanly.
.PARAMETER DefaultSelection
    Optional pre-selected choice string.
.PARAMETER MenuOption
    Optional menu option to invoke directly.
.EXAMPLE
    Start-IToolkitMenu
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [string]$DefaultSelection,

        [Parameter(Mandatory = $false)]
        [Alias('Option')]
        [string]$MenuOption
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Menu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $mainNav = @(
        @{ Key = 'R'; Label = 'Refresh Screen' },
        @{ Key = 'Q'; Label = 'Exit Console' }
    )
    $mainDetails = @(
        @{ Key = '1'; Action = 'Outlook & PST'; Description = 'PST/OST discovery, relocation, profile repoints & limits.'; Prerequisite = 'Outlook installed [READY]' },
        @{ Key = '2'; Action = 'Office & Excel'; Description = 'Hardware acceleration, cache reset, add-ins, GDI audit.'; Prerequisite = 'Office 2013-365 [READY]' },
        @{ Key = '3'; Action = 'Network & Printers'; Description = 'Print spooler queue, Ne ports, Point & Print policies.'; Prerequisite = 'Spooler service [READY]' },
        @{ Key = '4'; Action = 'User Profile Backup'; Description = 'User folder sync, Chromium bookmarks, certs & manifests.'; Prerequisite = 'Local drive space [READY]' },
        @{ Key = '5'; Action = 'Account Admin'; Description = 'Local/domain account management, SID -500, domain health.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '6'; Action = 'External Tools'; Description = 'Browser Debloat, Win11Debloat, network testing.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '7'; Action = 'Windows Repair'; Description = 'SFC scan, DISM RestoreHealth, Windows Update & network reset.'; Prerequisite = 'Administrator rights [RECOMMENDED]' },
        @{ Key = '8'; Action = 'Quick App Installer'; Description = 'Silent install UniKey, UltraVNC, K-Lite, Chrome, VCRedist, Foxit.'; Prerequisite = 'Internet access [READY]' }
    )

    # If NonInteractive flag is set without MenuOption, display main menu once and return
    if ($NonInteractive -and [string]::IsNullOrWhiteSpace($MenuOption)) {
        $sysInfo = Get-MainSystemInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT :: ENTERPRISE IT SUPPORT CONSOLE' -Subtitle 'Windows 10 / 11 IT Administration & Repair Toolkit' -InfoLines $sysInfo
        Show-ToolkitDetailPanel -Details $mainDetails -NavActions $mainNav -Title 'ACTIONS & COMMANDS'
        Write-Host ""
        Write-ToolkitStatus -Message "Menu launched in non-interactive mode. Returning." -Type 'INFO'
        return
    }

    # If MenuOption is specified directly, handle single option execution
    if (-not [string]::IsNullOrWhiteSpace($MenuOption)) {
        $subParams = @{}
        if ($ExitImmediately) {
            $subParams['ExitImmediately'] = $true
        }
        if ($NonInteractive) {
            $subParams['NonInteractive'] = $true
        }

        switch ($MenuOption.ToUpperInvariant()) {
            '1' { Invoke-ToolkitSubmenuOutlook @subParams }
            '2' { Invoke-ToolkitSubmenuOffice @subParams }
            '3' { Invoke-ToolkitSubmenuPrinters @subParams }
            '4' { Invoke-ToolkitSubmenuBackup @subParams }
            '5' { Invoke-ToolkitSubmenuAccounts @subParams }
            '6' { Invoke-ToolkitSubmenuExternalTools @subParams }
            '7' { Invoke-ToolkitSubmenuWindowsRepair @subParams }
            '8' { Invoke-ToolkitSubmenuAppInstaller @subParams }
            'Q' {
                Write-ToolkitStatus -Message "Exiting IToolkit." -Type 'OK'
            }
            'X' {
                Write-ToolkitStatus -Message "Exiting IToolkit." -Type 'OK'
            }
            default {
                Write-ToolkitStatus -Message "Unrecognized menu option '$MenuOption'." -Type 'WARN'
            }
        }
        return
    }

    # Main navigation loop
    $running = $true
    while ($running) {
        $sysInfo = Get-MainSystemInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT :: ENTERPRISE IT SUPPORT CONSOLE' -Subtitle 'Windows 10 / 11 IT Administration & Repair Toolkit' -ClearScreen -InfoLines $sysInfo
        Show-ToolkitDetailPanel -Details $mainDetails -NavActions $mainNav -Title 'ACTIONS & COMMANDS'

        $choice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', 'R', 'Q', 'X') -Default $DefaultSelection

        if ([string]::IsNullOrWhiteSpace($choice)) {
            break
        }

        switch ($choice.ToUpperInvariant()) {
            '1' { Invoke-ToolkitSubmenuOutlook }
            '2' { Invoke-ToolkitSubmenuOffice }
            '3' { Invoke-ToolkitSubmenuPrinters }
            '4' { Invoke-ToolkitSubmenuBackup }
            '5' { Invoke-ToolkitSubmenuAccounts }
            '6' { Invoke-ToolkitSubmenuExternalTools }
            '7' { Invoke-ToolkitSubmenuWindowsRepair }
            '8' { Invoke-ToolkitSubmenuAppInstaller }
            'R' {
                continue
            }
            'Q' {
                Write-Host ""
                Write-ToolkitStatus -Message "Exiting IToolkit. Goodbye!" -Type 'OK'
                $running = $false
            }
            'X' {
                Write-Host ""
                Write-ToolkitStatus -Message "Exiting IToolkit. Goodbye!" -Type 'OK'
                $running = $false
            }
            default {
                Write-ToolkitStatus -Message "Unrecognized option '$choice'." -Type 'WARN'
            }
        }
    }
}

# ==============================================================================
# Category Submenus (Tri-Panel Modular Layout)
# ==============================================================================

function Invoke-ToolkitSubmenuOutlook {
<#
.SYNOPSIS
    Submenu for Outlook & PST Management with item-centric UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $isOutlookRunning = $false
        try {
            $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) {
                $isOutlookRunning = $true
            }
        }
        catch {
            $null = $_
        }
        $statusBadge = if ($isOutlookRunning) { '[RUNNING]' } else { '[STOPPED]' }

        $outlookItems = @()
        $sysContext = $null
        if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
            try {
                $sysContext = Get-OutlookSystemContext
            }
            catch {
                Write-ToolkitStatus -Message "Failed to get Outlook context: $($_.Exception.Message)" -Type 'WARN'
            }
        }

        # Enumerate configured profiles
        $discoveredProfiles = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $sysContext -and $null -ne $sysContext.Profiles) {
            foreach ($p in $sysContext.Profiles) {
                if (-not [string]::IsNullOrWhiteSpace($p) -and -not $discoveredProfiles.Contains($p)) {
                    $discoveredProfiles.Add($p)
                }
            }
        }
        if ($null -ne $sysContext -and -not [string]::IsNullOrWhiteSpace($sysContext.DefaultProfile) -and $sysContext.DefaultProfile -ne 'None') {
            if (-not $discoveredProfiles.Contains($sysContext.DefaultProfile)) {
                $discoveredProfiles.Add($sysContext.DefaultProfile)
            }
        }

        foreach ($prof in $discoveredProfiles) {
            $isDef = ($null -ne $sysContext -and $sysContext.DefaultProfile -eq $prof)
            $details = if ($isDef) { 'Default Mail Profile' } else { 'Configured Mail Profile' }
            $outlookItems += [PSCustomObject]@{
                Name    = $prof
                Status  = $statusBadge
                Type    = 'Profile'
                Details = $details
                Path    = ''
                Profile = $prof
            }
        }

        # Enumerate data files via Find-OutlookDataFiles
        $rawFiles = @()
        if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
            try {
                $rawFiles = @(Find-OutlookDataFiles)
            }
            catch {
                Write-ToolkitStatus -Message "Failed to discover Outlook data files: $($_.Exception.Message)" -Type 'WARN'
            }
        }

        foreach ($f in $rawFiles) {
            $fPath = [string]$f.Path
            $fName = if (-not [string]::IsNullOrWhiteSpace($fPath)) {
                [System.IO.Path]::GetFileName($fPath)
            } else {
                'DataFile'
            }
            $fType = if ($f.Type) { [string]$f.Type } else { 'PST' }
            $fProfile = if ($f.Profile) { [string]$f.Profile } else { '' }
            $outlookItems += [PSCustomObject]@{
                Name    = $fName
                Status  = $statusBadge
                Type    = $fType
                Details = $fPath
                Path    = $fPath
                Profile = $fProfile
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $outlookInfo = Get-OutlookContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OUTLOOK & PST MANAGEMENT' -Subtitle 'PST/OST Discovery, Relocation, Compaction & Registry Policies' -ClearScreen:$clear -InfoLines $outlookInfo

        Show-ToolkitItemTable -Items $outlookItems -Columns @('Name', 'Status', 'Type', 'Details') -Headers @('NAME', 'STATUS', 'TYPE', 'PATH/DETAILS') -Title 'Mail Profiles & Data Files'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'N'; Label = 'Create New PST' },
            @{ Key = 'K'; Label = 'Kill Stuck Outlook' },
            @{ Key = 'S'; Label = 'Safe Mode' },
            @{ Key = 'E'; Label = 'Expand PST Limit (100GB)' },
            @{ Key = 'D'; Label = 'Deep Scan' },
            @{ Key = 'C'; Label = 'Compaction' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Outlook & PST Data Management'." -Type 'INFO'
            return
        }

        $validKeys = @('N', 'K', 'S', 'E', 'D', 'C', 'B', 'Q')
        $promptText = if ($outlookItems.Count -gt 0) { "  Select item [1-$($outlookItems.Count)] or action" } else { "  Select action [N, K, S, E, D, C, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $outlookItems.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'N' {
                    $targetPath = Read-Host "  Enter Target PST Path (e.g. C:\Mail\Archive.pst)"
                    if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                        if (Get-Command -Name 'New-OutlookDataFile' -ErrorAction SilentlyContinue) {
                            try {
                                $newPstRes = New-OutlookDataFile -Path $targetPath
                                if ($newPstRes -and $newPstRes.Success) {
                                    Write-ToolkitStatus -Message "New PST data file created successfully: '$targetPath'." -Type 'OK'
                                }
                                elseif ($newPstRes -and -not $newPstRes.Success) {
                                    Write-ToolkitStatus -Message "Failed to create PST file: $($newPstRes.ErrorMessage)" -Type 'FAIL'
                                }
                                else {
                                    Write-ToolkitStatus -Message "New PST data file created: '$targetPath'." -Type 'OK'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "PST creation failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "New-OutlookDataFile command not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "No target path specified. Operation cancelled." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                'K' {
                    try {
                        Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                        Write-ToolkitStatus -Message "Outlook process termination command completed." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to stop Outlook process: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    $outExe = 'outlook.exe'
                    if ($null -ne $sysContext -and -not [string]::IsNullOrWhiteSpace($sysContext.OutlookPath)) {
                        $outExe = $sysContext.OutlookPath
                    }
                    try {
                        Start-Process -FilePath $outExe -ArgumentList '/safe' -ErrorAction SilentlyContinue
                        Write-ToolkitStatus -Message "Outlook safe mode command issued (/safe)." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to start Outlook in safe mode: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'E' {
                    if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                        try {
                            Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                            Write-ToolkitStatus -Message "PST size limit policy expanded to 100 GB." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to expand PST size limit: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'D' {
                    if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
                        try {
                            $files = Find-OutlookDataFiles
                            if ($files) {
                                $files | Format-Table -AutoSize
                            }
                            else {
                                Write-ToolkitStatus -Message "No Outlook data files detected." -Type 'INFO'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Deep data files scan failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    if (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                        try {
                            Invoke-OutlookCompaction
                        }
                        catch {
                            Write-ToolkitStatus -Message "Compaction utility failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $outlookItems.Count) {
                $targetItem = $outlookItems[$idx - 1]

                $targetInfo = @(
                    "Item Name      : $($targetItem.Name)",
                    "Item Type      : $($targetItem.Type)",
                    "Outlook Status : $($targetItem.Status)",
                    "Path / Details : $($targetItem.Details)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > OUTLOOK: $($targetItem.Name)" -Subtitle "Type: $($targetItem.Type) | Details: $($targetItem.Details)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Repair Profile / Data File'; Description = "Run integrity check / SCANPST on '$($targetItem.Name)'."; Prerequisite = 'Outlook stopped [SAFE]' },
                    @{ Key = '2'; Action = 'Cache Reset [OST]'; Description = "Reset or rebuild offline cache file for '$($targetItem.Name)'."; Prerequisite = 'Outlook stopped [SAFE]' },
                    @{ Key = '3'; Action = 'Autodiscover Check'; Description = "Test Autodiscover and Exchange endpoints for profile '$($targetItem.Name)'."; Prerequisite = 'Network online [READY]' },
                    @{ Key = '4'; Action = 'Backup / Relocate Data File'; Description = "Relocate or back up '$($targetItem.Name)' with cryptographic SHA-256 verification."; Prerequisite = 'Target disk space [READY]' },
                    @{ Key = '5'; Action = 'Set as Default Data File'; Description = "Assign '$($targetItem.Name)' as default delivery data file for profile."; Prerequisite = 'Outlook data file [READY]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Outlook Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        if (-not [string]::IsNullOrWhiteSpace($targetItem.Path) -and (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue)) {
                            try {
                                $lockCheck = Test-OutlookDataFileLock -FilePath $targetItem.Path
                                if ($lockCheck.IsLocked) {
                                    Write-ToolkitStatus -Message "File '$($targetItem.Name)' is locked by PID $($lockCheck.LockingProcessId). Close Outlook before repairing." -Type 'WARN'
                                }
                                else {
                                    Write-ToolkitStatus -Message "File lock test passed. Data file is ready for SCANPST repair." -Type 'OK'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Repair check failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Profile / data file '$($targetItem.Name)' status checked: $($targetItem.Status)." -Type 'OK'
                        }
                    }
                    '2' {
                        if ($targetItem.Type -eq 'OST' -or $targetItem.Path -match '\.ost$') {
                            if (-not [string]::IsNullOrWhiteSpace($targetItem.Path) -and (Test-Path -LiteralPath $targetItem.Path)) {
                                try {
                                    $bakPath = "$($targetItem.Path).bak"
                                    Move-Item -LiteralPath $targetItem.Path -Destination $bakPath -Force -ErrorAction Stop
                                    Write-ToolkitStatus -Message "Offline cache renamed to '$bakPath'. Outlook will recreate cleanly on launch." -Type 'OK'
                                }
                                catch {
                                    Write-ToolkitStatus -Message "Failed to reset OST cache: $($_.Exception.Message)" -Type 'FAIL'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "OST file path '$($targetItem.Details)' verified." -Type 'OK'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Cache reset applies to OST data files. Current item type: $($targetItem.Type)." -Type 'INFO'
                        }
                    }
                    '3' {
                        Write-ToolkitStatus -Message "Testing Autodiscover endpoints for profile '$($targetItem.Name)'..." -Type 'INFO'
                        try {
                            if (Get-Command -Name 'Test-NetConnection' -ErrorAction SilentlyContinue) {
                                $tRes = Test-NetConnection -ComputerName 'autodiscover.outlook.com' -Port 443 -WarningAction SilentlyContinue
                                if ($null -ne $tRes -and $tRes.TcpTestSucceeded) {
                                    Write-ToolkitStatus -Message "Autodiscover cloud endpoint reachable (TCP 443 OK)." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Autodiscover endpoint probe finished (standard endpoints tested)." -Type 'INFO'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "Autodiscover check completed for profile '$($targetItem.Name)'." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Autodiscover probe error: $($_.Exception.Message)" -Type 'WARN'
                        }
                    }
                    '4' {
                        if (-not [string]::IsNullOrWhiteSpace($targetItem.Path)) {
                            $op = Read-Host "  Select operation: [B]ackup or [R]elocate (Default: B)"
                            if ([string]::IsNullOrWhiteSpace($op) -or $op.Trim().ToUpperInvariant() -eq 'B') {
                                $bakDir = Read-Host "  Enter Backup Destination Directory (Default: C:\Backups)"
                                if ([string]::IsNullOrWhiteSpace($bakDir)) {
                                    $bakDir = 'C:\Backups'
                                }
                                if (Get-Command -Name 'Backup-OutlookPst' -ErrorAction SilentlyContinue) {
                                    try {
                                        Backup-OutlookPst -SourcePath $targetItem.Path -BackupDirectory $bakDir | Format-List
                                        Write-ToolkitStatus -Message "Backup completed for '$($targetItem.Name)'." -Type 'OK'
                                    }
                                    catch {
                                        Write-ToolkitStatus -Message "Backup failed: $($_.Exception.Message)" -Type 'FAIL'
                                    }
                                }
                            }
                            else {
                                $dest = Read-Host "  Enter New Destination File Path"
                                if (-not [string]::IsNullOrWhiteSpace($dest)) {
                                    if (Get-Command -Name 'Move-OutlookDataFile' -ErrorAction SilentlyContinue) {
                                        try {
                                            Move-OutlookDataFile -SourcePath $targetItem.Path -DestinationPath $dest | Format-List
                                            Write-ToolkitStatus -Message "Relocation completed for '$($targetItem.Name)'." -Type 'OK'
                                        }
                                        catch {
                                            Write-ToolkitStatus -Message "Relocation failed: $($_.Exception.Message)" -Type 'FAIL'
                                        }
                                    }
                                }
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Target item '$($targetItem.Name)' does not have a bound data file path." -Type 'WARN'
                        }
                    }
                    '5' {
                        $filePath = $targetItem.Path
                        if ([string]::IsNullOrWhiteSpace($filePath) -and -not [string]::IsNullOrWhiteSpace($targetItem.Details) -and ($targetItem.Details -match '(?i)\.(pst|ost)$')) {
                            $filePath = $targetItem.Details
                        }
                        if (-not [string]::IsNullOrWhiteSpace($filePath)) {
                            if (Get-Command -Name 'Set-OutlookDefaultDataFile' -ErrorAction SilentlyContinue) {
                                try {
                                    $setDefaultParams = @{ Path = $filePath }
                                    if (-not [string]::IsNullOrWhiteSpace($targetItem.Profile)) {
                                        $setDefaultParams['ProfileName'] = $targetItem.Profile
                                    }
                                    $defRes = Set-OutlookDefaultDataFile @setDefaultParams
                                    if ($defRes -and $defRes.Success) {
                                        Write-ToolkitStatus -Message "Data file '$($targetItem.Name)' set as default for profile." -Type 'OK'
                                    }
                                    elseif ($defRes -and -not $defRes.Success) {
                                        Write-ToolkitStatus -Message "Failed to set default data file: $($defRes.ErrorMessage)" -Type 'FAIL'
                                    }
                                    else {
                                        Write-ToolkitStatus -Message "Data file '$($targetItem.Name)' configured as default." -Type 'OK'
                                    }
                                }
                                catch {
                                    Write-ToolkitStatus -Message "Failed to set default data file: $($_.Exception.Message)" -Type 'FAIL'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "Set-OutlookDefaultDataFile command not available." -Type 'WARN'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Target item '$($targetItem.Name)' does not have a bound data file path." -Type 'WARN'
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuOffice {
<#
.SYNOPSIS
    Submenu for Office & Excel Troubleshooting with item-centric UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $officeApps = @()
        $appsDef = @(
            @{ Name = 'Microsoft Excel';      Proc = 'EXCEL';    Exe = 'EXCEL.EXE' },
            @{ Name = 'Microsoft Word';       Proc = 'WINWORD';  Exe = 'WINWORD.EXE' },
            @{ Name = 'Microsoft PowerPoint'; Proc = 'POWERPNT'; Exe = 'POWERPNT.EXE' },
            @{ Name = 'Microsoft Outlook';    Proc = 'OUTLOOK';  Exe = 'OUTLOOK.EXE' },
            @{ Name = 'Microsoft OneNote';    Proc = 'ONENOTE';  Exe = 'ONENOTE.EXE' },
            @{ Name = 'Microsoft Access';     Proc = 'MSACCESS'; Exe = 'MSACCESS.EXE' }
        )

        $c2rVer = '16.0'
        $c2rArch = 'x64'
        try {
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') {
                $c2rProps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
                if ($null -ne $c2rProps) {
                    if ($c2rProps.VersionToReport) { $c2rVer = [string]$c2rProps.VersionToReport }
                    if ($c2rProps.Platform) { $c2rArch = [string]$c2rProps.Platform }
                }
            }
        }
        catch {
            $null = $_
        }

        foreach ($app in $appsDef) {
            $isInstalled = $false
            $exePath = ''
            try {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($app.Exe)"
                if (Test-Path $regPath) {
                    $isInstalled = $true
                    $prop = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
                    if ($null -ne $prop -and $prop.'(default)') {
                        $exePath = [string]$prop.'(default)'
                    }
                }
            }
            catch {
                $null = $_
            }

            $isRunning = $false
            try {
                $procs = @(Get-Process -Name $app.Proc -ErrorAction SilentlyContinue)
                if ($procs.Count -gt 0) {
                    $isRunning = $true
                    $isInstalled = $true
                }
            }
            catch {
                $null = $_
            }

            if ($isInstalled) {
                $stat = if ($isRunning) { '[ACTIVE]' } else { '[READY]' }
                $officeApps += [PSCustomObject]@{
                    Name         = $app.Name
                    Status       = $stat
                    Version      = $c2rVer
                    Architecture = $c2rArch
                    ProcessName  = $app.Proc
                    Executable   = $app.Exe
                    Path         = $exePath
                    IsRunning    = $isRunning
                }
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & EXCEL TROUBLESHOOTING' -Subtitle 'Graphics Acceleration, Cache Reset, COM Add-ins, GDI Leaks, Click-to-Run Repair' -ClearScreen:$clear -InfoLines $officeInfo

        Show-ToolkitItemTable -Items $officeApps -Columns @('Name', 'Status', 'Version', 'Architecture') -Headers @('NAME', 'STATUS', 'VERSION', 'ARCHITECTURE') -Title 'Installed Office Applications'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'K'; Label = 'KMS Probe' },
            @{ Key = 'L'; Label = 'License Diagnostics' },
            @{ Key = 'R'; Label = 'Quick Repair' },
            @{ Key = 'O'; Label = 'Online Repair' },
            @{ Key = 'C'; Label = 'Clear Temp Cache' },
            @{ Key = 'H'; Label = 'Toggle Graphics Acceleration' },
            @{ Key = 'G'; Label = 'Audit GDI Leakers' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Excel Troubleshooting & Repair'." -Type 'INFO'
            return
        }

        $validKeys = @('K', 'L', 'R', 'O', 'C', 'H', 'G', 'B', 'Q')
        $promptText = if ($officeApps.Count -gt 0) { "  Select item [1-$($officeApps.Count)] or action" } else { "  Select action [K, L, R, O, C, H, G, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $officeApps.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'K' {
                    Write-ToolkitStatus -Message "Probing KMS host connectivity (TCP 1688)..." -Type 'INFO'
                    try {
                        if (Get-Command -Name 'Test-NetConnection' -ErrorAction SilentlyContinue) {
                            $kmsRes = Test-NetConnection -ComputerName 'kms.local' -Port 1688 -WarningAction SilentlyContinue
                            if ($null -ne $kmsRes -and $kmsRes.TcpTestSucceeded) {
                                Write-ToolkitStatus -Message "KMS Host probe succeeded (port 1688 open)." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "KMS Host unreachable or unconfigured (port 1688)." -Type 'WARN'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "KMS probe skipped (Test-NetConnection unavailable)." -Type 'INFO'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "KMS probe error: $($_.Exception.Message)" -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'L' {
                    Write-ToolkitStatus -Message "Querying Office SoftwareLicensingProduct status..." -Type 'INFO'
                    try {
                        if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                            $lic = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "Name like 'Office%'" -ErrorAction SilentlyContinue)
                            if ($lic.Count -gt 0) {
                                $lic | Select-Object Name, LicenseStatus, GracePeriodRemaining | Format-Table -AutoSize
                                Write-ToolkitStatus -Message "Office license check completed." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "No SoftwareLicensingProduct Office records found." -Type 'INFO'
                            }
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "License query error: $($_.Exception.Message)" -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'R' {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Start-OfficeClickToRunRepair -RepairType 'Quick'
                            Write-ToolkitStatus -Message "Office Quick Repair launched." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Quick Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'O' {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Start-OfficeClickToRunRepair -RepairType 'Full'
                            Write-ToolkitStatus -Message "Office Online Repair launched." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Online Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                        try {
                            Clear-OfficeTempCache
                            Write-ToolkitStatus -Message "Office temporary cache cleared." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to clear temp cache: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'H' {
                    if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        try {
                            $regPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
                            $isCurrentlyDisabled = $false
                            if (Test-Path $regPath) {
                                $val = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DisableHardwareAcceleration
                                if ($val -eq 1) {
                                    $isCurrentlyDisabled = $true
                                }
                            }
                            if ($isCurrentlyDisabled) {
                                Set-ExcelHardwareAcceleration -Enable
                                Write-ToolkitStatus -Message "Hardware graphics acceleration enabled." -Type 'OK'
                            }
                            else {
                                Set-ExcelHardwareAcceleration -Disable
                                Write-ToolkitStatus -Message "Hardware graphics acceleration disabled." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to toggle acceleration: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'G' {
                    if (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                        try {
                            $gdi = Get-ExcelGdiHandleUsage
                            if ($null -ne $gdi) {
                                $gdi | Format-Table -AutoSize
                            }
                            else {
                                Write-ToolkitStatus -Message "No leaking Excel processes detected." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "GDI handle audit failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $officeApps.Count) {
                $targetApp = $officeApps[$idx - 1]

                $targetInfo = @(
                    "Application    : $($targetApp.Name)",
                    "Executable     : $($targetApp.Executable)",
                    "Version        : $($targetApp.Version) ($($targetApp.Architecture))",
                    "Process State  : $($targetApp.Status)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > OFFICE APP: $($targetApp.Name)" -Subtitle "Version: $($targetApp.Version) | State: $($targetApp.Status)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Targeted Repair'; Description = "Execute Click-to-Run repair for '$($targetApp.Name)'."; Prerequisite = 'C2R installation [READY]' },
                    @{ Key = '2'; Action = 'Kill Process'; Description = "Terminate running instances of '$($targetApp.Executable)'."; Prerequisite = 'Process running [READY]' },
                    @{ Key = '3'; Action = 'Clear Cache'; Description = "Reset UI buffers and application temp cache."; Prerequisite = 'Application stopped [READY]' },
                    @{ Key = '4'; Action = 'Manage Add-ins'; Description = "Audit and configure installed COM add-ins."; Prerequisite = 'Registry access [READY]' },
                    @{ Key = '5'; Action = 'Reset Resiliency'; Description = "Clear blocked items list in registry."; Prerequisite = 'Registry access [READY]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Office Apps Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                            try {
                                Start-OfficeClickToRunRepair -RepairType 'Quick'
                                Write-ToolkitStatus -Message "Targeted repair initiated for '$($targetApp.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Repair failed for '$($targetApp.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '2' {
                        try {
                            Stop-Process -Name $targetApp.ProcessName -Force -ErrorAction SilentlyContinue
                            Write-ToolkitStatus -Message "Terminated processes matching '$($targetApp.Executable)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to stop '$($targetApp.Executable)': $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '3' {
                        try {
                            if ($targetApp.ProcessName -eq 'EXCEL' -and (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue)) {
                                Reset-ExcelUiCache
                            }
                            if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                                Clear-OfficeTempCache
                            }
                            Write-ToolkitStatus -Message "Application cache cleared for '$($targetApp.Name)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to clear cache: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '4' {
                        if (Get-Command -Name 'Get-ExcelComAddin' -ErrorAction SilentlyContinue) {
                            try {
                                $addins = Get-ExcelComAddin
                                if ($addins) {
                                    $addins | Format-Table -AutoSize
                                }
                                else {
                                    Write-ToolkitStatus -Message "No COM add-ins registered for '$($targetApp.Name)'." -Type 'INFO'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to query COM add-ins: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '5' {
                        if (Get-Command -Name 'Reset-ExcelResiliency' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-ExcelResiliency
                                Write-ToolkitStatus -Message "Add-in resiliency list reset for '$($targetApp.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset resiliency: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuPrinters {
<#
.SYNOPSIS
    Submenu for Network & Print Spooler with item-centric UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $rawPrinters = @()
        try {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                $rawPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
            }
        }
        catch {
            Write-ToolkitStatus -Message "Failed to enumerate printers: $($_.Exception.Message)" -Type 'WARN'
        }

        $printers = @()
        foreach ($p in $rawPrinters) {
            if ($null -ne $p -and $p.PSObject.Properties['Name']) {
                $isOffline = [bool]$p.WorkOffline
                $statusBadge = '[READY]'
                if ($isOffline) {
                    $statusBadge = '[OFFLINE]'
                }
                elseif ($p.PrinterState -and $p.PrinterState -ne 0) {
                    $statusBadge = '[ERROR]'
                }
                elseif ($p.Status -and $p.Status -ne 'OK') {
                    $statusBadge = '[ERROR]'
                }

                $printers += [PSCustomObject]@{
                    Name   = [string]$p.Name
                    Status = $statusBadge
                    Driver = [string]$p.DriverName
                    Port   = [string]$p.PortName
                }
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $printersInfo = Get-PrintersContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK & PRINT SPOOLER' -Subtitle 'Spooler Diagnostics, Queue Purge, Ne Ports, Point & Print' -ClearScreen:$clear -InfoLines $printersInfo

        Show-ToolkitItemTable -Items $printers -Columns @('Name', 'Status', 'Driver', 'Port') -Headers @('NAME', 'STATUS', 'DRIVER', 'PORT') -Title 'Installed Printers'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'A'; Label = 'Apply All Server' },
            @{ Key = 'L'; Label = 'Apply All Client' },
            @{ Key = 'F'; Label = 'Fixes Catalog' },
            @{ Key = 'U'; Label = 'Rollback' },
            @{ Key = 'S'; Label = 'Spooler Restart & Purge' },
            @{ Key = 'R'; Label = 'Register DLLs' },
            @{ Key = 'P'; Label = 'Point & Print Remediation' },
            @{ Key = 'N'; Label = 'Reset Ne Ports' },
            @{ Key = 'C'; Label = 'Refresh Connections' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Network & Print Spooler Troubleshooting'." -Type 'INFO'
            return
        }

        $validKeys = @('A', 'L', 'F', 'U', 'S', 'R', 'P', 'N', 'C', 'B', 'Q')
        $promptText = if ($printers.Count -gt 0) { "  Select item [1-$($printers.Count)] or action" } else { "  Select action [A, L, F, U, S, R, P, N, C, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $printers.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'A' {
                    if (Get-Command -Name 'Set-PrinterServerRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-PrinterServerRemediation -All
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "All server printer remediations applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Server remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply server remediations: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-PrinterServerRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'L' {
                    if (Get-Command -Name 'Set-PrinterClientRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-PrinterClientRemediation -All
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "All client printer remediations applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Client remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply client remediations: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-PrinterClientRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'F' {
                    Write-Host ""
                    Write-Host "  Select remediation fix from catalog:" -ForegroundColor Cyan
                    Write-Host "  [1] RpcAuthnLevel (Server - Fix 0x0000011b)"
                    Write-Host "  [2] RemoteRpcEndPoint (Server - Allow client RPC binds)"
                    Write-Host "  [3] RpcProtocols (Server - Named pipes & protocols)"
                    Write-Host "  [4] SpoolerHealth (Server - Permissions & service restart)"
                    Write-Host "  [5] PointAndPrintAdmin (Client - RestrictDriverInstallationToAdministrators=0)"
                    Write-Host "  [6] PointAndPrintPrompts (Client - Suppress elevation prompts)"
                    Write-Host "  [7] RpcNamedPipe (Client - Fix 0x00000709)"
                    Write-Host "  [8] CopyFilesPolicy (Client - Fix 0x0000007c)"
                    Write-Host "  [B] Back"
                    $fChoice = Read-ToolkitMenuChoice -Prompt 'Select Fix' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', 'B') -Default 'B'
                    if (-not [string]::IsNullOrWhiteSpace($fChoice) -and $fChoice.ToUpperInvariant() -ne 'B') {
                        try {
                            switch ($fChoice) {
                                '1' {
                                    $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel'
                                    Write-ToolkitStatus -Message "Applied server fix: RpcAuthnLevel." -Type 'OK'
                                }
                                '2' {
                                    $res = Set-PrinterServerRemediation -Fix 'RemoteRpcEndPoint'
                                    Write-ToolkitStatus -Message "Applied server fix: RemoteRpcEndPoint." -Type 'OK'
                                }
                                '3' {
                                    $res = Set-PrinterServerRemediation -Fix 'RpcProtocols'
                                    Write-ToolkitStatus -Message "Applied server fix: RpcProtocols." -Type 'OK'
                                }
                                '4' {
                                    $res = Set-PrinterServerRemediation -Fix 'SpoolerHealth'
                                    Write-ToolkitStatus -Message "Applied server fix: SpoolerHealth." -Type 'OK'
                                }
                                '5' {
                                    $res = Set-PrinterClientRemediation -Fix 'PointAndPrintAdmin'
                                    Write-ToolkitStatus -Message "Applied client fix: PointAndPrintAdmin." -Type 'OK'
                                }
                                '6' {
                                    $res = Set-PrinterClientRemediation -Fix 'PointAndPrintPrompts'
                                    Write-ToolkitStatus -Message "Applied client fix: PointAndPrintPrompts." -Type 'OK'
                                }
                                '7' {
                                    $res = Set-PrinterClientRemediation -Fix 'RpcNamedPipe'
                                    Write-ToolkitStatus -Message "Applied client fix: RpcNamedPipe." -Type 'OK'
                                }
                                '8' {
                                    $res = Set-PrinterClientRemediation -Fix 'CopyFilesPolicy'
                                    Write-ToolkitStatus -Message "Applied client fix: CopyFilesPolicy." -Type 'OK'
                                }
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply fix: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'U' {
                    $regFile = Read-Host "  Enter registry backup .reg file path (or press Enter to search default backup folder)"
                    if ([string]::IsNullOrWhiteSpace($regFile)) {
                        $searchDirs = @('C:\Backups\Registry', "$env:TEMP\IToolkit_RegistryBackups", "$env:TEMP")
                        $foundFiles = @()
                        foreach ($sDir in $searchDirs) {
                            if (Test-Path -LiteralPath $sDir) {
                                $foundFiles += @(Get-ChildItem -LiteralPath $sDir -Filter '*.reg' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                            }
                        }
                        if ($foundFiles.Count -gt 0) {
                            $latest = $foundFiles[0].FullName
                            Write-Host "  Found recent backup: $latest" -ForegroundColor Cyan
                            $confirm = Read-Host "  Restore this backup? [Y/N] (Default: Y)"
                            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm.ToUpperInvariant() -eq 'Y') {
                                $regFile = $latest
                            }
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($regFile)) {
                        if (Get-Command -Name 'Restore-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                            try {
                                $success = Restore-RegistryKeyBackup -BackupFilePath $regFile
                                if ($success) {
                                    Write-ToolkitStatus -Message "Registry restored successfully from '$regFile'." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Registry restore failed for '$regFile'." -Type 'FAIL'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Rollback error: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Restore-RegistryKeyBackup command not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "No registry backup file selected. Rollback cancelled." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrintSpoolerQueue -Force
                            Write-ToolkitStatus -Message "Print spooler service restarted and queue purged." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to reset print spooler queue: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'R' {
                    if (Get-Command -Name 'Register-PrintSpoolerComponents' -ErrorAction SilentlyContinue) {
                        try {
                            Register-PrintSpoolerComponents
                            Write-ToolkitStatus -Message "Print spooler components and DLLs registered." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to register spooler components: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'P' {
                    if (Get-Command -Name 'Set-PointAndPrintRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            Set-PointAndPrintRemediation -Preset 'StrictAdminOnly'
                            Write-ToolkitStatus -Message "Point & Print remediation applied (StrictAdminOnly)." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply Point & Print remediation: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'N' {
                    if (Get-Command -Name 'Reset-PrinterNePortBindings' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrinterNePortBindings
                            Write-ToolkitStatus -Message "Printer Ne port registry bindings reset." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to reset Ne port bindings: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    if (Get-Command -Name 'Reset-PrinterConnections' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrinterConnections
                            Write-ToolkitStatus -Message "User network printer connections refreshed." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to refresh printer connections: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $printers.Count) {
                $targetPrinter = $printers[$idx - 1]

                $targetInfo = @(
                    "Printer Name   : $($targetPrinter.Name)",
                    "Driver Model   : $($targetPrinter.Driver)",
                    "Port Name      : $($targetPrinter.Port)",
                    "Current Status : $($targetPrinter.Status)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > PRINTER: $($targetPrinter.Name)" -Subtitle "Port: $($targetPrinter.Port) | Driver: $($targetPrinter.Driver)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Print Test Page'; Description = "Send diagnostic test page to '$($targetPrinter.Name)'."; Prerequisite = 'Printer online [READY]' },
                    @{ Key = '2'; Action = 'Purge Queue'; Description = "Purge print queue jobs for '$($targetPrinter.Name)'."; Prerequisite = 'Spooler service [READY]' },
                    @{ Key = '3'; Action = 'Port Diagnostics'; Description = "Probe network port connectivity for '$($targetPrinter.Port)'."; Prerequisite = 'Network online [READY]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Printers Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        try {
                            $escapedName = $targetPrinter.Name.Replace("'", "''")
                            $cimP = Get-CimInstance -ClassName Win32_Printer -Filter "Name = '$escapedName'" -ErrorAction SilentlyContinue
                            if ($null -ne $cimP) {
                                $null = Invoke-CimMethod -InputObject $cimP -MethodName PrintTestPage -ErrorAction SilentlyContinue
                            }
                            Write-ToolkitStatus -Message "Test page print command submitted for '$($targetPrinter.Name)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to print test page for '$($targetPrinter.Name)': $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '2' {
                        if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-PrintSpoolerQueue -Force
                                Write-ToolkitStatus -Message "Print spooler queue purged for '$($targetPrinter.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to purge queue for '$($targetPrinter.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '3' {
                        $targetHost = $targetPrinter.Port
                        if ($targetHost -match '^IP_(.+)$') {
                            $targetHost = $Matches[1]
                        }
                        elseif ($targetHost -match '^\\\\([^\\]+)') {
                            $targetHost = $Matches[1]
                        }
                        if ([string]::IsNullOrWhiteSpace($targetHost) -or $targetHost -match '^(LPT|COM|USB|FILE|PORTPROMPT|WSD)') {
                            $targetHost = '127.0.0.1'
                        }
                        if (Get-Command -Name 'Test-NetworkPrinterConnectivity' -ErrorAction SilentlyContinue) {
                            try {
                                Test-NetworkPrinterConnectivity -ComputerName $targetHost | Format-List
                                Write-ToolkitStatus -Message "Port diagnostics completed for '$targetHost'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Port diagnostics failed for '$targetHost': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuBackup {
<#
.SYNOPSIS
    Submenu for User Profile Data Backup with item-centric UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $backupItems = @()
        $backupDirs = @('C:\Backups', 'D:\Backups')
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $backupDirs += Join-Path $env:USERPROFILE 'Backups'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
            $backupDirs += Join-Path $env:TEMP 'IToolkitBackups'
        }

        foreach ($bDir in $backupDirs) {
            try {
                if (Test-Path -LiteralPath $bDir) {
                    $subDirs = @(Get-ChildItem -LiteralPath $bDir -Directory -ErrorAction SilentlyContinue)
                    foreach ($sd in $subDirs) {
                        $manifestFile = Join-Path $sd.FullName 'IToolkit_Backup_Manifest.json'
                        $isManifest = Test-Path -LiteralPath $manifestFile
                        $stat = if ($isManifest) { '[READY]' } else { '[OK]' }
                        $backupItems += [PSCustomObject]@{
                            Name     = [string]$sd.Name
                            Status   = $stat
                            Type     = 'Backup Set'
                            Details  = [string]$sd.FullName
                            Path     = [string]$sd.FullName
                            Manifest = $(if ($isManifest) { $manifestFile } else { $null })
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        # Query Volume Shadow Copies
        try {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                $shadows = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue)
                foreach ($s in $shadows) {
                    if ($null -ne $s) {
                        $sName = if ($s.ID) { "VSS: $($s.ID)" } else { 'ShadowCopy' }
                        $sDev = if ($s.DeviceObject) { [string]$s.DeviceObject } else { 'VSS Snapshot' }
                        $backupItems += [PSCustomObject]@{
                            Name     = $sName
                            Status   = '[HEALTHY]'
                            Type     = 'Shadow Copy'
                            Details  = $sDev
                            Path     = $sDev
                            Manifest = $null
                        }
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        # Query System Restore Points
        try {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                $restorePoints = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue)
                foreach ($rp in $restorePoints) {
                    if ($null -ne $rp) {
                        $rpDesc = if ($rp.Description) { [string]$rp.Description } else { 'Restore Point' }
                        $backupItems += [PSCustomObject]@{
                            Name     = $rpDesc
                            Status   = '[OK]'
                            Type     = 'Restore Point'
                            Details  = "Seq: $($rp.SequenceNumber)"
                            Path     = "Seq: $($rp.SequenceNumber)"
                            Manifest = $null
                        }
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $backupInfo = Get-BackupContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER PROFILE DATA BACKUP' -Subtitle 'Folders, Bookmarks, Certificates, Robocopy Engine & SHA-256 Manifests' -ClearScreen:$clear -InfoLines $backupInfo

        Show-ToolkitItemTable -Items $backupItems -Columns @('Name', 'Status', 'Type', 'Details') -Headers @('NAME', 'STATUS', 'TYPE', 'PATH/DETAILS') -Title 'Discovered Backups & Restore Points'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'N'; Label = 'New Full Backup' },
            @{ Key = 'E'; Label = 'Export Bookmarks' },
            @{ Key = 'C'; Label = 'Export Certs' },
            @{ Key = 'I'; Label = 'Import Certs' },
            @{ Key = 'M'; Label = 'Map Folders' },
            @{ Key = 'G'; Label = 'Generate Manifest' },
            @{ Key = 'V'; Label = 'Verify Manifest' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'User Profile Data Backup & Migration'." -Type 'INFO'
            return
        }

        $validKeys = @('N', 'E', 'C', 'I', 'M', 'G', 'V', 'B', 'Q')
        $promptText = if ($backupItems.Count -gt 0) { "  Select item [1-$($backupItems.Count)] or action" } else { "  Select action [N, E, C, I, M, G, V, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $backupItems.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'N' {
                    $src = Read-Host "  Enter Source Profile Path (Default: $env:USERPROFILE)"
                    if ([string]::IsNullOrWhiteSpace($src)) {
                        $src = $env:USERPROFILE
                    }
                    $dst = Read-Host "  Enter Target Backup Path (Default: C:\Backups\ProfileBackup)"
                    if ([string]::IsNullOrWhiteSpace($dst)) {
                        $dst = 'C:\Backups\ProfileBackup'
                    }
                    if (-not [string]::IsNullOrWhiteSpace($src) -and (Get-Command -Name 'Start-ProfileDirectoryBackup' -ErrorAction SilentlyContinue)) {
                        try {
                            Start-ProfileDirectoryBackup -SourceDirectories @($src) -DestinationPath $dst | Format-List
                            Write-ToolkitStatus -Message "Profile backup job completed." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Profile backup failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'E' {
                    $outDir = Read-Host "  Enter Export Destination Directory (Default: C:\Backups\Bookmarks)"
                    if ([string]::IsNullOrWhiteSpace($outDir)) {
                        $outDir = 'C:\Backups\Bookmarks'
                    }
                    if (Get-Command -Name 'Export-BrowserBookmarks' -ErrorAction SilentlyContinue) {
                        try {
                            Export-BrowserBookmarks -DestinationPath $outDir | Format-List
                            Write-ToolkitStatus -Message "Browser bookmarks exported to '$outDir'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Bookmarks export failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    $outDir = Read-Host "  Enter Export Destination Directory (Default: C:\Backups\Certificates)"
                    if ([string]::IsNullOrWhiteSpace($outDir)) {
                        $outDir = 'C:\Backups\Certificates'
                    }
                    $pwd = Read-Host "  Enter Protection Password for Certificates (Optional)" -AsSecureString
                    if (Get-Command -Name 'Export-ToolkitCertificates' -ErrorAction SilentlyContinue) {
                        try {
                            $exportParams = @{ DestinationPath = $outDir }
                            if ($pwd -is [System.Security.SecureString] -and $pwd.Length -gt 0) {
                                $exportParams['Password'] = $pwd
                            }
                            elseif ($pwd -is [string] -and -not [string]::IsNullOrWhiteSpace($pwd)) {
                                $exportParams['Password'] = ConvertTo-SecureString -String $pwd -AsPlainText -Force
                            }
                            $certs = Export-ToolkitCertificates @exportParams
                            $cnt = if ($null -ne $certs) { @($certs).Count } else { 0 }
                            Write-ToolkitStatus -Message "Certificate export completed ($cnt certificate(s) exported to '$outDir')." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Certificates export failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    elseif (Get-Command -Name 'Export-PersonalCertificates' -ErrorAction SilentlyContinue) {
                        try {
                            $secPwd = if ($pwd -is [System.Security.SecureString]) { $pwd } elseif ($pwd -is [string] -and -not [string]::IsNullOrWhiteSpace($pwd)) { ConvertTo-SecureString -String $pwd -AsPlainText -Force } else { $null }
                            Export-PersonalCertificates -DestinationPath $outDir -Password $secPwd | Format-List
                            Write-ToolkitStatus -Message "Personal certificates exported to '$outDir'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Certificates export failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'I' {
                    $inPath = Read-Host "  Enter Certificate File or Directory Path to Import"
                    if (-not [string]::IsNullOrWhiteSpace($inPath)) {
                        $pwd = Read-Host "  Enter Certificate Password for PFX (Optional)" -AsSecureString
                        if (Get-Command -Name 'Import-ToolkitCertificates' -ErrorAction SilentlyContinue) {
                            try {
                                $importParams = @{ Path = $inPath }
                                if ($pwd -is [System.Security.SecureString] -and $pwd.Length -gt 0) {
                                    $importParams['Password'] = $pwd
                                }
                                elseif ($pwd -is [string] -and -not [string]::IsNullOrWhiteSpace($pwd)) {
                                    $importParams['Password'] = ConvertTo-SecureString -String $pwd -AsPlainText -Force
                                }
                                $imported = Import-ToolkitCertificates @importParams
                                $cnt = if ($null -ne $imported) { @($imported).Count } else { 0 }
                                Write-ToolkitStatus -Message "Certificate import completed ($cnt certificate(s) imported from '$inPath')." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Certificate import failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Import-ToolkitCertificates command not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "No import path specified. Import cancelled." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                'M' {
                    if (Get-Command -Name 'Get-UserProfileDirectoryMap' -ErrorAction SilentlyContinue) {
                        try {
                            Get-UserProfileDirectoryMap | Format-List
                        }
                        catch {
                            Write-ToolkitStatus -Message "Profile directory mapping failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'G' {
                    $target = Read-Host "  Enter Target Directory for Manifest"
                    if (-not [string]::IsNullOrWhiteSpace($target) -and (Get-Command -Name 'New-BackupIntegrityManifest' -ErrorAction SilentlyContinue)) {
                        try {
                            $man = New-BackupIntegrityManifest -BackupRoot $target
                            Write-ToolkitStatus -Message "SHA-256 manifest generated: $man" -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Manifest generation failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'V' {
                    $manPath = Read-Host "  Enter Manifest File Path"
                    $rootPath = Read-Host "  Enter Target Root Path to Verify"
                    if (-not [string]::IsNullOrWhiteSpace($manPath) -and -not [string]::IsNullOrWhiteSpace($rootPath)) {
                        if (Get-Command -Name 'Test-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
                            try {
                                Test-BackupIntegrityManifest -ManifestPath $manPath -TargetRoot $rootPath | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Manifest verification failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $backupItems.Count) {
                $targetBackup = $backupItems[$idx - 1]

                $targetInfo = @(
                    "Backup Name    : $($targetBackup.Name)",
                    "Backup Type    : $($targetBackup.Type)",
                    "Status         : $($targetBackup.Status)",
                    "Path / Details : $($targetBackup.Details)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > BACKUP: $($targetBackup.Name)" -Subtitle "Type: $($targetBackup.Type) | Details: $($targetBackup.Details)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Restore Data'; Description = "Restore profile data from '$($targetBackup.Name)'."; Prerequisite = 'Target folder writable [READY]' },
                    @{ Key = '2'; Action = 'Verify Integrity'; Description = "Validate SHA-256 integrity manifest for '$($targetBackup.Name)'."; Prerequisite = 'Manifest present [READY]' },
                    @{ Key = '3'; Action = 'Delete Backup Set'; Description = "Permanently remove backup set '$($targetBackup.Name)'."; Prerequisite = 'Confirmation required [WARN]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Backups Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        if (Get-Command -Name 'Restore-UserProfileData' -ErrorAction SilentlyContinue) {
                            try {
                                Restore-UserProfileData -BackupRoot $targetBackup.Path | Format-List
                                Write-ToolkitStatus -Message "Profile data restoration completed from '$($targetBackup.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Restore failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '2' {
                        if (Get-Command -Name 'Test-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
                            try {
                                $manFile = $targetBackup.Manifest
                                if ([string]::IsNullOrWhiteSpace($manFile)) {
                                    $manFile = Join-Path $targetBackup.Path 'IToolkit_Backup_Manifest.json'
                                }
                                if (Test-Path -LiteralPath $manFile) {
                                    $vRes = Test-BackupIntegrityManifest -ManifestPath $manFile -TargetRoot $targetBackup.Path
                                    $vRes | Format-List
                                    $badge = if ($vRes.IsIntact) { 'OK' } else { 'FAIL' }
                                    Write-ToolkitStatus -Message "Manifest verification finished for '$($targetBackup.Name)'." -Type $badge
                                }
                                else {
                                    Write-ToolkitStatus -Message "No SHA-256 manifest found in '$($targetBackup.Path)'." -Type 'WARN'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Verification failed: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '3' {
                        if (Test-Path -LiteralPath $targetBackup.Path) {
                            $confirm = Read-Host "  Are you sure you want to delete backup set '$($targetBackup.Name)'? [Y/N]"
                            if (-not [string]::IsNullOrWhiteSpace($confirm) -and $confirm.Trim().ToUpperInvariant() -eq 'Y') {
                                try {
                                    Remove-Item -LiteralPath $targetBackup.Path -Recurse -Force -ErrorAction Stop
                                    Write-ToolkitStatus -Message "Backup set '$($targetBackup.Name)' successfully deleted." -Type 'OK'
                                }
                                catch {
                                    Write-ToolkitStatus -Message "Failed to delete backup set: $($_.Exception.Message)" -Type 'FAIL'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "Backup set deletion cancelled." -Type 'INFO'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Item '$($targetBackup.Name)' is a system snapshot and cannot be deleted directly." -Type 'WARN'
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuAccounts {
<#
.SYNOPSIS
    Submenu for User & Domain Account Administration with item-centric UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $rawAccounts = @()
        try {
            if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                $rawAccounts = @(Get-LocalAccountList)
            }
        }
        catch {
            Write-ToolkitStatus -Message "Failed to enumerate local accounts: $($_.Exception.Message)" -Type 'WARN'
        }

        $accounts = @()
        foreach ($acc in $rawAccounts) {
            $isEnabled = $true
            if ($null -ne $acc.Enabled) {
                $isEnabled = [bool]$acc.Enabled
            }
            elseif ($null -ne $acc.Disabled) {
                $isEnabled = (-not [bool]$acc.Disabled)
            }

            $isLocked = $false
            if ($null -ne $acc.Locked) {
                $isLocked = [bool]$acc.Locked
            }
            elseif ($null -ne $acc.Lockout) {
                $isLocked = [bool]$acc.Lockout
            }

            $statusBadge = if ($isEnabled) { '[ENABLED]' } else { '[DISABLED]' }
            $lockedBadge = if ($isLocked) { '[LOCKED]' } else { '[OK]' }

            $accounts += [PSCustomObject]@{
                Name     = [string]$acc.Name
                Status   = $statusBadge
                Locked   = $lockedBadge
                SID      = [string]$acc.SID
                Enabled  = $isEnabled
                IsLocked = $isLocked
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $accountsInfo = Get-AccountsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER & DOMAIN ACCOUNT ADMINISTRATION' -Subtitle 'Account Operations, Administrator SID -500, Domain Join/Disjoin' -ClearScreen:$clear -InfoLines $accountsInfo

        Show-ToolkitItemTable -Items $accounts -Columns @('Name', 'Status', 'Locked', 'SID') -Title 'Local User Accounts'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'A'; Label = 'Add Account' },
            @{ Key = 'S'; Label = 'Enable Admin SID-500' },
            @{ Key = 'P'; Label = 'Reset Admin Pwd' },
            @{ Key = 'D'; Label = 'Query Domain User' },
            @{ Key = 'U'; Label = 'Unlock Domain User' },
            @{ Key = 'T'; Label = 'Test Domain Health' },
            @{ Key = 'J'; Label = 'Disjoin Domain' },
            @{ Key = 'R'; Label = 'Refresh Table' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Account Administration'." -Type 'INFO'
            return
        }

        $validKeys = @('A', 'S', 'P', 'D', 'U', 'T', 'J', 'R', 'B', 'Q')
        $promptText = if ($accounts.Count -gt 0) { "  Select item [1-$($accounts.Count)] or action" } else { "  Select action [A, S, P, D, U, T, J, R, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $accounts.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'R' {
                    continue
                }
                'A' {
                    $user = Read-Host "  Enter New Username"
                    $pwd  = Read-Host "  Enter Secure Password" -AsSecureString
                    if (-not [string]::IsNullOrWhiteSpace($user) -and $null -ne $pwd) {
                        if (Get-Command -Name 'New-LocalAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                New-LocalAccountItem -Username $user -Password $pwd | Format-List
                                Write-ToolkitStatus -Message "Local account '$user' creation completed." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to create local account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    if (Get-Command -Name 'Enable-BuiltInAdministrator' -ErrorAction SilentlyContinue) {
                        try {
                            Enable-BuiltInAdministrator | Format-List
                            Write-ToolkitStatus -Message "Built-in Administrator (SID -500) activation completed." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to enable built-in Administrator: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'P' {
                    $pwd = Read-Host "  Enter New Password for Administrator" -AsSecureString
                    if ($null -ne $pwd) {
                        if (Get-Command -Name 'Reset-BuiltInAdministratorPassword' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-BuiltInAdministratorPassword -Password $pwd | Format-List
                                Write-ToolkitStatus -Message "Built-in Administrator password reset completed." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset Administrator password: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'D' {
                    $user = Read-Host "  Enter Domain SamAccountName"
                    if (-not [string]::IsNullOrWhiteSpace($user)) {
                        if (Get-Command -Name 'Get-DomainAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                Get-DomainAccountItem -Username $user | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to query domain account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'U' {
                    $user = Read-Host "  Enter Domain SamAccountName to Unlock"
                    if (-not [string]::IsNullOrWhiteSpace($user)) {
                        if (Get-Command -Name 'Unlock-DomainAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Unlock-DomainAccountItem -Username $user
                                Write-ToolkitStatus -Message "Domain account '$user' unlock result: $res" -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to unlock domain account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'T' {
                    $dom = Read-Host "  Enter Domain FQDN (e.g. corp.contoso.com)"
                    if (-not [string]::IsNullOrWhiteSpace($dom)) {
                        if (Get-Command -Name 'Test-DomainReachability' -ErrorAction SilentlyContinue) {
                            try {
                                Test-DomainReachability -DomainName $dom | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to test domain reachability for '$dom': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'J' {
                    $wg  = Read-Host "  Enter Target Workgroup Name (Default: WORKGROUP)"
                    if ([string]::IsNullOrWhiteSpace($wg)) {
                        $wg = 'WORKGROUP'
                    }
                    Write-Host "  Domain disjoin requires domain administrative credentials." -ForegroundColor Yellow
                    $cred = Get-Credential
                    if ($null -ne $cred) {
                        if (Get-Command -Name 'Disconnect-ToolkitDomain' -ErrorAction SilentlyContinue) {
                            try {
                                Disconnect-ToolkitDomain -WorkgroupName $wg -Credential $cred | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to disjoin domain: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $accounts.Count) {
                $targetAccount = $accounts[$idx - 1]

                $targetInfo = @(
                    "Target Account : $($targetAccount.Name)",
                    "Security ID    : $($targetAccount.SID)",
                    "Current State  : $($targetAccount.Status)",
                    "Lockout Status : $($targetAccount.Locked)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > ACCOUNT: $($targetAccount.Name)" -Subtitle "Target SID: $($targetAccount.SID)" -ClearScreen:$true -InfoLines $targetInfo

                $toggleDesc = if ($targetAccount.Enabled -or $targetAccount.Status -eq '[ENABLED]') { 'Disable Account' } else { 'Enable Account' }
                $contextDetails = @(
                    @{ Key = '1'; Action = "Toggle State ($toggleDesc)"; Description = 'Toggle account active or disabled state.'; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '2'; Action = 'Unlock Account'; Description = 'Clear account lockout flag via ADSI/LocalUser.'; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '3'; Action = 'Reset Password'; Description = "Set new password for '$($targetAccount.Name)'."; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '4'; Action = 'Remove Account'; Description = "Delete local user account '$($targetAccount.Name)'."; Prerequisite = 'Requires confirmation [WARN]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Accounts Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        $newState = -not ($targetAccount.Enabled -or $targetAccount.Status -eq '[ENABLED]')
                        if (Get-Command -Name 'Set-LocalAccountState' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Set-LocalAccountState -Username $targetAccount.Name -Enabled $newState
                                $stateText = if ($newState) { 'Enabled' } else { 'Disabled' }
                                Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' state successfully set to $stateText." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to set state for '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '2' {
                        if (Get-Command -Name 'Unlock-LocalAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Unlock-LocalAccountItem -Username $targetAccount.Name
                                Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' unlock result: $res" -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to unlock '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '3' {
                        $pwd = Read-Host "  Enter New Password for '$($targetAccount.Name)'" -AsSecureString
                        if ($null -ne $pwd) {
                            try {
                                if (Get-Command -Name 'Set-LocalUser' -ErrorAction SilentlyContinue) {
                                    Set-LocalUser -Name $targetAccount.Name -Password $pwd -ErrorAction Stop
                                    Write-ToolkitStatus -Message "Password successfully reset for account '$($targetAccount.Name)'." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Set-LocalUser command is not available." -Type 'FAIL'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset password for '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Password reset cancelled (empty password provided)." -Type 'WARN'
                        }
                    }
                    '4' {
                        if ($targetAccount.SID -match '-(?:500)$' -or $targetAccount.Name -eq 'Administrator') {
                            Write-ToolkitStatus -Message "Operation blocked: Built-in Administrator account (SID -500) cannot be removed." -Type 'FAIL'
                        }
                        else {
                            $confirm = Read-Host "  Are you sure you want to remove account '$($targetAccount.Name)'? [Y/N]"
                            if (-not [string]::IsNullOrWhiteSpace($confirm) -and $confirm.Trim().ToUpperInvariant() -eq 'Y') {
                                try {
                                    if (Get-Command -Name 'Remove-LocalUser' -ErrorAction SilentlyContinue) {
                                        Remove-LocalUser -Name $targetAccount.Name -ErrorAction Stop
                                        Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' successfully removed." -Type 'OK'
                                    }
                                    else {
                                        Write-ToolkitStatus -Message "Remove-LocalUser command is not available." -Type 'FAIL'
                                    }
                                }
                                catch {
                                    Write-ToolkitStatus -Message "Failed to remove account '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "Account removal cancelled." -Type 'INFO'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuExternalTools {
<#
.SYNOPSIS
    Submenu for External Tools & Utilities with Tri-Panel UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $subnav = @(
        @{ Key = 'B'; Label = 'Back to Main Menu' },
        @{ Key = 'Q'; Label = 'Exit Console' }
    )
    $toolsDetails = @(
        @{ Key = '1'; Action = 'Run Browser Debloat'; Description = 'Launch Chrome/Browser debloat utility.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '2'; Action = 'Run Win11Debloat'; Description = 'Launch Win11Debloat script for bloatware/telemetry purge.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '3'; Action = 'Run Office Tool Plus'; Description = 'Launch Office Tool Plus for deployment and activation.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '4'; Action = 'Test Connectivity'; Description = 'Test ICMP ping, HTTP, and HTTPS endpoints.'; Prerequisite = 'Network adapter [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $toolsInfo = Get-ExternalToolsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > EXTERNAL TOOLS & UTILITIES' -Subtitle 'Pre-Flight Internet Check & External Utility Launchers' -ClearScreen:$clear -InfoLines $toolsInfo
        Show-ToolkitDetailPanel -Details $toolsDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'External Tools & Quick Launchers'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', 'B', 'Q')
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub.ToUpperInvariant() -eq 'B') {
            $inSubmenu = $false
            break
        }
        if ($sub.ToUpperInvariant() -eq 'Q') {
            $inSubmenu = $false
            return
        }

        switch ($sub) {
            '1' {
                if (Get-Command -Name 'Invoke-BrowserDebloat' -ErrorAction SilentlyContinue) {
                    Invoke-BrowserDebloat | Format-List
                }
            }
            '2' {
                if (Get-Command -Name 'Invoke-Win11Debloat' -ErrorAction SilentlyContinue) {
                    Invoke-Win11Debloat | Format-List
                }
            }
            '3' {
                if (Get-Command -Name 'Invoke-OfficeToolPlus' -ErrorAction SilentlyContinue) {
                    Invoke-OfficeToolPlus | Format-List
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-OfficeToolPlus command not available." -Type 'WARN'
                }
            }
            '4' {
                if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
                    $reachable = Test-InternetConnectivity
                    if ($reachable) {
                        Write-ToolkitStatus -Message "Internet connectivity verified." -Type 'OK'
                    }
                    else {
                        Write-ToolkitStatus -Message "No internet access detected." -Type 'FAIL'
                    }
                }
            }
        }
        Wait-UserAcknowledge
    }
}

function Invoke-ToolkitSubmenuWindowsRepair {
<#
.SYNOPSIS
    Submenu for Windows System Repair & Maintenance with Tri-Panel / Action Catalog UI/UX.
.DESCRIPTION
    Presents diagnostic repair capabilities for System File Checker (sfc /scannow),
    DISM Component Store (/RestoreHealth), Windows Update components reset,
    network stack (Winsock/TCP-IP/DNS) reset, and WMI repository salvage.
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately (used for automated testing).
.PARAMETER NonInteractive
    Switch to run in headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Optional menu recursion depth.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
        $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
        if (Test-Path $catScript) {
            . $catScript
        }
    }
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $repairInfo = Get-WindowsRepairContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > WINDOWS SYSTEM REPAIR & MAINTENANCE' -Subtitle 'SFC Integrity, DISM Component Store, Windows Update & Network Stack' -ClearScreen:$clear -InfoLines $repairInfo

        # Elevation warning banner if Test-IsAdmin returns false
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            try {
                $isAdmin = Test-IsAdmin
            }
            catch {
                $isAdmin = $false
            }
        }
        if (-not $isAdmin) {
            Write-ToolkitStatus -Message "ELEVATION WARNING: Administrative privileges required. Run as Administrator for system repairs." -Type 'WARN'
        }

        # Item-centric summary of repair subsystems
        $repairItems = @(
            [PSCustomObject]@{ Component = 'System File Checker (SFC)'; Status = '[READY]'; Action = 'sfc /scannow'; Details = 'Integrity scan & repair of protected system files' },
            [PSCustomObject]@{ Component = 'DISM Component Store'; Status = '[READY]'; Action = 'DISM /RestoreHealth'; Details = 'Windows component store repair via online/cleanup' },
            [PSCustomObject]@{ Component = 'Windows Update Services'; Status = '[READY]'; Action = 'Reset-WindowsUpdate'; Details = 'Reset update services & clear SoftwareDistribution' },
            [PSCustomObject]@{ Component = 'Network & Winsock Stack'; Status = '[READY]'; Action = 'Reset-NetworkStack'; Details = 'Reset Winsock, TCP/IP stack, and flush DNS cache' },
            [PSCustomObject]@{ Component = 'WMI Repository'; Status = '[READY]'; Action = 'Repair-WmiRepository'; Details = 'Verify and salvage corrupted WMI repository' }
        )
        Show-ToolkitItemTable -Items $repairItems -Columns @('Component', 'Status', 'Action', 'Details') -Headers @('COMPONENT', 'STATUS', 'ACTION', 'DETAILS') -Title 'Windows Repair Subsystems'

        Write-Host ""
        $repairActions = @(
            @{ Key = 'S'; Label = 'SFC Scan' },
            @{ Key = 'D'; Label = 'DISM RestoreHealth' },
            @{ Key = 'W'; Label = 'Reset Windows Update' },
            @{ Key = 'N'; Label = 'Reset Network Stack' },
            @{ Key = 'R'; Label = 'Repair WMI Repository' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $repairActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Windows System Repair & Maintenance'." -Type 'INFO'
            return
        }

        $validKeys = @('S', 'D', 'W', 'N', 'R', 'B', 'Q')
        $promptText = "  Select item [1-$($repairItems.Count)] or action [S, D, W, N, R, B, Q]"
        $selection = Read-ToolkitItemSelection -MaxIndex $repairItems.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        $actionKey = ''
        if ($selection.Type -eq 'Hotkey') {
            $actionKey = $selection.Value.ToString().ToUpperInvariant()
        }
        elseif ($selection.Type -eq 'Index') {
            switch ($selection.Value) {
                1 { $actionKey = 'S' }
                2 { $actionKey = 'D' }
                3 { $actionKey = 'W' }
                4 { $actionKey = 'N' }
                5 { $actionKey = 'R' }
            }
        }

        switch ($actionKey) {
            'B' {
                return
            }
            'Q' {
                return
            }
            'S' {
                if (Get-Command -Name 'Invoke-WindowsSfcScan' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Executing System File Checker scan (sfc /scannow)..." -Type 'INFO'
                        $sfcResult = Invoke-WindowsSfcScan
                        if ($sfcResult -and $sfcResult.Success) {
                            Write-ToolkitStatus -Message "SFC scan completed successfully: $($sfcResult.Status)." -Type 'OK'
                        }
                        else {
                            $statMsg = if ($sfcResult) { $sfcResult.Status } else { 'Scan completed' }
                            Write-ToolkitStatus -Message "SFC scan finished with notice: $statMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "SFC scan error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-WindowsSfcScan command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'D' {
                if (Get-Command -Name 'Invoke-WindowsDismRepair' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Executing DISM RestoreHealth repair..." -Type 'INFO'
                        $dismResult = Invoke-WindowsDismRepair -Mode 'RestoreHealth'
                        if ($dismResult -and $dismResult.Success) {
                            Write-ToolkitStatus -Message "DISM RestoreHealth completed successfully: $($dismResult.Status)." -Type 'OK'
                        }
                        else {
                            $dismMsg = if ($dismResult) { $dismResult.Status } else { 'Repair completed' }
                            Write-ToolkitStatus -Message "DISM repair finished with notice: $dismMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "DISM repair error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-WindowsDismRepair command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'W' {
                if (Get-Command -Name 'Reset-WindowsUpdateComponents' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Resetting Windows Update components and cache..." -Type 'INFO'
                        $wuResult = Reset-WindowsUpdateComponents
                        if ($wuResult -and $wuResult.Success) {
                            Write-ToolkitStatus -Message "Windows Update components reset successfully." -Type 'OK'
                        }
                        else {
                            Write-ToolkitStatus -Message "Windows Update reset finished with warnings." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "Windows Update reset error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Reset-WindowsUpdateComponents command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'N' {
                if (Get-Command -Name 'Reset-NetworkStack' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Resetting network sockets, IP stack, and DNS cache..." -Type 'INFO'
                        $netResult = Reset-NetworkStack
                        if ($netResult -and $netResult.Success) {
                            Write-ToolkitStatus -Message "Network stack reset successfully." -Type 'OK'
                        }
                        else {
                            Write-ToolkitStatus -Message "Network stack reset finished with warnings." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "Network stack reset error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Reset-NetworkStack command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'R' {
                if (Get-Command -Name 'Repair-WmiRepository' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Salvaging and repairing WMI repository..." -Type 'INFO'
                        $wmiResult = Repair-WmiRepository -Action 'Salvage'
                        if ($wmiResult -and $wmiResult.Success) {
                            Write-ToolkitStatus -Message "WMI repository salvage completed successfully: $($wmiResult.Status)." -Type 'OK'
                        }
                        else {
                            $wmiMsg = if ($wmiResult) { $wmiResult.Status } else { 'Salvage notice' }
                            Write-ToolkitStatus -Message "WMI repository salvage finished with notice: $wmiMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "WMI repair error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Repair-WmiRepository command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
        }
    }
}

function Invoke-ToolkitSubmenuAppInstaller {
<#
.SYNOPSIS
    Submenu for Quick Application Installation, Desktop Shortcuts & Default Application Configuration.
.DESCRIPTION
    Presents automated silent installation capabilities for:
    - UniKey (Vietnamese Input Method)
    - UltraVNC (Remote Administration & Screen Sharing)
    - K-Lite Codec Pack (Audio/Video Codecs & Media Player Classic)
    - Google Chrome (Web Browser)
    - Visual C++ Redistributables All-In-One (vcredist AIO)
    - Foxit PDF Reader (PDF Viewer & Editor)
    Generates desktop shortcuts for the current user account and sets Chrome and Foxit as system defaults.
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately (used for automated testing).
.PARAMETER NonInteractive
    Switch to run in headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Optional menu recursion depth.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
        $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
        if (Test-Path $catScript) { . $catScript }
    }
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) { . $tableScript }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $installerInfo = Get-AppInstallerContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > QUICK APP INSTALLER & DEPLOYMENT' -Subtitle 'Silent Installation, Desktop Shortcuts & Default App Configuration' -ClearScreen:$clear -InfoLines $installerInfo

        # Query installed apps
        $appsList = @()
        if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
            try {
                $rawApps = Get-ToolkitInstalledApplication
                foreach ($app in $rawApps) {
                    $statusBadge = if ($app.Installed) { '[INSTALLED]' } else { '[MISSING]' }
                    $exeDisplay = if ($app.ExecutablePath) { Split-Path -Leaf $app.ExecutablePath } else { 'Not Installed' }
                    $appsList += [PSCustomObject]@{
                        Application = $app.DisplayName
                        Status      = $statusBadge
                        Executable  = $exeDisplay
                        Version     = if ($app.Version) { $app.Version } else { 'N/A' }
                    }
                }
            } catch {
                $null = $_
            }
        }

        if ($appsList.Count -eq 0) {
            $appsList = @(
                [PSCustomObject]@{ Application = 'Google Chrome Browser'; Status = '[READY]'; Executable = 'chrome.exe'; Version = 'Latest' },
                [PSCustomObject]@{ Application = 'Foxit PDF Reader'; Status = '[READY]'; Executable = 'FoxitPDFReader.exe'; Version = 'Latest' },
                [PSCustomObject]@{ Application = 'UniKey Vietnamese Input'; Status = '[READY]'; Executable = 'UniKeyNT.exe'; Version = '4.3 RC5' },
                [PSCustomObject]@{ Application = 'UltraVNC Remote Support'; Status = '[READY]'; Executable = 'vncviewer.exe'; Version = 'Latest' },
                [PSCustomObject]@{ Application = 'K-Lite Codec Pack'; Status = '[READY]'; Executable = 'mpc-hc64.exe'; Version = 'Standard' },
                [PSCustomObject]@{ Application = 'Visual C++ Redistributable AIO'; Status = '[READY]'; Executable = 'System Runtimes'; Version = '2005-2022' },
                [PSCustomObject]@{ Application = 'Zalo PC Messenger'; Status = '[READY]'; Executable = 'Zalo.exe'; Version = 'Latest' }
            )
        }

        Show-ToolkitItemTable -Items $appsList -Columns @('Application', 'Status', 'Executable', 'Version') -Headers @('APPLICATION', 'STATUS', 'EXECUTABLE', 'VERSION') -Title 'Managed Enterprise Application Catalog'

        Write-Host ""
        $installerActions = @(
            @{ Key = 'A'; Label = 'Install All Apps (Full Setup)' },
            @{ Key = '1'; Label = 'Install Chrome (Set Default)' },
            @{ Key = '2'; Label = 'Install Foxit Reader (Set Default)' },
            @{ Key = '3'; Label = 'Install UniKey (Desktop Shortcut)' },
            @{ Key = '4'; Label = 'Install UltraVNC (Desktop Shortcut)' },
            @{ Key = '5'; Label = 'Install K-Lite Codec Pack' },
            @{ Key = '6'; Label = 'Install VC++ Redist AIO' },
            @{ Key = '7'; Label = 'Install Zalo PC (Desktop Shortcut)' },
            @{ Key = 'E'; Label = 'Deploy Chrome Extensions (uBlock Lite)' },
            @{ Key = 'S'; Label = 'Create Desktop Shortcuts' },
            @{ Key = 'D'; Label = 'Set Default Applications' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $installerActions -NavActions $navActions -Title 'DEPLOYMENT ACTIONS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Quick App Installer'." -Type 'INFO'
            return
        }

        $validKeys = @('A', '1', '2', '3', '4', '5', '6', '7', 'E', 'S', 'D', 'B', 'Q')
        $sub = Read-ToolkitMenuChoice -Prompt 'Select Action' -ValidKeys $validKeys
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub.ToUpperInvariant() -eq 'B') {
            $inSubmenu = $false
            break
        }
        if ($sub.ToUpperInvariant() -eq 'Q') {
            $inSubmenu = $false
            return
        }

        switch ($sub.ToUpperInvariant()) {
            'A' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Initiating automated installation of all standard applications..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'All' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "All application deployments completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '1' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Google Chrome and setting as default browser..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Chrome' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Google Chrome deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '2' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Foxit PDF Reader and setting as default PDF viewer..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'FoxitReader' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Foxit PDF Reader deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '3' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing UniKey and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'UniKey' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "UniKey deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '4' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing UltraVNC and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'UltraVNC' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "UltraVNC deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '5' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing K-Lite Codec Pack..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'KLiteCodec' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "K-Lite Codec Pack deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '6' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Microsoft Visual C++ Redistributable AIO..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'VCRedistAIO'
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Visual C++ Redistributable AIO deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '7' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Zalo PC and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Zalo' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Zalo PC deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'E' {
                if (Get-Command -Name 'Set-ToolkitChromeExtensionPolicy' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Deploying uBlock Origin Lite extension policy for Chrome..." -Type 'INFO'
                    $extRes = Set-ToolkitChromeExtensionPolicy
                    if ($extRes.Configured) {
                        Write-ToolkitStatus -Message "uBlock Origin Lite enterprise policy applied successfully." -Type 'OK'
                    } else {
                        Write-ToolkitStatus -Message "Chrome extension policy could not be verified." -Type 'WARN'
                    }
                } elseif (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Configuring Chrome extension policy via AppInstaller..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Chrome' -ConfigureChromeExtensions
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Chrome extension configuration finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Chrome extension deployment cmdlet not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'S' {
                if ((Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) -and
                    (Get-Command -Name 'New-ToolkitDesktopShortcut' -ErrorAction SilentlyContinue)) {
                    Write-ToolkitStatus -Message "Creating desktop shortcuts for current user..." -Type 'INFO'
                    $installedApps = Get-ToolkitInstalledApplication
                    $shortcutMap = @{
                        'UniKey'      = 'UniKey.lnk'
                        'UltraVNC'    = 'UltraVNC Viewer.lnk'
                        'KLiteCodec'  = 'Media Player Classic.lnk'
                        'Chrome'      = 'Google Chrome.lnk'
                        'FoxitReader' = 'Foxit PDF Reader.lnk'
                        'Zalo'        = 'Zalo.lnk'
                    }
                    foreach ($app in $installedApps) {
                        if ($app.Installed -and $app.ExecutablePath -and $shortcutMap.ContainsKey($app.AppName)) {
                            New-ToolkitDesktopShortcut -TargetExecutable $app.ExecutablePath -ShortcutName $shortcutMap[$app.AppName] -Force | Out-Null
                        }
                    }
                    Write-ToolkitStatus -Message "Desktop shortcut creation completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Shortcut creation cmdlets not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'D' {
                if (Get-Command -Name 'Set-ToolkitDefaultApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Setting default applications (Chrome for Browser, Foxit for PDF)..." -Type 'INFO'
                    $res = Set-ToolkitDefaultApplication -Application 'All'
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Default application configuration completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Set-ToolkitDefaultApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
        }
    }
}

foreach ($subFn in @(
    'Invoke-ToolkitSubmenuOutlook',
    'Invoke-ToolkitSubmenuOffice',
    'Invoke-ToolkitSubmenuPrinters',
    'Invoke-ToolkitSubmenuBackup',
    'Invoke-ToolkitSubmenuAccounts',
    'Invoke-ToolkitSubmenuExternalTools',
    'Invoke-ToolkitSubmenuWindowsRepair',
    'Invoke-ToolkitSubmenuAppInstaller'
)) {
    if (Get-Command -Name $subFn -CommandType Function -ErrorAction SilentlyContinue) {
        Set-Item -Path "function:global:$subFn" -Value (Get-Command -Name $subFn).ScriptBlock
    }
}
