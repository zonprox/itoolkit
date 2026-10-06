function Join-ToolkitDomain {
<#
.SYNOPSIS
    Joins the computer to an Active Directory domain using CIM Win32_ComputerSystem.
.DESCRIPTION
    Invokes JoinDomainOrWorkgroup method on Win32_ComputerSystem. Compatible across
    Windows PowerShell 5.1 and PowerShell 7+ Core.
.PARAMETER DomainName
    The target domain name (e.g. corp.local).
.PARAMETER Credential
    Domain administrator or account with Join permissions [PSCredential].
.PARAMETER OUPath
    Optional Organizational Unit LDAP path (e.g. "OU=Workstations,DC=corp,DC=local").
.OUTPUTS
    [PSCustomObject]@{ DomainName, ReturnCode, Success, RestartNeeded }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DomainName,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$OUPath
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($DomainName, "Join computer to domain")) {
            return [PSCustomObject]@{
                DomainName    = $DomainName
                ReturnCode    = 0
                Success       = $true
                RestartNeeded = $false
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Initiating domain join to '$DomainName' for user '$($Credential.UserName)'..." -Level "Info" -Component "Accounts"
        }

        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

            # NETSETUP_JOIN_DOMAIN (1) + NETSETUP_ACCT_CREATE (2) = 3
            $joinArgs = @{
                Name         = $DomainName
                UserName     = $Credential.UserName
                Password     = $Credential.GetNetworkCredential().Password
                FJoinOptions = [uint32]3
            }

            if (-not [string]::IsNullOrWhiteSpace($OUPath)) {
                $joinArgs['AccountOU'] = $OUPath
            }

            $invokeResult = Invoke-CimMethod -InputObject $cs -MethodName 'JoinDomainOrWorkgroup' -Arguments $joinArgs -ErrorAction Stop
            $returnCode = 0
            if ($null -ne $invokeResult -and $invokeResult.PSObject.Properties['ReturnValue'] -and $null -ne $invokeResult.ReturnValue) {
                $returnCode = [int]$invokeResult.ReturnValue
            }
            $isSuccess = ($returnCode -eq 0)

            if ($isSuccess) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully joined computer to domain '$DomainName'. Reboot required." -Level "Info" -Component "Accounts"
                }
            } else {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Domain join returned non-zero Win32 error code: $returnCode" -Level "Error" -Component "Accounts"
                }
            }

            return [PSCustomObject]@{
                DomainName    = $DomainName
                ReturnCode    = $returnCode
                Success       = $isSuccess
                RestartNeeded = $isSuccess
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Domain join failed: $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
