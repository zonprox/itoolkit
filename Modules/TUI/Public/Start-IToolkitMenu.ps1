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
    $lines.Add("Tool 1         : Win11Debloat (Telemetry & bloatware purge) [READY]")
    $lines.Add("Tool 2         : Chris Titus WinUtil (General Windows optimization suite) [READY]")

    return $lines.ToArray()
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
        @{ Key = '6'; Action = 'External Tools'; Description = 'Win11Debloat, Chris Titus WinUtil, network testing.'; Prerequisite = 'Internet access [READY]' }
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

        $choice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', 'R', 'Q', 'X') -Default $DefaultSelection

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
    Submenu for Outlook & PST Management with Tri-Panel UI/UX.
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
    $outlookDetails = @(
        @{ Key = '1'; Action = 'Scan Data Files'; Description = 'Deep discovery across registry profiles & disk drives.'; Prerequisite = 'None [READY]' },
        @{ Key = '2'; Action = 'Relocate PST'; Description = 'Move PST/OST with SHA-256 validation & profile repoint.'; Prerequisite = 'Outlook must be stopped [SAFE]' },
        @{ Key = '3'; Action = 'Update Profile Path'; Description = 'Re-map MAPI binary registry paths to new file location.'; Prerequisite = 'Profile registry key [READY]' },
        @{ Key = '4'; Action = 'Expand Size Limit'; Description = 'Set MaxLargeFileSize policy (up to 100GB limit).'; Prerequisite = 'Admin elevation [READY]' },
        @{ Key = '5'; Action = 'Compact Data File'; Description = 'Launch MAPI profile compaction management utility.'; Prerequisite = 'Outlook installed [READY]' },
        @{ Key = '6'; Action = 'Backup PST'; Description = 'Copy PST to backup path with SHA-256 hash check.'; Prerequisite = 'Target drive space [READY]' },
        @{ Key = '7'; Action = 'Restore PST'; Description = 'Restore PST from backup with cryptographic verification.'; Prerequisite = 'Backup file exists [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $outlookInfo = Get-OutlookContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OUTLOOK & PST MANAGEMENT' -Subtitle 'PST/OST Discovery, Relocation, Compaction & Registry Policies' -ClearScreen:$clear -InfoLines $outlookInfo
        Show-ToolkitDetailPanel -Details $outlookDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Outlook & PST Data Management'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', 'B', 'Q')
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
                if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
                    $files = Find-OutlookDataFiles
                    if ($files) {
                        $files | Format-Table -AutoSize
                    }
                    else {
                        Write-ToolkitStatus -Message "No Outlook data files detected." -Type 'INFO'
                    }
                }
            }
            '2' {
                $src = Read-Host "  Enter Source PST Path"
                $dst = Read-Host "  Enter Destination PST Path"
                if (-not [string]::IsNullOrWhiteSpace($src) -and -not [string]::IsNullOrWhiteSpace($dst)) {
                    if (Get-Command -Name 'Move-OutlookDataFile' -ErrorAction SilentlyContinue) {
                        Move-OutlookDataFile -SourcePath $src -DestinationPath $dst
                    }
                }
            }
            '3' {
                $prof = Read-Host "  Enter Profile Name (e.g. Outlook)"
                $oldP = Read-Host "  Enter Old Path"
                $newP = Read-Host "  Enter New Path"
                if (Get-Command -Name 'Update-OutlookProfilePath' -ErrorAction SilentlyContinue) {
                    Update-OutlookProfilePath -ProfileName $prof -OldPath $oldP -NewPath $newP
                }
            }
            '4' {
                if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                    Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                }
            }
            '5' {
                if (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                    Invoke-OutlookCompaction
                }
            }
            '6' {
                $src = Read-Host "  Enter Source PST Path"
                $bak = Read-Host "  Enter Backup Directory"
                if (Get-Command -Name 'Backup-OutlookPst' -ErrorAction SilentlyContinue) {
                    Backup-OutlookPst -SourcePath $src -BackupDirectory $bak
                }
            }
            '7' {
                $bak = Read-Host "  Enter Backup PST Path"
                $dst = Read-Host "  Enter Restore Destination Path"
                if (Get-Command -Name 'Restore-OutlookPst' -ErrorAction SilentlyContinue) {
                    Restore-OutlookPst -BackupPath $bak -DestinationPath $dst
                }
            }
        }
        Wait-UserAcknowledge
    }
}

