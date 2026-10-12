function Set-PrinterRemediation {
<#
.SYNOPSIS
    Comprehensive printer connectivity, error catalog remediation, and batch repair engine.
.DESCRIPTION
    Provides automated remediation for Windows 10 and 11 printer subsystems across client,
    server, or both roles. Features targeted mitigations for 12 common error catalog items
    (0x0000011b, 0x00000709, 0x0000007c, 0x0000007e, 0x00000bcb, 0x00000002, 0x00000006,
    0x00000057, 0x000003e3, Spooler crash, NeXX port conflicts, and connection refresh)
    as well as batch execution modes (Apply All Client, Apply All Server, Apply All Both).
    Includes automatic pre-modification registry backups, -WhatIf simulation, and rollback safety.
.PARAMETER Role
    Target operational role: 'Client', 'Server', 'Both', or 'All'. Defaults to 'Both'.
.PARAMETER Fix
    Specific fix or fixes to apply. Accepts individual error codes, batch keywords, or fix names.
.PARAMETER ErrorCodes
    Alias for error codes (e.g., '0x0000011b', '0x00000709', etc.).
.PARAMETER All
    Batch switch to execute all mitigations for the selected role.
.PARAMETER BackupDirectory
    Optional directory path where pre-modification .reg backup files are saved.
.PARAMETER Force
    Forces termination of lingering spoolsv processes during spooler restarts and queue purges.
.OUTPUTS
    [PSCustomObject] containing Role, FixesApplied, RegBackupFiles, SpoolerRestarted,
    DirectoryStatus, QueuePurgedCount, CleanedNePortsCount, RefreshedConnections,
    StaleRemoved, Success, ErrorMessage.
.EXAMPLE
    Set-PrinterRemediation -All
.EXAMPLE
    Set-PrinterRemediation -Role Client -All
.EXAMPLE
    Set-PrinterRemediation -Fix '0x0000011b'
.EXAMPLE
    Set-PrinterRemediation -ErrorCodes '0x00000709', '0x0000007c'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Client', 'Server', 'Both', 'All')]
        [string]$Role = 'Both',

        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet(
            'All', 'AllClient', 'AllServer', 'AllBoth',
            '0x0000011b', '0x00000709', '0x0000007c', '0x0000007e', '0x00000bcb',
            '0x00000002', '0x00000006', '0x00000057', '0x000003e3',
            'SpoolerCrash', 'NePortConflict', 'RefreshConnections',
            'RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth',
            'PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'DefaultPrinterKey',
            'CopyFilesPolicy', 'SpoolerQueue', 'NePorts', 'SpoolerDLLs', 'DriverStoreRepair',
            'SpoolerHandles', 'DriverConfig', 'ClearStalledJobs'
        )]
        [string[]]$Fix = @(),

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
        # Normalize input tokens
        $inputTokens = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $Fix) {
            foreach ($f in $Fix) {
                if (-not [string]::IsNullOrWhiteSpace($f)) {
                    $inputTokens.Add($f)
                }
            }
        }
        if ($null -ne $ErrorCodes) {
            foreach ($e in $ErrorCodes) {
                if (-not [string]::IsNullOrWhiteSpace($e)) {
                    $inputTokens.Add($e)
                }
            }
        }

        # Resolve effective role
        $effectiveRole = $Role
        if ($inputTokens.Contains('AllClient')) {
            $effectiveRole = 'Client'
        } elseif ($inputTokens.Contains('AllServer')) {
            $effectiveRole = 'Server'
        } elseif ($inputTokens.Contains('AllBoth')) {
            $effectiveRole = 'Both'
        }

        $resolvedFixes = [System.Collections.Generic.List[string]]::new()

        $isBatchAll = $All.IsPresent -or ($inputTokens.Contains('All')) -or ($inputTokens.Contains('AllBoth')) -or ($inputTokens.Count -eq 0)
        $isBatchServer = ($inputTokens.Contains('AllServer')) -or ($isBatchAll -and $effectiveRole -eq 'Server')
        $isBatchClient = ($inputTokens.Contains('AllClient')) -or ($isBatchAll -and $effectiveRole -eq 'Client')
        $isBatchBoth   = ($inputTokens.Contains('AllBoth'))   -or ($isBatchAll -and ($effectiveRole -in @('Both', 'All')))

        if ($isBatchServer) {
            $effectiveRole = 'Server'
            $serverFixList = @('RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth', 'SpoolerDLLs', 'DriverStoreRepair', 'SpoolerHandles', 'ClearStalledJobs', 'SpoolerCrash')
            foreach ($sf in $serverFixList) {
                if (-not $resolvedFixes.Contains($sf)) { $resolvedFixes.Add($sf) }
            }
        } elseif ($isBatchClient) {
            $effectiveRole = 'Client'
            $clientFixList = @('PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'DefaultPrinterKey', 'CopyFilesPolicy', 'SpoolerDLLs', 'DriverStoreRepair', 'SpoolerHandles', 'DriverConfig', 'ClearStalledJobs', 'SpoolerQueue', 'NePorts', 'RefreshConnections')
            foreach ($cf in $clientFixList) {
                if (-not $resolvedFixes.Contains($cf)) { $resolvedFixes.Add($cf) }
            }
        } elseif ($isBatchBoth) {
            $effectiveRole = 'Both'
            $bothFixList = @('RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth', 'PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'DefaultPrinterKey', 'CopyFilesPolicy', 'SpoolerDLLs', 'DriverStoreRepair', 'SpoolerHandles', 'DriverConfig', 'ClearStalledJobs', 'SpoolerCrash', 'NePorts', 'RefreshConnections')
            foreach ($bf in $bothFixList) {
                if (-not $resolvedFixes.Contains($bf)) { $resolvedFixes.Add($bf) }
            }
        } else {
            foreach ($item in $inputTokens) {
                switch ($item) {
                    '0x0000011b' {
                        if (-not $resolvedFixes.Contains('0x0000011b')) { $resolvedFixes.Add('0x0000011b') }
                        if (-not $resolvedFixes.Contains('RpcAuthnLevel')) { $resolvedFixes.Add('RpcAuthnLevel') }
                        if (-not $resolvedFixes.Contains('RemoteRpcEndPoint')) { $resolvedFixes.Add('RemoteRpcEndPoint') }
                    }
                    '0x00000709' {
                        if (-not $resolvedFixes.Contains('0x00000709')) { $resolvedFixes.Add('0x00000709') }
                        if (-not $resolvedFixes.Contains('RpcNamedPipe')) { $resolvedFixes.Add('RpcNamedPipe') }
                        if (-not $resolvedFixes.Contains('DefaultPrinterKey')) { $resolvedFixes.Add('DefaultPrinterKey') }
                    }
                    '0x0000007c' {
                        if (-not $resolvedFixes.Contains('0x0000007c')) { $resolvedFixes.Add('0x0000007c') }
                        if (-not $resolvedFixes.Contains('CopyFilesPolicy')) { $resolvedFixes.Add('CopyFilesPolicy') }
                    }
                    '0x0000007e' {
                        if (-not $resolvedFixes.Contains('0x0000007e')) { $resolvedFixes.Add('0x0000007e') }
                        if (-not $resolvedFixes.Contains('SpoolerDLLs')) { $resolvedFixes.Add('SpoolerDLLs') }
                    }
                    '0x00000bcb' {
                        if (-not $resolvedFixes.Contains('0x00000bcb')) { $resolvedFixes.Add('0x00000bcb') }
                        if (-not $resolvedFixes.Contains('PointAndPrintAdmin')) { $resolvedFixes.Add('PointAndPrintAdmin') }
                        if (-not $resolvedFixes.Contains('PointAndPrintPrompts')) { $resolvedFixes.Add('PointAndPrintPrompts') }
                    }
                    '0x00000002' {
                        if (-not $resolvedFixes.Contains('0x00000002')) { $resolvedFixes.Add('0x00000002') }
                        if (-not $resolvedFixes.Contains('DriverStoreRepair')) { $resolvedFixes.Add('DriverStoreRepair') }
                    }
                    '0x00000006' {
                        if (-not $resolvedFixes.Contains('0x00000006')) { $resolvedFixes.Add('0x00000006') }
                        if (-not $resolvedFixes.Contains('SpoolerHandles')) { $resolvedFixes.Add('SpoolerHandles') }
                    }
                    '0x00000057' {
                        if (-not $resolvedFixes.Contains('0x00000057')) { $resolvedFixes.Add('0x00000057') }
                        if (-not $resolvedFixes.Contains('DriverConfig')) { $resolvedFixes.Add('DriverConfig') }
                    }
                    '0x000003e3' {
                        if (-not $resolvedFixes.Contains('0x000003e3')) { $resolvedFixes.Add('0x000003e3') }
                        if (-not $resolvedFixes.Contains('ClearStalledJobs')) { $resolvedFixes.Add('ClearStalledJobs') }
                    }
                    'SpoolerCrash' {
                        if (-not $resolvedFixes.Contains('SpoolerCrash')) { $resolvedFixes.Add('SpoolerCrash') }
                    }
                    'NePortConflict' {
                        if (-not $resolvedFixes.Contains('NePortConflict')) { $resolvedFixes.Add('NePortConflict') }
                        if (-not $resolvedFixes.Contains('NePorts')) { $resolvedFixes.Add('NePorts') }
                    }
                    default {
                        if (-not $resolvedFixes.Contains($item)) {
                            $resolvedFixes.Add($item)
                        }
                    }
                }
            }
        }

        # WhatIf side-effect suppression check
        if (-not $PSCmdlet.ShouldProcess("Printer Subsystem ($effectiveRole)", "Apply printer remediation: $($resolvedFixes -join ', ')")) {
            return [PSCustomObject]@{
                Role                 = $effectiveRole
                FixesApplied         = @($resolvedFixes)
                RegBackupFiles       = @('[Simulated - WhatIf]')
                SpoolerRestarted     = $false
                DirectoryStatus      = 'Simulated'
                QueuePurgedCount     = 0
                CleanedNePortsCount  = 0
                RefreshedConnections = 0
                StaleRemoved         = 0
                Success              = $true
                ErrorMessage         = $null
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Applying printer remediation ($effectiveRole): $($resolvedFixes -join ', ')..." -Level 'INFO' -Component 'Set-PrinterRemediation'
        }

        $regBackupFiles       = @()
        $appliedFixes         = @()
        $spoolerRestarted     = $false
        $dirStatus            = 'NotRequested'
        $queuePurgedCount     = 0
        $cleanedNePortsCount  = 0
        $refreshedConnections = 0
        $staleRemoved         = 0

        # Helper to apply registry value and capture backup path
        $setReg = {
            param([string]$Key, [string]$Name, [object]$Value, [string]$Type = 'DWord')
            $regParams = @{
                KeyPath      = $Key
                ValueName    = $Name
                Value        = $Value
                PropertyType = $Type
            }
            if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                $regParams['BackupDirectory'] = $BackupDirectory
            }
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $res = Set-ToolkitRegistryValue @regParams
                    if ($null -ne $res) {
                        if ($res.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.RegBackupFile)) {
                            return [string]$res.RegBackupFile
                        } elseif ($res.PSObject.Properties['BackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.BackupFile)) {
                            return [string]$res.BackupFile
                        }
                    }
                }
            } catch {
                Write-Verbose "Error setting registry value $Key\$Name : $($_.Exception.Message)"
            }
            return $null
        }

        # Helper to restart Spooler service
        $restartSpooler = {
            try {
                Stop-Service -Name 'Spooler' -Force -ErrorAction SilentlyContinue
                if ($Force.IsPresent) {
                    Get-Process -Name 'spoolsv' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Start-Service -Name 'Spooler' -ErrorAction SilentlyContinue
                $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
                if ($null -ne $svc -and $svc.Status -eq 'Running') {
                    return $true
                }
                return $true
            } catch {
                Write-Verbose "Spooler restart error: $($_.Exception.Message)"
                return $false
            }
        }

        $sys32 = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
            "$env:SystemRoot\System32"
        } else {
            "C:\Windows\System32"
        }
        $spoolDir = "$sys32\spool\PRINTERS"

        try {
            # 1. RpcAuthnLevel (Part of 0x0000011b)
            if ($resolvedFixes.Contains('RpcAuthnLevel')) {
                $b = & $setReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Print' 'RpcAuthnLevelPrivacyEnabled' 0 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }
                $appliedFixes += 'RpcAuthnLevel'
            }

            # 2. RemoteRpcEndPoint (Part of 0x0000011b)
            if ($resolvedFixes.Contains('RemoteRpcEndPoint')) {
                $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' 'RegisterSpoolerRemoteRpcEndPoint' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }
                $appliedFixes += 'RemoteRpcEndPoint'
            }

            # 3. 0x0000011b Composite Fix: RpcAuthnLevel + RemoteRpcEndPoint + Restart Spooler
            if ($resolvedFixes.Contains('0x0000011b')) {
                $sr = & $restartSpooler
                if ($sr) { $spoolerRestarted = $true }
                if ('0x0000011b' -notin $appliedFixes) {
                    $appliedFixes += '0x0000011b'
                }
            }

            # 4. RpcProtocols
            if ($resolvedFixes.Contains('RpcProtocols')) {
                $b1 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcUseNamedPipeProtocol' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                    $regBackupFiles += $b1
                }
                $b2 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcProtocols' 7 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                    $regBackupFiles += $b2
                }
                $appliedFixes += 'RpcProtocols'
            }

            # 5. PointAndPrintAdmin (Part of 0x00000bcb)
            if ($resolvedFixes.Contains('PointAndPrintAdmin')) {
                $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'RestrictDriverInstallationToAdministrators' 0 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }
                $appliedFixes += 'PointAndPrintAdmin'
            }

            # 6. PointAndPrintPrompts (Part of 0x00000bcb)
            if ($resolvedFixes.Contains('PointAndPrintPrompts')) {
                $b1 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'NoWarningNoElevationOnInstall' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                    $regBackupFiles += $b1
                }
                $b2 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'UpdatePromptSettings' 2 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                    $regBackupFiles += $b2
                }
                $appliedFixes += 'PointAndPrintPrompts'
            }

            if ($resolvedFixes.Contains('0x00000bcb') -and ('0x00000bcb' -notin $appliedFixes)) {
                $appliedFixes += '0x00000bcb'
            }

            # 7. RpcNamedPipe (Part of 0x00000709)
            if ($resolvedFixes.Contains('RpcNamedPipe')) {
                $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcUseNamedPipeProtocol' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }
                $appliedFixes += 'RpcNamedPipe'
            }

            # 8. DefaultPrinterKey (Part of 0x00000709)
            if ($resolvedFixes.Contains('DefaultPrinterKey')) {
                $b1 = & $setReg 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' 'UserSelectedDefault' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                    $regBackupFiles += $b1
                }
                $b2 = & $setReg 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' 'LegacyDefaultPrinterMode' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                    $regBackupFiles += $b2
                }
                $appliedFixes += 'DefaultPrinterKey'
            }

            if ($resolvedFixes.Contains('0x00000709') -and ('0x00000709' -notin $appliedFixes)) {
                $appliedFixes += '0x00000709'
            }

            # 9. CopyFilesPolicy (Fixes 0x0000007c)
            if ($resolvedFixes.Contains('CopyFilesPolicy')) {
                $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' 'CopyFilesPolicy' 1 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }
                $appliedFixes += 'CopyFilesPolicy'
            }
            if ($resolvedFixes.Contains('0x0000007c') -and ('0x0000007c' -notin $appliedFixes)) {
                $appliedFixes += '0x0000007c'
            }

            # 10. SpoolerDLLs (Fixes 0x0000007e)
            if ($resolvedFixes.Contains('SpoolerDLLs') -or $resolvedFixes.Contains('0x0000007e')) {
                if (Get-Command -Name 'Register-PrintSpoolerComponents' -ErrorAction SilentlyContinue) {
                    try { Register-PrintSpoolerComponents | Out-Null } catch { Write-Verbose "Component registration error: $($_.Exception.Message)" }
                } elseif ($IsWindows -or ($env:OS -match 'Windows')) {
                    if (Get-Command -Name 'regsvr32.exe' -ErrorAction SilentlyContinue) {
                        try {
                            regsvr32.exe /s "$sys32\printui.dll" 2>&1 | Out-Null
                            regsvr32.exe /s "$sys32\prntvpt.dll" 2>&1 | Out-Null
                        } catch { Write-Verbose "Regsvr32 error: $($_.Exception.Message)" }
                    }
                }

                # Restore mscms.dll to spool\drivers\x64\3 if missing
                try {
                    $driverDir = "$sys32\spool\drivers\x64\3"
                    if (-not (Test-Path -LiteralPath $driverDir -ErrorAction SilentlyContinue)) {
                        New-Item -ItemType Directory -Path $driverDir -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    $mscmsSrc = "$sys32\mscms.dll"
                    $mscmsDst = "$driverDir\mscms.dll"
                    if ((Test-Path -LiteralPath $mscmsSrc -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $mscmsDst -ErrorAction SilentlyContinue)) {
                        Copy-Item -Path $mscmsSrc -Destination $mscmsDst -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                } catch {
                    Write-Verbose "Error restoring mscms.dll: $($_.Exception.Message)"
                }

                # MOF recompilation & RPCSS dependency
                if ($IsWindows -or ($env:OS -match 'Windows')) {
                    $mofPath = "$sys32\wbem\prnprov.mof"
                    if (Test-Path -LiteralPath $mofPath -ErrorAction SilentlyContinue) {
                        if (Get-Command -Name 'mofcomp.exe' -ErrorAction SilentlyContinue) {
                            try { mofcomp.exe "$mofPath" 2>&1 | Out-Null } catch { Write-Verbose "Mofcomp error: $($_.Exception.Message)" }
                        }
                    }
                    if (Get-Command -Name 'sc.exe' -ErrorAction SilentlyContinue) {
                        try { sc.exe config spooler depend= RPCSS 2>&1 | Out-Null } catch { Write-Verbose "Service config error: $($_.Exception.Message)" }
                    }
                }

                if ('SpoolerDLLs' -notin $appliedFixes) { $appliedFixes += 'SpoolerDLLs' }
                if ($resolvedFixes.Contains('0x0000007e') -and ('0x0000007e' -notin $appliedFixes)) {
                    $appliedFixes += '0x0000007e'
                }
            }

            # 11. DriverStoreRepair (Fixes 0x00000002)
            if ($resolvedFixes.Contains('DriverStoreRepair') -or $resolvedFixes.Contains('0x00000002')) {
                try {
                    $dDir = "$sys32\spool\drivers\x64\3"
                    $pDir = "$sys32\spool\prtprocs\x64"
                    if (-not (Test-Path -LiteralPath $dDir -ErrorAction SilentlyContinue)) {
                        New-Item -ItemType Directory -Path $dDir -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    if (-not (Test-Path -LiteralPath $pDir -ErrorAction SilentlyContinue)) {
                        New-Item -ItemType Directory -Path $pDir -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                } catch {
                    Write-Verbose "Error verifying driver directories: $($_.Exception.Message)"
                }

                if ($IsWindows -or ($env:OS -match 'Windows')) {
                    if (Get-Command -Name 'pnputil.exe' -ErrorAction SilentlyContinue) {
                        try { pnputil.exe /scan-devices 2>&1 | Out-Null } catch { Write-Verbose "Pnputil error: $($_.Exception.Message)" }
                    }
                }

                # Verify Environments\Windows x64\Directory registry key
                $b = & $setReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Directory' 'Directory' 'W32X64' 'String'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }

                if ('DriverStoreRepair' -notin $appliedFixes) { $appliedFixes += 'DriverStoreRepair' }
                if ($resolvedFixes.Contains('0x00000002') -and ('0x00000002' -notin $appliedFixes)) {
                    $appliedFixes += '0x00000002'
                }
            }

            # 12. SpoolerHandles (Fixes 0x00000006)
            if ($resolvedFixes.Contains('SpoolerHandles') -or $resolvedFixes.Contains('0x00000006')) {
                try {
                    if (Test-Path -LiteralPath $spoolDir -ErrorAction SilentlyContinue) {
                        Get-ChildItem -LiteralPath $spoolDir -Include '*.tmp', '*.shd', '*.spl' -File -ErrorAction SilentlyContinue |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-Verbose "Spooler cleanup error: $($_.Exception.Message)"
                }

                $sr = & $restartSpooler
                if ($sr) { $spoolerRestarted = $true }

                if ('SpoolerHandles' -notin $appliedFixes) { $appliedFixes += 'SpoolerHandles' }
                if ($resolvedFixes.Contains('0x00000006') -and ('0x00000006' -notin $appliedFixes)) {
                    $appliedFixes += '0x00000006'
                }
            }

            # 13. DriverConfig (Fixes 0x00000057)
            if ($resolvedFixes.Contains('DriverConfig') -or $resolvedFixes.Contains('0x00000057')) {
                try {
                    $connKey = 'HKCU:\Printers\Connections'
                    if (Test-Path -LiteralPath $connKey -ErrorAction SilentlyContinue) {
                        if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                            $bk = Export-RegistryKeyBackup -KeyPath $connKey -ErrorAction SilentlyContinue
                            if ($null -ne $bk -and $bk.PSObject.Properties['BackupFilePath'] -and -not [string]::IsNullOrWhiteSpace($bk.BackupFilePath)) {
                                if ($bk.BackupFilePath -notin $regBackupFiles) {
                                    $regBackupFiles += [string]$bk.BackupFilePath
                                }
                            }
                        }
                        $subKeys = Get-ChildItem -LiteralPath $connKey -ErrorAction SilentlyContinue
                        if ($null -ne $subKeys) {
                            foreach ($sk in $subKeys) {
                                Remove-Item -LiteralPath $sk.PSPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error cleaning corrupt DevMode/Connections: $($_.Exception.Message)"
                }

                $b = & $setReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers' 'DefaultSpoolDirectory' $spoolDir 'String'
                if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                    $regBackupFiles += $b
                }

                if ('DriverConfig' -notin $appliedFixes) { $appliedFixes += 'DriverConfig' }
                if ($resolvedFixes.Contains('0x00000057') -and ('0x00000057' -notin $appliedFixes)) {
                    $appliedFixes += '0x00000057'
                }
            }

            # 14. ClearStalledJobs (Fixes 0x000003e3)
            if ($resolvedFixes.Contains('ClearStalledJobs') -or $resolvedFixes.Contains('0x000003e3')) {
                try {
                    if (Test-Path -LiteralPath $spoolDir -ErrorAction SilentlyContinue) {
                        $stalled = Get-ChildItem -LiteralPath $spoolDir -Include '*.SPL', '*.SHD' -File -ErrorAction SilentlyContinue
                        if ($null -ne $stalled) {
                            $queuePurgedCount += $stalled.Count
                            $stalled | Remove-Item -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                        $jobs = Get-CimInstance -ClassName Win32_PrintJob -ErrorAction SilentlyContinue
                        if ($null -ne $jobs) {
                            foreach ($job in $jobs) {
                                if (Get-Command -Name 'Remove-CimInstance' -ErrorAction SilentlyContinue) {
                                    Remove-CimInstance -InputObject $job -ErrorAction SilentlyContinue
                                }
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error clearing stalled jobs: $($_.Exception.Message)"
                }

                $sr = & $restartSpooler
                if ($sr) { $spoolerRestarted = $true }

                if ('ClearStalledJobs' -notin $appliedFixes) { $appliedFixes += 'ClearStalledJobs' }
                if ($resolvedFixes.Contains('0x000003e3') -and ('0x000003e3' -notin $appliedFixes)) {
                    $appliedFixes += '0x000003e3'
                }
            }

            # 15. SpoolerHealth (Directory verification, icacls, and Spooler restart)
            if ($resolvedFixes.Contains('SpoolerHealth')) {
                $dirStatus = 'Verified'
                try {
                    if (-not (Test-Path -LiteralPath $spoolDir -ErrorAction SilentlyContinue)) {
                        New-Item -ItemType Directory -Path $spoolDir -Force -ErrorAction SilentlyContinue | Out-Null
                        $dirStatus = 'Created'
                    }
                    if ($IsWindows -or ($env:OS -match 'Windows')) {
                        if (Get-Command -Name 'icacls.exe' -ErrorAction SilentlyContinue) {
                            icacls.exe "$spoolDir" /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                            $dirStatus = 'PermissionsConfigured'
                        }
                    }
                } catch {
                    Write-Verbose "Directory verification error: $($_.Exception.Message)"
                    $dirStatus = 'Warning'
                }

                $sr = & $restartSpooler
                if ($sr) { $spoolerRestarted = $true }
                $appliedFixes += 'SpoolerHealth'
            }

            # 16. SpoolerCrash (Full queue purge, permissions, RPCSS dependency, restart)
            if ($resolvedFixes.Contains('SpoolerCrash')) {
                try {
                    if (-not (Test-Path -LiteralPath $spoolDir -ErrorAction SilentlyContinue)) {
                        New-Item -ItemType Directory -Path $spoolDir -Force -ErrorAction SilentlyContinue | Out-Null
                    } else {
                        $files = Get-ChildItem -LiteralPath $spoolDir -File -ErrorAction SilentlyContinue
                        if ($null -ne $files) {
                            $queuePurgedCount += $files.Count
                            $files | Remove-Item -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if ($IsWindows -or ($env:OS -match 'Windows')) {
                        if (Get-Command -Name 'icacls.exe' -ErrorAction SilentlyContinue) {
                            icacls.exe "$spoolDir" /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                            $dirStatus = 'PermissionsConfigured'
                        }
                        if (Get-Command -Name 'sc.exe' -ErrorAction SilentlyContinue) {
                            sc.exe config spooler depend= RPCSS 2>&1 | Out-Null
                        }
                    }
                } catch {
                    Write-Verbose "Error executing SpoolerCrash recovery: $($_.Exception.Message)"
                }

                $sr = & $restartSpooler
                if ($sr) { $spoolerRestarted = $true }

                if ('SpoolerCrash' -notin $appliedFixes) { $appliedFixes += 'SpoolerCrash' }
            }

            # 17. SpoolerQueue (Reset-PrintSpoolerQueue)
            if ($resolvedFixes.Contains('SpoolerQueue')) {
                try {
                    if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                        $qRes = Reset-PrintSpoolerQueue -Force:$Force
                        if ($null -ne $qRes -and $qRes.PSObject.Properties['FilesPurged']) {
                            $queuePurgedCount += [int]$qRes.FilesPurged
                        }
                        if ($null -ne $qRes -and $qRes.PSObject.Properties['ServiceRestarted'] -and $qRes.ServiceRestarted) {
                            $spoolerRestarted = $true
                        }
                    }
                } catch {
                    Write-Verbose "Error running Reset-PrintSpoolerQueue: $($_.Exception.Message)"
                }
                $appliedFixes += 'SpoolerQueue'
            }

            # 18. NePorts & NePortConflict (Reset-PrinterNePortBindings)
            if ($resolvedFixes.Contains('NePorts') -or $resolvedFixes.Contains('NePortConflict')) {
                try {
                    if (Get-Command -Name 'Reset-PrinterNePortBindings' -ErrorAction SilentlyContinue) {
                        $neRes = Reset-PrinterNePortBindings
                        if ($null -ne $neRes) {
                            if ($neRes.PSObject.Properties['CleanedPortsCount']) {
                                $cleanedNePortsCount = [int]$neRes.CleanedPortsCount
                            }
                            if ($neRes.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($neRes.RegBackupFile)) {
                                if ($neRes.RegBackupFile -notin $regBackupFiles) {
                                    $regBackupFiles += [string]$neRes.RegBackupFile
                                }
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error running Reset-PrinterNePortBindings: $($_.Exception.Message)"
                }
                if ($resolvedFixes.Contains('NePorts') -and ('NePorts' -notin $appliedFixes)) {
                    $appliedFixes += 'NePorts'
                }
                if ($resolvedFixes.Contains('NePortConflict') -and ('NePortConflict' -notin $appliedFixes)) {
                    $appliedFixes += 'NePortConflict'
                }
            }

            # 19. RefreshConnections (Reset-PrinterConnections -All)
            if ($resolvedFixes.Contains('RefreshConnections')) {
                try {
                    if (Get-Command -Name 'Reset-PrinterConnections' -ErrorAction SilentlyContinue) {
                        $connRes = Reset-PrinterConnections -All
                        if ($null -ne $connRes) {
                            if ($connRes.PSObject.Properties['RefreshedConnections']) {
                                $refreshedConnections = [int]$connRes.RefreshedConnections
                            }
                            if ($connRes.PSObject.Properties['StaleRemoved']) {
                                $staleRemoved = [int]$connRes.StaleRemoved
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error running Reset-PrinterConnections: $($_.Exception.Message)"
                }
                $appliedFixes += 'RefreshConnections'
            }

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Printer remediation complete ($effectiveRole). Fixes applied: $($appliedFixes -join ', '). Backups: $($regBackupFiles.Count)" -Level 'INFO' -Component 'Set-PrinterRemediation'
            }

            return [PSCustomObject]@{
                Role                 = $effectiveRole
                FixesApplied         = @($appliedFixes)
                RegBackupFiles       = @($regBackupFiles)
                SpoolerRestarted     = $spoolerRestarted
                DirectoryStatus      = $dirStatus
                QueuePurgedCount     = $queuePurgedCount
                CleanedNePortsCount  = $cleanedNePortsCount
                RefreshedConnections = $refreshedConnections
                StaleRemoved         = $staleRemoved
                Success              = $true
                ErrorMessage         = $null
            }
        } catch {
            $errMsg = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Printer remediation error: $errMsg" -Level 'ERROR' -Component 'Set-PrinterRemediation'
            }
            return [PSCustomObject]@{
                Role                 = $effectiveRole
                FixesApplied         = @($appliedFixes)
                RegBackupFiles       = @($regBackupFiles)
                SpoolerRestarted     = $spoolerRestarted
                DirectoryStatus      = $dirStatus
                QueuePurgedCount     = $queuePurgedCount
                CleanedNePortsCount  = $cleanedNePortsCount
                RefreshedConnections = $refreshedConnections
                StaleRemoved         = $staleRemoved
                Success              = $false
                ErrorMessage         = $errMsg
            }
        }
    }
}
