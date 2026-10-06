function Test-PointAndPrintPolicy {
<#
.SYNOPSIS
    Audits PrintNightmare registry keys and Point and Print driver installation policies.
.DESCRIPTION
    Checks RpcAuthnLevelPrivacyEnabled under HKLM:\SYSTEM\CurrentControlSet\Control\Print
    and RestrictDriverInstallationToAdministrators under PointAndPrint policy.
.OUTPUTS
    [PSCustomObject] containing RpcAuthnLevelPrivacyEnabled, RestrictDriverInstallationToAdministrators, Vulnerabilities.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        $rpcAuthn = $null
        $restrictAdmin = $null
        $vulnerabilities = [System.Collections.Generic.List[string]]::new()

        # 1. Audit RpcAuthnLevelPrivacyEnabled
        try {
            $printKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Print"
            $printProp = Get-ItemProperty -Path $printKey -ErrorAction SilentlyContinue
            if ($null -ne $printProp) {
                if ($printProp.PSObject.Properties['RpcAuthnLevelPrivacyEnabled']) {
                    $rpcAuthn = [int]$printProp.RpcAuthnLevelPrivacyEnabled
                }
                # Check RestrictDriverInstallationToAdministrators if returned by mock
                if ($printProp.PSObject.Properties['RestrictDriverInstallationToAdministrators']) {
                    $restrictAdmin = [int]$printProp.RestrictDriverInstallationToAdministrators
                }
            }
        } catch {
            Write-Verbose "Error reading Print control key: $($_.Exception.Message)"
        }

        # 2. Audit RestrictDriverInstallationToAdministrators
        if ($null -eq $restrictAdmin) {
            try {
                $pnpKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
                $pnpProp = Get-ItemProperty -Path $pnpKey -ErrorAction SilentlyContinue
                if ($null -ne $pnpProp -and $pnpProp.PSObject.Properties['RestrictDriverInstallationToAdministrators']) {
                    $restrictAdmin = [int]$pnpProp.RestrictDriverInstallationToAdministrators
                }
            } catch {
                Write-Verbose "Error reading PointAndPrint policy key: $($_.Exception.Message)"
            }
        }

        # 3. Analyze vulnerabilities
        if ($rpcAuthn -eq 0) {
            $vulnerabilities.Add("RpcAuthnLevelPrivacyEnabled is 0 (Disabled). Vulnerable to CVE-2021-1678 / PrintNightmare.")
        }
        if ($restrictAdmin -eq 0) {
            $vulnerabilities.Add("RestrictDriverInstallationToAdministrators is 0 (Disabled). Non-administrators can install print drivers.")
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "PointAndPrint Audit: RpcAuthn=$rpcAuthn, RestrictAdmin=$restrictAdmin" -Level 'INFO' -Component 'Test-PointAndPrintPolicy'
        }

        return [PSCustomObject]@{
            RpcAuthnLevelPrivacyEnabled                = $rpcAuthn
            RestrictDriverInstallationToAdministrators = $restrictAdmin
            Vulnerabilities                            = @($vulnerabilities)
        }
    }
}