function Invoke-ToolkitSubmenuOffice {
<#
.SYNOPSIS
    Submenu for Office & Excel Troubleshooting with Tri-Panel UI/UX.
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
    $officeDetails = @(
        @{ Key = '1'; Action = 'Disable Acceleration'; Description = 'Disable hardware acceleration to avoid display crashes.'; Prerequisite = 'Office registry [READY]' },
        @{ Key = '2'; Action = 'Enable Acceleration'; Description = 'Re-enable hardware acceleration for normal performance.'; Prerequisite = 'Office registry [READY]' },
        @{ Key = '3'; Action = 'Reset Excel UI Cache'; Description = 'Rename Excel16.xlb and purge stale XLSTART templates.'; Prerequisite = 'Excel stopped [READY]' },
        @{ Key = '4'; Action = 'Clear Office Cache'; Description = 'Purge OfficeFileCache and temporary document buffers.'; Prerequisite = 'Office stopped [READY]' },
        @{ Key = '5'; Action = 'List COM Add-ins'; Description = 'Enumerate installed COM add-ins and startup behavior.'; Prerequisite = 'Registry access [READY]' },
        @{ Key = '6'; Action = 'Reset Resiliency'; Description = 'Clear disabled items list to restore blocked add-ins.'; Prerequisite = 'Registry access [READY]' },
        @{ Key = '7'; Action = 'Audit GDI Handles'; Description = 'Audit GDI and USER handle consumption across processes.'; Prerequisite = 'Excel running or stopped [READY]' },
        @{ Key = '8'; Action = 'Stop Leaking Excel'; Description = 'Terminate Excel instances exceeding handle thresholds.'; Prerequisite = 'Admin or user rights [READY]' },
        @{ Key = '9'; Action = 'Repair ClickToRun'; Description = 'Trigger native Office ClickToRun repair wizard.'; Prerequisite = 'C2R installation [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & EXCEL TROUBLESHOOTING' -Subtitle 'Graphics Acceleration, Cache Reset, COM Add-ins, GDI Leaks, Click-to-Run Repair' -ClearScreen:$clear -InfoLines $officeInfo
        Show-ToolkitDetailPanel -Details $officeDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Excel Troubleshooting & Repair'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'B', 'Q')
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
                if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                    Set-ExcelHardwareAcceleration -Disable
                }
            }
            '2' {
                if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                    Set-ExcelHardwareAcceleration -Enable
                }
            }
            '3' {
                if (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue) {
                    Reset-ExcelUiCache
                }
            }
            '4' {
                if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                    Clear-OfficeTempCache
                }
            }
            '5' {
                if (Get-Command -Name 'Get-ExcelComAddin' -ErrorAction SilentlyContinue) {
                    Get-ExcelComAddin | Format-Table -AutoSize
                }
            }
            '6' {
                if (Get-Command -Name 'Reset-ExcelResiliency' -ErrorAction SilentlyContinue) {
                    Reset-ExcelResiliency
                }
            }
            '7' {
                if (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                    Get-ExcelGdiHandleUsage | Format-Table -AutoSize
                }
            }
            '8' {
                if (Get-Command -Name 'Stop-ExcelGdiLeakers' -ErrorAction SilentlyContinue) {
                    Stop-ExcelGdiLeakers -Force
                }
            }
            '9' {
                $repairType = Read-Host "  Enter Repair Type [Quick/Online] (Default: Quick)"
                if ([string]::IsNullOrWhiteSpace($repairType)) {
                    $repairType = 'Quick'
                }
                if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                    Start-OfficeClickToRunRepair -RepairType $repairType
                }
            }
        }
        Wait-UserAcknowledge
    }
}

