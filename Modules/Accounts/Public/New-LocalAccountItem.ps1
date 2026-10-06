function New-LocalAccountItem {
<#
.SYNOPSIS
    Creates a new local user account with a secure password.
.DESCRIPTION
    Creates a new local account using New-LocalUser, accepting password as SecureString
    and returning account creation metadata.
.PARAMETER Username
    The login name for the new user account.
.PARAMETER Password
    The password typed strictly as [SecureString].
.PARAMETER FullName
    Optional display name for the user.
.PARAMETER Description
    Optional account description.
.OUTPUTS
    [PSCustomObject]@{ Username, Created, SID }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory = $false)]
        [string]$FullName,

        [Parameter(Mandatory = $false)]
        [string]$Description
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($Username, "Create local user account")) {
            return [PSCustomObject]@{
                Username = $Username
                Created  = $true
                SID      = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Creating new local user '$Username'..." -Level "Info" -Component "Accounts"
        }

        $createParams = @{
            Name     = $Username
            Password = $Password
        }

        if (-not [string]::IsNullOrWhiteSpace($FullName)) {
            $createParams['FullName'] = $FullName
        }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $createParams['Description'] = $Description
        }

        try {
            $newUser = New-LocalUser @createParams -ErrorAction Stop
            
            $sidVal = ''
            if ($null -ne $newUser) {
                if ($newUser.PSObject.Properties['SID'] -and $null -ne $newUser.SID) {
                    if ($newUser.SID.PSObject.Properties['Value'] -and $null -ne $newUser.SID.Value) {
                        $sidVal = [string]$newUser.SID.Value
                    } else {
                        $sidVal = [string]$newUser.SID
                    }
                }
            }

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully created local user '$Username' (SID: $sidVal)." -Level "Info" -Component "Accounts"
            }

            return [PSCustomObject]@{
                Username = $Username
                Created  = $true
                SID      = $sidVal
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to create local user '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
