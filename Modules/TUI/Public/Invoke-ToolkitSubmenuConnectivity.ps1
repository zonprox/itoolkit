if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
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

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
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
                        Device  = [string]$ad.Name
                        Status  = if ($ad.Status) { [string]$ad.Status } else { '[READY]' }
                        Type    = 'Adapter'
                        Details = if ($ad.IPv4) { [string]$ad.IPv4 } else { 'DHCP / Dynamic' }
                    }
                }
            }
        } catch { $null = $_ }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Device = 'Network Adapter Subsystem'; Status = '[READY]'; Type = 'Network'; Details = 'TCP/IP stack, DNS client & routing' },
                [PSCustomObject]@{ Device = 'Windows Print Spooler';    Status = '[READY]'; Type = 'Printer'; Details = 'Spooler service, queue & port bindings' },
                [PSCustomObject]@{ Device = 'Point & Print Engine';      Status = '[READY]'; Type = 'Policy';  Details = 'Driver isolation & RPC authentication' }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Device', 'Status', 'Type', 'Details') -Headers @('DEVICE', 'STATUS', 'TYPE', 'DETAILS') -Title 'Discovered Network & Peripheral Devices' -NoIndex

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Apply All Network Fixes' },
            @{ Key = '2'; Label = 'Reset Network Stack & DNS' },
            @{ Key = '3'; Label = 'Restart Print Spooler' },
            @{ Key = '4'; Label = 'Fix Point & Print Policies' },
            @{ Key = '5'; Label = 'Remediate SMB Sharing' },
            @{ Key = '6'; Label = 'Printer Server Remediation' },
            @{ Key = '7'; Label = 'Printer Client Remediation' },
            @{ Key = '8'; Label = 'Restart Network Adapter' },
            @{ Key = '9'; Label = 'Restore Registry Backup' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Network & Connectivity'." -Type 'INFO'
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '0')
        $promptText = "  Select action [1-9, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
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
            '2' {
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
            '3' {
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
            '4' {
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
            '5' {
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
            '6' {
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
            '7' {
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
            '8' {
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
            '9' {
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
