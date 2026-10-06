function Get-DomainAccountItem {
<#
.SYNOPSIS
    Queries domain account details and status without requiring RSAT.
.DESCRIPTION
    Queries domain accounts using Get-ADUser when present, or .NET
    System.DirectoryServices.AccountManagement on standard client workstations.
.PARAMETER Username
    The domain user's SamAccountName or UPN.
.PARAMETER Domain
    Optional Active Directory domain name.
.OUTPUTS
    [PSCustomObject]@{ SamAccountName, UserPrincipalName, Enabled, LockedOut, EmailAddress }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Domain
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Querying domain account '$Username'..." -Level "Info" -Component "Accounts"
        }

        # 1. RSAT / Pester Mock support (Get-ADUser)
        if (Get-Command -Name 'Get-ADUser' -ErrorAction SilentlyContinue) {
            try {
                $adParams = @{ Identity = $Username }
                if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                    $adParams['Server'] = $Domain
                }
                $user = Get-ADUser @adParams -ErrorAction Stop
                if ($null -ne $user) {
                    $email = $null
                    if ($user.PSObject.Properties['UserPrincipalName'] -and $user.UserPrincipalName -match '@') {
                        $email = [string]$user.UserPrincipalName
                    }
                    elseif ($user.PSObject.Properties['EmailAddress'] -and $null -ne $user.EmailAddress) {
                        $email = [string]$user.EmailAddress
                    }

                    return [PSCustomObject]@{
                        SamAccountName    = [string]$user.SamAccountName
                        UserPrincipalName = [string]$user.UserPrincipalName
                        Enabled           = [bool]$user.Enabled
                        LockedOut         = [bool]$user.LockedOut
                        EmailAddress      = $email
                    }
                }
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Get-ADUser failed: $($_.Exception.Message). Falling back to .NET AccountManagement." -Level "Warn" -Component "Accounts"
                }
            }
        }

        # 2. Zero-RSAT .NET AccountManagement implementation
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

            $isLocked = $false
            try {
                $isLocked = [bool]$userPrincipal.IsAccountLockedOut()
            } catch {
                $isLocked = $false
            }

            return [PSCustomObject]@{
                SamAccountName    = [string]$userPrincipal.SamAccountName
                UserPrincipalName = [string]$userPrincipal.UserPrincipalName
                Enabled           = [bool]$userPrincipal.Enabled
                LockedOut         = $isLocked
                EmailAddress      = [string]$userPrincipal.EmailAddress
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to query domain user '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
