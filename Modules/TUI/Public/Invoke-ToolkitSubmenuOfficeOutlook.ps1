<#
.SYNOPSIS
    Dedicated interactive submenu for Microsoft Outlook repairs, diagnostics,
    PST/OST contextual data file administration, and profile management.
.DESCRIPTION
    Provides an item-centric console interface displaying discovered Outlook data files
    (PST and OST) in a selectable table [1..N], routing selected files to
    Invoke-ToolkitDataFileContextMenu. Exposes category fixes for stuck Outbox messages,
    Send/Receive settings (.srs), RoamCache stream purges, Navigation Pane resets,
    compaction routines, file size threshold tests, and process termination.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders inventory table and action catalog once, then returns cleanly.
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

# 1. Defensive Loader for TUI and Subsystem Dependencies
if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path -LiteralPath $waitScript) { . $waitScript }
}
if (-not (Get-Command -Name 'Show-ToolkitHeader' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path -LiteralPath $headerScript) { . $headerScript }
}
if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
    $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
    if (Test-Path -LiteralPath $catScript) { . $catScript }
}
if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
    $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
    if (Test-Path -LiteralPath $tableScript) { . $tableScript }
}
if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
    $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
    if (Test-Path -LiteralPath $selectScript) { . $selectScript }
}
if (-not (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue)) {
    $statusScript = Join-Path $PSScriptRoot 'Write-ToolkitStatus.ps1'
    if (Test-Path -LiteralPath $statusScript) { . $statusScript }
}

# 2. Context Information Helper: Get-OutlookContextInfoLines
function Get-OutlookContextInfoLines {
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

    $lines.Add("Outlook Version : Microsoft Outlook $c2rVer ($c2rArch)")

    $isOutlookRunning = $false
    try {
        $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) { $isOutlookRunning = $true }
    } catch { $null = $_ }

    $outlookState = if ($isOutlookRunning) { 'Running [ACTIVE]' } else { 'Stopped [READY]' }
    $lines.Add("Process Status  : Outlook $outlookState")

    $defProf = 'Outlook'
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($ctx -and $ctx.DefaultProfile -and $ctx.DefaultProfile -ne 'None') {
                $defProf = $ctx.DefaultProfile
            }
        } catch { $null = $_ }
    }
    $lines.Add("Active Profile  : $defProf")
    $lines.Add("Outlook Repairs : Stuck Outbox, SRS Reset, RoamCache Purge, NavPane Reset, Compaction [READY]")

    return $lines.ToArray()
}

# 3. Data File Inventory Discovery Helper: Get-OutlookDataFileInventory
function Get-OutlookDataFileInventory {
<#
.SYNOPSIS
    Discovers Outlook PST and OST data files and formats structured inventory records.
.DESCRIPTION
    Queries Find-OutlookDataFiles across user profile and registry scopes,
    mapping output attributes into standardized Filename, Size, Format, and Status fields.
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Scope = 'All',

        [Parameter(Mandatory = $false)]
        [string]$ProfileName
    )

    $inventory = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
        try {
            $rawFiles = @(Find-OutlookDataFiles -Scope $Scope -ProfileName $ProfileName)
            foreach ($f in $rawFiles) {
                $p = if ($f.Path) { [string]$f.Path } elseif ($f.FullName) { [string]$f.FullName } else { '' }
                $fn = if ($f.Filename) { [string]$f.Filename } elseif ($f.Item) { [string]$f.Item } elseif (-not [string]::IsNullOrWhiteSpace($p)) { Split-Path -Leaf $p } else { 'OutlookDataFile' }
                $fmt = if ($f.Format) { [string]$f.Format } elseif ($f.Type) { [string]$f.Type } elseif ($p -match '(?i)\.ost$') { 'OST' } else { 'PST' }

                $sizeStr = if ($f.Size) {
                    [string]$f.Size
                } elseif ($f.SizeGB -and $f.SizeGB -gt 0) {
                    "$([Math]::Round([double]$f.SizeGB, 2)) GB"
                } elseif ($f.SizeBytes -and $f.SizeBytes -gt 0) {
                    "$([Math]::Round([double]$f.SizeBytes / 1MB, 2)) MB"
                } else {
                    "0.00 MB"
                }

                $statusStr = if ($f.Status) {
                    [string]$f.Status
                } elseif ($f.IsLocked) {
                    '[LOCKED]'
                } else {
                    '[READY]'
                }

                $prof = if ($f.Profile) { [string]$f.Profile } else { 'DefaultProfile' }

                $inventory.Add([PSCustomObject]@{
                    Filename   = $fn
                    Size       = $sizeStr
                    Format     = $fmt
                    Status     = $statusStr
                    Path       = $p
                    Profile    = $prof
                    Item       = $fn
                    Type       = $fmt
                    Details    = $p
                    SizeGB     = if ($f.SizeGB) { $f.SizeGB } else { 0 }
                    FileObject = $f
                })
            }
        } catch {
            Write-Verbose "Get-OutlookDataFileInventory discovery notice: $($_.Exception.Message)"
        }
    }

    return $inventory.ToArray()
}

