function Uninstall-OfficeSuiteCleanly {
<#
.SYNOPSIS
    Performs a native pure-PowerShell deep uninstallation and scrubbing of Microsoft Office.
.DESCRIPTION
    Executes a comprehensive 6-phase pipeline to scrub Microsoft Office (2016-2024, M365, C2R):
    Phase 1: Terminates all running and background Office processes.
    Phase 2: Stops and disables Click-to-Run, maintenance, and telemetry services.
    Phase 3: Unregisters all scheduled tasks under \Microsoft\Office.
    Phase 4: Recursively scrubs Office registry hives under HKLM and HKCU with rollback backup.
    Phase 5: Purges licensing/activation tokens (tokens.dat) and Modern Auth identity caches.
    Phase 6: Safely purges residual filesystem directories across Program Files, ProgramData, and AppData.
.PARAMETER Force
    Bypasses interactive confirmation prompts and forces termination of locked processes.
.PARAMETER SkipBackup
    Bypasses automated pre-modification registry and token file backups.
.PARAMETER BackupDirectory
    Custom directory for registry and token backups. Defaults to %ProgramData%\IToolkit\Backups.
.PARAMETER ScanAllProfiles
    Scans and purges Office AppData directories across all user profiles on the system.
.OUTPUTS
    [PSCustomObject] Containing Status, PhasesCompleted, ProcessesTerminated, ServicesStopped,
    TasksRemoved, RegistryKeysRemoved, FilesRemoved, BackupLocation, and Errors.
.EXAMPLE
    Uninstall-OfficeSuiteCleanly -WhatIf
    Simulates complete uninstallation without modifying the system.
.EXAMPLE
    Uninstall-OfficeSuiteCleanly -Force
    Unattended clean removal bypassing confirmation prompts.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$SkipBackup,

        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$ScanAllProfiles
    )

    process {
        # ----------------------------------------------------------------------
        # 0. Internal Path Safety Guardrail Helper
        # ----------------------------------------------------------------------
        function local:Test-SafeOfficeDirectoryPath {
            param([string]$Path)
            if ([string]::IsNullOrWhiteSpace($Path)) {
                return [PSCustomObject]@{ Safe = $false; Reason = "Path is null or whitespace" }
            }
            $clean = $Path.Trim().TrimEnd('\', '/')

            # Layer 1 & 2: Traversal check
            if ($clean -match '\.\.') {
                return [PSCustomObject]@{ Safe = $false; Reason = "Path traversal token ('..') detected" }
            }

            # Layer 3: Drive root check
            if ($clean -match '^[a-zA-Z]:$') {
                return [PSCustomObject]@{ Safe = $false; Reason = "Drive root detected" }
            }

            # Layer 4: System critical directory blacklist
            $blacklist = @(
                '', '/', '/root', '/home', '/etc', '/var', '/usr', '/tmp',
                'C:', 'C:\', 'D:', 'D:\', 'E:', 'E:\',
                'C:\Windows', 'C:\Windows\System32', 'C:\Windows\SysWOW64',
                'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users',
                $env:SystemRoot, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)},
                $env:ProgramData, $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd('\', '/') }

            if ($clean -in $blacklist) {
                return [PSCustomObject]@{ Safe = $false; Reason = "Path is in system critical directory blacklist" }
            }

            # Layer 5: Depth gate (at least 3 segments: e.g. C:, Program Files, Microsoft Office)
            $parts = @($clean -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($parts.Count -lt 3) {
                return [PSCustomObject]@{ Safe = $false; Reason = "Insufficient directory depth (< 3 segments)" }
            }

            # Layer 6: Whitelist leaf folder verification
            $leaf = $parts[-1]
            $allowedLeaves = @(
                'Microsoft Office',
                'ClickToRun',
                'Office',
                'OFFICE16',
                'OfficeSoftwareProtectionPlatform',
                'IdentityCache',
                'OneAuth',
                'Accounts'
            )
            if ($leaf -notin $allowedLeaves) {
                return [PSCustomObject]@{ Safe = $false; Reason = "Leaf folder '$leaf' not in authorized Office whitelist" }
            }

            return [PSCustomObject]@{ Safe = $true; Reason = $null; NormalizedPath = $clean }
        }

        # ----------------------------------------------------------------------
        # 1. Output Accumulators & Context Initialization
        # ----------------------------------------------------------------------
        $phasesCompleted     = [System.Collections.Generic.List[string]]::new()
        $processesTerminated = [System.Collections.Generic.List[string]]::new()
        $servicesStopped     = [System.Collections.Generic.List[string]]::new()
        $tasksRemoved        = [System.Collections.Generic.List[string]]::new()
        $registryKeysRemoved = [System.Collections.Generic.List[string]]::new()
        $filesRemoved        = [System.Collections.Generic.List[string]]::new()
        $errors              = [System.Collections.Generic.List[string]]::new()

        $isWhatIf = ($PSBoundParameters.ContainsKey('WhatIf') -and $PSBoundParameters['WhatIf']) -or $WhatIfPreference

        # Resolve Backup Directory
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $actualBackupDir = if (-not [string]::IsNullOrWhiteSpace($BackupDirectory)) {
            $BackupDirectory
        } elseif ($Global:IToolkitBackupDirectory) {
            Join-Path $Global:IToolkitBackupDirectory "OfficeScrub_$timestamp"
        } elseif ($env:ProgramData) {
            Join-Path $env:ProgramData "IToolkit\Backups\OfficeScrub_$timestamp"
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) "IToolkit\Backups\OfficeScrub_$timestamp"
        }

        # ----------------------------------------------------------------------
        # 2. Guardrails: Simulation (-WhatIf) & Confirmation (-Force)
        # ----------------------------------------------------------------------
        if ($isWhatIf) {
            $null = $PSCmdlet.ShouldProcess("Microsoft Office Suite", "Simulated uninstallation and scrub")
            $backupLocationOutput = if (-not $SkipBackup) { "[Simulated] $actualBackupDir" } else { $null }
        } else {
            # Interactive Confirmation Gate
            if (-not $Force) {
                $confirmed = $false
                try {
                    $promptMsg = "Are you sure you want to completely scrub Microsoft Office, all licensing tokens, and residual directories from this machine? This action is permanent."
                    $confirmed = $PSCmdlet.ShouldContinue($promptMsg, "Uninstall-OfficeSuiteCleanly")
                } catch {
                    # Fail closed in non-interactive environments without -Force
                    $confirmed = $false
                }

                if (-not $confirmed) {
                    return [PSCustomObject]@{
                        Status              = 'Failed'
                        PhasesCompleted     = @()
                        ProcessesTerminated = @()
                        ServicesStopped     = @()
                        TasksRemoved        = @()
                        RegistryKeysRemoved = @()
                        FilesRemoved        = @()
                        BackupLocation      = $null
                        Errors              = @("Execution cancelled: confirmation not granted (use -Force to bypass in automated environments).")
                    }
                }

                if (-not $PSCmdlet.ShouldProcess("Microsoft Office Suite", "Deep uninstallation and scrubbing")) {
                    return [PSCustomObject]@{
                        Status              = 'Failed'
                        PhasesCompleted     = @()
                        ProcessesTerminated = @()
                        ServicesStopped     = @()
                        TasksRemoved        = @()
                        RegistryKeysRemoved = @()
                        FilesRemoved        = @()
                        BackupLocation      = $null
                        Errors              = @("Execution cancelled: declined via ShouldProcess prompt.")
                    }
                }
            }
            $backupLocationOutput = if (-not $SkipBackup) { $actualBackupDir } else { $null }
        }

        # ----------------------------------------------------------------------
        # PHASE 1: Process Termination
        # ----------------------------------------------------------------------
        $phase1Name = 'ProcessTermination'
        try {
            $targetProcs = @(
                'WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'ONENOTEM', 'MSACCESS', 'MSPUB',
                'VISIO', 'WINPROJ', 'OFFICECLICKTORUN', 'OfficeC2RClient', 'AppvShNotify', 'Integrator',
                'FirstRun', 'OfficeBackgroundHandler', 'SETUP', 'MSOSYNC', 'GROOVE', 'COMMUNICATOR',
                'LYNC', 'Teams', 'msoia', 'msoas', 'mscorsvw', 'odc', 'ucapi', 'MSOHTMED', 'MSOPUS',
                'PROTOCOLHANDLER', 'MSOXV', 'OfficeTelemetryAgentFallback', 'OfficeTelemetryAgentLogCommandLine'
            )

            if ($isWhatIf) {
                $runningProcs = @(Get-Process -Name $targetProcs -ErrorAction SilentlyContinue)
                foreach ($rp in $runningProcs) {
                    if ($null -ne $rp -and -not [string]::IsNullOrWhiteSpace($rp.ProcessName)) {
                        $simProcName = "[Simulated] $($rp.ProcessName)"
                        if (-not $processesTerminated.Contains($simProcName)) {
                            $processesTerminated.Add($simProcName)
                        }
                    }
                }
            } else {
                if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                    $termRes = Stop-OfficeProcess -ProcessNames $targetProcs -Force:$Force -TimeoutSeconds 3
                    if ($null -ne $termRes -and $null -ne $termRes.Terminated) {
                        foreach ($tp in $termRes.Terminated) {
                            if ($tp -ne '[Simulated - WhatIf]' -and -not $processesTerminated.Contains($tp)) {
                                $processesTerminated.Add($tp)
                            }
                        }
                    }
                } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    foreach ($p in $targetProcs) {
                        $pRes = Stop-ToolkitProcess -ProcessName $p -TimeoutSeconds 3 -Force:$Force
                        if ($null -ne $pRes -and $pRes.Terminated -and -not $processesTerminated.Contains($p)) {
                            $processesTerminated.Add($p)
                        }
                    }
                } else {
                    foreach ($p in $targetProcs) {
                        $running = @(Get-Process -Name $p -ErrorAction SilentlyContinue)
                        if ($running.Count -gt 0) {
                            Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
                            if (-not $processesTerminated.Contains($p)) {
                                $processesTerminated.Add($p)
                            }
                        }
                    }
                }
            }
            $phasesCompleted.Add($phase1Name)
        } catch {
            $errors.Add("Phase 1 (ProcessTermination) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # PHASE 2: Service Control
        # ----------------------------------------------------------------------
        $phase2Name = 'ServiceControl'
        try {
            $targetServices = @('ClickToRunSvc', 'OfficeSvc', 'ose', 'ose64')
            foreach ($sName in $targetServices) {
                $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
                if ($null -ne $svc) {
                    if ($isWhatIf) {
                        $servicesStopped.Add("[Simulated] $sName")
                    } else {
                        if ($svc.Status -ne 'Stopped') {
                            Stop-Service -Name $sName -Force -ErrorAction SilentlyContinue
                            $sw = [System.Diagnostics.Stopwatch]::StartNew()
                            while ($sw.ElapsedMilliseconds -lt 5000) {
                                try {
                                    $svc.Refresh()
                                    if ($svc.Status -eq 'Stopped') { break }
                                } catch {
                                    break
                                }
                                Start-Sleep -Milliseconds 250
                            }
                            $sw.Stop()
                        }
                        Set-Service -Name $sName -StartupType Disabled -ErrorAction SilentlyContinue
                        if (($IsWindows -or ($env:OS -eq 'Windows_NT')) -and (Get-Command -Name 'sc.exe' -ErrorAction SilentlyContinue)) {
                            $null = Start-Process -FilePath 'sc.exe' -ArgumentList @('config', $sName, 'start=', 'disabled') -NoNewWindow -Wait -ErrorAction SilentlyContinue
                        }
                        $servicesStopped.Add($sName)
                    }
                }
            }
            $phasesCompleted.Add($phase2Name)
        } catch {
            $errors.Add("Phase 2 (ServiceControl) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # PHASE 3: Scheduled Task Removal
        # ----------------------------------------------------------------------
        $phase3Name = 'ScheduledTasks'
        try {
            $knownTasks = @(
                'Office ClickToRun Service Monitor',
                'Office Automatic Updates 2.0',
                'Office Feature Updates',
                'Office Feature Updates Logon',
                'OfficeTelemetryAgentFallback',
                'OfficeTelemetryAgentFallback2016',
                'OfficeTelemetryAgentLogCommandLine',
                'OfficeTelemetryAgentLogCommandLine2016'
            )

            $tasksToProcess = [System.Collections.Generic.List[string]]::new()
            if (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue) {
                $foundTasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Office\*' -ErrorAction SilentlyContinue)
                if ($foundTasks.Count -eq 0) {
                    $foundTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like '\Microsoft\Office*' })
                }
                foreach ($ft in $foundTasks) {
                    if ($null -ne $ft -and -not [string]::IsNullOrWhiteSpace($ft.TaskName)) {
                        if (-not $tasksToProcess.Contains($ft.TaskName)) { $tasksToProcess.Add($ft.TaskName) }
                    }
                }
                foreach ($kt in $knownTasks) {
                    $singleTask = Get-ScheduledTask -TaskName $kt -ErrorAction SilentlyContinue
                    if ($null -ne $singleTask -and -not $tasksToProcess.Contains($kt)) {
                        $tasksToProcess.Add($kt)
                    }
                }
            }

            foreach ($tName in $tasksToProcess) {
                if ($isWhatIf) {
                    $tasksRemoved.Add("[Simulated] $tName")
                } else {
                    $unregSuccess = $false
                    if (Get-Command -Name 'Unregister-ScheduledTask' -ErrorAction SilentlyContinue) {
                        try {
                            Unregister-ScheduledTask -TaskName $tName -TaskPath '\Microsoft\Office\' -Confirm:$false -ErrorAction Stop
                            $unregSuccess = $true
                        } catch {
                            $unregSuccess = $false
                        }
                    }
                    if (-not $unregSuccess -and ($IsWindows -or ($env:OS -eq 'Windows_NT')) -and (Get-Command -Name 'schtasks.exe' -ErrorAction SilentlyContinue)) {
                        $null = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', "\Microsoft\Office\$tName", '/F') -NoNewWindow -Wait -ErrorAction SilentlyContinue
                    }
                    $tasksRemoved.Add($tName)
                }
            }
            $phasesCompleted.Add($phase3Name)
        } catch {
            $errors.Add("Phase 3 (ScheduledTasks) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # PHASE 4: Registry Scrub
        # ----------------------------------------------------------------------
        $phase4Name = 'RegistryScrub'
        try {
            $primaryRegHives = @(
                'HKLM:\SOFTWARE\Microsoft\Office',
                'HKCU:\SOFTWARE\Microsoft\Office',
                'HKLM:\SOFTWARE\Microsoft\AppVISV',
                'HKCU:\SOFTWARE\Microsoft\AppVISV',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office',
                'HKLM:\SOFTWARE\Microsoft\OfficeSoftwareProtectionPlatform',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\OfficeSoftwareProtectionPlatform'
            )

            # Pre-modification backup
            if (-not $SkipBackup -and -not $isWhatIf -and (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue)) {
                $regBkDir = Join-Path $actualBackupDir 'Registry'
                foreach ($rk in $primaryRegHives) {
                    if (Test-Path -LiteralPath $rk) {
                        try {
                            $null = Export-RegistryKeyBackup -KeyPath $rk -BackupDirectory $regBkDir
                        } catch {
                            $errors.Add("Failed to back up registry key '$rk': $($_.Exception.Message)")
                        }
                    }
                }
            }

            foreach ($rk in $primaryRegHives) {
                if (Test-Path -LiteralPath $rk) {
                    if ($isWhatIf) {
                        $registryKeysRemoved.Add("[Simulated] $rk")
                    } else {
                        try {
                            Remove-Item -LiteralPath $rk -Recurse -Force -ErrorAction Stop
                            $registryKeysRemoved.Add($rk)
                        } catch {
                            if (($IsWindows -or ($env:OS -eq 'Windows_NT')) -and (Get-Command -Name 'reg.exe' -ErrorAction SilentlyContinue)) {
                                $nativePath = if (Get-Command -Name 'Normalize-RegistryPath' -ErrorAction SilentlyContinue) {
                                    Normalize-RegistryPath -Path $rk -Format 'Native'
                                } else {
                                    $rk -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
                                }
                                $null = Start-Process -FilePath 'reg.exe' -ArgumentList @('delete', "`"$nativePath`"", '/f') -NoNewWindow -Wait -ErrorAction SilentlyContinue
                                $registryKeysRemoved.Add($rk)
                            } else {
                                $errors.Add("Failed to remove registry key '$rk': $($_.Exception.Message)")
                            }
                        }
                    }
                }
            }

            # Uninstall Hives Scrubbing
            $uninstallHives = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            foreach ($uHive in $uninstallHives) {
                if (Test-Path -LiteralPath $uHive) {
                    $uSubKeys = Get-ChildItem -LiteralPath $uHive -ErrorAction SilentlyContinue
                    if ($uSubKeys) {
                        foreach ($sub in $uSubKeys) {
                            $subPath = $sub.PSPath
                            $subName = $sub.PSChildName
                            $uProps  = Get-ItemProperty -LiteralPath $subPath -ErrorAction SilentlyContinue

                            $isMatch = $false
                            if ($subName -like 'Office16.*' -or
                                $subName -like 'O365*Retail*' -or
                                $subName -like 'ProPlus*Retail*' -or
                                $subName -like 'Home*Retail*' -or
                                $subName -like 'ClickToRunStore' -or
                                $subName -like '{90160000-*}') {
                                $isMatch = $true
                            } elseif ($uProps -and $uProps.DisplayName -and ($uProps.DisplayName -like '*Microsoft Office*' -or $uProps.DisplayName -like '*Microsoft 365*') -and ($uProps.Publisher -eq 'Microsoft Corporation')) {
                                $isMatch = $true
                            }

                            if ($isMatch) {
                                if ($isWhatIf) {
                                    $registryKeysRemoved.Add("[Simulated] $subPath")
                                } else {
                                    Remove-Item -LiteralPath $subPath -Recurse -Force -ErrorAction SilentlyContinue
                                    $registryKeysRemoved.Add($subPath)
                                }
                            }
                        }
                    }
                }
            }

            # App Paths and Installer Products
            $appPathsRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
            if (Test-Path -LiteralPath $appPathsRoot) {
                $officeAppExecs = @('winword.exe', 'excel.exe', 'powerpnt.exe', 'outlook.exe', 'onenote.exe', 'msaccess.exe', 'mspub.exe', 'visio.exe', 'winproj.exe', 'protocolhandler.exe')
                foreach ($appExec in $officeAppExecs) {
                    $appExecPath = "$appPathsRoot\$appExec"
                    if (Test-Path -LiteralPath $appExecPath) {
                        if ($isWhatIf) {
                            $registryKeysRemoved.Add("[Simulated] $appExecPath")
                        } else {
                            Remove-Item -LiteralPath $appExecPath -Recurse -Force -ErrorAction SilentlyContinue
                            $registryKeysRemoved.Add($appExecPath)
                        }
                    }
                }
            }

            $installerProductsRoot = 'HKLM:\SOFTWARE\Classes\Installer\Products'
            if (Test-Path -LiteralPath $installerProductsRoot) {
                $prodKeys = Get-ChildItem -LiteralPath $installerProductsRoot -ErrorAction SilentlyContinue
                if ($prodKeys) {
                    foreach ($pk in $prodKeys) {
                        if ($pk.PSChildName -like '000061*') {
                            if ($isWhatIf) {
                                $registryKeysRemoved.Add("[Simulated] $($pk.PSPath)")
                            } else {
                                Remove-Item -LiteralPath $pk.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                                $registryKeysRemoved.Add($pk.PSPath)
                            }
                        }
                    }
                }
            }

            $phasesCompleted.Add($phase4Name)
        } catch {
            $errors.Add("Phase 4 (RegistryScrub) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # PHASE 5: Licensing & Token Purge
        # ----------------------------------------------------------------------
        $phase5Name = 'LicensingTokenPurge'
        try {
            $progData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
            $osppDir = Join-Path $progData 'Microsoft\OfficeSoftwareProtectionPlatform'
            $tokensFile = Join-Path $osppDir 'tokens.dat'
            $cacheFile = Join-Path $osppDir 'cache.dat'

            # Pre-purge token backup
            if (-not $SkipBackup -and -not $isWhatIf) {
                $tokenBkDir = Join-Path $actualBackupDir 'Tokens'
                if (-not (Test-Path -LiteralPath $tokenBkDir)) {
                    $null = New-Item -ItemType Directory -Path $tokenBkDir -Force -ErrorAction SilentlyContinue
                }
                foreach ($tItem in @($tokensFile, $cacheFile)) {
                    if (Test-Path -LiteralPath $tItem) {
                        try {
                            Copy-Item -LiteralPath $tItem -Destination $tokenBkDir -Force -ErrorAction SilentlyContinue
                        } catch {
                            $errors.Add("Failed to back up token file '$tItem': $($_.Exception.Message)")
                        }
                    }
                }
            }

            # Purge OSPP token files
            foreach ($tItem in @($tokensFile, $cacheFile)) {
                if (Test-Path -LiteralPath $tItem) {
                    if ($isWhatIf) {
                        $filesRemoved.Add("[Simulated] $tItem")
                    } else {
                        try {
                            Remove-Item -LiteralPath $tItem -Force -ErrorAction Stop
                            $filesRemoved.Add($tItem)
                        } catch {
                            $errors.Add("Failed to remove token file '$tItem': $($_.Exception.Message)")
                        }
                    }
                }
            }

            # Purge auxiliary OSPP store files
            if (Test-Path -LiteralPath $osppDir) {
                $extraOsppItems = Get-ChildItem -LiteralPath $osppDir -Recurse -File -Force -ErrorAction SilentlyContinue
                if ($extraOsppItems) {
                    foreach ($eo in $extraOsppItems) {
                        if ($isWhatIf) {
                            $filesRemoved.Add("[Simulated] $($eo.FullName)")
                        } else {
                            try {
                                Remove-Item -LiteralPath $eo.FullName -Force -ErrorAction Stop
                                $filesRemoved.Add($eo.FullName)
                            } catch {
                                $errors.Add("Failed to remove OSPP store file '$($eo.FullName)': $($_.Exception.Message)")
                            }
                        }
                    }
                }
            }

            # Modern Auth / IdentityCache Token Cache Purge
            $localApp = if ($env:LOCALAPPDATA) {
                $env:LOCALAPPDATA
            } elseif ($env:USERPROFILE) {
                Join-Path $env:USERPROFILE 'AppData\Local'
            } else {
                $null
            }

            if (-not [string]::IsNullOrWhiteSpace($localApp)) {
                $identityCacheDirs = @(
                    (Join-Path $localApp 'Microsoft\IdentityCache'),
                    (Join-Path $localApp 'Microsoft\OneAuth'),
                    (Join-Path $localApp 'Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts')
                )
                foreach ($ic in $identityCacheDirs) {
                    if (Test-Path -LiteralPath $ic) {
                        if ($isWhatIf) {
                            $filesRemoved.Add("[Simulated] $ic")
                        } else {
                            try {
                                Remove-Item -LiteralPath $ic -Recurse -Force -ErrorAction Stop
                                $filesRemoved.Add($ic)
                            } catch {
                                $errors.Add("Failed to purge identity cache directory '$ic': $($_.Exception.Message)")
                            }
                        }
                    }
                }
            }

            # Licensing Registry Reset
            $licensingKeys = @(
                'HKLM:\SOFTWARE\Microsoft\OfficeSoftwareProtectionPlatform',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\OfficeSoftwareProtectionPlatform',
                'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\Licensing',
                'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Licensing',
                'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ProductCodes',
                'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ScenarioProductCodes',
                'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Identity\Identities',
                'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Identity\Profiles'
            )
            foreach ($lk in $licensingKeys) {
                if (Test-Path -LiteralPath $lk) {
                    if ($isWhatIf) {
                        if (-not $registryKeysRemoved.Contains("[Simulated] $lk")) {
                            $registryKeysRemoved.Add("[Simulated] $lk")
                        }
                    } else {
                        try {
                            Remove-Item -LiteralPath $lk -Recurse -Force -ErrorAction Stop
                            if (-not $registryKeysRemoved.Contains($lk)) {
                                $registryKeysRemoved.Add($lk)
                            }
                        } catch {
                            $errors.Add("Failed to remove licensing registry key '$lk': $($_.Exception.Message)")
                        }
                    }
                }
            }

            $phasesCompleted.Add($phase5Name)
        } catch {
            $errors.Add("Phase 5 (LicensingTokenPurge) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # PHASE 6: Filesystem Directory Purge
        # ----------------------------------------------------------------------
        $phase6Name = 'FilesystemPurge'
        try {
            $basePF      = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
            $basePF86    = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } elseif ($env:ProgramFiles -and ${env:PROCESSOR_ARCHITECTURE} -eq 'AMD64') { 'C:\Program Files (x86)' } else { $null }
            $basePD      = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
            $baseLocal   = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Local' } else { $null }
            $baseRoaming = if ($env:APPDATA) { $env:APPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' } else { $null }
            $baseCPF     = if ($env:CommonProgramFiles) { $env:CommonProgramFiles } else { 'C:\Program Files\Common Files' }
            $baseCPF86   = if (${env:CommonProgramFiles(x86)}) { ${env:CommonProgramFiles(x86)} } else { $null }

            $dirCandidates = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace($basePF)) {
                $dirCandidates.Add((Join-Path $basePF 'Microsoft Office'))
            }
            if (-not [string]::IsNullOrWhiteSpace($basePF86)) {
                $dirCandidates.Add((Join-Path $basePF86 'Microsoft Office'))
            }
            if (-not [string]::IsNullOrWhiteSpace($basePD)) {
                $dirCandidates.Add((Join-Path $basePD 'Microsoft\ClickToRun'))
                $dirCandidates.Add((Join-Path $basePD 'Microsoft\Office'))
                $dirCandidates.Add((Join-Path $basePD 'Microsoft\OfficeSoftwareProtectionPlatform'))
            }
            if (-not [string]::IsNullOrWhiteSpace($baseLocal)) {
                $dirCandidates.Add((Join-Path $baseLocal 'Microsoft\Office'))
            }
            if (-not [string]::IsNullOrWhiteSpace($baseRoaming)) {
                $dirCandidates.Add((Join-Path $baseRoaming 'Microsoft\Office'))
            }
            if (-not [string]::IsNullOrWhiteSpace($baseCPF)) {
                $dirCandidates.Add((Join-Path $baseCPF 'microsoft shared\ClickToRun'))
                $dirCandidates.Add((Join-Path $baseCPF 'microsoft shared\OFFICE16'))
            }
            if (-not [string]::IsNullOrWhiteSpace($baseCPF86)) {
                $dirCandidates.Add((Join-Path $baseCPF86 'microsoft shared\ClickToRun'))
                $dirCandidates.Add((Join-Path $baseCPF86 'microsoft shared\OFFICE16'))
            }

            # Optional multi-user profile scanning
            if ($ScanAllProfiles) {
                $usersRoot = 'C:\Users'
                if (Test-Path -LiteralPath $usersRoot) {
                    $profiles = Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue
                    if ($profiles) {
                        foreach ($prof in $profiles) {
                            $pLocal = Join-Path $prof.FullName 'AppData\Local\Microsoft\Office'
                            $pRoam  = Join-Path $prof.FullName 'AppData\Roaming\Microsoft\Office'
                            if (-not $dirCandidates.Contains($pLocal)) { $dirCandidates.Add($pLocal) }
                            if (-not $dirCandidates.Contains($pRoam))  { $dirCandidates.Add($pRoam) }
                        }
                    }
                }
            }

            foreach ($dir in $dirCandidates) {
                $safety = local:Test-SafeOfficeDirectoryPath -Path $dir
                if (-not $safety.Safe) {
                    Write-Verbose "Skipped path '$dir' - Guardrail rejected: $($safety.Reason)"
                    continue
                }

                $validatedDir = $safety.NormalizedPath
                if (Test-Path -LiteralPath $validatedDir) {
                    if ($isWhatIf) {
                        if (-not $filesRemoved.Contains("[Simulated] $validatedDir")) {
                            $filesRemoved.Add("[Simulated] $validatedDir")
                        }
                    } else {
                        try {
                            Remove-Item -LiteralPath $validatedDir -Recurse -Force -ErrorAction Stop
                            if (-not $filesRemoved.Contains($validatedDir)) {
                                $filesRemoved.Add($validatedDir)
                            }
                        } catch {
                            $errors.Add("Failed to remove Office directory '$validatedDir': $($_.Exception.Message)")
                        }
                    }
                }
            }
            $phasesCompleted.Add($phase6Name)
        } catch {
            $errors.Add("Phase 6 (FilesystemPurge) encountered an error: $($_.Exception.Message)")
        }

        # ----------------------------------------------------------------------
        # 3. Final Status Resolution & Return Object Construction
        # ----------------------------------------------------------------------
        $finalStatus = if ($isWhatIf) {
            'Simulated'
        } elseif ($errors.Count -gt 0) {
            'Failed'
        } else {
            'Success'
        }

        return [PSCustomObject]@{
            Status              = $finalStatus
            PhasesCompleted     = @($phasesCompleted)
            ProcessesTerminated = @($processesTerminated)
            ServicesStopped     = @($servicesStopped)
            TasksRemoved        = @($tasksRemoved)
            RegistryKeysRemoved = @($registryKeysRemoved)
            FilesRemoved        = @($filesRemoved)
            BackupLocation      = $backupLocationOutput
            Errors              = @($errors)
        }
    }
}
