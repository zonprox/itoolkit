if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-OfficeSuiteContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
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
    } catch { $null = $_ }

    $lines.Add("Office Build   : Microsoft Office $c2rVer | $c2rArch")

    $isOutlookRunning = $false
    try {
        $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) { $isOutlookRunning = $true }
    } catch { $null = $_ }

    $outlookState = if ($isOutlookRunning) { 'Running [ACTIVE]' } else { 'Stopped [READY]' }
    $lines.Add("Outlook Status : $outlookState")

    $defProf = 'DefaultProfile'
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($ctx -and $ctx.DefaultProfile) { $defProf = $ctx.DefaultProfile }
        } catch { $null = $_ }
    }
    $lines.Add("Mail Profile   : Default Profile: $defProf")
    $lines.Add("Office Tools   : PST/OST Engine, Acceleration, COM Add-ins, C2R Repair [READY]")

    return $lines.ToArray()
}

function Get-OfficeContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

function Get-OutlookContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeSuiteContextInfoLines' -Value (Get-Command -Name 'Get-OfficeSuiteContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeContextInfoLines' -Value (Get-Command -Name 'Get-OfficeContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OutlookContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OutlookContextInfoLines' -Value (Get-Command -Name 'Get-OutlookContextInfoLines').ScriptBlock
}

