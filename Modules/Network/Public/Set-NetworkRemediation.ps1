function Set-NetworkRemediation {
<#
.SYNOPSIS
    Master orchestrator for Windows network stack troubleshooting, error repair, and batch remediation.
.DESCRIPTION
    Applies targeted or batch remediations across the Windows 10/11 network stack.
    Handles error codes 0x80070035, 0x80070043, DNS resolution failure, DHCP APIPA leases,
    ARP gateway corruption, Winsock catalog corruption, TCP/IP stack damage, NLA stalls,
    proxy misconfigurations, and adapter resets.
    Generates pre-modification registry backups and returns a comprehensive structured report.
.PARAMETER Fix
    One or more specific remediation fixes to execute. Valid values:
    'All', '0x80070035', '0x80070043', 'NetworkPathNotFound', 'DnsResolution', 'DhcpLease',
    'DefaultGatewayArp', 'Winsock', 'TcpIpStack', 'NlaService', 'ProxyMisconfig',
    'AdapterReset', 'SmbConfig'. Default is 'All'.
.PARAMETER ErrorCodes
    Alias for error code based remediation targeting.
.PARAMETER All
    Batch flag to execute all network fixes sequentially.
.PARAMETER BackupDirectory
    Custom directory path where pre-modification .reg backup files are saved.
.PARAMETER Force
    Forces execution without prompting.
.OUTPUTS
    [PSCustomObject] containing FixesApplied, RegBackupFiles, DnsFlushed, WinsockReset,
    TcpIpReset, ArpFlushed, DhcpRenewed, NlaRestarted, SmbConfigured, ProxyReset,
    AdapterReset, Success, ErrorMessage.
.EXAMPLE
    Set-NetworkRemediation -All
.EXAMPLE
    Set-NetworkRemediation -Fix DnsResolution, Winsock
.EXAMPLE
    Set-NetworkRemediation -ErrorCodes '0x80070035'
.EXAMPLE
    Set-NetworkRemediation -All -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('All', '0x80070035', '0x80070043', 'NetworkPathNotFound', 'DnsResolution', 'DhcpLease', 'DefaultGatewayArp', 'Winsock', 'TcpIpStack', 'NlaService', 'ProxyMisconfig', 'AdapterReset', 'SmbConfig')]
        [string[]]$Fix = @('All'),

        [Parameter(Mandatory = $false)]
        [Alias('ErrorCode')]
        [string[]]$ErrorCodes = @(),

        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to execute network remediations. Current session is not elevated."
        }

        # 2. Map input parameters to canonical fix actions
        $hasExplicitFix = $PSBoundParameters.ContainsKey('Fix')
        $hasExplicitErrorCodes = ($PSBoundParameters.ContainsKey('ErrorCodes') -or $PSBoundParameters.ContainsKey('ErrorCode'))

        $rawFixes = [System.Collections.Generic.List[string]]::new()
        if ($hasExplicitErrorCodes -and -not $hasExplicitFix) {
            foreach ($item in $ErrorCodes) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $rawFixes.Add($item)
                }
            }
        }
        else {
            if ($null -ne $Fix) {
                foreach ($item in $Fix) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) {
                        $rawFixes.Add($item)
                    }
                }
            }
            if ($hasExplicitErrorCodes) {
                foreach ($item in $ErrorCodes) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) {
                        $rawFixes.Add($item)
                    }
                }
            }
        }

        $allFixOrder = @(
            'DnsResolution',
            'DhcpLease',
            'DefaultGatewayArp',
            'Winsock',
            'TcpIpStack',
            'NlaService',
            'ProxyMisconfig',
            'SmbConfig',
            'AdapterReset'
        )

        $targetFixes = [System.Collections.Generic.List[string]]::new()
        $isAllMode = ($All.IsPresent -or ($rawFixes -contains 'All') -or ($rawFixes.Count -eq 0))

        if ($isAllMode) {
            foreach ($f in $allFixOrder) {
                $targetFixes.Add($f)
            }
        }
        else {
            foreach ($item in $rawFixes) {
                $canonical = switch ($item) {
                    '0x80070035'          { 'SmbConfig' }
                    '0x80070043'          { 'SmbConfig' }
                    'NetworkPathNotFound' { 'SmbConfig' }
                    'SmbConfig'           { 'SmbConfig' }
                    'DnsResolution'       { 'DnsResolution' }
                    'DhcpLease'           { 'DhcpLease' }
                    'DefaultGatewayArp'   { 'DefaultGatewayArp' }
                    'Winsock'             { 'Winsock' }
                    'TcpIpStack'          { 'TcpIpStack' }
                    'NlaService'          { 'NlaService' }
                    'ProxyMisconfig'      { 'ProxyMisconfig' }
                    'AdapterReset'        { 'AdapterReset' }
                    default               { $item }
                }
                if ($canonical -notin $targetFixes) {
                    $targetFixes.Add($canonical)
                }
            }
        }

        # 3. WhatIf / ShouldProcess support
        $actionDesc = "Execute network remediation: $($targetFixes -join ', ')"
        if (-not $PSCmdlet.ShouldProcess("Windows Network Subsystem", $actionDesc)) {
            return [PSCustomObject]@{
                FixesApplied   = $targetFixes.ToArray()
                RegBackupFiles = @('[Simulated - WhatIf]')
                DnsFlushed     = $true
                WinsockReset   = $true
                TcpIpReset     = $true
                ArpFlushed     = $true
                DhcpRenewed    = $true
                NlaRestarted   = $true
                SmbConfigured  = $true
                ProxyReset     = $true
                AdapterReset   = $true
                Success        = $true
                ErrorMessage   = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Starting network remediation (Target: $($targetFixes -join ', '))..." -Level 'INFO' -Component 'Network:Remediation'
        }

        # Dot-source helper cmdlets if not loaded
        $requiredCmdlets = @{
            'Reset-NetworkDns'               = 'Reset-NetworkDns.ps1'
            'Reset-NetworkDhcp'              = 'Reset-NetworkDhcp.ps1'
            'Reset-NetworkArp'               = 'Reset-NetworkArp.ps1'
            'Reset-NetworkWinsock'           = 'Reset-NetworkWinsock.ps1'
            'Reset-NetworkTcpIp'             = 'Reset-NetworkTcpIp.ps1'
            'Reset-NetworkLocationAwareness' = 'Reset-NetworkLocationAwareness.ps1'
            'Reset-NetworkProxy'             = 'Reset-NetworkProxy.ps1'
            'Set-NetworkSmbConfiguration'    = 'Set-NetworkSmbConfiguration.ps1'
            'Restart-ToolkitNetworkAdapter'  = 'Restart-ToolkitNetworkAdapter.ps1'
        }
        foreach ($kv in $requiredCmdlets.GetEnumerator()) {
            if (-not (Get-Command -Name $kv.Key -ErrorAction SilentlyContinue)) {
                $scriptFile = Join-Path -Path $PSScriptRoot -ChildPath $kv.Value
                if (Test-Path -LiteralPath $scriptFile) {
                    . $scriptFile
                }
            }
        }

        $fixesApplied   = [System.Collections.Generic.List[string]]::new()
        $regBackupFiles = [System.Collections.Generic.List[string]]::new()
        $errorMessages  = [System.Collections.Generic.List[string]]::new()

        $dnsFlushed    = $false
        $winsockReset  = $false
        $tcpIpReset    = $false
        $arpFlushed    = $false
        $dhcpRenewed   = $false
        $nlaRestarted  = $false
        $smbConfigured = $false
        $proxyReset    = $false
        $adapterReset  = $false

        # Execute in logical sequence
        # 1. DNS Resolution
        if ($targetFixes -contains 'DnsResolution') {
            try {
                if (Get-Command -Name 'Reset-NetworkDns' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkDns
                    if ($null -ne $res) {
                        $dnsFlushed = [bool]$res.DnsFlushed
                    }
                }
                $fixesApplied.Add('DnsResolution')
            }
            catch {
                $errorMessages.Add("DnsResolution failed: $($_.Exception.Message)")
            }
        }

        # 2. DHCP Lease
        if ($targetFixes -contains 'DhcpLease') {
            try {
                if (Get-Command -Name 'Reset-NetworkDhcp' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkDhcp
                    if ($null -ne $res) {
                        $dhcpRenewed = [bool]$res.LeaseRenewed
                    }
                }
                $fixesApplied.Add('DhcpLease')
            }
            catch {
                $errorMessages.Add("DhcpLease failed: $($_.Exception.Message)")
            }
        }

        # 3. Default Gateway / ARP
        if ($targetFixes -contains 'DefaultGatewayArp') {
            try {
                if (Get-Command -Name 'Reset-NetworkArp' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkArp
                    if ($null -ne $res) {
                        $arpFlushed = [bool]$res.ArpFlushed
                    }
                }
                $fixesApplied.Add('DefaultGatewayArp')
            }
            catch {
                $errorMessages.Add("DefaultGatewayArp failed: $($_.Exception.Message)")
            }
        }

        # 4. Winsock
        if ($targetFixes -contains 'Winsock') {
            try {
                if (Get-Command -Name 'Reset-NetworkWinsock' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkWinsock
                    if ($null -ne $res) {
                        $winsockReset = [bool]$res.WinsockReset
                    }
                }
                $fixesApplied.Add('Winsock')
            }
            catch {
                $errorMessages.Add("Winsock reset failed: $($_.Exception.Message)")
            }
        }

        # 5. TCP/IP Stack
        if ($targetFixes -contains 'TcpIpStack') {
            try {
                if (Get-Command -Name 'Reset-NetworkTcpIp' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkTcpIp
                    if ($null -ne $res) {
                        $tcpIpReset = [bool]$res.IpReset
                    }
                }
                $fixesApplied.Add('TcpIpStack')
            }
            catch {
                $errorMessages.Add("TcpIpStack reset failed: $($_.Exception.Message)")
            }
        }

        # 6. NLA Service
        if ($targetFixes -contains 'NlaService') {
            try {
                if (Get-Command -Name 'Reset-NetworkLocationAwareness' -ErrorAction SilentlyContinue) {
                    $res = Reset-NetworkLocationAwareness
                    if ($null -ne $res) {
                        $nlaRestarted = [bool]$res.NlaRestarted
                    }
                }
                $fixesApplied.Add('NlaService')
            }
            catch {
                $errorMessages.Add("NlaService reset failed: $($_.Exception.Message)")
            }
        }

        # 7. Proxy Misconfiguration
        if ($targetFixes -contains 'ProxyMisconfig') {
            try {
                if (Get-Command -Name 'Reset-NetworkProxy' -ErrorAction SilentlyContinue) {
                    $pParams = @{}
                    if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                        $pParams['BackupDirectory'] = $BackupDirectory
                    }
                    $res = Reset-NetworkProxy @pParams
                    if ($null -ne $res) {
                        $proxyReset = [bool]$res.WinHttpReset
                        if ($res.RegBackupFiles) {
                            foreach ($b in $res.RegBackupFiles) {
                                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                                    $regBackupFiles.Add($b)
                                }
                            }
                        }
                    }
                }
                $fixesApplied.Add('ProxyMisconfig')
            }
            catch {
                $errorMessages.Add("ProxyMisconfig reset failed: $($_.Exception.Message)")
            }
        }

        # 8. SMB / Discovery / Network Path Not Found
        if ($targetFixes -contains 'SmbConfig') {
            try {
                if (Get-Command -Name 'Set-NetworkSmbConfiguration' -ErrorAction SilentlyContinue) {
                    $sParams = @{}
                    if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                        $sParams['BackupDirectory'] = $BackupDirectory
                    }
                    $res = Set-NetworkSmbConfiguration @sParams
                    if ($null -ne $res) {
                        $smbConfigured = [bool]$res.SmbConfigured
                        if ($res.RegBackupFiles) {
                            foreach ($b in $res.RegBackupFiles) {
                                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                                    $regBackupFiles.Add($b)
                                }
                            }
                        }
                    }
                }
                $fixesApplied.Add('SmbConfig')
            }
            catch {
                $errorMessages.Add("SmbConfig configuration failed: $($_.Exception.Message)")
            }
        }

        # 9. Adapter Reset
        if ($targetFixes -contains 'AdapterReset') {
            try {
                if (Get-Command -Name 'Restart-ToolkitNetworkAdapter' -ErrorAction SilentlyContinue) {
                    $res = Restart-ToolkitNetworkAdapter -All
                    if ($null -ne $res) {
                        $adapterReset = [bool]$res.Success
                    }
                }
                $fixesApplied.Add('AdapterReset')
            }
            catch {
                $errorMessages.Add("AdapterReset failed: $($_.Exception.Message)")
            }
        }

        $overallSuccess = ($errorMessages.Count -eq 0 -and $fixesApplied.Count -gt 0)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "Network remediation completed. Applied: $($fixesApplied -join ', '). Backups: $($regBackupFiles.Count)" -Level $level -Component 'Network:Remediation'
        }

        return [PSCustomObject]@{
            FixesApplied   = $fixesApplied.ToArray()
            RegBackupFiles = $regBackupFiles.ToArray()
            DnsFlushed     = [bool]$dnsFlushed
            WinsockReset   = [bool]$winsockReset
            TcpIpReset     = [bool]$tcpIpReset
            ArpFlushed     = [bool]$arpFlushed
            DhcpRenewed    = [bool]$dhcpRenewed
            NlaRestarted   = [bool]$nlaRestarted
            SmbConfigured  = [bool]$smbConfigured
            ProxyReset     = [bool]$proxyReset
            AdapterReset   = [bool]$adapterReset
            Success        = [bool]$overallSuccess
            ErrorMessage   = [string]$errText
        }
    }
}
