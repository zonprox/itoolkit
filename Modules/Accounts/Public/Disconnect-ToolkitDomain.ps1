function Disconnect-ToolkitDomain {
<#
.SYNOPSIS
    Switches computer from a Domain to a Workgroup with mandatory local admin verification.
.DESCRIPTION
    Enforces a strict pre-flight lockout prevention barrier: checks Get-LocalAccountList
    to ensure at least one active, enabled local administrator exists. If satisfied,
    invokes UnjoinDomainOrWorkgroup on Win32_ComputerSystem.
.PARAMETER WorkgroupName
    Target workgroup name (e.g. 'WORKGROUP').
.PARAMETER Credential
    Local or domain administrative credentials for unjoining [PSCredential].
.OUTPUTS
    [PSCustomObject]@{ WorkgroupName, ReturnCode, Success, RestartNeeded }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkgroupName,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Validating pre-flight local administrator lockout defense..." -Level "Info" -Component "Accounts"
        }

        # 1. Pre-flight Lockout Prevention Verification
        $localAccounts = Get-LocalAccountList
        $hasActiveAdmin = $false

        if ($localAccounts) {
            foreach ($acc in $localAccounts) {
                if ($acc.Enabled -eq $true) {
                    if ($acc.SID -match '-(?:500)$' -or $acc.Name -eq 'Administrator') {
                        $hasActiveAdmin = $true
                        break
                    }
                }
            }
        }

        if (-not $hasActiveAdmin) {
            $lockoutError = "CRITICAL LOCKOUT DEFENSE: Disjoin aborted! No active, enabled local administrator account found. Risk of lockout. Activate the built-in Administrator account before disjoining from the domain."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $lockoutError -Level "Error" -Component "Accounts"
            }
            throw $lockoutError
        }

        if (-not $PSCmdlet.ShouldProcess($WorkgroupName, "Disjoin domain and revert to workgroup")) {
            return [PSCustomObject]@{
                WorkgroupName = $WorkgroupName
                ReturnCode    = 0
                Success       = $true
                RestartNeeded = $false
            }
        }

        # 2. Invoke CIM UnjoinDomainOrWorkgroup
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

            $unjoinArgs = @{
                UserName       = $Credential.UserName
                Password       = $Credential.GetNetworkCredential().Password
                FUnjoinOptions = [uint32]0
            }

            $invokeResult = Invoke-CimMethod -InputObject $cs -MethodName 'UnjoinDomainOrWorkgroup' -Arguments $unjoinArgs -ErrorAction Stop
            $returnCode = 0
            if ($null -ne $invokeResult -and $invokeResult.PSObject.Properties['ReturnValue'] -and $null -ne $invokeResult.ReturnValue) {
                $returnCode = [int]$invokeResult.ReturnValue
            }
            $isSuccess = ($returnCode -eq 0)

            if ($isSuccess) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully unjoined from domain into workgroup '$WorkgroupName'. Reboot required." -Level "Info" -Component "Accounts"
                }
            } else {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Domain disjoin returned non-zero Win32 error code: $returnCode" -Level "Error" -Component "Accounts"
                }
            }

            return [PSCustomObject]@{
                WorkgroupName = $WorkgroupName
                ReturnCode    = $returnCode
                Success       = $isSuccess
                RestartNeeded = $isSuccess
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Domain disjoin failed: $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
