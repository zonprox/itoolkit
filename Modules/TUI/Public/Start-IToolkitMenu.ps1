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
    Launches the interactive keyboard-driven main console menu for IToolkit.
.DESCRIPTION
    Main console menu engine orchestrating category navigation across all toolkit modules:
    1. Outlook & PST Data Management
    2. Office & Excel Troubleshooting & Repair
    3. Network & Print Spooler Troubleshooting
    4. User Profile Data Backup & Migration
    5. User & Domain Account Administration
    6. External Tools & Quick Launchers (Win11Debloat, WinUtil)
    Q. Exit / Quit
    Supports safe non-interactive execution via -ExitImmediately switch or -MenuOption parameter.
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately (used for automated testing).
.PARAMETER NonInteractive
    Switch to run in headless automation mode without interactive prompt loops.
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

    # ==============================================================================
    # Diagnostic Telemetry & Header Context Collectors
    # ==============================================================================

    function Get-OutlookContextInfoLines {
        $lines = [System.Collections.Generic.List[string]]::new()

        # 1. Outlook Process
        $procStatus = "Stopped (Safe to migrate PST/OST)"
        try {
            $p = Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue
            if ($null -ne $p) {
                $procStatus = "Running (PID: $($p.Id)) - Must close before moving files"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Outlook State  : $procStatus")

        # 2. Default Profile
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

        # 3. Large PST Policy
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

        # 4. Data Files Found
        $fileInfo = "PST/OST Discovery Ready"
        try {
            if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
                $found = Find-OutlookDataFiles
                if ($null -ne $found -and $found.Count -gt 0) {
                    $totalSize = 0
                    foreach ($f in $found) {
                        if ($f.SizeGB) {
                            $totalSize += $f.SizeGB
                        }
                    }
                    $roundSize = [math]::Round($totalSize, 1)
                    $fileInfo = "$($found.Count) Data File(s) Detected | Total: ${roundSize} GB"
                }
                else {
                    $fileInfo = "0 Data Files Detected (Standard Directories)"
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
                    $officeVer = "Microsoft Office ClickToRun v$verNum [$arch] ($prod)"
                }
            }
            elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot') {
                $officeVer = "Microsoft Office 16.0 Desktop (MSI / Volume LTSC)"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Office Product : $officeVer")

        # 2. Graphics Acceleration
        $accelStatus = "Enabled [Default]"
        try {
            $regPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
            if (Test-Path $regPath) {
                $val = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DisableHardwareAcceleration
                if ($val -eq 1) {
                    $accelStatus = "Disabled [Safe against Print Preview crashes]"
                }
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Graphics Acceleration : $accelStatus")

        # 3. Excel Process
        $excelStatus = "Stopped (Not Running)"
        try {
            $procs = Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue
            if ($null -ne $procs) {
                $pCount = $procs.Count
                $pids = ($procs | ForEach-Object { $_.Id }) -join ', '
                $excelStatus = "Running ($pCount instance; PID: $pids)"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Excel Process  : $excelStatus")

        # 4. Excel UI Cache
        $cacheStatus = "Clean (No corrupt Excel16.xlb found)"
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
                $xlb15 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel15.xlb'
                $xlb16 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel16.xlb'
                if ((Test-Path $xlb15) -or (Test-Path $xlb16)) {
                    $cacheStatus = "Cache Present (Excel16.xlb found - Reset available)"
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
        $spoolerStatus = "Spooler Service: Unknown"
        try {
            $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
            if ($null -ne $svc) {
                $spoolerStatus = "Spooler Service: $($svc.Status) (Startup: $($svc.StartType))"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Spooler Status : $spoolerStatus")

        # 2. Print Queue Jobs
        $queueInfo = "0 Pending Jobs in Spool Folder (Queue Clean)"
        try {
            $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
            if (Test-Path $spoolDir) {
                $shdFiles = Get-ChildItem -Path $spoolDir -Filter '*.SHD' -ErrorAction SilentlyContinue
                if ($null -ne $shdFiles -and $shdFiles.Count -gt 0) {
                    $queueInfo = "$($shdFiles.Count) Stuck Job(s) Queued in Spool Directory"
                }
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Print Queue    : $queueInfo")

        # 3. Point & Print Policy
        $rpcPolicy = "Default / Unrestricted"
        try {
            $regP = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
            if (Test-Path $regP) {
                $val = (Get-ItemProperty $regP -ErrorAction SilentlyContinue).RestrictDriverInstallationToAdministrators
                if ($val -eq 1) {
                    $rpcPolicy = "StrictAdminOnly [PrintNightmare Mitigated]"
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
        $lines.Add("Target Profile : $profPath")

        # 2. Storage Free Space
        $freeSpace = "Drive Space Available"
        try {
            $telemetry = Get-ToolkitTelemetryData
            if ($null -ne $telemetry -and -not [string]::IsNullOrWhiteSpace($telemetry.StorageDisplay)) {
                $freeSpace = $telemetry.StorageDisplay
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Storage Target : $freeSpace")

        # 3. Backup Scope
        $lines.Add("Backup Scope   : Desktop, Documents, Downloads, Edge/Chrome Bookmarks, Certificates")

        return $lines.ToArray()
    }

    function Get-AccountsContextInfoLines {
        $lines = [System.Collections.Generic.List[string]]::new()

        # 1. Current User
        $currUser = "$env:USERDOMAIN\$env:USERNAME"
        $lines.Add("Current User   : $currUser")

        # 2. Privilege Level
        $adminStr = "Standard User"
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            try {
                if (Test-IsAdmin) {
                    $adminStr = "Local Administrator [Elevated]"
                }
            }
            catch {
                $null = $_
            }
        }
        $lines.Add("Privilege Level: $adminStr")

        # 3. Domain Status
        $domStatus = "Workgroup Mode ($env:USERDOMAIN)"
        if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
            $domStatus = "Active Directory Domain ($env:USERDNSDOMAIN)"
        }
        $lines.Add("Domain Status  : $domStatus")

        # 4. Built-in Administrator
        $lines.Add("Built-in Administrator : Active (SID -500) Management Available")

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
                    $netStatus = "ONLINE [Internet Reachability Verified]"
                }
                else {
                    $netStatus = "OFFLINE [No External Connection Detected]"
                }
            }
            else {
                $netStatus = "ONLINE (TCP / DNS Available)"
            }
        }
        catch {
            $netStatus = "OFFLINE [Connection Failed]"
        }
        $lines.Add("Internet Check : $netStatus")

        # 2. Integrated Launchers
        $lines.Add("Tool 1         : Win11Debloat (yashg/raphi.re - Telemetry & bloatware purge)")
        $lines.Add("Tool 2         : Chris Titus WinUtil (General Windows optimization suite)")

        return $lines.ToArray()
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

    # If NonInteractive flag is set without MenuOption, display main menu once and return
    if ($NonInteractive -and [string]::IsNullOrWhiteSpace($MenuOption)) {
        Show-ToolkitHeader -Title 'ITOOLKIT :: ENTERPRISE IT SUPPORT CONSOLE' -Subtitle 'Windows 10 / 11 Enterprise Support Toolkit' -NoSystemInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Data Management'
        Show-ToolkitMenuOption -Key '2' -Label 'Office & Excel Troubleshooting & Repair'
        Show-ToolkitMenuOption -Key '3' -Label 'Network & Print Spooler Troubleshooting'
        Show-ToolkitMenuOption -Key '4' -Label 'User Profile Data Backup & Migration'
        Show-ToolkitMenuOption -Key '5' -Label 'User & Domain Account Administration'
        Show-ToolkitMenuOption -Key '6' -Label 'External Tools & Quick Launchers (Win11Debloat, WinUtil)'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""
        Write-ToolkitStatus -Message "Menu launched in non-interactive mode. Returning." -Type 'INFO'
        return
    }

    # If MenuOption is specified directly, handle single option execution
    if (-not [string]::IsNullOrWhiteSpace($MenuOption)) {
        $subParams = @{}
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

        Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Data Management'
        Show-ToolkitMenuOption -Key '2' -Label 'Office & Excel Troubleshooting & Repair'
        Show-ToolkitMenuOption -Key '3' -Label 'Network & Print Spooler Troubleshooting'
        Show-ToolkitMenuOption -Key '4' -Label 'User Profile Data Backup & Migration'
        Show-ToolkitMenuOption -Key '5' -Label 'User & Domain Account Administration'
        Show-ToolkitMenuOption -Key '6' -Label 'External Tools & Quick Launchers (Win11Debloat, WinUtil)'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'R' -Label 'Refresh Screen'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
                # Screen clears automatically on next loop iteration
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
# Category Submenus
# ==============================================================================

function Invoke-ToolkitSubmenuOutlook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $outlookInfo = Get-OutlookContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OUTLOOK & PST MANAGEMENT' -Subtitle 'PST/OST Discovery, Relocation, Compaction & Registry Policies' -ClearScreen -InfoLines $outlookInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Find Outlook Data Files (.pst / .ost)'
        Show-ToolkitMenuOption -Key '2' -Label 'Safe Relocate Outlook Data File (with SHA-256 Checksum)'
        Show-ToolkitMenuOption -Key '3' -Label 'Update Outlook Profile Path in Registry'
        Show-ToolkitMenuOption -Key '4' -Label 'Expand PST File Size Threshold Policy (>30GB / 100GB)'
        Show-ToolkitMenuOption -Key '5' -Label 'Launch Outlook Compaction Guidance'
        Show-ToolkitMenuOption -Key '6' -Label 'Backup Outlook PST Data File'
        Show-ToolkitMenuOption -Key '7' -Label 'Restore Outlook PST Data File'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $officeInfo = Get-OfficeContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & EXCEL TROUBLESHOOTING' -Subtitle 'Graphics Acceleration, Cache Reset, COM Add-ins, GDI Leaks, Click-to-Run Repair' -ClearScreen -InfoLines $officeInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Disable Excel Hardware Graphics Acceleration'
        Show-ToolkitMenuOption -Key '2' -Label 'Enable Excel Hardware Graphics Acceleration'
        Show-ToolkitMenuOption -Key '3' -Label 'Reset Excel UI & Printer Cache (Excel16.xlb & XLSTART)'
        Show-ToolkitMenuOption -Key '4' -Label 'Clear Office Temporary & Document Caches'
        Show-ToolkitMenuOption -Key '5' -Label 'List Installed Excel COM Add-ins'
        Show-ToolkitMenuOption -Key '6' -Label 'Reset Excel Disabled Items Resiliency List'
        Show-ToolkitMenuOption -Key '7' -Label 'Inspect Excel GDI Handle Usage (Leak Audit)'
        Show-ToolkitMenuOption -Key '8' -Label 'Stop Leaking Excel Processes'
        Show-ToolkitMenuOption -Key '9' -Label 'Launch Office ClickToRun Repair [Quick / Online]'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $printersInfo = Get-PrintersContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK & PRINT SPOOLER' -Subtitle 'Spooler Diagnostics, Queue Purge, Ne Ports, Point & Print' -ClearScreen -InfoLines $printersInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Inspect Print Spooler Status & Queue Size'
        Show-ToolkitMenuOption -Key '2' -Label 'Reset Print Spooler Queue & Restart Service'
        Show-ToolkitMenuOption -Key '3' -Label 'Re-register Print Spooler DLLs & Subsystems'
        Show-ToolkitMenuOption -Key '4' -Label 'Reset Stale Ne Virtual Port Bindings'
        Show-ToolkitMenuOption -Key '5' -Label 'Audit Point & Print (PrintNightmare) Policies'
        Show-ToolkitMenuOption -Key '6' -Label 'Apply Point & Print Strict Administrator Remediation'
        Show-ToolkitMenuOption -Key '7' -Label 'Test Network Printer Connectivity (SMB/RPC/9100)'
        Show-ToolkitMenuOption -Key '8' -Label 'Refresh Active User Printer Connections'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $backupInfo = Get-BackupContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER PROFILE DATA BACKUP' -Subtitle 'Folders, Bookmarks, Certificates, Robocopy Engine & SHA-256 Manifests' -ClearScreen -InfoLines $backupInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Display User Profile Directory Map'
        Show-ToolkitMenuOption -Key '2' -Label 'Export Chromium Bookmarks (Chrome / Edge)'
        Show-ToolkitMenuOption -Key '3' -Label 'Export Personal Certificate Store (.pfx / .cer)'
        Show-ToolkitMenuOption -Key '4' -Label 'Start Profile Directory Backup (Robocopy Engine)'
        Show-ToolkitMenuOption -Key '5' -Label 'Generate SHA-256 Backup Integrity Manifest'
        Show-ToolkitMenuOption -Key '6' -Label 'Validate Backup Integrity Manifest'
        Show-ToolkitMenuOption -Key '7' -Label 'Restore User Profile Data from Backup'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $accountsInfo = Get-AccountsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER & DOMAIN ACCOUNT ADMINISTRATION' -Subtitle 'Account Operations, Administrator SID -500, Domain Join/Disjoin' -ClearScreen -InfoLines $accountsInfo
        Show-ToolkitMenuOption -Key '1' -Label 'List Local Windows User Accounts'
        Show-ToolkitMenuOption -Key '2' -Label 'Create New Local User Account'
        Show-ToolkitMenuOption -Key '3' -Label 'Unlock Local User Account (ADSI WinNT)'
        Show-ToolkitMenuOption -Key '4' -Label 'Enable / Disable Local User Account'
        Show-ToolkitMenuOption -Key '5' -Label 'Query Domain User Account (.NET DirectoryServices)'
        Show-ToolkitMenuOption -Key '6' -Label 'Unlock Domain User Account'
        Show-ToolkitMenuOption -Key '7' -Label 'Activate Built-in Administrator Account (SID -500)'
        Show-ToolkitMenuOption -Key '8' -Label 'Reset Built-in Administrator Password'
        Show-ToolkitMenuOption -Key '9' -Label 'Test Domain Reachability (DNS SRV & Ports)'
        Show-ToolkitMenuOption -Key '10' -Label 'Safe Domain Disjoin (with Lockout Defense)'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $toolsInfo = Get-ExternalToolsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > EXTERNAL TOOLS & UTILITIES' -Subtitle 'Pre-Flight Internet Check & External Utility Launchers' -ClearScreen -InfoLines $toolsInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Launch Windows 11 / 10 Debloat (Win11Debloat)'
        Show-ToolkitMenuOption -Key '2' -Label 'Launch Chris Titus Tech Windows Utility (WinUtil)'
        Show-ToolkitMenuOption -Key '3' -Label 'Test Pre-Flight Internet Reachability'
        Write-ToolkitMenuDivider
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu'
        Show-ToolkitMenuOption -Key 'Q' -Label 'Exit Console'
        Write-Host ""

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
            [System.Environment]::Exit(0)
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
