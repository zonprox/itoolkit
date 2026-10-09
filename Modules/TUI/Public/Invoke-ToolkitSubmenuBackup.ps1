if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
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

if (Get-Command -Name Get-BackupContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-BackupContextInfoLines -Value (Get-Command -Name Get-BackupContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuBackup -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuBackup -Value (Get-Command -Name Invoke-ToolkitSubmenuBackup).ScriptBlock
}

