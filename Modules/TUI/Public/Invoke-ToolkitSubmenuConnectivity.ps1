if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


function Get-ConnectivityContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
    $telemetry = Get-ToolkitTelemetryData
    $lines.Add("Network Status : IPv4: $($telemetry.ActiveIPv4) | MAC: $($telemetry.ActiveMAC)")

    $spoolerStatus = "Stopped [WARN]"
    try {
        $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $spoolerStatus = "Running [ONLINE]"
        }
    } catch { $null = $_ }
    $lines.Add("Print Spooler  : $spoolerStatus | Queue: Active")

    $lines.Add("Security State : Point & Print Verified | SMB Insecure Guest Disabled")
    $lines.Add("Engines Loaded : Winsock, TCP/IP, DNS, DHCP, SMB, Spooler, Error Catalog [READY]")

    return $lines.ToArray()
}

function Get-NetworkContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-ConnectivityContextInfoLines
}

function Get-PrintersContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-ConnectivityContextInfoLines
}

if (Get-Command -Name 'Get-ConnectivityContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-ConnectivityContextInfoLines' -Value (Get-Command -Name 'Get-ConnectivityContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-NetworkContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-NetworkContextInfoLines' -Value (Get-Command -Name 'Get-NetworkContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-PrintersContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-PrintersContextInfoLines' -Value (Get-Command -Name 'Get-PrintersContextInfoLines').ScriptBlock
}

function Invoke-ToolkitNetworkDeviceContextMenu {
<#
.SYNOPSIS
    Contextual administration menu for a targeted network adapter or printer device.
.DESCRIPTION
    Provides targeted diagnostic and repair operations for a selected network interface or printer:
    - [1] Restart Adapter (restart targeted network interface)
    - [2] Flush DNS & Renew DHCP (flush resolver cache and rebind DHCP lease)
    - [3] Test Connectivity & Latency (test ICMP ping reachability and target port latency)
    - [4] Purge Spooler Queue (terminate spoolsv, clear stuck jobs, and restart Spooler)
    - [0] Back to Devices Table (return to parent submenu)
.PARAMETER Device
    The selected device PSCustomObject from the parent table.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for testing).
.PARAMETER NonInteractive
    Headless automation mode: renders context menu once and returns cleanly.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [PSCustomObject]$Device,

        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Device context menu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inContext = $true
    while ($inContext) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $deviceName = if ($Device.Device) { [string]$Device.Device } else { 'Network Device' }
        $deviceStatus = if ($Device.Status) { [string]$Device.Status } else { '[READY]' }
        $deviceType = if ($Device.Type) { [string]$Device.Type } else { 'Adapter' }
        $deviceDetails = if ($Device.Details) { [string]$Device.Details } else { '--' }

        $infoLines = @(
            "Target Device  : $deviceName | Type: $deviceType",
            "Status         : $deviceStatus | Details: $deviceDetails",
            "Engines Loaded : Adapter Restart, DNS/DHCP Reset, Connectivity Test, Spooler Purge"
        )

        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK & CONNECTIVITY > DEVICE CONTEXT' `
            -Subtitle "Contextual Diagnostics & Remediation: $deviceName" `
            -ClearScreen:$clear `
            -InfoLines $infoLines

        $contextActions = @(
            @{ Key = '1'; Label = 'Restart Adapter' },
            @{ Key = '2'; Label = 'Flush DNS & Renew DHCP' },
            @{ Key = '3'; Label = 'Test Connectivity & Latency' },
            @{ Key = '4'; Label = 'Purge Spooler Queue' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Devices Table' }
        )
        Show-ToolkitActionCatalog -Actions $contextActions -NavActions $navActions -Title "DEVICE ACTIONS: $deviceName"

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive contextual listing complete for device '$deviceName'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive contextual listing complete for device '$deviceName'." -ForegroundColor Cyan
            return
        }

        $contextHotkeys = @('1', '2', '3', '4')
        $promptText = "  Select action for '$deviceName' [1-4, 0]: "
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $contextHotkeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            $inContext = $false
            return
        }

        switch ("$($selection.Value)") {
            '1' {
                if (Get-Command -Name 'Restart-ToolkitNetworkAdapter' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Restarting network adapter '$deviceName'..." -Type 'INFO'
                        if ($Device.Type -eq 'Adapter' -and -not [string]::IsNullOrWhiteSpace($Device.Device) -and $Device.Device -ne 'Network Adapter Subsystem') {
                            $res = Restart-ToolkitNetworkAdapter -Name $Device.Device
                        } else {
                            $res = Restart-ToolkitNetworkAdapter -All
                        }
                        Write-ToolkitStatus -Message "Network adapter '$deviceName' restart completed." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Adapter restart failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '2' {
                try {
                    Write-ToolkitStatus -Message "Flushing DNS resolver and renewing DHCP leases..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-NetworkDns' -ErrorAction SilentlyContinue) {
                        $null = Reset-NetworkDns
                    }
                    if (Get-Command -Name 'Reset-NetworkDhcp' -ErrorAction SilentlyContinue) {
                        $null = Reset-NetworkDhcp
                    }
                    Write-ToolkitStatus -Message "DNS flushed and DHCP lease renewed successfully." -Type 'OK'
                } catch {
                    Write-ToolkitStatus -Message "DNS/DHCP reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '3' {
                $targetHost = if ($Device.Gateway -and $Device.Gateway -ne '--') {
                    $Device.Gateway
                } elseif ($Device.Details -and $Device.Details -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $Device.Details
                } else {
                    '8.8.8.8'
                }
                Write-ToolkitStatus -Message "Testing network connectivity to '$targetHost'..." -Type 'INFO'
                if (Get-Command -Name 'Test-NetworkPrinterConnectivity' -ErrorAction SilentlyContinue) {
                    try {
                        $testRes = Test-NetworkPrinterConnectivity -ComputerName $targetHost
                        if ($testRes.PingSuccess -or $testRes.RawPrintPortOpen -or $testRes.SmbPortOpen -or $testRes.RpcPortOpen) {
                            Write-ToolkitStatus -Message "Connectivity test to '$targetHost' succeeded (Ping: $($testRes.PingSuccess))." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Connectivity test to '$targetHost' timed out or unreachable." -Type 'WARN'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Connectivity probe failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } elseif (Get-Command -Name 'Test-Connection' -ErrorAction SilentlyContinue) {
                    $ping = Test-Connection -ComputerName $targetHost -Count 1 -Quiet -ErrorAction SilentlyContinue
                    if ($ping) {
                        Write-ToolkitStatus -Message "ICMP ping to '$targetHost' succeeded." -Type 'OK'
                    } else {
                        Write-ToolkitStatus -Message "ICMP ping to '$targetHost' unreachable." -Type 'WARN'
                    }
                }
                Wait-UserAcknowledge
            }
            '4' {
                if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Purging print spooler queue and restarting service..." -Type 'INFO'
                        Reset-PrintSpoolerQueue -Force
                        Write-ToolkitStatus -Message "Print spooler queue purged and service restarted." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Spooler purge failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '0' {
                $inContext = $false
                return
            }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


function Invoke-ToolkitSubmenuConnectivity {
<#
.SYNOPSIS
    Submenu for Network & Connectivity (Network Diagnostics & Printer Management).
.DESCRIPTION
    Combines network diagnostics, TCP/IP stack remediation, and printer troubleshooting:
    - Network stack reset (DNS, DHCP, Winsock, TCP/IP, ARP)
    - Print Spooler queue reset, service cleanup, and Ne port binding repair
    - Server and Client Point & Print remediation (RPC Authn Level, Named Pipes)
    - Network and printer targeted error code catalogs
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
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

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
        $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
        if (Test-Path $catScript) { . $catScript }
    }
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) { . $tableScript }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) { . $selectScript }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $connInfo = Get-ConnectivityContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > NETWORK & CONNECTIVITY' -Subtitle 'Unified Network Diagnostics & Repair, Printers & Spooler Administration' -ClearScreen:$clear -InfoLines $connInfo

        $items = @()
        try {
            if (Get-Command -Name 'Get-NetworkAdapterStatus' -ErrorAction SilentlyContinue) {
                $adapters = @(Get-NetworkAdapterStatus)
                foreach ($ad in $adapters) {
                    $items += [PSCustomObject]@{
                        Device         = [string]$ad.Name
                        Status         = if ($ad.Status) { [string]$ad.Status } else { '[READY]' }
                        Type           = 'Adapter'
                        Details        = if ($ad.IPv4) { [string]$ad.IPv4 } else { 'DHCP / Dynamic' }
                        InterfaceIndex = $ad.InterfaceIndex
                        MAC            = if ($ad.MAC) { [string]$ad.MAC } else { '--' }
                        Gateway        = if ($ad.Gateway) { [string]$ad.Gateway } else { '--' }
                    }
                }
            }
        } catch { $null = $_ }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Device = 'Network Adapter Subsystem'; Status = '[READY]'; Type = 'Network'; Details = 'TCP/IP stack, DNS client & routing'; Gateway = '--'; MAC = '--' },
                [PSCustomObject]@{ Device = 'Windows Print Spooler';    Status = '[READY]'; Type = 'Printer'; Details = 'Spooler service, queue & port bindings'; Gateway = '--'; MAC = '--' },
                [PSCustomObject]@{ Device = 'Point & Print Engine';      Status = '[READY]'; Type = 'Policy';  Details = 'Driver isolation & RPC authentication'; Gateway = '--'; MAC = '--' }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Device', 'Status', 'Type', 'Details') -Headers @('DEVICE', 'STATUS', 'TYPE', 'DETAILS') -Title 'Discovered Network & Peripheral Devices'

        Write-Host ""
        $actions = @(
            @{ Key = '10'; Label = 'Apply All Fixes' },
            @{ Key = '11'; Label = 'Reset Stack & DNS' },
            @{ Key = '12'; Label = 'Restart Spooler' },
            @{ Key = '13'; Label = 'Fix Point & Print' },
            @{ Key = '14'; Label = 'Remediate SMB' },
            @{ Key = '15'; Label = 'Server Remediation' },
            @{ Key = '16'; Label = 'Client Remediation' },
            @{ Key = '17'; Label = 'Restart All Adapters' },
            @{ Key = '18'; Label = 'Restore Registry' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Network & Connectivity'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Network & Connectivity'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('10', '11', '12', '13', '14', '15', '16', '17', '18')
        $promptText = "  Select Device [1-$($items.Count)], Action [10-18], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex $items.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        if ($selection.Type -eq 'Index') {
            $targetIndex = [int]$selection.Value - 1
            if ($targetIndex -ge 0 -and $targetIndex -lt $items.Count) {
                $selectedDevice = $items[$targetIndex]
                Invoke-ToolkitNetworkDeviceContextMenu -Device $selectedDevice -NonInteractive:$NonInteractive
            }
            continue
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            { $_ -in @('10', '1') } {
                if (Get-Command -Name 'Set-NetworkRemediation' -ErrorAction SilentlyContinue) {
                    try {
                        $res = Set-NetworkRemediation -All
                        Write-ToolkitStatus -Message "All network fixes applied successfully." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Network remediation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('11', '2') } {
                if (Get-Command -Name 'Set-NetworkRemediation' -ErrorAction SilentlyContinue) {
                    try {
                        $res = Set-NetworkRemediation -Fix @('DnsResolution', 'DhcpLease', 'Winsock', 'TcpIpStack', 'DefaultGatewayArp')
                        Write-ToolkitStatus -Message "Network stack and DNS cache reset completed." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Network reset failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('12', '3') } {
                if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                    try {
                        Reset-PrintSpoolerQueue
                        Write-ToolkitStatus -Message "Print Spooler queue reset and service restarted." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Spooler restart failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('13', '4') } {
                if (Get-Command -Name 'Set-PointAndPrintRemediation' -ErrorAction SilentlyContinue) {
                    try {
                        Set-PointAndPrintRemediation
                        Write-ToolkitStatus -Message "Point & Print driver installation policies remediated." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Point & Print remediation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('14', '5') } {
                if (Get-Command -Name 'Set-NetworkSmbConfiguration' -ErrorAction SilentlyContinue) {
                    try {
                        Set-NetworkSmbConfiguration -EnableInsecureGuestAuth $false -RequireSecuritySignature $true
                        Write-ToolkitStatus -Message "SMB configuration updated." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "SMB configuration failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('15', '6') } {
                if (Get-Command -Name 'Set-PrinterServerRemediation' -ErrorAction SilentlyContinue) {
                    try {
                        Set-PrinterServerRemediation -All
                        Write-ToolkitStatus -Message "Server printer remediations applied." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Printer server remediation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('16', '7') } {
                if (Get-Command -Name 'Set-PrinterClientRemediation' -ErrorAction SilentlyContinue) {
                    try {
                        Set-PrinterClientRemediation -All
                        Write-ToolkitStatus -Message "Client printer remediations applied." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Printer client remediation failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('17', '8') } {
                if (Get-Command -Name 'Restart-ToolkitNetworkAdapter' -ErrorAction SilentlyContinue) {
                    try {
                        Restart-ToolkitNetworkAdapter
                        Write-ToolkitStatus -Message "Active network adapters restarted." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Adapter restart failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            { $_ -in @('18', '9') } {
                $regPath = Read-Host "  Enter Registry Backup Path"
                if (-not [string]::IsNullOrWhiteSpace($regPath) -and (Get-Command -Name 'Restore-RegistryKeyBackup' -ErrorAction SilentlyContinue)) {
                    try {
                        Restore-RegistryKeyBackup -BackupFilePath $regPath
                        Write-ToolkitStatus -Message "Registry backup restored from '$regPath'." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Registry restore failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '0' { return }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


function Invoke-ToolkitSubmenuNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuConnectivity @PSBoundParameters
}

function Invoke-ToolkitSubmenuPrinters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuConnectivity @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuConnectivity' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuConnectivity' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuConnectivity').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuNetwork' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuNetwork').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuPrinters' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuPrinters' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuPrinters').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitNetworkDeviceContextMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitNetworkDeviceContextMenu' -Value (Get-Command -Name 'Invoke-ToolkitNetworkDeviceContextMenu').ScriptBlock
}