function Invoke-ToolkitSubmenuPrinters {
<#
.SYNOPSIS
    Submenu for Network & Print Spooler with Tri-Panel UI/UX.
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
    $printersDetails = @(
        @{ Key = '1'; Action = 'Spooler Status'; Description = 'Inspect Print Spooler service state, PID and queue size.'; Prerequisite = 'Spooler service [READY]' },
        @{ Key = '2'; Action = 'Purge Spooler Queue'; Description = 'Stop spooler, purge stuck jobs, restart service.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '3'; Action = 'Register Spooler DLLs'; Description = 'Re-register spoolss.dll, winspool.drv and compile MOF.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '4'; Action = 'Reset Ne Ports'; Description = 'Purge stale NeXX: virtual port mappings in registry.'; Prerequisite = 'HKCU registry [READY]' },
        @{ Key = '5'; Action = 'Audit Point & Print'; Description = 'Inspect Point and Print mitigation policies.'; Prerequisite = 'Registry access [READY]' },
        @{ Key = '6'; Action = 'Apply PnP Remediation'; Description = 'Apply RestrictDriverInstallationToAdministrators policy.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '7'; Action = 'Test Printer Network'; Description = 'Probe printer network ports (SMB, RPC, TCP 9100, 515).'; Prerequisite = 'Network online [READY]' },
        @{ Key = '8'; Action = 'Refresh Connections'; Description = 'Refresh active user network printer bindings.'; Prerequisite = 'WScript.Network [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $printersInfo = Get-PrintersContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK & PRINT SPOOLER' -Subtitle 'Spooler Diagnostics, Queue Purge, Ne Ports, Point & Print' -ClearScreen:$clear -InfoLines $printersInfo
        Show-ToolkitDetailPanel -Details $printersDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Network & Print Spooler Troubleshooting'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', 'B', 'Q')
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
                if (Get-Command -Name 'Get-PrintSpoolerStatus' -ErrorAction SilentlyContinue) {
                    Get-PrintSpoolerStatus | Format-List
                }
            }
            '2' {
                if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                    Reset-PrintSpoolerQueue -Force
                }
            }
            '3' {
                if (Get-Command -Name 'Register-PrintSpoolerComponents' -ErrorAction SilentlyContinue) {
                    Register-PrintSpoolerComponents
                }
            }
            '4' {
                if (Get-Command -Name 'Reset-PrinterNePortBindings' -ErrorAction SilentlyContinue) {
                    Reset-PrinterNePortBindings
                }
            }
            '5' {
                if (Get-Command -Name 'Test-PointAndPrintPolicy' -ErrorAction SilentlyContinue) {
                    Test-PointAndPrintPolicy | Format-List
                }
            }
            '6' {
                if (Get-Command -Name 'Set-PointAndPrintRemediation' -ErrorAction SilentlyContinue) {
                    Set-PointAndPrintRemediation -Preset 'StrictAdminOnly'
                }
            }
            '7' {
                $srv = Read-Host "  Enter Printer Server / IP Address"
                if (-not [string]::IsNullOrWhiteSpace($srv)) {
                    if (Get-Command -Name 'Test-NetworkPrinterConnectivity' -ErrorAction SilentlyContinue) {
                        Test-NetworkPrinterConnectivity -ComputerName $srv | Format-List
                    }
                }
            }
            '8' {
                if (Get-Command -Name 'Reset-PrinterConnections' -ErrorAction SilentlyContinue) {
                    Reset-PrinterConnections
                }
            }
        }
        Wait-UserAcknowledge
    }
}

