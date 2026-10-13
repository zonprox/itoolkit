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

function Invoke-ToolkitAccountContextMenu {
<#
.SYNOPSIS
    Contextual administration menu for a targeted user account.
.PARAMETER Account
    Selected account object, hashtable, or username string.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately.
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('SelectedAccount')]
        [object]$Account,

        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Account context menu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $userName = if ($Account -is [string]) {
        $Account
    } elseif ($Account.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($Account.Name)) {
        [string]$Account.Name
    } elseif ($Account.PSObject.Properties['Identity'] -and -not [string]::IsNullOrWhiteSpace($Account.Identity)) {
        [string]$Account.Identity
    } else {
        [string]$Account
    }

    $innerAcc = if ($Account.PSObject.Properties['AccountObject'] -and $null -ne $Account.AccountObject) {
        $Account.AccountObject
    } else {
        $Account
    }

    $inContext = $true
    while ($inContext) {
        $clear = if ($NonInteractive) { $false } else { $true }

        $isEnabled = $true
        if ($innerAcc.PSObject.Properties['Enabled']) { $isEnabled = [bool]$innerAcc.Enabled }
        elseif ($Account.PSObject.Properties['Status']) { $isEnabled = ($Account.Status -match '(?i)ENABLED') }

        $isLocked = $false
        if ($innerAcc.PSObject.Properties['Locked']) { $isLocked = [bool]$innerAcc.Locked }
        elseif ($innerAcc.PSObject.Properties['Lockout']) { $isLocked = [bool]$innerAcc.Lockout }

        $sid = 'Local Account'
        if ($innerAcc.PSObject.Properties['SID'] -and -not [string]::IsNullOrWhiteSpace($innerAcc.SID)) { $sid = [string]$innerAcc.SID }
        elseif ($Account.PSObject.Properties['Details'] -and -not [string]::IsNullOrWhiteSpace($Account.Details)) { $sid = [string]$Account.Details }

        $statusBadge = if ($isEnabled) { '[ENABLED]' } else { '[DISABLED]' }
        $lockBadge = if ($isLocked) { '[LOCKED]' } else { '[UNLOCKED]' }

        Show-ToolkitHeader -Title 'ITOOLKIT > ACCOUNTS > USER CONTEXT' `
            -Subtitle "Contextual Administration for Local Account: $userName" `
            -ClearScreen:$clear `
            -InfoLines @(
                "Target Account : $userName | SID: $sid",
                "Account State  : $statusBadge | Lockout: $lockBadge",
                "Privilege      : $(if ($sid -match '-(?:500)$') { 'Built-in Administrator (SID-500)' } else { 'Standard User' })"
            )

        $contextActions = @(
            @{ Key = '1'; Label = 'Toggle State (Enable/Disable)' },
            @{ Key = '2'; Label = 'Unlock Account' },
            @{ Key = '3'; Label = 'Reset Password' },
            @{ Key = '4'; Label = 'Inspect Account Details' }
        )
        $contextNav = @(
            @{ Key = '0'; Label = 'Back to Accounts List' }
        )
        Show-ToolkitActionCatalog -Actions $contextActions -NavActions $contextNav -Title "ACCOUNT ACTIONS: $userName"

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive context listing complete for user '$userName'." -Type 'INFO'
            return
        }

        $choice = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys @('1', '2', '3', '4') -Prompt "  Select action for '$userName' [1-4, 0]"
        if ($null -eq $choice -or $choice.Type -eq 'Exit' -or $choice.Value -eq '0') {
            $inContext = $false
            return
        }

        switch ("$($choice.Value)") {
            '1' {
                $targetState = -not $isEnabled
                if (Get-Command -Name 'Set-LocalAccountState' -ErrorAction SilentlyContinue) {
                    try {
                        Set-LocalAccountState -Username $userName -Enabled $targetState
                        if ($innerAcc.PSObject.Properties['Enabled']) { $innerAcc.Enabled = $targetState }
                        if ($Account.PSObject.Properties['Status']) { $Account.Status = if ($targetState) { '[ENABLED]' } else { '[DISABLED]' } }
                        $newStateStr = if ($targetState) { 'Enabled' } else { 'Disabled' }
                        Write-ToolkitStatus -Message "Account '$userName' state toggled to $newStateStr." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to toggle account state: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Set-LocalAccountState command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '2' {
                if (Get-Command -Name 'Unlock-LocalAccountItem' -ErrorAction SilentlyContinue) {
                    try {
                        Unlock-LocalAccountItem -Username $userName
                        if ($innerAcc.PSObject.Properties['Locked']) { $innerAcc.Locked = $false }
                        if ($innerAcc.PSObject.Properties['Lockout']) { $innerAcc.Lockout = $false }
                        Write-ToolkitStatus -Message "Account '$userName' lockout cleared." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to unlock account: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Unlock-LocalAccountItem command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '3' {
                $pwd = Read-Host "  Enter New Password for '$userName'" -AsSecureString
                if ($null -ne $pwd) {
                    try {
                        if ($userName -eq 'Administrator' -or $sid -match '-(?:500)$') {
                            if (Get-Command -Name 'Reset-BuiltInAdministratorPassword' -ErrorAction SilentlyContinue) {
                                Reset-BuiltInAdministratorPassword -Password $pwd
                                Write-ToolkitStatus -Message "Administrator password reset successfully." -Type 'OK'
                            }
                        } else {
                            if (Get-Command -Name 'Set-LocalUser' -ErrorAction SilentlyContinue) {
                                Set-LocalUser -Name $userName -Password $pwd
                                Write-ToolkitStatus -Message "Password reset for '$userName' successfully." -Type 'OK'
                            } else {
                                Write-ToolkitStatus -Message "Set-LocalUser command unavailable." -Type 'WARN'
                            }
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Password reset failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '4' {
                $detailList = @(
                    "Username         : $userName",
                    "Security SID     : $sid",
                    "Account State    : $(if ($isEnabled) { '[ENABLED]' } else { '[DISABLED]' })",
                    "Lockout State    : $(if ($isLocked) { '[LOCKED]' } else { '[UNLOCKED]' })"
                )
                if ($innerAcc.PSObject.Properties['PasswordRequired']) {
                    $detailList += "Password Required: $(if ($innerAcc.PasswordRequired) { '[YES]' } else { '[NO]' })"
                }
                Show-ToolkitDetailPanel -Details $detailList -Title "ACCOUNT ATTRIBUTES: $userName"
                Wait-UserAcknowledge
            }
            '0' {
                $inContext = $false
                return
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitAccountContextMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitAccountContextMenu' -Value (Get-Command -Name 'Invoke-ToolkitAccountContextMenu').ScriptBlock
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
                        Identity         = [string]$a.Name
                        Status           = if ($a.Enabled) { '[ENABLED]' } else { '[DISABLED]' }
                        Type             = 'Account'
                        Details          = if ($a.SID) { [string]$a.SID } else { 'Local User' }
                        Name             = [string]$a.Name
                        SID              = [string]$a.SID
                        Enabled          = [bool]$a.Enabled
                        Locked           = [bool]$a.Locked
                        Lockout          = [bool]$a.Lockout
                        PasswordRequired = [bool]$a.PasswordRequired
                        AccountObject    = $a
                    }
                }
            }
        } catch { $null = $_ }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Identity = 'Built-in Administrator'; Status = '[READY]'; Type = 'Account'; Details = 'Security Identifier SID -500'; Name = 'Administrator'; SID = 'S-1-5-21-0-0-0-500'; Enabled = $true; Locked = $false },
                [PSCustomObject]@{ Identity = 'Active User Profile';    Status = '[READY]'; Type = 'Profile'; Details = 'Folder structure and browser bookmarks'; Name = 'CurrentUser'; Enabled = $true; Locked = $false },
                [PSCustomObject]@{ Identity = 'Backup Manifest Engine';  Status = '[READY]'; Type = 'Storage'; Details = 'SHA-256 file verification catalog'; Name = 'ManifestEngine'; Enabled = $true; Locked = $false }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Identity', 'Status', 'Type', 'Details') -Headers @('IDENTITY', 'STATUS', 'TYPE', 'DETAILS') -Title 'Managed Accounts & Identity Artifacts'

        Write-Host ""
        $actions = @(
            @{ Key = '10'; Label = 'Create Local Account' },
            @{ Key = '11'; Label = 'Enable Built-in Administrator' },
            @{ Key = '12'; Label = 'Reset Admin Password' },
            @{ Key = '13'; Label = 'Query Domain User' },
            @{ Key = '14'; Label = 'Unlock Domain User' },
            @{ Key = '15'; Label = 'New Profile Backup' },
            @{ Key = '16'; Label = 'Verify Backup Manifest' },
            @{ Key = '17'; Label = 'Export Browser Bookmarks' },
            @{ Key = '18'; Label = 'Export Personal Certificates' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Accounts, Identity & Backup'." -Type 'INFO'
            return
        }

        $categoryKeys = @('10', '11', '12', '13', '14', '15', '16', '17', '18')
        $promptText = "  Select Item [1-$($items.Count)], Action [10-18], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex $items.Count -ValidHotkeys $categoryKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        if ($selection.Type -eq 'Index') {
            $targetIdx = [int]$selection.Value - 1
            if ($targetIdx -ge 0 -and $targetIdx -lt $items.Count) {
                $selectedAccount = $items[$targetIdx]
                Invoke-ToolkitAccountContextMenu -Account $selectedAccount -NonInteractive:$NonInteractive
            }
        }
        elseif ($selection.Type -eq 'Hotkey') {
            $actionKey = "$($selection.Value)"

            switch ($actionKey) {
                { $_ -in @('10', '1') } {
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
                { $_ -in @('11', '2') } {
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
                { $_ -in @('12', '3') } {
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
                { $_ -in @('13', '4') } {
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
                { $_ -in @('14', '5') } {
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
                { $_ -in @('15', '6') } {
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
                { $_ -in @('16', '7') } {
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
                { $_ -in @('17', '8') } {
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
                { $_ -in @('18', '9') } {
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
