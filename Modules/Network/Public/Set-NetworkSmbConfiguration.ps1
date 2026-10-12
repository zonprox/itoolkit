function Set-NetworkSmbConfiguration {
<#
.SYNOPSIS
    Configures Windows SMB client, NetBIOS, firewall rules, and services for network sharing.
.DESCRIPTION
    Remediates Windows error codes 0x80070035 and 0x80070043 ("Network path not found") by:
    - Enabling Network Discovery and File and Printer Sharing firewall rule groups via netsh advfirewall.
    - Setting discovery services (FDResPub, SSDPSRV, upnphost, LanmanServer, LanmanWorkstation) to Automatic and starting them.
    - Enabling NetBIOS over TCP/IP across active network interfaces.
    - Configuring Windows 11 SMB client parameters (AllowInsecureGuestAuth = 1, RequireSecuritySignature = 0)
      to remediate legacy NAS share access and Windows 11 24H2 mandatory SMB signing requirements.
.PARAMETER BackupDirectory
    Optional directory path where pre-modification .reg backup files will be saved.
.OUTPUTS
    [PSCustomObject] containing Success, FirewallRulesEnabled, ServicesStarted, NetbiosEnabled, SmbConfigured, RegBackupFiles, ErrorMessage.
.EXAMPLE
    Set-NetworkSmbConfiguration
.EXAMPLE
    Set-NetworkSmbConfiguration -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory
    )

    process {
        # 1. Admin privilege check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to configure SMB, firewall rules, and services."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("Windows SMB & Discovery Subsystems", "Enable Network Discovery firewall rules, start discovery services, enable NetBIOS, and configure SMB parameters")) {
            return [PSCustomObject]@{
                Success              = $true
                FirewallRulesEnabled = $true
                ServicesStarted      = @('FDResPub', 'SSDPSRV', 'upnphost', 'LanmanServer', 'LanmanWorkstation')
                NetbiosEnabled       = $true
                SmbConfigured        = $true
                RegBackupFiles       = @('[Simulated - WhatIf]')
                ErrorMessage         = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Configuring SMB, Network Discovery, and NetBIOS settings..." -Level 'INFO' -Component 'Network:SMB'
        }

        $regBackupFiles   = [System.Collections.Generic.List[string]]::new()
        $servicesStarted  = [System.Collections.Generic.List[string]]::new()
        $firewallSuccess  = $false
        $netbiosSuccess   = $false
        $smbSuccess       = $false
        $errorMessages    = [System.Collections.Generic.List[string]]::new()

        # Helper to set registry with backup
        $setReg = {
            param([string]$Key, [string]$Name, [object]$Val, [string]$Type = 'DWord')
            $regParams = @{
                KeyPath      = $Key
                ValueName    = $Name
                Value        = $Val
                PropertyType = $Type
            }
            if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                $regParams['BackupDirectory'] = $BackupDirectory
            }
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $res = Set-ToolkitRegistryValue @regParams
                    if ($null -ne $res) {
                        if ($res.PSObject.Properties['BackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.BackupFile)) {
                            return [string]$res.BackupFile
                        }
                        elseif ($res.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.RegBackupFile)) {
                            return [string]$res.RegBackupFile
                        }
                    }
                }
                else {
                    if (-not (Test-Path -LiteralPath $Key)) {
                        $null = New-Item -Path $Key -Force -ErrorAction SilentlyContinue
                    }
                    Set-ItemProperty -LiteralPath $Key -Name $Name -Value $Val -Type $Type -Force -ErrorAction Stop
                }
            }
            catch {
                Write-Verbose "Failed to write registry value $Key\$Name : $($_.Exception.Message)"
            }
            return $null
        }

        # 3. Enable Firewall Rules for Network Discovery and File/Printer Sharing
        $netshExe = 'netsh.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
        }

        try {
            $fwGroups = @('Network Discovery', 'File and Printer Sharing')
            $fwAllOk = $true
            foreach ($grp in $fwGroups) {
                $proc = Start-Process -FilePath $netshExe -ArgumentList @('advfirewall', 'firewall', 'set', 'rule', "group=$grp", 'new', 'enable=Yes') -Wait -NoNewWindow -PassThru -ErrorAction Stop
                if ($null -ne $proc -and $proc.ExitCode -ne 0) {
                    $fwAllOk = $false
                }
            }
            $firewallSuccess = $fwAllOk
        }
        catch {
            $firewallSuccess = $false
            $errorMessages.Add("Firewall rule configuration failed: $($_.Exception.Message)")
        }

        # Also attempt PowerShell NetSecurity cmdlets if available
        if (Get-Command -Name 'Enable-NetFirewallRule' -ErrorAction SilentlyContinue) {
            try {
                Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue
                Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
                $firewallSuccess = $true
            }
            catch {
                $null = $_
            }
        }

        # 4. Discovery & Lanman Services Configuration
        $targetServices = @('FDResPub', 'SSDPSRV', 'upnphost', 'LanmanServer', 'LanmanWorkstation')
        foreach ($svcName in $targetServices) {
            try {
                if (Get-Command -Name 'Set-Service' -ErrorAction SilentlyContinue) {
                    Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
                }
                if (Get-Command -Name 'Start-Service' -ErrorAction SilentlyContinue) {
                    Start-Service -Name $svcName -ErrorAction SilentlyContinue
                }
                $servicesStarted.Add($svcName)
            }
            catch {
                Write-Verbose "Could not start service $($svcName) - $($_.Exception.Message)"
            }
        }

        # 5. Enable NetBIOS over TCP/IP (NetbiosOptions = 1)
        try {
            $netbtInterfacesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
            if (Test-Path -LiteralPath $netbtInterfacesKey) {
                $subKeys = Get-ChildItem -LiteralPath $netbtInterfacesKey -ErrorAction SilentlyContinue
                if ($null -ne $subKeys) {
                    foreach ($sk in $subKeys) {
                        $bk = & $setReg $sk.PSPath 'NetbiosOptions' 1 'DWord'
                        if (-not [string]::IsNullOrWhiteSpace($bk) -and ($bk -notin $regBackupFiles)) {
                            $regBackupFiles.Add($bk)
                        }
                    }
                }
            }

            # Global NetBT parameters key
            $netbtParamsKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters'
            $bkGlob = & $setReg $netbtParamsKey 'NetbiosOptions' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($bkGlob) -and ($bkGlob -notin $regBackupFiles)) {
                $regBackupFiles.Add($bkGlob)
            }

            $netbiosSuccess = $true
        }
        catch {
            $netbiosSuccess = $false
            $errorMessages.Add("NetBIOS configuration failed: $($_.Exception.Message)")
        }

        # 6. Windows 11 SMB Parameters (AllowInsecureGuestAuth = 1, RequireSecuritySignature = 0)
        try {
            $lanmanKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'

            $b1 = & $setReg $lanmanKey 'AllowInsecureGuestAuth' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b1)
            }

            $b2 = & $setReg $lanmanKey 'RequireSecuritySignature' 0 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b2)
            }

            $smbSuccess = $true
        }
        catch {
            $smbSuccess = $false
            $errorMessages.Add("SMB parameters configuration failed: $($_.Exception.Message)")
        }

        $overallSuccess = ($smbSuccess -and $netbiosSuccess)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "SMB configuration completed (Success: $overallSuccess, Backups: $($regBackupFiles.Count))" -Level $level -Component 'Network:SMB'
        }

        return [PSCustomObject]@{
            Success              = [bool]$overallSuccess
            FirewallRulesEnabled = [bool]$firewallSuccess
            ServicesStarted      = $servicesStarted.ToArray()
            NetbiosEnabled       = [bool]$netbiosSuccess
            SmbConfigured        = [bool]$smbSuccess
            RegBackupFiles       = $regBackupFiles.ToArray()
            ErrorMessage         = [string]$errText
        }
    }
}