function Invoke-ToolkitSubmenuBackup {
<#
.SYNOPSIS
    Submenu for User Profile Data Backup with Tri-Panel UI/UX.
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
    $backupDetails = @(
        @{ Key = '1'; Action = 'Map Profile Folders'; Description = 'Map standard user folders and OneDrive redirection.'; Prerequisite = 'Profile exists [READY]' },
        @{ Key = '2'; Action = 'Export Bookmarks'; Description = 'Extract Chrome and Edge browser bookmarks to JSON.'; Prerequisite = 'Browser app data [READY]' },
        @{ Key = '3'; Action = 'Export Certificates'; Description = 'Export personal certificates from CurrentUser store.'; Prerequisite = 'Certificate store [READY]' },
        @{ Key = '4'; Action = 'Backup Profile Folders'; Description = 'Robocopy multithreaded directory backup engine.'; Prerequisite = 'Target free space [READY]' },
        @{ Key = '5'; Action = 'Generate Manifest'; Description = 'Compute SHA-256 cryptographic JSON backup manifest.'; Prerequisite = 'Directory path [READY]' },
        @{ Key = '6'; Action = 'Verify Manifest'; Description = 'Validate files against SHA-256 backup manifest.'; Prerequisite = 'Manifest JSON [READY]' },
        @{ Key = '7'; Action = 'Restore Profile Data'; Description = 'Restore user profile data from verified backup.'; Prerequisite = 'Backup files [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $backupInfo = Get-BackupContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER PROFILE DATA BACKUP' -Subtitle 'Folders, Bookmarks, Certificates, Robocopy Engine & SHA-256 Manifests' -ClearScreen:$clear -InfoLines $backupInfo
        Show-ToolkitDetailPanel -Details $backupDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'User Profile Data Backup & Migration'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', 'B', 'Q')
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
                if (Get-Command -Name 'Get-UserProfileDirectoryMap' -ErrorAction SilentlyContinue) {
                    Get-UserProfileDirectoryMap | Format-List
                }
            }
            '2' {
                $outDir = Read-Host "  Enter Export Destination Directory"
                if (-not [string]::IsNullOrWhiteSpace($outDir)) {
                    if (Get-Command -Name 'Export-BrowserBookmarks' -ErrorAction SilentlyContinue) {
                        Export-BrowserBookmarks -DestinationDirectory $outDir | Format-List
                    }
                }
            }
            '3' {
                $outDir = Read-Host "  Enter Export Destination Directory"
                if (-not [string]::IsNullOrWhiteSpace($outDir)) {
                    if (Get-Command -Name 'Export-PersonalCertificates' -ErrorAction SilentlyContinue) {
                        Export-PersonalCertificates -DestinationDirectory $outDir | Format-List
                    }
                }
            }
            '4' {
                $src = Read-Host "  Enter Source Profile Path (e.g. C:\Users\Username)"
                $dst = Read-Host "  Enter Target Backup Path"
                if (-not [string]::IsNullOrWhiteSpace($src) -and -not [string]::IsNullOrWhiteSpace($dst)) {
                    if (Get-Command -Name 'Start-ProfileDirectoryBackup' -ErrorAction SilentlyContinue) {
                        Start-ProfileDirectoryBackup -SourceProfilePath $src -DestinationBackupPath $dst | Format-List
                    }
                }
            }
            '5' {
                $target = Read-Host "  Enter Target Directory for Manifest"
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    if (Get-Command -Name 'New-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
                        New-BackupIntegrityManifest -TargetDirectory $target | Format-List
                    }
                }
            }
            '6' {
                $manPath = Read-Host "  Enter Manifest File Path"
                if (-not [string]::IsNullOrWhiteSpace($manPath)) {
                    if (Get-Command -Name 'Test-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
                        Test-BackupIntegrityManifest -ManifestPath $manPath | Format-List
                    }
                }
            }
            '7' {
                $root = Read-Host "  Enter Backup Root Path"
                if (-not [string]::IsNullOrWhiteSpace($root)) {
                    if (Get-Command -Name 'Restore-UserProfileData' -ErrorAction SilentlyContinue) {
                        Restore-UserProfileData -BackupRoot $root | Format-List
                    }
                }
            }
        }
        Wait-UserAcknowledge
    }
}

