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

    function Get-MainSystemInfoLines {
        $lines = [System.Collections.Generic.List[string]]::new()

        # 1. OS & Build
        $osName = [System.Environment]::OSVersion.VersionString
        $osArch = [System.IntPtr]::Size * 8
        try {
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') {
                $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                if ($null -ne $reg -and -not [string]::IsNullOrWhiteSpace($reg.ProductName)) {
                    $osName = $reg.ProductName
                    if (-not [string]::IsNullOrWhiteSpace($reg.DisplayVersion)) {
                        $osName = "$osName $($reg.DisplayVersion)"
                    }
                    if (-not [string]::IsNullOrWhiteSpace($reg.CurrentBuildNumber)) {
                        $osName = "$osName (Build $($reg.CurrentBuildNumber))"
                    }
                }
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("OS & Build     : $osName | ${osArch}-bit Architecture")

        # 2. Hardware / CPU & RAM
        $cpuCount = [System.Environment]::ProcessorCount
        $cpuName = "$cpuCount Logical Processors"
        if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_IDENTIFIER)) {
            $cpuName = "$($env:PROCESSOR_IDENTIFIER) ($cpuCount Cores)"
        }
        $ramInfo = "Total RAM: Available"
        try {
            $gcMem = [System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes
            if ($gcMem -gt 0) {
                $totalGB = [math]::Round($gcMem / 1GB, 1)
                $ramInfo = "Total RAM: ${totalGB} GB"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Processor & RAM: $cpuName | $ramInfo")

        # 3. Storage
        $driveInfo = "Storage: System Drive"
        try {
            $d = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.Name -match '^[Cc]:' -or $_.RootDirectory.FullName -eq '/') } | Select-Object -First 1
            if ($null -ne $d) {
                $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                $totalGB = [math]::Round($d.TotalSize / 1GB, 1)
                $pctFree = [math]::Round(($d.AvailableFreeSpace / $d.TotalSize) * 100, 0)
                $driveInfo = "System Drive ($($d.Name)) ${freeGB} GB Free / ${totalGB} GB Total (${pctFree}% Free)"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Storage Space  : $driveInfo")

        # 4. Network & Domain
        $ipStr = "127.0.0.1"
        try {
            $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne '127.0.0.1' }
            if ($null -ne $ips) {
                $firstIp = $ips | Select-Object -First 1
                if ($null -ne $firstIp) {
                    $ipStr = $firstIp.ToString()
                }
            }
        }
        catch {
            $null = $_
        }
        $domain = "WORKGROUP"
        if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
            $domain = $env:USERDNSDOMAIN
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
            $domain = $env:USERDOMAIN
        }
        $lines.Add("Network Status : IPv4: $ipStr | Domain/Workgroup: $domain")

        # 5. Security & Elevation
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

        return $lines.ToArray()
    }

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
        $lines.Add("Graphics Accel : $accelStatus")

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
            $d = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.Name -match '^[Cc]:' -or $_.RootDirectory.FullName -eq '/') } | Select-Object -First 1
            if ($null -ne $d) {
                $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                $freeSpace = "System Drive ($($d.Name)) Free Space: ${freeGB} GB"
            }
        }
        catch {
            $null = $_
        }
        $lines.Add("Storage Target : $freeSpace")

        # 3. Backup Scope
        $lines.Add("Backup Scope   : Desktop, Documents, Downloads, Edge/Chrome Bookmarks, Certs")

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

        # 4. Built-in Admin
        $lines.Add("Built-in Admin : Administrator (SID -500) Management Available")

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
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
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
        Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Data Management' -Category 'OUTLOOK'
        Show-ToolkitMenuOption -Key '2' -Label 'Office & Excel Troubleshooting & Repair' -Category 'OFFICE '
        Show-ToolkitMenuOption -Key '3' -Label 'Network & Print Spooler Troubleshooting' -Category 'PRINTER'
        Show-ToolkitMenuOption -Key '4' -Label 'User Profile Data Backup & Migration' -Category 'BACKUP '
        Show-ToolkitMenuOption -Key '5' -Label 'User & Domain Account Administration' -Category 'ACCOUNT'
        Show-ToolkitMenuOption -Key '6' -Label 'External Tools & Quick Launchers (Win11Debloat, WinUtil)' -Category 'TOOLS  '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
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

        Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Data Management' -Category 'OUTLOOK'
        Show-ToolkitMenuOption -Key '2' -Label 'Office & Excel Troubleshooting & Repair' -Category 'OFFICE '
        Show-ToolkitMenuOption -Key '3' -Label 'Network & Print Spooler Troubleshooting' -Category 'PRINTER'
        Show-ToolkitMenuOption -Key '4' -Label 'User Profile Data Backup & Migration' -Category 'BACKUP '
        Show-ToolkitMenuOption -Key '5' -Label 'User & Domain Account Administration' -Category 'ACCOUNT'
        Show-ToolkitMenuOption -Key '6' -Label 'External Tools & Quick Launchers (Win11Debloat, WinUtil)' -Category 'TOOLS  '
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'R' -Label 'Refresh / Clear Screen' -Category 'SYSTEM '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        $choice = Read-ToolkitMenuChoice -Prompt 'Select Category' -ValidKeys @('1', '2', '3', '4', '5', '6', 'R', 'Q', 'X') -Default $DefaultSelection

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
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Outlook & PST Data Management'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', 'B', 'Q')
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
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & EXCEL TROUBLESHOOTING' -Subtitle 'Graphics Accel, Cache Reset, COM Add-ins, GDI Leaks, C2R Repair' -ClearScreen -InfoLines $officeInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Disable Excel Hardware Graphics Acceleration'
        Show-ToolkitMenuOption -Key '2' -Label 'Enable Excel Hardware Graphics Acceleration'
        Show-ToolkitMenuOption -Key '3' -Label 'Reset Excel UI & Printer Cache (Excel16.xlb & XLSTART)'
        Show-ToolkitMenuOption -Key '4' -Label 'Clear Office Temporary & Document Caches'
        Show-ToolkitMenuOption -Key '5' -Label 'List Installed Excel COM Add-ins'
        Show-ToolkitMenuOption -Key '6' -Label 'Reset Excel Disabled Items Resiliency List'
        Show-ToolkitMenuOption -Key '7' -Label 'Inspect Excel GDI Handle Usage (Leak Audit)'
        Show-ToolkitMenuOption -Key '8' -Label 'Stop Leaking Excel Processes'
        Show-ToolkitMenuOption -Key '9' -Label 'Launch Office ClickToRun Repair [Quick / Online]'
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Excel Troubleshooting & Repair'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'B', 'Q')
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
        Show-ToolkitMenuOption -Key '6' -Label 'Apply Point & Print Strict Admin Remediation'
        Show-ToolkitMenuOption -Key '7' -Label 'Test Network Printer Connectivity (SMB/RPC/9100)'
        Show-ToolkitMenuOption -Key '8' -Label 'Refresh Active User Printer Connections'
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Network & Print Spooler Troubleshooting'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', 'B', 'Q')
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
        Show-ToolkitHeader -Title 'ITOOLKIT > USER PROFILE DATA BACKUP' -Subtitle 'Folders, Bookmarks, Certs, Robocopy Engine & SHA-256 Manifests' -ClearScreen -InfoLines $backupInfo
        Show-ToolkitMenuOption -Key '1' -Label 'Display User Profile Directory Map'
        Show-ToolkitMenuOption -Key '2' -Label 'Export Chromium Bookmarks (Chrome / Edge)'
        Show-ToolkitMenuOption -Key '3' -Label 'Export Personal Certificate Store (.pfx / .cer)'
        Show-ToolkitMenuOption -Key '4' -Label 'Start Profile Directory Backup (Robocopy Engine)'
        Show-ToolkitMenuOption -Key '5' -Label 'Generate SHA-256 Backup Integrity Manifest'
        Show-ToolkitMenuOption -Key '6' -Label 'Validate Backup Integrity Manifest'
        Show-ToolkitMenuOption -Key '7' -Label 'Restore User Profile Data from Backup'
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'User Profile Data Backup & Migration'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', 'B', 'Q')
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
        Show-ToolkitHeader -Title 'ITOOLKIT > USER & DOMAIN ACCOUNT ADMIN' -Subtitle 'Local/Domain CRUD, Admin SID -500, Domain Join/Disjoin' -ClearScreen -InfoLines $accountsInfo
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
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'User & Domain Account Administration'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'B', 'Q')
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
        Write-Host "  ----------------------------------------------------------------------------" -ForegroundColor DarkGray
        Show-ToolkitMenuOption -Key 'B' -Label 'Back to Main Menu' -Category 'NAV    '
        Show-ToolkitMenuOption -Key 'Q' -Label 'Quit / Exit Console' -Category 'SYSTEM '
        Write-Host ""

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'External Tools & Quick Launchers'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '3', 'B', 'Q')
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
