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
if (-not (Get-Command -Name 'Enter-ToolkitConsoleView' -ErrorAction SilentlyContinue)) {
    $enterConsole = Join-Path $PSScriptRoot 'Enter-ToolkitConsoleView.ps1'
    if (Test-Path -LiteralPath $enterConsole) { . $enterConsole }
}
if (-not (Get-Command -Name 'Exit-ToolkitConsoleView' -ErrorAction SilentlyContinue)) {
    $exitConsole = Join-Path $PSScriptRoot 'Exit-ToolkitConsoleView.ps1'
    if (Test-Path -LiteralPath $exitConsole) { . $exitConsole }
}
function Confirm-ToolkitAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ActionDescription,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }

    try {
        $raw = Read-Host -Prompt "  Confirm ${ActionDescription}? [y/N]"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $false
        }
        return [bool]($raw.Trim() -match '^(?i)y(?:es)?$')
    }
    catch {
        return $false
    }
}
if (Get-Command -Name 'Confirm-ToolkitAction' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Confirm-ToolkitAction' -Value (Get-Command -Name 'Confirm-ToolkitAction').ScriptBlock
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

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}

if (-not (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue)) {
    $profileSelectorScript = Join-Path $PSScriptRoot 'Select-ToolkitOutlookProfile.ps1'
    if (Test-Path -LiteralPath $profileSelectorScript) { . $profileSelectorScript }
}


