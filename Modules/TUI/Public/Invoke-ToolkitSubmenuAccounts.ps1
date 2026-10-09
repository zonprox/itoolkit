if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-AccountsContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Current User
    $currUser = "$env:USERDOMAIN\$env:USERNAME"
    $lines.Add("Current User   : $currUser")

    # 2. Privilege Level
    $adminStr = "Standard User [WARN]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Local Administrator [ELEVATED]"
            }
        }
        catch {
            $null = $_
        }
    }
    $lines.Add("Privilege Level: $adminStr")

    # 3. Domain Status
    $domStatus = "Workgroup Mode ($env:USERDOMAIN) [READY]"
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $domStatus = "Active Directory Domain ($env:USERDNSDOMAIN) [READY]"
    }
    $lines.Add("Domain Status  : $domStatus")

    # 4. Built-in Administrator
    $lines.Add("Built-in Administrator : Active (SID -500) Management Available [READY]")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuAccounts {
<#
.SYNOPSIS
    Submenu for User & Domain Account Administration with item-centric UI/UX.
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
        $rawAccounts = @()
        try {
            if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                $rawAccounts = @(Get-LocalAccountList)
            }
        }
        catch {
            Write-ToolkitStatus -Message "Failed to enumerate local accounts: $($_.Exception.Message)" -Type 'WARN'
        }

        $accounts = @()
        foreach ($acc in $rawAccounts) {
            $isEnabled = $true
            if ($null -ne $acc.Enabled) {
                $isEnabled = [bool]$acc.Enabled
            }
            elseif ($null -ne $acc.Disabled) {
                $isEnabled = (-not [bool]$acc.Disabled)
            }

            $isLocked = $false
            if ($null -ne $acc.Locked) {
                $isLocked = [bool]$acc.Locked
            }
            elseif ($null -ne $acc.Lockout) {
                $isLocked = [bool]$acc.Lockout
            }

            $statusBadge = if ($isEnabled) { '[ENABLED]' } else { '[DISABLED]' }
            $lockedBadge = if ($isLocked) { '[LOCKED]' } else { '[OK]' }

            $accounts += [PSCustomObject]@{
                Name     = [string]$acc.Name
                Status   = $statusBadge
                Locked   = $lockedBadge
                SID      = [string]$acc.SID
                Enabled  = $isEnabled
                IsLocked = $isLocked
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $accountsInfo = Get-AccountsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > USER & DOMAIN ACCOUNT ADMINISTRATION' -Subtitle 'Account Operations, Administrator SID -500, Domain Join/Disjoin' -ClearScreen:$clear -InfoLines $accountsInfo

        Show-ToolkitItemTable -Items $accounts -Columns @('Name', 'Status', 'Locked', 'SID') -Title 'Local User Accounts'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'A'; Label = 'Add Account' },
            @{ Key = 'S'; Label = 'Enable Admin SID-500' },
            @{ Key = 'P'; Label = 'Reset Admin Pwd' },
            @{ Key = 'D'; Label = 'Query Domain User' },
            @{ Key = 'U'; Label = 'Unlock Domain User' },
            @{ Key = 'T'; Label = 'Test Domain Health' },
            @{ Key = 'J'; Label = 'Disjoin Domain' },
            @{ Key = 'R'; Label = 'Refresh Table' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Account Administration'." -Type 'INFO'
            return
        }

        $validKeys = @('A', 'S', 'P', 'D', 'U', 'T', 'J', 'R', 'B', 'Q')
        $promptText = if ($accounts.Count -gt 0) { "  Select item [1-$($accounts.Count)] or action" } else { "  Select action [A, S, P, D, U, T, J, R, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $accounts.Count -ValidHotkeys $validKeys -Prompt $promptText

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
                'R' {
                    continue
                }
                'A' {
                    $user = Read-Host "  Enter New Username"
                    $pwd  = Read-Host "  Enter Secure Password" -AsSecureString
                    if (-not [string]::IsNullOrWhiteSpace($user) -and $null -ne $pwd) {
                        if (Get-Command -Name 'New-LocalAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                New-LocalAccountItem -Username $user -Password $pwd | Format-List
                                Write-ToolkitStatus -Message "Local account '$user' creation completed." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to create local account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    if (Get-Command -Name 'Enable-BuiltInAdministrator' -ErrorAction SilentlyContinue) {
                        try {
                            Enable-BuiltInAdministrator | Format-List
                            Write-ToolkitStatus -Message "Built-in Administrator (SID -500) activation completed." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to enable built-in Administrator: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'P' {
                    $pwd = Read-Host "  Enter New Password for Administrator" -AsSecureString
                    if ($null -ne $pwd) {
                        if (Get-Command -Name 'Reset-BuiltInAdministratorPassword' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-BuiltInAdministratorPassword -Password $pwd | Format-List
                                Write-ToolkitStatus -Message "Built-in Administrator password reset completed." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset Administrator password: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'D' {
                    $user = Read-Host "  Enter Domain SamAccountName"
                    if (-not [string]::IsNullOrWhiteSpace($user)) {
                        if (Get-Command -Name 'Get-DomainAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                Get-DomainAccountItem -Username $user | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to query domain account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'U' {
                    $user = Read-Host "  Enter Domain SamAccountName to Unlock"
                    if (-not [string]::IsNullOrWhiteSpace($user)) {
                        if (Get-Command -Name 'Unlock-DomainAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Unlock-DomainAccountItem -Username $user
                                Write-ToolkitStatus -Message "Domain account '$user' unlock result: $res" -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to unlock domain account '$user': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'T' {
                    $dom = Read-Host "  Enter Domain FQDN (e.g. corp.contoso.com)"
                    if (-not [string]::IsNullOrWhiteSpace($dom)) {
                        if (Get-Command -Name 'Test-DomainReachability' -ErrorAction SilentlyContinue) {
                            try {
                                Test-DomainReachability -DomainName $dom | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to test domain reachability for '$dom': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
                'J' {
                    $wg  = Read-Host "  Enter Target Workgroup Name (Default: WORKGROUP)"
                    if ([string]::IsNullOrWhiteSpace($wg)) {
                        $wg = 'WORKGROUP'
                    }
                    Write-Host "  Domain disjoin requires domain administrative credentials." -ForegroundColor Yellow
                    $cred = Get-Credential
                    if ($null -ne $cred) {
                        if (Get-Command -Name 'Disconnect-ToolkitDomain' -ErrorAction SilentlyContinue) {
                            try {
                                Disconnect-ToolkitDomain -WorkgroupName $wg -Credential $cred | Format-List
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to disjoin domain: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $accounts.Count) {
                $targetAccount = $accounts[$idx - 1]

                $targetInfo = @(
                    "Target Account : $($targetAccount.Name)",
                    "Security ID    : $($targetAccount.SID)",
                    "Current State  : $($targetAccount.Status)",
                    "Lockout Status : $($targetAccount.Locked)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > ACCOUNT: $($targetAccount.Name)" -Subtitle "Target SID: $($targetAccount.SID)" -ClearScreen:$true -InfoLines $targetInfo

                $toggleDesc = if ($targetAccount.Enabled -or $targetAccount.Status -eq '[ENABLED]') { 'Disable Account' } else { 'Enable Account' }
                $contextDetails = @(
                    @{ Key = '1'; Action = "Toggle State ($toggleDesc)"; Description = 'Toggle account active or disabled state.'; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '2'; Action = 'Unlock Account'; Description = 'Clear account lockout flag via ADSI/LocalUser.'; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '3'; Action = 'Reset Password'; Description = "Set new password for '$($targetAccount.Name)'."; Prerequisite = 'Administrator rights [READY]' },
                    @{ Key = '4'; Action = 'Remove Account'; Description = "Delete local user account '$($targetAccount.Name)'."; Prerequisite = 'Requires confirmation [WARN]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Accounts Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        $newState = -not ($targetAccount.Enabled -or $targetAccount.Status -eq '[ENABLED]')
                        if (Get-Command -Name 'Set-LocalAccountState' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Set-LocalAccountState -Username $targetAccount.Name -Enabled $newState
                                $stateText = if ($newState) { 'Enabled' } else { 'Disabled' }
                                Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' state successfully set to $stateText." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to set state for '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '2' {
                        if (Get-Command -Name 'Unlock-LocalAccountItem' -ErrorAction SilentlyContinue) {
                            try {
                                $res = Unlock-LocalAccountItem -Username $targetAccount.Name
                                Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' unlock result: $res" -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to unlock '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '3' {
                        $pwd = Read-Host "  Enter New Password for '$($targetAccount.Name)'" -AsSecureString
                        if ($null -ne $pwd) {
                            try {
                                if (Get-Command -Name 'Set-LocalUser' -ErrorAction SilentlyContinue) {
                                    Set-LocalUser -Name $targetAccount.Name -Password $pwd -ErrorAction Stop
                                    Write-ToolkitStatus -Message "Password successfully reset for account '$($targetAccount.Name)'." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Set-LocalUser command is not available." -Type 'FAIL'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset password for '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Password reset cancelled (empty password provided)." -Type 'WARN'
                        }
                    }
                    '4' {
                        if ($targetAccount.SID -match '-(?:500)$' -or $targetAccount.Name -eq 'Administrator') {
                            Write-ToolkitStatus -Message "Operation blocked: Built-in Administrator account (SID -500) cannot be removed." -Type 'FAIL'
                        }
                        else {
                            $confirm = Read-Host "  Are you sure you want to remove account '$($targetAccount.Name)'? [Y/N]"
                            if (-not [string]::IsNullOrWhiteSpace($confirm) -and $confirm.Trim().ToUpperInvariant() -eq 'Y') {
                                try {
                                    if (Get-Command -Name 'Remove-LocalUser' -ErrorAction SilentlyContinue) {
                                        Remove-LocalUser -Name $targetAccount.Name -ErrorAction Stop
                                        Write-ToolkitStatus -Message "Account '$($targetAccount.Name)' successfully removed." -Type 'OK'
                                    }
                                    else {
                                        Write-ToolkitStatus -Message "Remove-LocalUser command is not available." -Type 'FAIL'
                                    }
                                }
                                catch {
                                    Write-ToolkitStatus -Message "Failed to remove account '$($targetAccount.Name)': $($_.Exception.Message)" -Type 'FAIL'
                                }
                            }
                            else {
                                Write-ToolkitStatus -Message "Account removal cancelled." -Type 'INFO'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

if (Get-Command -Name Get-AccountsContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-AccountsContextInfoLines -Value (Get-Command -Name Get-AccountsContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuAccounts -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuAccounts -Value (Get-Command -Name Invoke-ToolkitSubmenuAccounts).ScriptBlock
}

