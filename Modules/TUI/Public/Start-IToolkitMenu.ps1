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
    7. Windows Repair
    8. Quick App Installer
    9. Windows Cleanup
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
        @{ Key = '8'; Action = 'Quick App Installer'; Description = 'Silent install UniKey, UltraVNC, K-Lite, Chrome, VCRedist, Foxit, Zalo.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '9'; Action = 'Windows Cleanup'; Description = 'Component store, update cache, dumps, DO cache & temp files.'; Prerequisite = 'Administrator rights [RECOMMENDED]' }
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
            '9' { Invoke-ToolkitSubmenuWindowsCleanup @subParams }
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

        $choice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'R', 'Q', 'X') -Default $DefaultSelection

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
            '9' { Invoke-ToolkitSubmenuWindowsCleanup }
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

if (Get-Command -Name 'Start-IToolkitMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Start-IToolkitMenu' -Value (Get-Command -Name 'Start-IToolkitMenu').ScriptBlock
}