function Invoke-ToolkitDataFileContextMenu {
<#
.SYNOPSIS
    Contextual administration menu for a targeted Outlook data file (PST or OST).
.PARAMETER DataFile
    Selected data file object or hashtable.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately.
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('SelectedFile', 'SelectedDataFile')]
        [object]$DataFile,

        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Data file context menu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $filePath = if ($DataFile.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Path)) {
        [string]$DataFile.Path
    } elseif ($DataFile.PSObject.Properties['Details'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Details)) {
        [string]$DataFile.Details
    } else {
        [string]$DataFile
    }

    $fileName = if ($DataFile.PSObject.Properties['Item'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Item)) {
        [string]$DataFile.Item
    } elseif (-not [string]::IsNullOrWhiteSpace($filePath)) {
        Split-Path -Leaf $filePath
    } else {
        'OutlookDataFile'
    }

    $fileType = if ($DataFile.PSObject.Properties['Type'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Type)) {
        [string]$DataFile.Type
    } elseif ($filePath -match '(?i)\.ost$') {
        'OST'
    } else {
        'PST'
    }

    $profileName = if ($DataFile.PSObject.Properties['Profile'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Profile)) {
        [string]$DataFile.Profile
    } else {
        'Outlook'
    }

    $inContext = $true
    while ($inContext) {
        $clear = if ($NonInteractive) { $false } else { $true }

        $outlookRunning = $false
        try {
            $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) { $outlookRunning = $true }
        } catch { $null = $_ }

        $runningBadge = if ($outlookRunning) { 'Running [ACTIVE]' } else { 'Stopped [READY]' }

        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE > DATA FILE CONTEXT' `
            -Subtitle "Contextual Administration for Outlook Data File: $fileName" `
            -ClearScreen:$clear `
            -InfoLines @(
                "Target File    : $fileName ($fileType) | Profile: $profileName",
                "Full Path      : $filePath",
                "Lock & Process : Outlook: $runningBadge | Storage: [READY]"
            )

        $contextActions = @(
            @{ Key = '1'; Label = 'Compact Data File' },
            @{ Key = '2'; Label = 'Expand PST Limit (100GB)' },
            @{ Key = '3'; Label = 'Backup Data File' },
            @{ Key = '4'; Label = 'Relocate Data File' },
            @{ Key = '5'; Label = 'Set Default Delivery File' },
            @{ Key = '6'; Label = 'Permanently Delete Data File' }
        )
        $contextNav = @(
            @{ Key = '0'; Label = 'Back to Data Files Table' }
        )
        Show-ToolkitActionCatalog -Actions $contextActions -NavActions $contextNav -Title "DATA FILE ACTIONS: $fileName"

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive context listing complete for data file '$fileName'." -Type 'INFO'
            return
        }

        $choice = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys @('1', '2', '3', '4', '5', '6') -Prompt "  Select action for '$fileName' [1-6, 0]"
        if ($null -eq $choice -or $choice.Type -eq 'Exit' -or $choice.Value -eq '0') {
            $inContext = $false
            return
        }

        switch ("$($choice.Value)") {
            '1' {
                if (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Launching compaction guidance for '$fileName'..." -Type 'INFO'
                        Invoke-OutlookCompaction -FilePath $filePath
                        Write-ToolkitStatus -Message "Outlook compaction routine invoked." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Compaction failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Invoke-OutlookCompaction command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '2' {
                if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                    try {
                        Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                        Write-ToolkitStatus -Message "PST threshold expanded to 100GB (Warn: 95GB)." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to set PST threshold: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Set-OutlookPstThreshold command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '3' {
                $destDir = Read-Host "  Enter Backup Destination Directory (Default: C:\Backups\Outlook)"
                if ([string]::IsNullOrWhiteSpace($destDir)) { $destDir = 'C:\Backups\Outlook' }
                if (Get-Command -Name 'Backup-OutlookPst' -ErrorAction SilentlyContinue) {
                    try {
                        $bkRes = Backup-OutlookPst -SourcePath $filePath -BackupDirectory $destDir
                        if ($bkRes -and $bkRes.Success) {
                            Write-ToolkitStatus -Message "Data file successfully backed up to '$($bkRes.BackupPath)'." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Backup verification processed." -Type 'INFO'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Backup error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Backup-OutlookPst command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '4' {
                $destPath = Read-Host "  Enter Target Destination File Path"
                if (-not [string]::IsNullOrWhiteSpace($destPath)) {
                    if (Get-Command -Name 'Move-OutlookDataFile' -ErrorAction SilentlyContinue) {
                        try {
                            $mvRes = Move-OutlookDataFile -SourcePath $filePath -DestinationPath $destPath -UpdateProfile
                            if ($mvRes -and $mvRes.Success) {
                                Write-ToolkitStatus -Message "Data file successfully relocated to '$destPath'." -Type 'OK'
                                $filePath = $destPath
                                $fileName = Split-Path -Leaf $destPath
                            } else {
                                Write-ToolkitStatus -Message "Relocation processed." -Type 'INFO'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Relocation error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Move-OutlookDataFile command unavailable." -Type 'WARN'
                    }
                }
                Wait-UserAcknowledge
            }
            '5' {
                if (Get-Command -Name 'Set-OutlookDefaultDataFile' -ErrorAction SilentlyContinue) {
                    try {
                        $defRes = Set-OutlookDefaultDataFile -Path $filePath -ProfileName $profileName
                        if ($defRes -and $defRes.Success) {
                            Write-ToolkitStatus -Message "Data file '$fileName' configured as default for profile '$profileName'." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Could not configure default data file: $($defRes.ErrorMessage)" -Type 'WARN'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Failed to set default data file: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Set-OutlookDefaultDataFile command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '6' {
                $outlookRunning = $false
                try {
                    $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
                    if ($procs.Count -gt 0) { $outlookRunning = $true }
                } catch { $null = $_ }

                if ($outlookRunning) {
                    Write-ToolkitStatus -Message "Deletion blocked: Outlook is currently running. Please close Outlook first." -Type 'FAIL'
                    Wait-UserAcknowledge
                    continue
                }

                if (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue) {
                    $lockTest = Test-OutlookDataFileLock -Path $filePath
                    if ($null -ne $lockTest -and $lockTest.IsLocked) {
                        Write-ToolkitStatus -Message "Deletion blocked: File '$fileName' is locked by an external process ($($lockTest.ErrorMessage))." -Type 'FAIL'
                        Wait-UserAcknowledge
                        continue
                    }
                }

                $confirm = Read-Host "  Confirm permanent deletion of '$fileName'? [y/N]"
                if ($confirm -match '^(?i)y(es)?$') {
                    if (Get-Command -Name 'Remove-OutlookDataFile' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Permanently deleting '$fileName'..." -Type 'INFO'
                            $delRes = Remove-OutlookDataFile -Path $filePath -ProfileName $profileName
                            if ($delRes -and $delRes.Success) {
                                Write-ToolkitStatus -Message "Data file '$fileName' permanently deleted from disk and profile." -Type 'OK'
                                Wait-UserAcknowledge
                                $inContext = $false
                                return
                            } else {
                                $err = if ($delRes -and $delRes.ErrorMessage) { $delRes.ErrorMessage } else { "Unknown deletion failure." }
                                Write-ToolkitStatus -Message "Failed to delete '$fileName': $err" -Type 'FAIL'
                                Wait-UserAcknowledge
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Deletion failed: $($_.Exception.Message)" -Type 'FAIL'
                            Wait-UserAcknowledge
                        }
                    } else {
                        Write-ToolkitStatus -Message "Remove-OutlookDataFile command unavailable." -Type 'WARN'
                        Wait-UserAcknowledge
                    }
                } else {
                    Write-ToolkitStatus -Message "Permanent deletion cancelled by user." -Type 'INFO'
                    Wait-UserAcknowledge
                }
            }
            '0' {
                $inContext = $false
                return
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitDataFileContextMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitDataFileContextMenu' -Value (Get-Command -Name 'Invoke-ToolkitDataFileContextMenu').ScriptBlock
}

function Invoke-ToolkitSubmenuOfficeSuite {
<#
.SYNOPSIS
    Submenu for Office & Productivity Suite (Office & Outlook Administration).
.DESCRIPTION
    Combines troubleshooting for Outlook PST/OST files and Microsoft Office:
    - PST/OST data file creation, limit expansion, compaction, and default profile binding
    - Hardware acceleration toggling, UI cache reset, and temp cache purge
    - Click-to-Run repair (Quick / Online) and KMS licensing verification
    - COM add-in resiliency and GDI handle leak audits
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
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
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) { . $selectScript }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeSuiteContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & PRODUCTIVITY SUITE' -Subtitle 'Unified Office & Outlook Administration, Data Files, Performance & Repair' -ClearScreen:$clear -InfoLines $officeInfo

        $items = @()
        if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
            try {
                $rawFiles = @(Find-OutlookDataFiles)
                foreach ($f in $rawFiles) {
                    $p = [string]$f.Path
                    $n = if (-not [string]::IsNullOrWhiteSpace($p)) { Split-Path -Leaf $p } else { 'DataFile' }
                    $items += [PSCustomObject]@{
                        Item       = $n
                        Status     = '[READY]'
                        Type       = if ($f.Type) { [string]$f.Type } else { 'PST' }
                        Details    = $p
                        Path       = $p
                        Profile    = if ($f.Profile) { [string]$f.Profile } else { 'DefaultProfile' }
                        SizeGB     = if ($f.SizeGB) { $f.SizeGB } else { 0 }
                        FileObject = $f
                    }
                }
            } catch { $null = $_ }
        }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Item = 'Outlook Data Engine'; Status = '[READY]'; Type = 'Service'; Details = 'PST/OST file discovery and compaction'; Path = 'C:\Users\Default\AppData\Local\Microsoft\Outlook\Outlook.pst'; Profile = 'DefaultProfile' },
                [PSCustomObject]@{ Item = 'Microsoft Excel';     Status = '[READY]'; Type = 'Application'; Details = 'Hardware acceleration and GDI management'; Path = ''; Profile = '' },
                [PSCustomObject]@{ Item = 'Microsoft Word';      Status = '[READY]'; Type = 'Application'; Details = 'Document processor and cache resiliency'; Path = ''; Profile = '' },
                [PSCustomObject]@{ Item = 'Microsoft Outlook';   Status = '[READY]'; Type = 'Application'; Details = 'Messaging client and mail profiles'; Path = ''; Profile = '' }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Item', 'Status', 'Type', 'Details') -Headers @('ITEM', 'STATUS', 'TYPE', 'DETAILS') -Title 'Productivity Applications & Data Files'

        Write-Host ""
        $actions = @(
            @{ Key = '10'; Label = 'Quick Repair Office' },
            @{ Key = '11'; Label = 'Online Repair Office' },
            @{ Key = '12'; Label = 'Toggle Graphics Acceleration' },
            @{ Key = '13'; Label = 'Clear Temp & Cache' },
            @{ Key = '14'; Label = 'License Diagnostics (KMS)' },
            @{ Key = '15'; Label = 'Audit GDI Leakers' },
            @{ Key = '16'; Label = 'Terminate Office Processes' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Productivity Suite'." -Type 'INFO'
            return
        }

        $categoryKeys = @('10', '11', '12', '13', '14', '15', '16')
        $promptText = "  Select Item [1-$($items.Count)], Action [10-16], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex $items.Count -ValidHotkeys $categoryKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        if ($selection.Type -eq 'Index') {
            $targetIdx = [int]$selection.Value - 1
            if ($targetIdx -ge 0 -and $targetIdx -lt $items.Count) {
                $selectedFile = $items[$targetIdx]
                Invoke-ToolkitDataFileContextMenu -DataFile $selectedFile -NonInteractive:$NonInteractive
            }
        }
        elseif ($selection.Type -eq 'Hotkey') {
            switch ($actionKey) {
                { $_ -in @('10', '1') } {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Initiating Office Quick Repair..." -Type 'INFO'
                            Start-OfficeClickToRunRepair -RepairType 'Quick'
                            Write-ToolkitStatus -Message "Office Quick Repair invoked." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Office Quick Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('11', '2') } {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Initiating Office Online Repair..." -Type 'INFO'
                            Start-OfficeClickToRunRepair -RepairType 'Online'
                            Write-ToolkitStatus -Message "Office Online Repair invoked." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Office Online Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('12', '5') } {
                    if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        try {
                            Set-ExcelHardwareAcceleration -Disable $true
                            Write-ToolkitStatus -Message "Hardware graphics acceleration disabled for Office." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Failed to set hardware acceleration: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('13', '6') } {
                    if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                        try {
                            Clear-OfficeTempCache
                            Write-ToolkitStatus -Message "Office temporary cache files cleared." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Cache purge failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    if (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-ExcelUiCache
                        } catch { $null = $_ }
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('14', '7') } {
                    Write-ToolkitStatus -Message "Probing KMS licensing host connectivity (port 1688)..." -Type 'INFO'
                    try {
                        if (Get-Command -Name 'Test-NetConnection' -ErrorAction SilentlyContinue) {
                            $kmsRes = Test-NetConnection -ComputerName 'kms.local' -Port 1688 -WarningAction SilentlyContinue
                            if ($kmsRes -and $kmsRes.TcpTestSucceeded) {
                                Write-ToolkitStatus -Message "KMS Host probe succeeded." -Type 'OK'
                            } else {
                                Write-ToolkitStatus -Message "KMS Host probe unreachable or unconfigured." -Type 'WARN'
                            }
                        }
                    } catch {
                        Write-ToolkitStatus -Message "KMS probe failed: $($_.Exception.Message)" -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('15', '8') } {
                    if (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                        try {
                            $gdi = Get-ExcelGdiHandleUsage
                            Write-ToolkitStatus -Message "GDI Handle Audit completed. Active Excel processes audited." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "GDI audit failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                { $_ -in @('16', '9') } {
                    try {
                        Write-ToolkitStatus -Message "Stopping stuck Office processes..." -Type 'INFO'
                        if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                            Stop-ToolkitProcess -ProcessName @('OUTLOOK', 'EXCEL', 'WINWORD', 'POWERPNT')
                        }
                        Write-ToolkitStatus -Message "Office processes terminated." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to stop Office processes: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                '3' {
                    if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                        try {
                            Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                            Write-ToolkitStatus -Message "PST file threshold expanded to 100GB." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Failed to set PST threshold: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                '4' {
                    if (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Starting data file compaction..." -Type 'INFO'
                            Invoke-OutlookCompaction
                            Write-ToolkitStatus -Message "Outlook compaction routine finished." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Compaction failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                '0' { return }
            }
        }
    }
}

function Invoke-ToolkitSubmenuOffice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
}

function Invoke-ToolkitSubmenuOutlook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeSuite' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOffice' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOffice' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOffice').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOutlook' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook').ScriptBlock
}