# 4. Contextual Data File Administration Menu: Invoke-ToolkitDataFileContextMenu
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

    $filePath = if ($DataFile -is [string]) {
        $DataFile
    } elseif ($DataFile.PSObject.Properties['Path']) {
        [string]$DataFile.Path
    } elseif ($DataFile.PSObject.Properties['FilePath']) {
        [string]$DataFile.FilePath
    } elseif ($DataFile.PSObject.Properties['FullName']) {
        [string]$DataFile.FullName
    } elseif ($DataFile.PSObject.Properties['Details']) {
        [string]$DataFile.Details
    } else {
        [string]$DataFile
    }
    if (-not [string]::IsNullOrWhiteSpace($filePath)) {
        $filePath = $filePath.Trim().Trim('"').Trim("'")
    }

    $fileName = if ($DataFile.PSObject.Properties['Item'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Item)) {
        [string]$DataFile.Item
    } elseif ($DataFile.PSObject.Properties['Filename'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Filename)) {
        [string]$DataFile.Filename
    } elseif (-not [string]::IsNullOrWhiteSpace($filePath)) {
        Split-Path -Leaf $filePath
    } else {
        'OutlookDataFile'
    }

    $fileType = if ($DataFile.PSObject.Properties['Type'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Type)) {
        [string]$DataFile.Type
    } elseif ($DataFile.PSObject.Properties['Format'] -and -not [string]::IsNullOrWhiteSpace($DataFile.Format)) {
        [string]$DataFile.Format
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
                $destDir = if ($NonInteractive) { 'C:\Backups\Outlook' } else { Read-Host "  Enter Backup Destination Directory (Default: C:\Backups\Outlook)" }
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
                $destPath = if ($NonInteractive) { Join-Path (Split-Path -Parent $filePath) ("Moved_" + $fileName) } else { Read-Host "  Enter Target Destination File Path" }
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
                if ([string]::IsNullOrWhiteSpace($filePath)) {
                    Write-ToolkitStatus -Message "Invalid or empty data file path." -Type 'FAIL'
                    Wait-UserAcknowledge
                    continue
                }

                if ($filePath -match '[\*\?]') {
                    Write-ToolkitStatus -Message "Data file path cannot contain wildcard characters: '$filePath'." -Type 'FAIL'
                    Wait-UserAcknowledge
                    continue
                }

                if ([System.IO.Directory]::Exists($filePath) -or ((Test-Path -LiteralPath $filePath -PathType Container) -and -not (Test-Path -LiteralPath $filePath -PathType Leaf))) {
                    Write-ToolkitStatus -Message "Specified path is a directory, not an Outlook data file: '$filePath'." -Type 'FAIL'
                    Wait-UserAcknowledge
                    continue
                }

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

                $confirmAccepted = if ($NonInteractive) { $true } else { (Read-Host "  Confirm permanent deletion of '$fileName'? [y/N]") -match '^(?i)y(es)?$' }
                if ($confirmAccepted) {
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

# 5. Primary Outlook Submenu: Invoke-ToolkitSubmenuOfficeOutlook
function Invoke-ToolkitSubmenuOfficeOutlook {
<#
.SYNOPSIS
    Submenu for Microsoft Outlook repairs, data files, and profile troubleshooting.
.DESCRIPTION
    Renders selectable Outlook PST and OST data files [1..N], contextual actions,
    and operational category fixes [10..16] with pure numeric navigation [0] Back.
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

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $outlookInfo = Get-OutlookContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE > OUTLOOK & DATA FILES' `
            -Subtitle 'Dedicated Outlook Diagnostics, PST/OST Data Management & Profile Repairs' `
            -ClearScreen:$clear `
            -InfoLines $outlookInfo

        # Discover data files via Get-OutlookDataFileInventory
        $items = @()
        try {
            $rawInventory = @(Get-OutlookDataFileInventory)
            foreach ($item in $rawInventory) {
                $items += $item
            }
        } catch { $null = $_ }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{
                    Filename   = 'Outlook.pst'
                    Size       = '0.00 MB'
                    Format     = 'PST'
                    Status     = '[READY]'
                    Path       = 'C:\Users\Default\AppData\Local\Microsoft\Outlook\Outlook.pst'
                    Profile    = 'DefaultProfile'
                    Item       = 'Outlook.pst'
                    Type       = 'PST'
                    Details    = 'C:\Users\Default\AppData\Local\Microsoft\Outlook\Outlook.pst'
                    SizeGB     = 0
                    FileObject = $null
                }
            )
        }

        # Format and display selectable data files table [1..N] without -NoIndex
        Show-ToolkitItemTable -Items $items `
            -Columns @('Filename', 'Size', 'Format', 'Status') `
            -Headers @('FILENAME', 'SIZE', 'FORMAT', 'STATUS') `
            -Title 'Discovered Outlook PST / OST Data Files'

        Write-Host ""
        $actions = @(
            @{ Key = '10'; Label = 'Clear Stuck Outbox Messages' },
            @{ Key = '11'; Label = 'Reset Send/Receive Settings SRS' },
            @{ Key = '12'; Label = 'Clear RoamCache Streams' },
            @{ Key = '13'; Label = 'Reset Navigation Pane Configuration' },
            @{ Key = '14'; Label = 'Compact Outlook Data Files' },
            @{ Key = '15'; Label = 'Test Data File Size Thresholds' },
            @{ Key = '16'; Label = 'Terminate Outlook Processes' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Office Hub' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'OUTLOOK OPERATIONAL FIXES & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Microsoft Outlook & Data Files'." -Type 'INFO'
            return
        }

        $categoryKeys = @('10', '11', '12', '13', '14', '15', '16')
        $promptText = "  Select Item [1-$($items.Count)], Action [10-16], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex $items.Count -ValidHotkeys $categoryKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        if ($selection.Type -eq 'Index') {
            $targetIdx = [int]$selection.Value - 1
            if ($targetIdx -ge 0 -and $targetIdx -lt $items.Count) {
                $selectedFile = $items[$targetIdx]
                Invoke-ToolkitDataFileContextMenu -DataFile $selectedFile -NonInteractive:$NonInteractive
            }
        }
        elseif ($selection.Type -eq 'Hotkey') {
            $actionKey = "$($selection.Value)"

            switch ($actionKey) {
                '10' {
                    if (Get-Command -Name 'Clear-OutlookStuckOutbox' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Clearing stuck Outbox messages..." -Type 'INFO'
                            $res = Clear-OutlookStuckOutbox
                            if ($res -and $res.Status -eq 'Success') {
                                Write-ToolkitStatus -Message "Outbox cleared successfully ($($res.ClearedMessages) message(s) purged)." -Type 'OK'
                            } elseif ($res -and $res.Status -eq 'Warning') {
                                Write-ToolkitStatus -Message "Outbox notice: $($res.ErrorMessage)" -Type 'WARN'
                            } else {
                                $err = if ($res -and $res.ErrorMessage) { $res.ErrorMessage } else { "Failed to clear Outbox." }
                                Write-ToolkitStatus -Message "Outbox error: $err" -Type 'FAIL'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Failed to clear Outbox: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Clear-OutlookStuckOutbox command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '11' {
                    if (Get-Command -Name 'Reset-OutlookSendReceiveSettings' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Resetting Send/Receive settings (.srs)..." -Type 'INFO'
                            $res = Reset-OutlookSendReceiveSettings -Backup
                            if ($res -and $res.Status -eq 'Success') {
                                $bkMsg = if ($res.BackupFile) { " (Backup: $($res.BackupFile))" } else { "" }
                                Write-ToolkitStatus -Message "Send/Receive settings reset successfully$bkMsg." -Type 'OK'
                            } elseif ($res -and $res.Status -eq 'Warning') {
                                Write-ToolkitStatus -Message "Send/Receive settings notice: $($res.ErrorMessage)" -Type 'WARN'
                            } else {
                                Write-ToolkitStatus -Message "Send/Receive reset failed: $($res.ErrorMessage)" -Type 'FAIL'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Failed to reset Send/Receive settings: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-OutlookSendReceiveSettings command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '12' {
                    if (Get-Command -Name 'Clear-OutlookRoamCache' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Purging RoamCache stream cache (preserving AutoComplete)..." -Type 'INFO'
                            $res = Clear-OutlookRoamCache -PreserveAutocomplete
                            if ($res -and $res.Status -eq 'Success') {
                                Write-ToolkitStatus -Message "RoamCache cleared: $($res.PurgedCount) stream(s) purged, $($res.PreservedCount) AutoComplete file(s) preserved." -Type 'OK'
                            } elseif ($res -and $res.Status -eq 'Warning') {
                                Write-ToolkitStatus -Message "RoamCache notice: $($res.ErrorMessage)" -Type 'WARN'
                            } else {
                                Write-ToolkitStatus -Message "RoamCache purge failed: $($res.ErrorMessage)" -Type 'FAIL'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Failed to purge RoamCache: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Clear-OutlookRoamCache command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '13' {
                    if (Get-Command -Name 'Reset-OutlookNavigationPane' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Resetting Outlook navigation pane configuration (/resetnavpane)..." -Type 'INFO'
                            $res = Reset-OutlookNavigationPane
                            if ($res -and $res.Status -eq 'Success') {
                                Write-ToolkitStatus -Message "Navigation pane reset successfully across registry and XML profiles." -Type 'OK'
                            } elseif ($res -and $res.Status -eq 'Warning') {
                                Write-ToolkitStatus -Message "Navigation pane notice: $($res.ErrorMessage)" -Type 'WARN'
                            } else {
                                Write-ToolkitStatus -Message "Navigation pane reset failed: $($res.ErrorMessage)" -Type 'FAIL'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Failed to reset navigation pane: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-OutlookNavigationPane command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '14' {
                    if (Get-Command -Name 'Invoke-OutlookPstCompaction' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Launching Outlook data file compaction routine..." -Type 'INFO'
                            Invoke-OutlookPstCompaction
                            Write-ToolkitStatus -Message "Outlook compaction routine invoked." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Compaction failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } elseif (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Launching Outlook data file compaction routine..." -Type 'INFO'
                            Invoke-OutlookCompaction
                            Write-ToolkitStatus -Message "Outlook compaction routine invoked." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Compaction failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Invoke-OutlookPstCompaction command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '15' {
                    if (Get-Command -Name 'Test-OutlookDataFileSize' -ErrorAction SilentlyContinue) {
                        try {
                            $validPaths = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) })
                            if ($validPaths.Count -gt 0) {
                                foreach ($vf in $validPaths) {
                                    $eval = Test-OutlookDataFileSize -FilePath $vf.Path
                                    $typeTag = if ($eval.Status -eq 'Critical') { 'FAIL' } elseif ($eval.Status -eq 'Warning') { 'WARN' } else { 'OK' }
                                    Write-ToolkitStatus -Message "$($vf.Filename): $($eval.SizeGB) GB / $($eval.MaxThresholdGB) GB limit ($($eval.PercentOfMax)%) - Status: $($eval.Status)" -Type $typeTag
                                }
                            } elseif (-not $NonInteractive) {
                                $targetPath = Read-Host "  Enter path to PST/OST file to test"
                                if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                                    $eval = Test-OutlookDataFileSize -FilePath $targetPath
                                    $typeTag = if ($eval.Status -eq 'Critical') { 'FAIL' } elseif ($eval.Status -eq 'Warning') { 'WARN' } else { 'OK' }
                                    Write-ToolkitStatus -Message "$($targetPath): $($eval.SizeGB) GB / $($eval.MaxThresholdGB) GB limit ($($eval.PercentOfMax)%) - Status: $($eval.Status)" -Type $typeTag
                                } else {
                                    Write-ToolkitStatus -Message "No data file path provided." -Type 'WARN'
                                }
                            } else {
                                Write-ToolkitStatus -Message "No data files found to test." -Type 'WARN'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Threshold evaluation error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Test-OutlookDataFileSize command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '16' {
                    if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Terminating Outlook processes..." -Type 'INFO'
                            $stopRes = Stop-OfficeProcess -ProcessNames @('OUTLOOK') -Force
                            if ($stopRes -and $stopRes.Terminated) {
                                Write-ToolkitStatus -Message "Outlook processes terminated: $($stopRes.Terminated -join ', ')." -Type 'OK'
                            } else {
                                Write-ToolkitStatus -Message "No active Outlook processes found." -Type 'INFO'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Failed to terminate Outlook: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Terminating Outlook processes..." -Type 'INFO'
                            $null = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5 -Force
                            Write-ToolkitStatus -Message "Outlook process termination requested." -Type 'OK'
                        } catch {
                            Write-ToolkitStatus -Message "Failed to terminate Outlook: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Stop-OfficeProcess command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '0' {
                    return
                }
            }
        }
    }
}

# 6. Backward-Compatibility Delegate: Invoke-ToolkitSubmenuOutlook
function Invoke-ToolkitSubmenuOutlook {
<#
.SYNOPSIS
    Backward-compatible entry point for Outlook Submenu.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeOutlook @PSBoundParameters
}

# 7. Global Session Scope Exports
if (Get-Command -Name 'Get-OutlookContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OutlookContextInfoLines' -Value (Get-Command -Name 'Get-OutlookContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OutlookDataFileInventory' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OutlookDataFileInventory' -Value (Get-Command -Name 'Get-OutlookDataFileInventory').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitDataFileContextMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitDataFileContextMenu' -Value (Get-Command -Name 'Invoke-ToolkitDataFileContextMenu').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeOutlook' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOutlook' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook').ScriptBlock
}