function Invoke-ToolkitSubmenuAccounts {
<#
.SYNOPSIS
    Submenu for User & Domain Account Administration with Tri-Panel UI/UX.
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
    $accountsDetails = @(
        @{ Key = '1'; Action = 'List Local Accounts'; Description = 'Enumerate local user accounts via ADSI WinNT.'; Prerequisite = 'Local system [READY]' },
        @{ Key = '2'; Action = 'Create Local Account'; Description = 'Create local user account with SecureString password.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '3'; Action = 'Unlock Local Account'; Description = 'Clear account lockout flag for local account.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '4'; Action = 'Set Account Status'; Description = 'Enable or disable local user account.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '5'; Action = 'Query Domain User'; Description = 'Query Active Directory user details without RSAT.'; Prerequisite = 'Domain reachability [READY]' },
        @{ Key = '6'; Action = 'Unlock Domain User'; Description = 'Unlock domain account via .NET DirectoryEntry.'; Prerequisite = 'Domain reachability [READY]' },
        @{ Key = '7'; Action = 'Enable Admin (SID 500)'; Description = 'Activate built-in Administrator account.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '8'; Action = 'Reset Admin Password'; Description = 'Reset built-in Administrator account password.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '9'; Action = 'Test Domain Health'; Description = 'Test DNS SRV, LDAP, Kerberos, SMB and RPC ports.'; Prerequisite = 'Network connection [READY]' },
        @{ Key = '10'; Action = 'Disjoin Domain'; Description = 'Disjoin machine from domain with lockout defense.'; Prerequisite = 'Domain admin creds [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $accountsInfo = Get-AccountsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER & DOMAIN ACCOUNT ADMINISTRATION' -Subtitle 'Account Operations, Administrator SID -500, Domain Join/Disjoin' -ClearScreen:$clear -InfoLines $accountsInfo
        Show-ToolkitDetailPanel -Details $accountsDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'User & Domain Account Administration'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'B', 'Q')
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
                if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                    Get-LocalAccountList | Format-Table -AutoSize
                }
            }
            '2' {
                $user = Read-Host "  Enter New Username"
                $pwd  = Read-Host "  Enter Secure Password" -AsSecureString
                if (-not [string]::IsNullOrWhiteSpace($user) -and $null -ne $pwd) {
                    if (Get-Command -Name 'New-LocalAccountItem' -ErrorAction SilentlyContinue) {
                        New-LocalAccountItem -Username $user -Password $pwd | Format-List
                    }
                }
            }
            '3' {
                $user = Read-Host "  Enter Username to Unlock"
                if (-not [string]::IsNullOrWhiteSpace($user)) {
                    if (Get-Command -Name 'Unlock-LocalAccountItem' -ErrorAction SilentlyContinue) {
                        $res = Unlock-LocalAccountItem -Username $user
                        Write-ToolkitStatus -Message "Account '$user' unlock result: $res" -Type 'OK'
                    }
                }
            }
            '4' {
                $user = Read-Host "  Enter Username"
                $act  = Read-Host "  Enable account? [Y/N]"
                $enab = ($act.Trim().ToUpperInvariant() -eq 'Y')
                if (-not [string]::IsNullOrWhiteSpace($user)) {
                    if (Get-Command -Name 'Set-LocalAccountState' -ErrorAction SilentlyContinue) {
                        Set-LocalAccountState -Username $user -Enabled $enab
                    }
                }
            }
            '5' {
                $user = Read-Host "  Enter Domain SamAccountName"
                if (-not [string]::IsNullOrWhiteSpace($user)) {
                    if (Get-Command -Name 'Get-DomainAccountItem' -ErrorAction SilentlyContinue) {
                        Get-DomainAccountItem -Username $user | Format-List
                    }
                }
            }
            '6' {
                $user = Read-Host "  Enter Domain SamAccountName to Unlock"
                if (-not [string]::IsNullOrWhiteSpace($user)) {
                    if (Get-Command -Name 'Unlock-DomainAccountItem' -ErrorAction SilentlyContinue) {
                        $res = Unlock-DomainAccountItem -Username $user
                        Write-ToolkitStatus -Message "Domain account '$user' unlock result: $res" -Type 'OK'
                    }
                }
            }
            '7' {
                if (Get-Command -Name 'Enable-BuiltInAdministrator' -ErrorAction SilentlyContinue) {
                    Enable-BuiltInAdministrator | Format-List
                }
            }
            '8' {
                $pwd = Read-Host "  Enter New Password for Administrator" -AsSecureString
                if ($null -ne $pwd) {
                    if (Get-Command -Name 'Reset-BuiltInAdministratorPassword' -ErrorAction SilentlyContinue) {
                        Reset-BuiltInAdministratorPassword -Password $pwd | Format-List
                    }
                }
            }
            '9' {
                $dom = Read-Host "  Enter Domain FQDN (e.g. corp.contoso.com)"
                if (-not [string]::IsNullOrWhiteSpace($dom)) {
                    if (Get-Command -Name 'Test-DomainReachability' -ErrorAction SilentlyContinue) {
                        Test-DomainReachability -DomainName $dom | Format-List
                    }
                }
            }
            '10' {
                $wg  = Read-Host "  Enter Target Workgroup Name (Default: WORKGROUP)"
                if ([string]::IsNullOrWhiteSpace($wg)) {
                    $wg = 'WORKGROUP'
                }
                Write-Host "  Domain disjoin requires domain administrative credentials." -ForegroundColor Yellow
                $cred = Get-Credential
                if ($null -ne $cred) {
                    if (Get-Command -Name 'Disconnect-ToolkitDomain' -ErrorAction SilentlyContinue) {
                        Disconnect-ToolkitDomain -WorkgroupName $wg -Credential $cred | Format-List
                    }
                }
            }
        }
        Wait-UserAcknowledge
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
        @{ Key = '1'; Action = 'Run Win11Debloat'; Description = 'Launch Win11Debloat script for bloatware/telemetry purge.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '2'; Action = 'Run ChrisTitus WinUtil'; Description = 'Launch Chris Titus Tech Windows Utility.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '3'; Action = 'Test Connectivity'; Description = 'Test ICMP ping, HTTP, and HTTPS endpoints.'; Prerequisite = 'Network adapter [READY]' }
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

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', 'B', 'Q')
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
                if (Get-Command -Name 'Invoke-Win11Debloat' -ErrorAction SilentlyContinue) {
                    Invoke-Win11Debloat | Format-List
                }
            }
            '2' {
                if (Get-Command -Name 'Invoke-ChrisTitusWinUtil' -ErrorAction SilentlyContinue) {
                    Invoke-ChrisTitusWinUtil | Format-List
                }
            }
            '3' {
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

foreach ($subFn in @(
    'Invoke-ToolkitSubmenuOutlook',
    'Invoke-ToolkitSubmenuOffice',
    'Invoke-ToolkitSubmenuPrinters',
    'Invoke-ToolkitSubmenuBackup',
    'Invoke-ToolkitSubmenuAccounts',
    'Invoke-ToolkitSubmenuExternalTools'
)) {
    if (Get-Command -Name $subFn -CommandType Function -ErrorAction SilentlyContinue) {
        Set-Item -Path "function:global:$subFn" -Value (Get-Command -Name $subFn).ScriptBlock
    }
}
