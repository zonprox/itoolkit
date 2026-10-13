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
    Launches the interactive keyboard-driven main console menu for IToolkit with 5 Core Pillars.
.DESCRIPTION
    Main console menu engine orchestrating category navigation across the 5 Enterprise Core Pillars:
    1. System Health & Maintenance (Windows Repair & Cleanup)
    2. Office & Productivity Suite (Office & Outlook Administration)
    3. Network & Connectivity (Network Diagnostics & Printers)
    4. Accounts, Identity & Backup (User Accounts, SID -500 & Profile Protection)
    5. Software & System Optimization (64-Bit App Deployment & Debloat)
    9. Refresh Screen
    0. Exit Console
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
        @{ Key = '9'; Label = 'Refresh Screen' },
        @{ Key = '0'; Label = 'Exit Console' }
    )
    $mainDetails = @(
        @{ Key = '1'; Action = 'System Health & Maintenance'; Description = 'Unified Windows repair, SFC/DISM servicing, update reset, and component store cleanup.'; Prerequisite = 'Administrator rights [RECOMMENDED]' },
        @{ Key = '2'; Action = 'Office & Productivity Suite'; Description = 'Unified Office and Outlook administration, hardware acceleration, add-ins, and PST/OST repair.'; Prerequisite = 'Office installed [READY]' },
        @{ Key = '3'; Action = 'Network & Connectivity'; Description = 'Unified network configuration, Winsock/DNS reset, SMB policies, print spooler, and printer repair.'; Prerequisite = 'Network adapter [READY]' },
        @{ Key = '4'; Action = 'Accounts, Identity & Backup'; Description = 'Unified local and domain account administration, SID -500 activation, profile backup, and certs.'; Prerequisite = 'Administrator rights [READY]' },
        @{ Key = '5'; Action = 'Software & System Optimization'; Description = 'Unified 64-bit silent application deployment, WinRAR, UniKey, winget update, and system debloat.'; Prerequisite = 'Internet access [READY]' }
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

        $cleanOption = $MenuOption.Trim().Trim('[', ']').Trim().ToUpperInvariant()
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Direct menu option executed: $cleanOption" -Level INFO -Component 'Start-IToolkitMenu' -NoConsole
        }

        switch ($cleanOption) {
            '1' { Invoke-ToolkitSubmenuSystemHealth @subParams }
            '2' { Invoke-ToolkitSubmenuOfficeSuite @subParams }
            '3' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuPrinters' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuPrinters @subParams
                } else {
                    Invoke-ToolkitSubmenuConnectivity @subParams
                }
            }
            '4' { Invoke-ToolkitSubmenuIdentityBackup @subParams }
            '5' { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            # Legacy numeric switches
            '6' { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            '7' { Invoke-ToolkitSubmenuSystemHealth @subParams }
            '8' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuAppInstaller' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuAppInstaller @subParams
                } else {
                    Invoke-ToolkitSubmenuSoftwareOptimization @subParams
                }
            }
            'N' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuNetwork @subParams
                } else {
                    Invoke-ToolkitSubmenuConnectivity @subParams
                }
            }
            # Named option aliases
            'NETWORK'              {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuNetwork @subParams
                } else {
                    Invoke-ToolkitSubmenuConnectivity @subParams
                }
            }
            'HEALTH'               { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'SYSTEMHEALTH'         { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'REPAIR'               { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'CLEANUP'              { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'WINDOWSREPAIR'        { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'WINDOWSCLEANUP'       { Invoke-ToolkitSubmenuSystemHealth @subParams }
            'OFFICE'               { Invoke-ToolkitSubmenuOfficeSuite @subParams }
            'OUTLOOK'              { Invoke-ToolkitSubmenuOfficeSuite @subParams }
            'OFFICESUITE'          { Invoke-ToolkitSubmenuOfficeSuite @subParams }
            'CONNECTIVITY'         { Invoke-ToolkitSubmenuConnectivity @subParams }
            'PRINTERS'             {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuPrinters' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuPrinters @subParams
                } else {
                    Invoke-ToolkitSubmenuConnectivity @subParams
                }
            }
            'IDENTITY'             { Invoke-ToolkitSubmenuIdentityBackup @subParams }
            'BACKUP'               { Invoke-ToolkitSubmenuIdentityBackup @subParams }
            'ACCOUNTS'             { Invoke-ToolkitSubmenuIdentityBackup @subParams }
            'IDENTITYBACKUP'       { Invoke-ToolkitSubmenuIdentityBackup @subParams }
            'SOFTWARE'             { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            'APPS'                 {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuAppInstaller' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuAppInstaller @subParams
                } else {
                    Invoke-ToolkitSubmenuSoftwareOptimization @subParams
                }
            }
            'APPINSTALLER'         {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuAppInstaller' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuAppInstaller @subParams
                } else {
                    Invoke-ToolkitSubmenuSoftwareOptimization @subParams
                }
            }
            'EXTERNALTOOLS'        { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            'DEBLOAT'              { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            'OPTIMIZATION'         { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            'SOFTWAREOPTIMIZATION' { Invoke-ToolkitSubmenuSoftwareOptimization @subParams }
            '9' {
                if (Get-Command -Name 'Clear-ToolkitTelemetryCache' -ErrorAction SilentlyContinue) {
                    Clear-ToolkitTelemetryCache
                }
                Write-ToolkitStatus -Message "Telemetry cache cleared." -Type 'OK'
            }
            'R' {
                if (Get-Command -Name 'Clear-ToolkitTelemetryCache' -ErrorAction SilentlyContinue) {
                    Clear-ToolkitTelemetryCache
                }
                Write-ToolkitStatus -Message "Telemetry cache cleared." -Type 'OK'
            }
            'REFRESH' {
                if (Get-Command -Name 'Clear-ToolkitTelemetryCache' -ErrorAction SilentlyContinue) {
                    Clear-ToolkitTelemetryCache
                }
                Write-ToolkitStatus -Message "Telemetry cache cleared." -Type 'OK'
            }
            '0' {
                Write-ToolkitStatus -Message "Exiting IToolkit." -Type 'OK'
            }
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

        $choice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', '9', '0') -Default $DefaultSelection

        if ([string]::IsNullOrWhiteSpace($choice)) {
            break
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Interactive menu selection: [$choice]" -Level INFO -Component 'Start-IToolkitMenu' -NoConsole
        }

        switch ($choice) {
            '1' { Invoke-ToolkitSubmenuSystemHealth }
            '2' { Invoke-ToolkitSubmenuOfficeSuite }
            '3' { Invoke-ToolkitSubmenuConnectivity }
            '4' { Invoke-ToolkitSubmenuIdentityBackup }
            '5' { Invoke-ToolkitSubmenuSoftwareOptimization }
            '9' {
                if (Get-Command -Name 'Clear-ToolkitTelemetryCache' -ErrorAction SilentlyContinue) {
                    Clear-ToolkitTelemetryCache
                }
                continue
            }
            '0' {
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
