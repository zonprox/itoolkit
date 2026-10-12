if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-NetworkContextInfoLines {
<#
.SYNOPSIS
    Gathers network configuration telemetry for the TUI header status panel.
#>
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. IPv4 Address & Interface
    $ipStr = "-- [NO CONNECTION]"
    try {
        if (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue) {
            $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
            foreach ($cfg in $configs) {
                if ($null -ne $cfg -and $cfg.IPv4Address -and $cfg.IPv4Address.IPAddress) {
                    $ipVal = [string]($cfg.IPv4Address.IPAddress -join ', ')
                    $alias = if ($cfg.InterfaceAlias) { $cfg.InterfaceAlias } else { 'Adapter' }
                    $ipStr = "$ipVal ($alias)"
                    break
                }
            }
        }
        elseif (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
            $cfgs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" -ErrorAction SilentlyContinue)
            if ($cfgs.Count -gt 0 -and $cfgs[0].IPAddress) {
                $v4 = @($cfgs[0].IPAddress) | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
                if ($v4.Count -gt 0) {
                    $ipStr = "$($v4 -join ', ') (CIM Adapter)"
                }
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("IPv4 Address   : $ipStr")

    # 2. Default Gateway & DNS
    $gwStr = "--"
    $dnsStr = "--"
    try {
        if (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue) {
            $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
            foreach ($cfg in $configs) {
                if ($null -ne $cfg -and $cfg.IPv4DefaultGateway -and $cfg.IPv4DefaultGateway.NextHop) {
                    $gwStr = [string]($cfg.IPv4DefaultGateway.NextHop -join ', ')
                }
                if ($null -ne $cfg -and $cfg.DnsServer -and $cfg.DnsServer.ServerAddresses) {
                    $dnsStr = [string]($cfg.DnsServer.ServerAddresses -join ', ')
                }
                if ($gwStr -ne '--' -or $dnsStr -ne '--') {
                    break
                }
            }
        }
        elseif (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
            $cfgs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" -ErrorAction SilentlyContinue)
            if ($cfgs.Count -gt 0) {
                if ($cfgs[0].DefaultIPGateway) {
                    $gwList = @($cfgs[0].DefaultIPGateway) | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
                    if ($gwList.Count -gt 0) {
                        $gwStr = $gwList -join ', '
                    }
                }
                if ($cfgs[0].DNSServerSearchOrder) {
                    $dnsStr = $cfgs[0].DNSServerSearchOrder -join ', '
                }
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Default Gateway: $gwStr | DNS: $dnsStr")

    # 3. Proxy Status & Network Profile
    $proxyStatus = "DIRECT (Disabled)"
    try {
        $regP = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if (Test-Path $regP) {
            $prop = Get-ItemProperty -Path $regP -ErrorAction SilentlyContinue
            if ($null -ne $prop -and $prop.ProxyEnable -eq 1) {
                $server = if ($prop.ProxyServer) { $prop.ProxyServer } else { 'Configured' }
                $proxyStatus = "Enabled ($server)"
            }
        }
    }
    catch {
        $null = $_
    }

    $profileCat = "Private"
    try {
        if (Get-Command -Name 'Get-NetConnectionProfile' -ErrorAction SilentlyContinue) {
            $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
            if ($null -ne $profiles -and $profiles.Count -gt 0 -and $profiles[0].NetworkCategory) {
                $profileCat = [string]$profiles[0].NetworkCategory
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Proxy Status   : $proxyStatus | Network Profile: $profileCat")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-NetworkContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-NetworkContextInfoLines' -Value (Get-Command -Name 'Get-NetworkContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuNetwork {
<#
.SYNOPSIS
    Submenu for Network Diagnostics & Repair with item-centric UI/UX.
.DESCRIPTION
    Presents network adapter telemetry, Error Code Catalog (0x80070035, DNS,
    DHCP, ARP, Winsock, TCP/IP, NLA, Proxy, Adapter Reset), batch 'Apply All Network Fixes',
    and registry rollback capabilities.
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately.
.PARAMETER NonInteractive
    Switch to run in headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Optional menu recursion depth.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    # Ensure UI rendering helpers are dot-sourced
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    # Ensure Network module cmdlets are loaded
    if (-not (Get-Command -Name 'Get-NetworkAdapterStatus' -ErrorAction SilentlyContinue)) {
        $adapterScript = Join-Path $PSScriptRoot '../../Network/Public/Get-NetworkAdapterStatus.ps1'
        if (Test-Path $adapterScript) {
            . $adapterScript
        }
    }
    if (-not (Get-Command -Name 'Set-NetworkRemediation' -ErrorAction SilentlyContinue)) {
        $remScript = Join-Path $PSScriptRoot '../../Network/Public/Set-NetworkRemediation.ps1'
        if (Test-Path $remScript) {
            . $remScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $adapters = @()
        try {
            if (Get-Command -Name 'Get-NetworkAdapterStatus' -ErrorAction SilentlyContinue) {
                $adapters = @(Get-NetworkAdapterStatus)
            }
        }
        catch {
            Write-ToolkitStatus -Message "Failed to enumerate network adapters: $($_.Exception.Message)" -Type 'WARN'
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $networkInfo = Get-NetworkContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK DIAGNOSTICS & REPAIR' -Subtitle 'Network Error Code Catalog, Stack Reset & Diagnostics' -ClearScreen:$clear -InfoLines $networkInfo

        Show-ToolkitItemTable -Items $adapters -Columns @('Name', 'Status', 'IPv4', 'Gateway', 'MAC') -Headers @('NAME', 'STATUS', 'IPV4', 'GATEWAY', 'MAC') -Title 'Detected Network Adapters'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'A'; Label = 'Apply All Network Fixes' },
            @{ Key = 'F'; Label = 'Error Code Catalog' },
            @{ Key = 'U'; Label = 'Rollback Registry' },
            @{ Key = 'D'; Label = 'Flush & Re-register DNS' },
            @{ Key = 'H'; Label = 'Release & Renew DHCP' },
            @{ Key = 'W'; Label = 'Reset Winsock Catalog' },
            @{ Key = 'T'; Label = 'Reset TCP/IP Stack' },
            @{ Key = 'G'; Label = 'Flush ARP Cache' },
            @{ Key = 'S'; Label = 'SMB & Sharing Remediation' },
            @{ Key = 'P'; Label = 'Reset Proxy & WPAD' },
            @{ Key = 'R'; Label = 'Restart Network Adapter' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Exit Console' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Network Diagnostics & Repair'." -Type 'INFO'
            return
        }

        $validKeys = @('A', 'F', 'U', 'D', 'H', 'W', 'T', 'G', 'S', 'P', 'R', 'B', 'Q')
        $promptText = if ($adapters.Count -gt 0) { "  Select item [1-$($adapters.Count)] or action" } else { "  Select action [A, F, U, D, H, W, T, G, S, P, R, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $adapters.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'A' {
                    if (Get-Command -Name 'Set-NetworkRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-NetworkRemediation -All
                            if ($null -ne $res -and $res.Success) {
                                Write-ToolkitStatus -Message "All network fixes applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Network remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply network fixes: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-NetworkRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'F' {
                    Write-Host ""
                    Write-Host "  Select Network Error Remediation from Catalog:" -ForegroundColor Cyan
                    Write-Host "  [1] 0x80070035 / 0x80070043: Network Path Not Found (Discovery, SMB Signing & Guest Auth)"
                    Write-Host "  [2] DNS Resolution Failure ('DNS Server Not Responding' / Flush & Register DNS)"
                    Write-Host "  [3] APIPA / DHCP Failure (169.254.x.x / Release & Renew Leases)"
                    Write-Host "  [4] Default Gateway Unavailable / ARP Corruption (Flush ARP & Route Cache)"
                    Write-Host "  [5] Winsock Corruption (Socket Error 10013 / 10054 / Reset Winsock Catalog)"
                    Write-Host "  [6] TCP/IP Stack Corruption (Reset IP & TCP Stack)"
                    Write-Host "  [7] NLA Stuck / Unidentified Network (Restart NlaSvc/netprofm, Set Private Profile)"
                    Write-Host "  [8] Proxy / WPAD Misconfiguration ('No Internet, Secured' / Reset WinHTTP & User Proxy)"
                    Write-Host "  [9] Adapter Reset (Restart Physical / Virtual Network Adapters via CIM)"
                    Write-Host "  [B] Back to Network Menu"
                    $fChoice = Read-ToolkitMenuChoice -Prompt 'Select Error Remediation' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'B') -Default 'B'
                    if (-not [string]::IsNullOrWhiteSpace($fChoice) -and $fChoice.ToUpperInvariant() -ne 'B') {
                        try {
                            switch ($fChoice) {
                                '1' {
                                    $res = Set-NetworkRemediation -Fix 'SmbConfig'
                                    Write-ToolkitStatus -Message "Applied fix: SMB, Network Discovery & NetBIOS (0x80070035)." -Type 'OK'
                                }
                                '2' {
                                    $res = Set-NetworkRemediation -Fix 'DnsResolution'
                                    Write-ToolkitStatus -Message "Applied fix: Flush & Re-register DNS." -Type 'OK'
                                }
                                '3' {
                                    $res = Set-NetworkRemediation -Fix 'DhcpLease'
                                    Write-ToolkitStatus -Message "Applied fix: Release & Renew DHCP Leases." -Type 'OK'
                                }
                                '4' {
                                    $res = Set-NetworkRemediation -Fix 'DefaultGatewayArp'
                                    Write-ToolkitStatus -Message "Applied fix: Flush ARP Cache & Destination Cache." -Type 'OK'
                                }
                                '5' {
                                    $res = Set-NetworkRemediation -Fix 'Winsock'
                                    Write-ToolkitStatus -Message "Applied fix: Reset Winsock Catalog." -Type 'OK'
                                }
                                '6' {
                                    $res = Set-NetworkRemediation -Fix 'TcpIpStack'
                                    Write-ToolkitStatus -Message "Applied fix: Reset TCP/IP Protocol Stack." -Type 'OK'
                                }
                                '7' {
                                    $res = Set-NetworkRemediation -Fix 'NlaService'
                                    Write-ToolkitStatus -Message "Applied fix: Restart NLA Services & Set Private Profile." -Type 'OK'
                                }
                                '8' {
                                    $res = Set-NetworkRemediation -Fix 'ProxyMisconfig'
                                    Write-ToolkitStatus -Message "Applied fix: Reset WinHTTP Proxy & Clear User Proxy." -Type 'OK'
                                }
                                '9' {
                                    $res = Set-NetworkRemediation -Fix 'AdapterReset'
                                    Write-ToolkitStatus -Message "Applied fix: Restart Network Adapters." -Type 'OK'
                                }
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply fix: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'U' {
                    $regFile = Read-Host "  Enter registry backup .reg file path (or press Enter to search default backup folder)"
                    if ([string]::IsNullOrWhiteSpace($regFile)) {
                        $searchDirs = @('C:\Backups\Registry', "$env:TEMP\IToolkit_RegistryBackups", "$env:TEMP")
                        $foundFiles = @()
                        foreach ($sDir in $searchDirs) {
                            if (Test-Path -LiteralPath $sDir) {
                                $foundFiles += @(Get-ChildItem -LiteralPath $sDir -Filter '*.reg' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                            }
                        }
                        if ($foundFiles.Count -gt 0) {
                            $latest = $foundFiles[0].FullName
                            Write-Host "  Found recent backup: $latest" -ForegroundColor Cyan
                            $confirm = Read-Host "  Restore this backup? [Y/N] (Default: Y)"
                            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm.ToUpperInvariant() -eq 'Y') {
                                $regFile = $latest
                            }
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($regFile)) {
                        if (Get-Command -Name 'Restore-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                            try {
                                $success = Restore-RegistryKeyBackup -BackupFilePath $regFile
                                if ($success) {
                                    Write-ToolkitStatus -Message "Registry restored successfully from '$regFile'." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Registry restore failed for '$regFile'." -Type 'FAIL'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Rollback error: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Restore-RegistryKeyBackup command not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "No registry backup file selected. Rollback cancelled." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                'D' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'DnsResolution'
                        Write-ToolkitStatus -Message "DNS cache flushed and re-registered successfully." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to flush DNS: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'H' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'DhcpLease'
                        Write-ToolkitStatus -Message "DHCP leases released, renewed, and service restarted." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to renew DHCP: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'W' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'Winsock'
                        Write-ToolkitStatus -Message "Winsock catalog reset successfully (Reboot recommended)." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to reset Winsock: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'T' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'TcpIpStack'
                        Write-ToolkitStatus -Message "TCP/IP stack reset successfully (Reboot recommended)." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to reset TCP/IP: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'G' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'DefaultGatewayArp'
                        Write-ToolkitStatus -Message "ARP neighbor cache and destination route cache flushed." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to flush ARP cache: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'SmbConfig'
                        Write-ToolkitStatus -Message "SMB, Network Discovery, and NetBIOS remediations applied." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to apply SMB remediations: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'P' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'ProxyMisconfig'
                        Write-ToolkitStatus -Message "WinHTTP proxy reset and user proxy overrides cleared." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to reset proxy: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
                'R' {
                    try {
                        $res = Set-NetworkRemediation -Fix 'AdapterReset'
                        Write-ToolkitStatus -Message "Network adapters restarted successfully." -Type 'OK'
                    }
                    catch {
                        Write-ToolkitStatus -Message "Failed to restart adapters: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value - 1
            if ($idx -ge 0 -and $idx -lt $adapters.Count) {
                $targetAdapter = $adapters[$idx]
                Write-Host ""
                Write-Host "  Target Adapter: $($targetAdapter.Name) [Status: $($targetAdapter.Status)]" -ForegroundColor Cyan
                Write-Host "  [1] Restart Adapter"
                Write-Host "  [2] Renew DHCP on Adapter"
                Write-Host "  [3] Adapter Telemetry Details"
                Write-Host "  [B] Back"
                $subChoice = Read-ToolkitMenuChoice -Prompt 'Select Adapter Action' -ValidKeys @('1', '2', '3', 'B') -Default 'B'
                if (-not [string]::IsNullOrWhiteSpace($subChoice) -and $subChoice.ToUpperInvariant() -ne 'B') {
                    try {
                        switch ($subChoice) {
                            '1' {
                                if (Get-Command -Name 'Restart-ToolkitNetworkAdapter' -ErrorAction SilentlyContinue) {
                                    $res = Restart-ToolkitNetworkAdapter -Name $targetAdapter.Name
                                    Write-ToolkitStatus -Message "Adapter '$($targetAdapter.Name)' restarted." -Type 'OK'
                                }
                            }
                            '2' {
                                if (Get-Command -Name 'Reset-NetworkDhcp' -ErrorAction SilentlyContinue) {
                                    $res = Reset-NetworkDhcp
                                    Write-ToolkitStatus -Message "DHCP renewed for adapter '$($targetAdapter.Name)'." -Type 'OK'
                                }
                            }
                            '3' {
                                Write-Host ""
                                Write-Host "  --- Adapter Telemetry ---" -ForegroundColor Yellow
                                Write-Host "  Name           : $($targetAdapter.Name)"
                                Write-Host "  Status         : $($targetAdapter.Status)"
                                Write-Host "  IPv4           : $($targetAdapter.IPv4)"
                                Write-Host "  Gateway        : $($targetAdapter.Gateway)"
                                Write-Host "  MAC Address    : $($targetAdapter.MAC)"
                                Write-Host "  Interface Index: $($targetAdapter.InterfaceIndex)"
                            }
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "Adapter operation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                    Wait-UserAcknowledge
                }
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuNetwork' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork').ScriptBlock
}
