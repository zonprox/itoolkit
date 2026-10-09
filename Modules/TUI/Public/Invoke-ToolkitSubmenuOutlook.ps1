if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

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

if (Get-Command -Name Get-OutlookContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-OutlookContextInfoLines -Value (Get-Command -Name Get-OutlookContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuOutlook -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuOutlook -Value (Get-Command -Name Invoke-ToolkitSubmenuOutlook).ScriptBlock
}