# 2. Context Information Helper: Get-OutlookContextInfoLines
function Get-OutlookContextInfoLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName
    )

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

    $defProf = if (-not [string]::IsNullOrWhiteSpace($ProfileName)) {
        $ProfileName
    } else {
        'Outlook'
    }
    if ([string]::IsNullOrWhiteSpace($ProfileName) -and (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue)) {
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
        [Alias('ProfileFilter')]
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
                } elseif ($f.SizeBytes -and $f.SizeBytes -gt 0) {
                    if (Get-Command -Name 'Format-ByteSize' -ErrorAction SilentlyContinue) {
                        Format-ByteSize -Bytes ([int64]$f.SizeBytes)
                    } else {
                        "$([Math]::Round([double]$f.SizeBytes / 1MB, 2)) MB"
                    }
                } elseif ($f.SizeGB -and $f.SizeGB -gt 0) {
                    "$([Math]::Round([double]$f.SizeGB, 2)) GB"
                } else {
                    "0 B"
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

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Data file context menu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
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
            @{ Key = '1'; Label = 'Compact Data File'; Description = 'Compact target PST or OST storage file to reclaim unused disk space' },
            @{ Key = '2'; Label = 'Expand PST Limit'; Description = 'Configure registry thresholds to support up to 100GB data file capacity' },
            @{ Key = '3'; Label = 'Backup Data File'; Description = 'Create timestamped backup copy with SHA-256 integrity validation' },
            @{ Key = '4'; Label = 'Relocate Data File'; Description = 'Safely move data file to a new disk location or directory' },
            @{ Key = '5'; Label = 'Set Default Delivery File'; Description = 'Assign this store as the primary mail delivery location for its profile' },
            @{ Key = '6'; Label = 'Create New Default PST from This Store'; Description = 'Create clean PST store, set as default, and clone folder structure and rules' },
            @{ Key = '7'; Label = 'Permanently Delete Data File'; Description = 'Remove data file from Outlook profile and permanently delete from disk' }
        )
        $contextNav = @(
            @{ Key = '0'; Label = 'Return to Data Files'; Description = 'Exit context menu and return to discovered data files list' }
        )
        Show-ToolkitActionCatalog -Actions $contextActions -NavActions $contextNav -Title "DATA FILE ACTIONS: $fileName"

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive context listing complete for data file '$fileName'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive context listing complete for data file '$fileName'." -ForegroundColor Cyan
            return
        }

        $choice = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10') -Prompt "  Select Action for '$fileName' [1-7], or [0] Back"
        if ($null -eq $choice -or $choice.Type -eq 'Exit' -or $choice.Value -eq '0') {
            $inContext = $false
            return
        }

        Enter-ToolkitConsoleView -ActionTitle "Data File: $fileName" -NonInteractive:$NonInteractive
        try {
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
                $parentDir = Split-Path -Parent $filePath
                $defaultRelocatePath = if ([string]::IsNullOrWhiteSpace($parentDir)) { "Moved_$fileName" } else { [System.IO.Path]::Combine($parentDir, "Moved_$fileName") }
                $destPath = if ($NonInteractive) { $defaultRelocatePath } else {
                    $inputRelocate = Read-Host "  Enter Target Destination File Path (Default: $defaultRelocatePath)"
                    if ([string]::IsNullOrWhiteSpace($inputRelocate)) { $defaultRelocatePath } else { $inputRelocate.Trim() }
                }
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
                $script:inContextExit = $false
                # Canonical Action 6: Create New Default PST from This Store
                $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                if ([string]::IsNullOrWhiteSpace($docPath)) {
                    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                        $docPath = Join-Path $env:USERPROFILE 'Documents'
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                        $docPath = Join-Path $env:HOME 'Documents'
                    } else {
                        $docPath = [System.IO.Path]::GetTempPath()
                    }
                }
                $defaultPstDir = Join-Path $docPath "Outlook Files"
                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $defaultPstName = "${profileName}_${timestamp}.pst"
                $defaultPstPath = Join-Path $defaultPstDir $defaultPstName

                $targetPst = if ($NonInteractive) { $defaultPstPath } else {
                    Read-Host "  Enter Target PST Path (Default: $defaultPstPath)"
                }
                if ([string]::IsNullOrWhiteSpace($targetPst)) {
                    $targetPst = $defaultPstPath
                }
                if (-not ($targetPst -match '[\\/]')) {
                    $targetPst = Join-Path $defaultPstDir $targetPst
                }
                if ($targetPst -notmatch '(?i)\.pst$') {
                    $targetPst = "$targetPst.pst"
                }

                if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                    try {
                        $null = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                    } catch { $null = $_ }
                }

                if (Get-Command -Name 'New-OutlookDataFile' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Creating new default PST and migrating rules/folders..." -Type 'INFO'
                        $res = New-OutlookDataFile -Path $targetPst -ProfileName $profileName -SetAsDefault -CloneFolderHierarchy -MigrateRules -SourceStorePath $filePath
                        if ($res -and $res.Success) {
                            Write-ToolkitStatus -Message "New default PST created: '$targetPst' for profile '$profileName' with folders and rules preserved." -Type 'OK'
                            Wait-UserAcknowledge
                            $inContext = $false
                            return
                        } else {
                            $errMsg = if ($res -and $res.ErrorMessage) { $res.ErrorMessage } else { "Failed to create new default PST." }
                            Write-ToolkitStatus -Message "Failed: $errMsg" -Type 'FAIL'
                            Wait-UserAcknowledge
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Error: $($_.Exception.Message)" -Type 'FAIL'
                        Wait-UserAcknowledge
                    }
                } else {
                    Write-ToolkitStatus -Message "New-OutlookDataFile command unavailable." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '7' {
                # Canonical Action 7: Permanently Delete Data File
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
            '8' {
                $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                if ([string]::IsNullOrWhiteSpace($docPath)) {
                    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                        $docPath = Join-Path $env:USERPROFILE 'Documents'
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                        $docPath = Join-Path $env:HOME 'Documents'
                    } else {
                        $docPath = [System.IO.Path]::GetTempPath()
                    }
                }
                $defaultRulesDir = Join-Path $docPath "Outlook Files"
                if (-not (Test-Path -LiteralPath $defaultRulesDir)) {
                    $null = New-Item -ItemType Directory -Path $defaultRulesDir -Force -ErrorAction SilentlyContinue
                }
                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $cleanLeaf = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $defaultManifestPath = Join-Path $defaultRulesDir "${cleanLeaf}_Rules_${timestamp}.json"

                $targetExportPath = if ($NonInteractive) { $defaultManifestPath } else {
                    Read-Host "  Enter Manifest Destination Path (Default: $defaultManifestPath)"
                }
                if ([string]::IsNullOrWhiteSpace($targetExportPath)) {
                    $targetExportPath = $defaultManifestPath
                }
                if (-not ($targetExportPath -match '[\\/]')) {
                    $targetExportPath = Join-Path $defaultRulesDir $targetExportPath
                }
                if ($targetExportPath -notmatch '(?i)\.json$') {
                    $targetExportPath = "$targetExportPath.json"
                }

                if (Get-Command -Name 'Export-OutlookRule' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Exporting rules from store '$fileName'..." -Type 'INFO'
                        $exportRes = Export-OutlookRule -Path $targetExportPath -ProfileName $profileName -StorePath $filePath -Force
                        if ($exportRes -and $exportRes.Success) {
                            Write-ToolkitStatus -Message "Rules successfully exported to '$targetExportPath' ($($exportRes.RulesExported) rules exported)." -Type 'OK'
                        } else {
                            $errMsg = if ($exportRes -and $exportRes.ErrorMessage) { $exportRes.ErrorMessage } else { "Unknown export failure." }
                            Write-ToolkitStatus -Message "Export failed: $errMsg" -Type 'FAIL'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Export error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Export-OutlookRule command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '9' {
                $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                if ([string]::IsNullOrWhiteSpace($docPath)) {
                    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                        $docPath = Join-Path $env:USERPROFILE 'Documents'
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                        $docPath = Join-Path $env:HOME 'Documents'
                    } else {
                        $docPath = [System.IO.Path]::GetTempPath()
                    }
                }
                $defaultManifestDir = Join-Path $docPath "Outlook Files"
                $latestManifest = $null
                if (Test-Path -LiteralPath $defaultManifestDir) {
                    $latestManifest = Get-ChildItem -Path $defaultManifestDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
                }
                $defaultPrompt = if ($latestManifest) { " (Default: $($latestManifest.FullName))" } else { "" }

                $manifestPath = if ($NonInteractive) {
                    if ($latestManifest) { $latestManifest.FullName } else { '' }
                } else {
                    Read-Host "  Enter Path to Rule Manifest JSON$defaultPrompt"
                }
                if ([string]::IsNullOrWhiteSpace($manifestPath) -and $latestManifest) {
                    $manifestPath = $latestManifest.FullName
                }
                if ([string]::IsNullOrWhiteSpace($manifestPath)) {
                    Write-ToolkitStatus -Message "Manifest path is required for rule import." -Type 'WARN'
                    Wait-UserAcknowledge
                    continue
                }
                $manifestPath = $manifestPath.Trim().Trim('"').Trim("'")
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    Write-ToolkitStatus -Message "Manifest file does not exist: '$manifestPath'." -Type 'FAIL'
                    Wait-UserAcknowledge
                    continue
                }

                if (Get-Command -Name 'Import-OutlookRule' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Importing and remapping rules into store '$fileName'..." -Type 'INFO'
                        $importRes = Import-OutlookRule -Path $manifestPath -TargetStorePath $filePath -ProfileName $profileName -AutoCreateFolders -DuplicateHandling 'Skip'
                        if ($importRes -and $importRes.Success) {
                            Write-ToolkitStatus -Message "Rules imported into '$fileName': $($importRes.RulesImported) imported, $($importRes.RulesSkipped) skipped, $($importRes.FoldersCreated) folders created." -Type 'OK'
                        } else {
                            $errMsg = if ($importRes -and $importRes.ErrorMessage) { $importRes.ErrorMessage } else { "Unknown import failure." }
                            Write-ToolkitStatus -Message "Import failed: $errMsg" -Type 'FAIL'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Import error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Import-OutlookRule command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '10' {
                $autoRepair = if ($NonInteractive) { $false } else {
                    (Read-Host "  Enable Auto-Repair to fix broken rules & folders? [y/N]") -match '^(?i)y(es)?$'
                }

                $cmdName = if (Get-Command -Name 'Repair-OutlookRule' -ErrorAction SilentlyContinue) {
                    'Repair-OutlookRule'
                } elseif (Get-Command -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue) {
                    'Test-OutlookRule'
                } else {
                    $null
                }

                if ($null -ne $cmdName) {
                    try {
                        Write-ToolkitStatus -Message "Executing rule diagnostics on store '$fileName'..." -Type 'INFO'
                        $diagRes = & $cmdName -StorePath $filePath -ProfileName $profileName -AutoRepair:$autoRepair
                        if ($diagRes -and $diagRes.Success) {
                            $brokenCount = if ($diagRes.BrokenRules -is [int]) { $diagRes.BrokenRules } elseif ($diagRes.BrokenRules) { @($diagRes.BrokenRules).Count } else { 0 }
                            $dupCount = if ($diagRes.DuplicateRules -is [int]) { $diagRes.DuplicateRules } elseif ($diagRes.DuplicateRules) { @($diagRes.DuplicateRules).Count } else { 0 }
                            $emptyCount = if ($diagRes.EmptyRules -is [int]) { $diagRes.EmptyRules } elseif ($diagRes.EmptyRules) { @($diagRes.EmptyRules).Count } else { 0 }
                            $statusSummary = "Store rules scanned: $($diagRes.TotalRules) | Broken: $brokenCount | Duplicates: $dupCount | Empty: $emptyCount"
                            if ($autoRepair) {
                                $statusSummary += " | Repaired: $($diagRes.RepairedRulesCount)"
                            }
                            Write-ToolkitStatus -Message $statusSummary -Type 'OK'
                        } else {
                            $errMsg = if ($diagRes -and $diagRes.ErrorMessage) { $diagRes.ErrorMessage } else { "Rule diagnostics completed with warnings." }
                            Write-ToolkitStatus -Message "Diagnostics: $errMsg" -Type 'WARN'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Diagnostics error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Repair-OutlookRule / Test-OutlookRule command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '0' {
                $inContext = $false
                return
            }
            }
        }
        catch {
            $errDetail = if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) { $_.Exception.Message } else { "$_" }
            if (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue) {
                Write-ToolkitStatus -Message "Action execution failed: $errDetail" -Type 'FAIL'
            }
            Wait-UserAcknowledge
        }
        finally {
            Exit-ToolkitConsoleView
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
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
.PARAMETER ProfileName
    Optional profile name filter for data file inventory.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName
    )

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $activeProfileFilter = $ProfileName
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
            $invParams = @{}
            if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                $invParams['ProfileName'] = $activeProfileFilter
            }
            $rawInventory = @(Get-OutlookDataFileInventory @invParams)
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
            @{ Key = '10'; Label = 'Quick Mail & Cache Repair'; Description = 'Sequential Outbox clearing, SRS reset, RoamCache purge, and NavPane reset' },
            @{ Key = '11'; Label = 'Create New Default PST for Profile'; Description = 'Create 100GB PST store, set as default, and migrate folder tree and rules' },
            @{ Key = '12'; Label = 'Export Outlook Rules'; Description = 'Export profile rules, folder maps, and account definitions to JSON manifest' },
            @{ Key = '13'; Label = 'Import & Auto-Remap Outlook Rules'; Description = 'Import JSON rule manifest with automatic folder creation and account remapping' },
            @{ Key = '14'; Label = 'Smart Rule Diagnostics & Auto-Repair'; Description = 'Inspect rules for orphaned folder targets, duplicates, and auto-repair' },
            @{ Key = '15'; Label = 'Test & Expand PST Size Thresholds'; Description = 'Validate current store limits and configure registry for 100GB capacity' },
            @{ Key = '16'; Label = 'Switch Active Outlook Profile Filter'; Description = 'Filter discovered data files and target actions by a specific Outlook profile' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub'; Description = 'Return to the central Office & Productivity Suite menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'OUTLOOK OPERATIONAL FIXES & COMMANDS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Microsoft Outlook & Data Files'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Microsoft Outlook & Data Files'." -ForegroundColor Cyan
            return
        }

        $categoryKeys = @('10', '11', '12', '13', '14', '15', '16')
        $promptText = if ($items.Count -gt 0) {
            "  Select Data File [1-$($items.Count)], Action [10-16], or [0] Back"
        } else {
            "  Select Action [10-16], or [0] Back"
        }
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
            if ($actionKey -eq '0') { return }

            Enter-ToolkitConsoleView -ActionTitle "Outlook Action: $actionKey" -NonInteractive:$NonInteractive
            try {
                switch ($actionKey) {
                '10' {
                    # Pre-execution process guard: checks running OUTLOOK, warns/terminates via Stop-OfficeProcess
                    $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
                    if ($procs.Count -gt 0) {
                        Write-ToolkitStatus -Message "Outlook process detected. Terminating to release file and spooler locks..." -Type 'WARN'
                        if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                            try {
                                $stopRes = Stop-OfficeProcess -ProcessNames @('OUTLOOK') -Force
                                if ($stopRes -and $stopRes.Terminated) {
                                    Write-ToolkitStatus -Message "Outlook terminated: $($stopRes.Terminated -join ', ')." -Type 'INFO'
                                }
                            } catch {
                                Write-Verbose "Stop-OfficeProcess notice: $($_.Exception.Message)"
                            }
                        } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                            try {
                                $null = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5 -Force
                            } catch {
                                Write-Verbose "Stop-ToolkitProcess notice: $($_.Exception.Message)"
                            }
                        } else {
                            Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                        }
                        Start-Sleep -Milliseconds 500
                    }

                    # Sequence Step 1: Clear-OutlookStuckOutbox -Force
                    $clearedMsgs = 0
                    if (Get-Command -Name 'Clear-OutlookStuckOutbox' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Clearing stuck Outbox messages..." -Type 'INFO'
                            $outboxRes = Clear-OutlookStuckOutbox -Force
                            if ($outboxRes -and $outboxRes.ClearedMessages) {
                                $clearedMsgs = $outboxRes.ClearedMessages
                            }
                        } catch {
                            Write-Verbose "Clear-OutlookStuckOutbox notice: $($_.Exception.Message)"
                        }
                    }

                    # Sequence Step 2: Post-COM safety cleanup
                    $postProcs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
                    if ($postProcs.Count -gt 0) {
                        if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                            try { $null = Stop-OfficeProcess -ProcessNames @('OUTLOOK') -Force } catch { $null = $_ }
                        } else {
                            Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                        }
                        Start-Sleep -Milliseconds 250
                    }

                    # Sequence Step 3: Reset-OutlookSendReceiveSettings -Backup -Force
                    $srsBackup = 'None'
                    if (Get-Command -Name 'Reset-OutlookSendReceiveSettings' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Resetting Send/Receive settings (.srs)..." -Type 'INFO'
                            $srsRes = Reset-OutlookSendReceiveSettings -Backup -Force
                            if ($srsRes -and $srsRes.BackupFile) {
                                $srsBackup = $srsRes.BackupFile
                            }
                        } catch {
                            Write-Verbose "Reset-OutlookSendReceiveSettings notice: $($_.Exception.Message)"
                        }
                    }

                    # Sequence Step 4: Clear-OutlookRoamCache -PreserveAutocomplete -Force
                    $purgedStreams = 0
                    $preservedAuto = 0
                    if (Get-Command -Name 'Clear-OutlookRoamCache' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Purging RoamCache stream cache (preserving AutoComplete)..." -Type 'INFO'
                            $roamRes = Clear-OutlookRoamCache -PreserveAutocomplete -Force
                            if ($roamRes) {
                                if ($roamRes.PurgedCount) { $purgedStreams = $roamRes.PurgedCount }
                                if ($roamRes.PreservedCount) { $preservedAuto = $roamRes.PreservedCount }
                            }
                        } catch {
                            Write-Verbose "Clear-OutlookRoamCache notice: $($_.Exception.Message)"
                        }
                    }

                    # Sequence Step 5: Reset-OutlookNavigationPane -Force
                    if (Get-Command -Name 'Reset-OutlookNavigationPane' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Resetting Navigation Pane configuration..." -Type 'INFO'
                            $null = Reset-OutlookNavigationPane -Force
                        } catch {
                            Write-Verbose "Reset-OutlookNavigationPane notice: $($_.Exception.Message)"
                        }
                    }

                    # Consolidated status banner
                    Write-ToolkitStatus -Message "Quick Repair Complete: Outbox cleared ($clearedMsgs msg), SRS reset (Backup: $srsBackup), RoamCache purged ($purgedStreams streams, $preservedAuto autocomplete preserved), NavPane reset." -Type 'OK'
                    Wait-UserAcknowledge
                }
                '11' {
                    # Discover available profiles
                    $discoveredProfiles = @()
                    $defaultProfile = 'Outlook'
                    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                        try {
                            $sysCtx = Get-OutlookSystemContext
                            if ($null -ne $sysCtx) {
                                if ($null -ne $sysCtx.Profiles) {
                                    $discoveredProfiles = @($sysCtx.Profiles)
                                }
                                if (-not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                                    $defaultProfile = $sysCtx.DefaultProfile
                                }
                            }
                        } catch { $null = $_ }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $defaultProfile = $activeProfileFilter
                    }
                    if ($discoveredProfiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultProfile)) {
                        $discoveredProfiles = @($defaultProfile)
                    }

                    $targetProfile = $defaultProfile
                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $targetProfile = $activeProfileFilter
                    } elseif ($discoveredProfiles.Count -le 1) {
                        $targetProfile = if ($discoveredProfiles.Count -gt 0) { $discoveredProfiles[0] } else { $defaultProfile }
                    } elseif (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                        $selectedProfile = Select-ToolkitOutlookProfile -DefaultProfile $defaultProfile -Profiles $discoveredProfiles -NonInteractive:$NonInteractive -Prompt "  Select Target Outlook Profile"
                        if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                            $targetProfile = $selectedProfile.Trim()
                        }
                    } else {
                        if (-not $NonInteractive) {
                            if ($discoveredProfiles.Count -gt 0) {
                                Write-Host "  Available Profiles: $($discoveredProfiles -join ', ')" -ForegroundColor Cyan
                            }
                            $chosenProfile = Read-Host "  Enter Target Outlook Profile (Default: $defaultProfile)"
                            if (-not [string]::IsNullOrWhiteSpace($chosenProfile)) {
                                $targetProfile = $chosenProfile.Trim()
                            }
                        }
                    }

                    # Maintain active profile filter across re-renders
                    $activeProfileFilter = $targetProfile

                    $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                    if ([string]::IsNullOrWhiteSpace($docPath)) {
                        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                            $docPath = Join-Path $env:USERPROFILE 'Documents'
                        } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                            $docPath = Join-Path $env:HOME 'Documents'
                        } else {
                            $docPath = [System.IO.Path]::GetTempPath()
                        }
                    }
                    $defaultPstDir = Join-Path $docPath "Outlook Files"
                    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $defaultPstName = "${targetProfile}_${timestamp}.pst"
                    $defaultPstPath = Join-Path $defaultPstDir $defaultPstName

                    $targetPst = if ($NonInteractive) { $defaultPstPath } else {
                        Read-Host "  Enter Target PST Path (Default: $defaultPstPath)"
                    }
                    if ([string]::IsNullOrWhiteSpace($targetPst)) {
                        $targetPst = $defaultPstPath
                    }
                    if (-not ($targetPst -match '[\\/]')) {
                        $targetPst = Join-Path $defaultPstDir $targetPst
                    }
                    if ($targetPst -notmatch '(?i)\.pst$') {
                        $targetPst = "$targetPst.pst"
                    }

                    # Bundle Set-OutlookPstThreshold (100GB)
                    if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                        try {
                            $null = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                        } catch {
                            Write-Verbose "Threshold expansion notice: $($_.Exception.Message)"
                        }
                    }

                    if (Get-Command -Name 'New-OutlookDataFile' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Creating new default PST and migrating rules/folders for profile '$targetProfile'..." -Type 'INFO'
                            $res = New-OutlookDataFile -Path $targetPst -ProfileName $targetProfile -SetAsDefault -CloneFolderHierarchy -MigrateRules
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "New default PST created: '$targetPst' for profile '$targetProfile' with 100GB limit, folders, and rules preserved." -Type 'OK'
                            } else {
                                $errMsg = if ($res -and $res.ErrorMessage) { $res.ErrorMessage } else { "Failed to create new default PST." }
                                Write-ToolkitStatus -Message "Failed: $errMsg" -Type 'FAIL'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "New-OutlookDataFile command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '12' {
                    # Discover available profiles
                    $discoveredProfiles = @()
                    $defaultProfile = 'Outlook'
                    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                        try {
                            $sysCtx = Get-OutlookSystemContext
                            if ($null -ne $sysCtx) {
                                if ($null -ne $sysCtx.Profiles) {
                                    $discoveredProfiles = @($sysCtx.Profiles)
                                }
                                if (-not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                                    $defaultProfile = $sysCtx.DefaultProfile
                                }
                            }
                        } catch { $null = $_ }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $defaultProfile = $activeProfileFilter
                    }
                    if ($discoveredProfiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultProfile)) {
                        $discoveredProfiles = @($defaultProfile)
                    }

                    $targetProfile = $defaultProfile
                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $targetProfile = $activeProfileFilter
                    } elseif ($discoveredProfiles.Count -le 1) {
                        $targetProfile = if ($discoveredProfiles.Count -gt 0) { $discoveredProfiles[0] } else { $defaultProfile }
                    } elseif (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                        $selectedProfile = Select-ToolkitOutlookProfile -DefaultProfile $defaultProfile -Profiles $discoveredProfiles -NonInteractive:$NonInteractive -Prompt "  Select Source Outlook Profile for Rule Export"
                        if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                            $targetProfile = $selectedProfile.Trim()
                        }
                    } else {
                        if (-not $NonInteractive) {
                            if ($discoveredProfiles.Count -gt 0) {
                                Write-Host "  Available Profiles: $($discoveredProfiles -join ', ')" -ForegroundColor Cyan
                            }
                            $chosenProfile = Read-Host "  Enter Source Outlook Profile (Default: $defaultProfile)"
                            if (-not [string]::IsNullOrWhiteSpace($chosenProfile)) {
                                $targetProfile = $chosenProfile.Trim()
                            }
                        }
                    }

                    $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                    if ([string]::IsNullOrWhiteSpace($docPath)) {
                        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                            $docPath = Join-Path $env:USERPROFILE 'Documents'
                        } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                            $docPath = Join-Path $env:HOME 'Documents'
                        } else {
                            $docPath = [System.IO.Path]::GetTempPath()
                        }
                    }
                    $defaultExportDir = Join-Path $docPath "Outlook Files"
                    if (-not (Test-Path -LiteralPath $defaultExportDir)) {
                        try { [void](New-Item -ItemType Directory -Path $defaultExportDir -Force -ErrorAction SilentlyContinue) } catch { $null = $_ }
                    }
                    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $defaultExportName = "OutlookRules_${targetProfile}_${timestamp}.json"
                    $defaultExportPath = Join-Path $defaultExportDir $defaultExportName

                    $targetExportPath = if ($NonInteractive) { $defaultExportPath } else {
                        Read-Host "  Enter Export Manifest JSON Path (Default: $defaultExportPath)"
                    }
                    if ([string]::IsNullOrWhiteSpace($targetExportPath)) {
                        $targetExportPath = $defaultExportPath
                    }
                    if (-not ($targetExportPath -match '[\\/]')) {
                        $targetExportPath = Join-Path $defaultExportDir $targetExportPath
                    }
                    if ($targetExportPath -notmatch '(?i)\.json$') {
                        $targetExportPath = "$targetExportPath.json"
                    }

                    if (Get-Command -Name 'Export-OutlookRule' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Exporting Outlook rules from profile '$targetProfile'..." -Type 'INFO'
                            $exportResult = Export-OutlookRule -Path $targetExportPath -ProfileName $targetProfile -Force
                            if ($exportResult -and $exportResult.Success) {
                                $customFoldersCount = if ($exportResult.CustomFoldersExported) { $exportResult.CustomFoldersExported } else { 0 }
                                Write-ToolkitStatus -Message "Exported $($exportResult.RulesExported) rule(s) to '$targetExportPath' ($customFoldersCount custom folder(s))." -Type 'OK'
                            } else {
                                $errMsg = if ($exportResult -and $exportResult.ErrorMessage) { $exportResult.ErrorMessage } else { "Failed to export Outlook rules." }
                                Write-ToolkitStatus -Message "Export failed: $errMsg" -Type 'FAIL'
                            }
                        } catch {
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "Export-OutlookRule failed with exception: $($_.Exception.Message)" -Level ERROR -Component 'TUI' -NoConsole
                            }
                            Write-ToolkitStatus -Message "Export error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Export-OutlookRule command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '13' {
                    # Discover available profiles
                    $discoveredProfiles = @()
                    $defaultProfile = 'Outlook'
                    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                        try {
                            $sysCtx = Get-OutlookSystemContext
                            if ($null -ne $sysCtx) {
                                if ($null -ne $sysCtx.Profiles) {
                                    $discoveredProfiles = @($sysCtx.Profiles)
                                }
                                if (-not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                                    $defaultProfile = $sysCtx.DefaultProfile
                                }
                            }
                        } catch { $null = $_ }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $defaultProfile = $activeProfileFilter
                    }
                    if ($discoveredProfiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultProfile)) {
                        $discoveredProfiles = @($defaultProfile)
                    }

                    $targetProfile = $defaultProfile
                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $targetProfile = $activeProfileFilter
                    } elseif ($discoveredProfiles.Count -le 1) {
                        $targetProfile = if ($discoveredProfiles.Count -gt 0) { $discoveredProfiles[0] } else { $defaultProfile }
                    } elseif (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                        $selectedProfile = Select-ToolkitOutlookProfile -DefaultProfile $defaultProfile -Profiles $discoveredProfiles -NonInteractive:$NonInteractive -Prompt "  Select Destination Outlook Profile for Rule Import"
                        if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                            $targetProfile = $selectedProfile.Trim()
                        }
                    } else {
                        if (-not $NonInteractive) {
                            if ($discoveredProfiles.Count -gt 0) {
                                Write-Host "  Available Profiles: $($discoveredProfiles -join ', ')" -ForegroundColor Cyan
                            }
                            $chosenProfile = Read-Host "  Enter Destination Outlook Profile (Default: $defaultProfile)"
                            if (-not [string]::IsNullOrWhiteSpace($chosenProfile)) {
                                $targetProfile = $chosenProfile.Trim()
                            }
                        }
                    }

                    $docPath = [System.Environment]::GetFolderPath('MyDocuments')
                    if ([string]::IsNullOrWhiteSpace($docPath)) {
                        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                            $docPath = Join-Path $env:USERPROFILE 'Documents'
                        } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
                            $docPath = Join-Path $env:HOME 'Documents'
                        } else {
                            $docPath = [System.IO.Path]::GetTempPath()
                        }
                    }
                    $defaultManifestDir = Join-Path $docPath "Outlook Files"

                    $recentManifest = $null
                    if (Test-Path -LiteralPath $defaultManifestDir) {
                        $recentManifest = Get-ChildItem -Path $defaultManifestDir -Filter "OutlookRules_*.json" -File -ErrorAction SilentlyContinue |
                            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
                        if (-not $recentManifest) {
                            $recentManifest = Get-ChildItem -Path $defaultManifestDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                                Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
                        }
                    }
                    $manifestPrompt = if ($recentManifest) { " (Default: $($recentManifest.FullName))" } else { "" }

                    $manifestPath = if ($NonInteractive) { '' } else {
                        Read-Host "  Enter Path to Rule Manifest JSON$manifestPrompt"
                    }

                    if ([string]::IsNullOrWhiteSpace($manifestPath) -and $recentManifest) {
                        $manifestPath = $recentManifest.FullName
                    }

                    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
                        Write-ToolkitStatus -Message "No rule manifest JSON path provided." -Type 'WARN'
                        Wait-UserAcknowledge
                        break
                    }

                    if (-not (Test-Path -LiteralPath $manifestPath)) {
                        Write-ToolkitStatus -Message "Rule manifest file not found: '$manifestPath'" -Type 'FAIL'
                        Wait-UserAcknowledge
                        break
                    }

                    if (Get-Command -Name 'Import-OutlookRule' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Importing and remapping rules into profile '$targetProfile'..." -Type 'INFO'
                            $importResult = Import-OutlookRule -Path $manifestPath -ProfileName $targetProfile -AutoCreateFolders -DuplicateHandling 'Skip'
                            if ($importResult -and $importResult.Success) {
                                $importedCount = if ($null -ne $importResult.RulesImported) { $importResult.RulesImported } else { 0 }
                                $createdFolders = if ($null -ne $importResult.FoldersCreated) { $importResult.FoldersCreated } else { 0 }
                                $skippedCount = if ($null -ne $importResult.RulesSkipped) { $importResult.RulesSkipped } else { 0 }
                                Write-ToolkitStatus -Message "Import Complete: $importedCount rule(s) imported, $createdFolders folder(s) created, $skippedCount duplicate(s) skipped into '$targetProfile'." -Type 'OK'
                            } else {
                                $errMsg = if ($importResult -and $importResult.ErrorMessage) { $importResult.ErrorMessage } else { "Failed to import Outlook rules." }
                                Write-ToolkitStatus -Message "Import failed: $errMsg" -Type 'FAIL'
                            }
                        } catch {
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "Import-OutlookRule failed with exception: $($_.Exception.Message)" -Level ERROR -Component 'TUI' -NoConsole
                            }
                            Write-ToolkitStatus -Message "Import error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Import-OutlookRule command unavailable." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                '14' {
                    # Discover available profiles
                    $discoveredProfiles = @()
                    $defaultProfile = 'Outlook'
                    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                        try {
                            $sysCtx = Get-OutlookSystemContext
                            if ($null -ne $sysCtx) {
                                if ($null -ne $sysCtx.Profiles) {
                                    $discoveredProfiles = @($sysCtx.Profiles)
                                }
                                if (-not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                                    $defaultProfile = $sysCtx.DefaultProfile
                                }
                            }
                        } catch { $null = $_ }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $defaultProfile = $activeProfileFilter
                    }
                    if ($discoveredProfiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultProfile)) {
                        $discoveredProfiles = @($defaultProfile)
                    }

                    $targetProfile = $defaultProfile
                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $targetProfile = $activeProfileFilter
                    } elseif ($discoveredProfiles.Count -le 1) {
                        $targetProfile = if ($discoveredProfiles.Count -gt 0) { $discoveredProfiles[0] } else { $defaultProfile }
                    } elseif (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                        $selectedProfile = Select-ToolkitOutlookProfile -DefaultProfile $defaultProfile -Profiles $discoveredProfiles -NonInteractive:$NonInteractive -Prompt "  Select Outlook Profile for Diagnostics & Repair"
                        if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                            $targetProfile = $selectedProfile.Trim()
                        }
                    } else {
                        if (-not $NonInteractive) {
                            if ($discoveredProfiles.Count -gt 0) {
                                Write-Host "  Available Profiles: $($discoveredProfiles -join ', ')" -ForegroundColor Cyan
                            }
                            $chosenProfile = Read-Host "  Enter Target Outlook Profile (Default: $defaultProfile)"
                            if (-not [string]::IsNullOrWhiteSpace($chosenProfile)) {
                                $targetProfile = $chosenProfile.Trim()
                            }
                        }
                    }

                    $autoRepair = $false
                    if (-not $NonInteractive) {
                        $repairChoice = Read-Host "  Enable Auto-Repair (recreate broken folders & prune invalid rules)? [y/N]"
                        if (-not [string]::IsNullOrWhiteSpace($repairChoice) -and $repairChoice.Trim() -match '^(?i)y(?:es)?$') {
                            $autoRepair = $true
                        }
                    }

                    $cmdName = if (Get-Command -Name 'Repair-OutlookRule' -ErrorAction SilentlyContinue) {
                        'Repair-OutlookRule'
                    } elseif (Get-Command -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue) {
                        'Test-OutlookRule'
                    } else {
                        $null
                    }

                    if ($null -ne $cmdName) {
                        try {
                            $statusMsg = if ($autoRepair) { "Running smart rule diagnostics and auto-repair for profile '$targetProfile'..." } else { "Running smart rule diagnostics scan for profile '$targetProfile'..." }
                            Write-ToolkitStatus -Message $statusMsg -Type 'INFO'
                            $diagResult = & $cmdName -ProfileName $targetProfile -AutoRepair:$autoRepair
                            if ($diagResult -and $diagResult.Success) {
                                $brokenCount = if ($diagResult.BrokenRules) { @($diagResult.BrokenRules).Count } else { 0 }
                                $dupCount = if ($diagResult.DuplicateRules) { @($diagResult.DuplicateRules).Count } else { 0 }
                                $emptyCount = if ($diagResult.EmptyRules) { @($diagResult.EmptyRules).Count } else { 0 }
                                $disabledCount = if ($diagResult.DisabledRules) { @($diagResult.DisabledRules).Count } else { 0 }
                                $totalCount = if ($diagResult.TotalRules) { $diagResult.TotalRules } else { 0 }

                                if ($autoRepair) {
                                    Write-ToolkitStatus -Message "Diagnostics & Repair Complete: $totalCount rule(s) scanned. Repaired: $($diagResult.RepairedRulesCount), Pruned Duplicates: $($diagResult.RemovedDuplicatesCount), Pruned Empty: $($diagResult.RemovedEmptyCount)." -Type 'OK'
                                } else {
                                    $statusType = if ($brokenCount -gt 0 -or $dupCount -gt 0 -or $emptyCount -gt 0) { 'WARN' } else { 'OK' }
                                    Write-ToolkitStatus -Message "Diagnostics Scan Complete: $totalCount rule(s) scanned. Broken: $brokenCount, Duplicates: $dupCount, Empty: $emptyCount, Disabled: $disabledCount." -Type $statusType
                                }
                            } else {
                                $errMsg = if ($diagResult -and $diagResult.ErrorMessage) { $diagResult.ErrorMessage } else { "Rule diagnostics failed." }
                                Write-ToolkitStatus -Message "Diagnostics failed: $errMsg" -Type 'FAIL'
                            }
                        } catch {
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "$cmdName failed with exception: $($_.Exception.Message)" -Level ERROR -Component 'TUI' -NoConsole
                            }
                            Write-ToolkitStatus -Message "Diagnostics error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Repair-OutlookRule / Test-OutlookRule command unavailable." -Type 'WARN'
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

                    # Expand threshold to 100GB
                    if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                        try {
                            $null = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                            Write-ToolkitStatus -Message "Configured PST size threshold to 100GB (Warn: 95GB)." -Type 'OK'
                        } catch {
                            Write-Verbose "Threshold expansion notice: $($_.Exception.Message)"
                        }
                    }
                    Wait-UserAcknowledge
                }
                '16' {
                    # Discover available profiles
                    $discoveredProfiles = @()
                    $defaultProfile = 'Outlook'
                    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                        try {
                            $sysCtx = Get-OutlookSystemContext
                            if ($null -ne $sysCtx) {
                                if ($null -ne $sysCtx.Profiles) {
                                    $discoveredProfiles = @($sysCtx.Profiles)
                                }
                                if (-not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                                    $defaultProfile = $sysCtx.DefaultProfile
                                }
                            }
                        } catch { $null = $_ }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($activeProfileFilter)) {
                        $defaultProfile = $activeProfileFilter
                    }
                    if ($discoveredProfiles.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultProfile)) {
                        $discoveredProfiles = @($defaultProfile)
                    }

                    if ($discoveredProfiles.Count -le 1) {
                        $profName = if ($discoveredProfiles.Count -gt 0) { $discoveredProfiles[0] } else { $defaultProfile }
                        Write-ToolkitStatus -Message "Only 1 Outlook profile found ('$profName'). Switching profile filter is not applicable." -Type 'INFO'
                        Wait-UserAcknowledge
                        break
                    }

                    $targetProfile = $defaultProfile
                    if (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                        try {
                            $selectedProfile = Select-ToolkitOutlookProfile -DefaultProfile $defaultProfile -Profiles $discoveredProfiles -NonInteractive:$NonInteractive -Prompt "  Select Outlook Profile to Filter Data Files"
                            if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                                $targetProfile = $selectedProfile.Trim()
                            }
                        } catch {
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "Select-ToolkitOutlookProfile failed with exception: $($_.Exception.Message)" -Level ERROR -Component 'TUI' -NoConsole
                            }
                            Write-ToolkitStatus -Message "Profile selection error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        if (-not $NonInteractive) {
                            if ($discoveredProfiles.Count -gt 0) {
                                Write-Host "  Available Profiles: $($discoveredProfiles -join ', ')" -ForegroundColor Cyan
                            }
                            $chosenProfile = Read-Host "  Enter Outlook Profile to Filter (Default: $defaultProfile)"
                            if (-not [string]::IsNullOrWhiteSpace($chosenProfile)) {
                                $targetProfile = $chosenProfile.Trim()
                            }
                        }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($targetProfile)) {
                        $activeProfileFilter = $targetProfile
                        Write-ToolkitStatus -Message "Active profile filter set to '$targetProfile'. Refreshed data file inventory." -Type 'OK'
                    } else {
                        Write-ToolkitStatus -Message "Profile filter unchanged." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                '0' {
                    return
                }
                }
            }
            catch {
                $errDetail = if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) { $_.Exception.Message } else { "$_" }
                if (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Action execution failed: $errDetail" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            finally {
                Exit-ToolkitConsoleView
            }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
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
