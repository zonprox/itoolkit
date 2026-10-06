function Set-DomainAccountState {
<#
.SYNOPSIS
    Enables or disables an Active Directory domain account without RSAT.
.DESCRIPTION
    Modifies domain user account status via Enable-ADAccount/Disable-ADAccount or
    .NET System.DirectoryServices.AccountManagement.
.PARAMETER Username
    The domain user's SamAccountName or UPN.
.PARAMETER Enabled
    Boolean flag ($true to enable, $false to disable).
.PARAMETER Domain
    Optional Active Directory domain name.
.OUTPUTS
    [bool] $true on success.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $true, Position = 1)]
        [bool]$Enabled,

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$Domain
    )

    process {
        $actionDesc = "Disable domain account"
        if ($Enabled) {
            $actionDesc = "Enable domain account"
        }
        if (-not $PSCmdlet.ShouldProcess($Username, $actionDesc)) {
            return $true
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Setting domain account '$Username' Enabled state to $Enabled..." -Level "Info" -Component "Accounts"
        }

        # 1. RSAT / Mock check
        if ($Enabled -and (Get-Command -Name 'Enable-ADAccount' -ErrorAction SilentlyContinue)) {
            try {
                $adParams = @{ Identity = $Username }
                if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                    $adParams['Server'] = $Domain
                }
                Enable-ADAccount @adParams -ErrorAction Stop
                return $true
            }
            catch {
                Write-Verbose "Enable-ADAccount failed: $($_.Exception.Message)"
            }
        }
        elseif ((-not $Enabled) -and (Get-Command -Name 'Disable-ADAccount' -ErrorAction SilentlyContinue)) {
            try {
                $adParams = @{ Identity = $Username }
                if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                    $adParams['Server'] = $Domain
                }
                Disable-ADAccount @adParams -ErrorAction Stop
                return $true
            }
            catch {
                Write-Verbose "Disable-ADAccount failed: $($_.Exception.Message)"
            }
        }

        # 2. Zero-RSAT .NET AccountManagement
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue
            $ctxType = [System.DirectoryServices.AccountManagement.ContextType]::Domain

            $ctx = $null
            if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                $ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new($ctxType, $Domain)
            } else {
                $ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new($ctxType)
            }

            $userPrincipal = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($ctx, $Username)
            if ($null -eq $userPrincipal) {
                throw "Domain user '$Username' was not found in directory."
            }

            $userPrincipal.Enabled = $Enabled
            $userPrincipal.Save()
            return $true
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to set domain account '$Username' state: $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
