function Unlock-DomainAccountItem {
<#
.SYNOPSIS
    Unlocks an Active Directory domain account without requiring RSAT.
.DESCRIPTION
    Unlocks domain account using Unlock-ADAccount when available, or .NET
    System.DirectoryServices.AccountManagement.
.PARAMETER Username
    The domain user's SamAccountName or UPN.
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

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Domain
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($Username, "Unlock domain user account")) {
            return $true
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Unlocking domain account '$Username'..." -Level "Info" -Component "Accounts"
        }

        # 1. RSAT / Mock check
        if (Get-Command -Name 'Unlock-ADAccount' -ErrorAction SilentlyContinue) {
            try {
                $adParams = @{ Identity = $Username }
                if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                    $adParams['Server'] = $Domain
                }
                Unlock-ADAccount @adParams -ErrorAction Stop
                return $true
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Unlock-ADAccount failed: $($_.Exception.Message). Falling back to .NET AccountManagement." -Level "Warn" -Component "Accounts"
                }
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

            $userPrincipal.UnlockAccount()
            return $true
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to unlock domain user '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
