function Get-LocalAccountList {
<#
.SYNOPSIS
    Retrieves the list of local user accounts with their SID, status, and attributes.
.DESCRIPTION
    Queries local user accounts using CIM Win32_UserAccount. Maps Disabled to Enabled
    and formats account status for enterprise support workflows.
.OUTPUTS
    [PSCustomObject[]]@{ Name, SID, Enabled, Disabled, Locked, Lockout, PasswordRequired }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Querying local user account list..." -Level "Info" -Component "Accounts"
        }

        $cimAccounts = $null
        try {
            $cimAccounts = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True" -ErrorAction Stop
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to query Win32_UserAccount with filter: $($_.Exception.Message). Falling back to unfiltered query." -Level "Warn" -Component "Accounts"
            }
            try {
                $rawAccounts = Get-CimInstance -ClassName Win32_UserAccount -ErrorAction Stop
                if ($null -ne $rawAccounts) {
                    $cimAccounts = @($rawAccounts | Where-Object { $_.LocalAccount -eq $true })
                }
            } catch {
                Write-Verbose "Could not query Win32_UserAccount: $($_.Exception.Message)"
            }
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($null -ne $cimAccounts) {
            foreach ($acc in $cimAccounts) {
                $isDisabled = [bool]$acc.Disabled
                $isLocked = [bool]$acc.Lockout
                $isPwdReq = [bool]$acc.PasswordRequired

                $results.Add([PSCustomObject]@{
                    Name             = [string]$acc.Name
                    SID              = [string]$acc.SID
                    Enabled          = (-not $isDisabled)
                    Disabled         = $isDisabled
                    Locked           = $isLocked
                    Lockout          = $isLocked
                    PasswordRequired = $isPwdReq
                })
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Successfully enumerated $($results.Count) local account(s)." -Level "Info" -Component "Accounts"
        }

        return @($results)
    }
}
