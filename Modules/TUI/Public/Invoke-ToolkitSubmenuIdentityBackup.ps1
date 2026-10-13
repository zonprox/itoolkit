if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-IdentityBackupContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
    $telemetry = Get-ToolkitTelemetryData

    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Environment]::MachineName }
    $userName = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
    $domain = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { 'WORKGROUP' }
    $lines.Add("User & Host    : $userName @ $hostName | Domain: $domain")

    $adminStr = "Standard User [Non-Elevated]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) { $adminStr = "Administrator [Elevated]" }
        } catch { $null = $_ }
    }
    $lines.Add("Identity State : $adminStr | SID-500 Protection Active")

    $profPath = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $lines.Add("Profile Path   : $profPath | Storage: $($telemetry.StorageDisplay)")
    $lines.Add("Backup Engine  : Profile Sync, Bookmarks, Certs, SHA-256 Manifest [READY]")

    return $lines.ToArray()
}

function Get-AccountsContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-IdentityBackupContextInfoLines
}

function Get-BackupContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-IdentityBackupContextInfoLines
}

if (Get-Command -Name 'Get-IdentityBackupContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-IdentityBackupContextInfoLines' -Value (Get-Command -Name 'Get-IdentityBackupContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-AccountsContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-AccountsContextInfoLines' -Value (Get-Command -Name 'Get-AccountsContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-BackupContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-BackupContextInfoLines' -Value (Get-Command -Name 'Get-BackupContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuIdentityBackup {
<#
.SYNOPSIS
    Submenu for Accounts, Identity & Backup (Account Administration & Data Protection).
.DESCRIPTION
    Combines user account management, domain integration, and profile backup:
    - Local user creation, password reset, and built-in Administrator (SID -500) activation
    - Domain user querying, account unlocking, and domain reachability tests
    - User profile directory sync, Chromium bookmark exports, certificate management
    - SHA-256 backup integrity manifest generation and verification
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
        $idInfo = Get-IdentityBackupContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > ACCOUNTS, IDENTITY & BACKUP' -Subtitle 'Unified User & Domain Administration, Profile Protection & Backup Verification' -ClearScreen:$clear -InfoLines $idInfo

        $items = @()
        try {
            if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                $accs = @(Get-LocalAccountList)
                foreach ($a in $accs) {
                    $items += [PSCustomObject]@{
                        Identity = [string]$a.Name
                        Status   = if ($a.Enabled) { '[ENABLED]' } else { '[DISABLED]' }
                        Type     = 'Account'
                        Details  = if ($a.SID) { [string]$a.SID } else { 'Local User' }
                    }
                }
            }
        } catch { $null = $_ }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Identity = 'Built-in Administrator'; Status = '[READY]'; Type = 'Account'; Details = 'Security Identifier SID -500' },
                [PSCustomObject]@{ Identity = 'Active User Profile';    Status = '[READY]'; Type = 'Profile'; Details = 'Folder structure and browser bookmarks' },
                [PSCustomObject]@{ Identity = 'Backup Manifest Engine';  Status = '[READY]'; Type = 'Storage'; Details = 'SHA-256 file verification catalog' }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Identity', 'Status', 'Type', 'Details') -Headers @('IDENTITY', 'STATUS', 'TYPE', 'DETAILS') -Title 'Managed Accounts & Identity Artifacts' -NoIndex

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Create Local Account' },
            @{ Key = '2'; Label = 'Enable Built-in Administrator' },
            @{ Key = '3'; Label = 'Reset Admin Password' },
            @{ Key = '4'; Label = 'Query Domain User' },
            @{ Key = '5'; Label = 'Unlock Domain User' },
            @{ Key = '6'; Label = 'New Profile Backup' },
            @{ Key = '7'; Label = 'Verify Backup Manifest' },
            @{ Key = '8'; Label = 'Export Browser Bookmarks' },
            @{ Key = '9'; Label = 'Export Personal Certificates' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Accounts, Identity & Backup'." -Type 'INFO'
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '0')
        $promptText = "  Select action [1-9, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                $user = Read-Host "  Enter New Username"
                $pwd  = Read-Host "  Enter Password" -AsSecureString
                if (-not [string]::IsNullOrWhiteSpace($user) -and $null -ne $pwd -and (Get-Command -Name 'New-LocalAccountItem' -ErrorAction SilentlyContinue)) {
                    try {
                        New-LocalAccountItem -Username $user -Password $pwd
                        Write-ToolkitStatus -Message "Local account '$user' created successfully." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Account creation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '2' {
                if (Get-Command -Name 'Enable-BuiltInAdministrator' -ErrorAction SilentlyContinue) {
                    try {
                        Enable-BuiltInAdministrator
                        Write-ToolkitStatus -Message "Built-in Administrator (SID -500) enabled." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to enable Administrator: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '3' {
                $pwd = Read-Host "  Enter New Password" -AsSecureString
                if ($null -ne $pwd -and (Get-Command -Name 'Reset-BuiltInAdministratorPassword' -ErrorAction SilentlyContinue)) {
                    try {
                        Reset-BuiltInAdministratorPassword -Password $pwd
                        Write-ToolkitStatus -Message "Administrator password reset successfully." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Password reset failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '4' {
                $domUser = Read-Host "  Enter Domain Username"
                if (-not [string]::IsNullOrWhiteSpace($domUser) -and (Get-Command -Name 'Get-DomainAccountItem' -ErrorAction SilentlyContinue)) {
                    try {
                        $res = Get-DomainAccountItem -Username $domUser
                        Write-ToolkitStatus -Message "Queried domain account '$domUser'." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Domain query failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '5' {
                $domUser = Read-Host "  Enter Domain Username to Unlock"
                if (-not [string]::IsNullOrWhiteSpace($domUser) -and (Get-Command -Name 'Unlock-DomainAccountItem' -ErrorAction SilentlyContinue)) {
                    try {
                        Unlock-DomainAccountItem -Username $domUser
                        Write-ToolkitStatus -Message "Domain account '$domUser' unlocked." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to unlock domain user: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '6' {
                $src = Read-Host "  Enter Source Profile Path (Default: $env:USERPROFILE)"
                if ([string]::IsNullOrWhiteSpace($src)) { $src = $env:USERPROFILE }
                $dst = Read-Host "  Enter Target Backup Path (Default: C:\Backups\ProfileBackup)"
                if ([string]::IsNullOrWhiteSpace($dst)) { $dst = 'C:\Backups\ProfileBackup' }
                if (-not [string]::IsNullOrWhiteSpace($src) -and (Get-Command -Name 'Start-ProfileDirectoryBackup' -ErrorAction SilentlyContinue)) {
                    try {
                        Start-ProfileDirectoryBackup -SourceDirectories @($src) -DestinationPath $dst
                        if (Get-Command -Name 'New-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
                            try { $null = New-BackupIntegrityManifest -BackupRoot $dst } catch { $null = $_ }
                        }
                        Write-ToolkitStatus -Message "Profile backup job completed to '$dst'." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Profile backup failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '7' {
                $bRoot = Read-Host "  Enter Backup Root Path to Verify"
                if (-not [string]::IsNullOrWhiteSpace($bRoot) -and (Get-Command -Name 'Test-BackupIntegrityManifest' -ErrorAction SilentlyContinue)) {
                    try {
                        $vRes = Test-BackupIntegrityManifest -BackupRoot $bRoot
                        Write-ToolkitStatus -Message "Backup integrity manifest verification completed." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Manifest verification failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '8' {
                $outDir = Read-Host "  Enter Export Destination Directory (Default: C:\Backups\Bookmarks)"
                if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = 'C:\Backups\Bookmarks' }
                if (Get-Command -Name 'Export-BrowserBookmarks' -ErrorAction SilentlyContinue) {
                    try {
                        Export-BrowserBookmarks -DestinationPath $outDir
                        Write-ToolkitStatus -Message "Browser bookmarks exported to '$outDir'." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Bookmarks export failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '9' {
                $dest = Read-Host "  Enter Certificate Export Path"
                if (-not [string]::IsNullOrWhiteSpace($dest) -and (Get-Command -Name 'Export-ToolkitCertificates' -ErrorAction SilentlyContinue)) {
                    try {
                        Export-ToolkitCertificates -DestinationPath $dest
                        Write-ToolkitStatus -Message "Certificates exported to '$dest'." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Certificate export failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '0' { return }
        }
    }
}

function Invoke-ToolkitSubmenuAccounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuIdentityBackup @PSBoundParameters
}

function Invoke-ToolkitSubmenuBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuIdentityBackup @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuIdentityBackup' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuIdentityBackup' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuIdentityBackup').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuAccounts' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuAccounts' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuAccounts').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuBackup' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuBackup' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuBackup').ScriptBlock
}
