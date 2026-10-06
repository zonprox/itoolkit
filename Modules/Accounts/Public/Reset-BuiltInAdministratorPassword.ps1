function Reset-BuiltInAdministratorPassword {
<#
.SYNOPSIS
    Resets the password for the built-in Administrator account.
.DESCRIPTION
    Locates the built-in Administrator by SID suffix -500 and updates its password.
.PARAMETER Password
    The new password typed strictly as [SecureString].
.OUTPUTS
    [PSCustomObject]@{ AdministratorName, PasswordReset }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Locating built-in Administrator account for password reset..." -Level "Info" -Component "Accounts"
        }

        $adminName = 'Administrator'
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
                    Write-ToolkitLog -Message "CIM query error: $($_.Exception.Message). Defaulting to '$adminName'." -Level "Warn" -Component "Accounts"
                }
            }
        }

        if ($null -ne $adminAccount -and $adminAccount.PSObject.Properties['Name']) {
            $adminName = [string]$adminAccount.Name
        }

        if (-not $PSCmdlet.ShouldProcess($adminName, "Reset built-in Administrator password")) {
            return [PSCustomObject]@{
                AdministratorName = $adminName
                PasswordReset     = $true
            }
        }

        try {
            Set-LocalUser -Name $adminName -Password $Password -ErrorAction Stop
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully reset password for '$adminName'." -Level "Info" -Component "Accounts"
            }

            return [PSCustomObject]@{
                AdministratorName = $adminName
                PasswordReset     = $true
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to reset password for '$adminName': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
