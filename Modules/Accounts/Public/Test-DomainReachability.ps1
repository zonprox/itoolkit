function Test-DomainReachability {
<#
.SYNOPSIS
    Pre-flight network validation for Active Directory domain reachability.
.DESCRIPTION
    Validates DNS resolution and tests essential Active Directory ports:
    Kerberos (88), LDAP (389), and SMB (445).
.PARAMETER DomainName
    The FQDN of the Active Directory domain (e.g. corp.local).
.OUTPUTS
    [PSCustomObject]@{ DomainName, DcHost, DnsResolved, KerberosPortOpen, LdapPortOpen, SmbPortOpen, Reachable }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DomainName
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Testing domain reachability for '$DomainName'..." -Level "Info" -Component "Accounts"
        }

        $dnsResolved = $false
        $dcHost = $DomainName

        # 1. Test DNS Resolution (A and SRV record)
        try {
            $srvRecord = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction SilentlyContinue
            if ($srvRecord) {
                $dnsResolved = $true
                $firstTarget = $srvRecord[0]
                if ($firstTarget.PSObject.Properties['NameTarget'] -and -not [string]::IsNullOrWhiteSpace($firstTarget.NameTarget)) {
                    $dcHost = [string]$firstTarget.NameTarget
                }
                elseif ($firstTarget.PSObject.Properties['NameHost'] -and -not [string]::IsNullOrWhiteSpace($firstTarget.NameHost)) {
                    $dcHost = [string]$firstTarget.NameHost
                }
            }
            else {
                $aRecord = Resolve-DnsName -Name $DomainName -ErrorAction SilentlyContinue
                if ($aRecord) {
                    $dnsResolved = $true
                    $firstRec = $aRecord[0]
                    if ($firstRec.PSObject.Properties['NameHost'] -and -not [string]::IsNullOrWhiteSpace($firstRec.NameHost)) {
                        $dcHost = [string]$firstRec.NameHost
                    }
                }
            }
        }
        catch {
            $dnsResolved = $false
        }

        # 2. Port Reachability Checks
        $krbOpen = $false
        $ldapOpen = $false
        $smbOpen = $false

        if ($dnsResolved) {
            # Kerberos Port 88
            try {
                $resKrb = Test-NetConnection -ComputerName $dcHost -Port 88 -WarningAction SilentlyContinue
                if ($resKrb -and $resKrb.PSObject.Properties['TcpTestSucceeded']) {
                    $krbOpen = [bool]$resKrb.TcpTestSucceeded
                }
            } catch {
                $krbOpen = $false
            }

            # LDAP Port 389
            try {
                $resLdap = Test-NetConnection -ComputerName $dcHost -Port 389 -WarningAction SilentlyContinue
                if ($resLdap -and $resLdap.PSObject.Properties['TcpTestSucceeded']) {
                    $ldapOpen = [bool]$resLdap.TcpTestSucceeded
                }
            } catch {
                $ldapOpen = $false
            }

            # SMB Port 445
            try {
                $resSmb = Test-NetConnection -ComputerName $dcHost -Port 445 -WarningAction SilentlyContinue
                if ($resSmb -and $resSmb.PSObject.Properties['TcpTestSucceeded']) {
                    $smbOpen = [bool]$resSmb.TcpTestSucceeded
                }
            } catch {
                $smbOpen = $false
            }
        }

        $reachable = ($dnsResolved -and $krbOpen -and $ldapOpen)

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $statusStr = "FAILED"
            if ($reachable) {
                $statusStr = "SUCCESS"
            }
            Write-ToolkitLog -Message "Domain reachability check '$statusStr': Dns=$dnsResolved, Kerberos=$krbOpen, LDAP=$ldapOpen, SMB=$smbOpen" -Level "Info" -Component "Accounts"
        }

        return [PSCustomObject]@{
            DomainName       = $DomainName
            DcHost           = $dcHost
            DnsResolved      = $dnsResolved
            KerberosPortOpen = $krbOpen
            LdapPortOpen     = $ldapOpen
            SmbPortOpen      = $smbOpen
            Reachable        = $reachable
        }
    }
}
