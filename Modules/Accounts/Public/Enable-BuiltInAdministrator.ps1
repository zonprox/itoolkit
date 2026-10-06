function Enable-BuiltInAdministrator {
<#
.SYNOPSIS
    Identifies the built-in Administrator account by SID -500 and activates it safely.
.DESCRIPTION
    Uses well-known SID suffix -500 to identify the built-in Administrator account
    across all language localizations, enables the account, and optionally sets a password.
.PARAMETER Password
    Optional password typed strictly as [SecureString].
.OUTPUTS
    [PSCustomObject]@{ AdministratorName, Enabled, PasswordReset }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$Password
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Locating built-in Administrator account by SID -500..." -Level "Info" -Component "Accounts"
        }

        $adminAccount = $null
        try {
            $accounts = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True" -ErrorAction Stop
            if ($accounts) {
                foreach ($acc in $accounts) {
                    if ($acc.PSObject.Properties['LocalAccount'] -and $acc.LocalAccount -ne $true) {
                        continue
                    }
                    if ($acc.SID -match '-(?:500)$') {
                        $adminAccount = $acc
                        break
                    }
                }
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Filtered CIM query failed: $($_.Exception.Message). Falling back to unfiltered query." -Level "Warn" -Component "Accounts"
            }
            try {
                $rawAccounts = Get-CimInstance -ClassName Win32_UserAccount -ErrorAction Stop
                if ($rawAccounts) {
                    foreach ($acc in $rawAccounts) {
                        if ($acc.LocalAccount -eq $true -and $acc.SID -match '-(?:500)$') {
                            $adminAccount = $acc
                            break
                        }
                    }
                }
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Failed to query CIM Win32_UserAccount: $($_.Exception.Message)" -Level "Warn" -Component "Accounts"
                }
            }
        }

        # Fallback if SID query failed to find object
        $adminName = 'Administrator'
        if ($null -ne $adminAccount -and $adminAccount.PSObject.Properties['Name']) {
            $adminName = [string]$adminAccount.Name
        }

        if (-not $PSCmdlet.ShouldProcess($adminName, "Enable built-in Administrator account")) {
            return [PSCustomObject]@{
                AdministratorName = $adminName
                Enabled           = $true
                PasswordReset     = ($null -ne $Password)
            }
        }

        try {
            Enable-LocalUser -Name $adminName -ErrorAction Stop
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Activated built-in Administrator account '$adminName'." -Level "Info" -Component "Accounts"
            }

            $pwdReset = $false
            if ($null -ne $Password) {
                Set-LocalUser -Name $adminName -Password $Password -ErrorAction Stop
                $pwdReset = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully updated password for '$adminName'." -Level "Info" -Component "Accounts"
                }
            }

            return [PSCustomObject]@{
                AdministratorName = $adminName
                Enabled           = $true
                PasswordReset     = $pwdReset
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to activate Administrator account '$adminName': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
