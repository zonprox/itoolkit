# ==============================================================================
# WindowsRepair.Tests.ps1
# Unit test suite for Modules/WindowsRepair
# Covers: Invoke-WindowsSfcScan, Invoke-WindowsDismRepair,
# Reset-WindowsUpdateComponents, Reset-NetworkStack, Repair-WmiRepository.
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:RepairManifest = Join-Path $script:ProjectRoot 'Modules/WindowsRepair/WindowsRepair.psd1'
    $script:RootManifest = Join-Path $script:ProjectRoot 'IToolkit.psd1'

    $manifests = Get-ChildItem -Path (Join-Path $script:ProjectRoot "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }

    # Stubs for native Windows commands if running on non-Windows
    $compatCmds = @('sfc', 'DISM', 'netsh', 'ipconfig', 'winmgmt', 'regsvr32', 'Stop-Service', 'Start-Service')
    foreach ($cmd in $compatCmds) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
    }

    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'D' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
}

Describe 'Unit: Windows Repair & Diagnostics Module' {

    Context 'Module Manifest & Export Integrity' {
        It 'WindowsRepair manifest exists and exports all 5 cmdlets' {
            Test-Path -LiteralPath $script:RepairManifest | Should -BeTrue
            $manifest = Import-PowerShellDataFile -Path $script:RepairManifest
            $manifest.FunctionsToExport | Should -Contain 'Invoke-WindowsSfcScan'
            $manifest.FunctionsToExport | Should -Contain 'Invoke-WindowsDismRepair'
            $manifest.FunctionsToExport | Should -Contain 'Reset-WindowsUpdateComponents'
            $manifest.FunctionsToExport | Should -Contain 'Reset-NetworkStack'
            $manifest.FunctionsToExport | Should -Contain 'Repair-WmiRepository'
        }

        It 'IToolkit root manifest exports all 5 Windows Repair cmdlets' {
            Test-Path -LiteralPath $script:RootManifest | Should -BeTrue
            $rootManifest = Import-PowerShellDataFile -Path $script:RootManifest
            $rootManifest.FunctionsToExport | Should -Contain 'Invoke-WindowsSfcScan'
            $rootManifest.FunctionsToExport | Should -Contain 'Invoke-WindowsDismRepair'
            $rootManifest.FunctionsToExport | Should -Contain 'Reset-WindowsUpdateComponents'
            $rootManifest.FunctionsToExport | Should -Contain 'Reset-NetworkStack'
            $rootManifest.FunctionsToExport | Should -Contain 'Repair-WmiRepository'
        }
    }

    Context 'Invoke-WindowsSfcScan Engine' {
        It 'Executes sfc /scannow and returns success when exit code is 0' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $result = Invoke-WindowsSfcScan
            $result.Tool | Should -Be 'SFC'
            $result.ExitCode | Should -Be 0
            $result.Status | Should -Be 'No integrity violations found'
            $result.Success | Should -BeTrue
        }

        It 'Returns failure status when sfc reports exit code 1 (unable to repair)' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            $result = Invoke-WindowsSfcScan
            $result.Tool | Should -Be 'SFC'
            $result.ExitCode | Should -Be 1
            $result.Status | Should -Be 'Verification failure or unable to repair'
            $result.Success | Should -BeFalse
        }

        It 'Evaluates arbitrary non-zero exit codes as failure' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 2 } }

            $result = Invoke-WindowsSfcScan
            $result.ExitCode | Should -Be 2
            $result.Success | Should -BeFalse
            $result.Status | Should -Match 'exit code 2'
        }

        It 'Supports -WhatIf simulation without executing Start-Process' {
            Mock Start-Process { throw 'Start-Process must not be invoked during WhatIf' }

            $result = Invoke-WindowsSfcScan -WhatIf
            $result.Tool | Should -Be 'SFC'
            $result.Status | Should -Match 'WhatIf'
            $result.Success | Should -BeTrue
        }

        It 'Warns when running without administrative elevation' {
            Mock Test-IsAdmin { return $false }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $warn = $null
            Invoke-WindowsSfcScan -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
            $warn.Count | Should -BeGreaterThan 0
            $warn[0].ToString() | Should -Match 'Administrative privileges'
        }

        It 'Handles execution exceptions gracefully without uncaught crash' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { throw 'Access is denied or binary missing' }

            $result = Invoke-WindowsSfcScan
            $result.Success | Should -BeFalse
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Access is denied'
        }
    }

    Context 'Invoke-WindowsDismRepair Engine' {
        It 'Executes default RestoreHealth mode and returns success on exit code 0' {
            Mock Test-IsAdmin { return $true }
            $script:capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsDismRepair
            $result.Tool | Should -Be 'DISM'
            $result.Mode | Should -Be 'RestoreHealth'
            $result.ExitCode | Should -Be 0
            $result.Status | Should -Be 'Operation completed successfully'
            $result.Success | Should -BeTrue
            $script:capturedArgs | Should -Contain '/Online'
            $script:capturedArgs | Should -Contain '/Cleanup-Image'
            $script:capturedArgs | Should -Contain '/RestoreHealth'
        }

        It 'Executes CheckHealth mode correctly' {
            Mock Test-IsAdmin { return $true }
            $script:capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsDismRepair -Mode 'CheckHealth'
            $result.Mode | Should -Be 'CheckHealth'
            $script:capturedArgs | Should -Contain '/CheckHealth'
        }

        It 'Executes ScanHealth mode correctly' {
            Mock Test-IsAdmin { return $true }
            $script:capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsDismRepair -Mode 'ScanHealth'
            $result.Mode | Should -Be 'ScanHealth'
            $script:capturedArgs | Should -Contain '/ScanHealth'
        }

        It 'Appends SourcePath and LimitAccess arguments when specified' {
            Mock Test-IsAdmin { return $true }
            $script:capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsDismRepair -Mode 'RestoreHealth' -SourcePath 'D:\Sources\install.wim' -LimitAccess
            $script:capturedArgs | Should -Contain '/Source:D:\Sources\install.wim'
            $script:capturedArgs | Should -Contain '/LimitAccess'
        }

        It 'Treats reboot-required exit code 3010 as success with reboot notification' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 3010 } }

            $result = Invoke-WindowsDismRepair
            $result.ExitCode | Should -Be 3010
            $result.Success | Should -BeTrue
            $result.Status | Should -Match 'restart is required'
        }

        It 'Reports failure on non-zero exit code (e.g. 87 invalid parameter)' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 87 } }

            $result = Invoke-WindowsDismRepair
            $result.ExitCode | Should -Be 87
            $result.Success | Should -BeFalse
            $result.Status | Should -Match 'exit code 87'
        }

        It 'Supports -WhatIf simulation without executing Start-Process' {
            Mock Start-Process { throw 'Start-Process must not be called during WhatIf' }

            $result = Invoke-WindowsDismRepair -Mode 'RestoreHealth' -WhatIf
            $result.Tool | Should -Be 'DISM'
            $result.Status | Should -Match 'WhatIf'
            $result.Success | Should -BeTrue
        }
    }

    Context 'Reset-WindowsUpdateComponents Engine' {
        It 'Stops services, renames cache folders, registers DLLs, and restarts services' {
            Mock Test-IsAdmin { return $true }
            $stopped = [System.Collections.Generic.List[string]]::new()
            $started = [System.Collections.Generic.List[string]]::new()
            Mock Stop-Service { $stopped.Add($Name) }
            Mock Start-Service { $started.Add($Name) }

            $registeredDlls = [System.Collections.Generic.List[string]]::new()
            Mock Start-Process {
                if ($ArgumentList -contains '/s') {
                    $registeredDlls.Add($ArgumentList[1])
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            Mock Test-Path { return $true }
            Mock Rename-Item { }
            Mock Remove-Item { }

            $result = Reset-WindowsUpdateComponents
            $result.Operation | Should -Be 'Reset-WindowsUpdateComponents'
            $result.Success | Should -BeTrue
            $result.ServicesRestarted | Should -Contain 'wuauserv'
            $result.ServicesRestarted | Should -Contain 'cryptSvc'
            $result.ServicesRestarted | Should -Contain 'bits'
            $result.ServicesRestarted | Should -Contain 'msiserver'
            $result.FoldersRenamed | Should -Contain 'SoftwareDistribution.bak'
            $result.FoldersRenamed | Should -Contain 'catroot2.bak'

            $registeredDlls | Should -Contain 'atl.dll'
            $registeredDlls | Should -Contain 'wuaueng.dll'
            $registeredDlls | Should -Contain 'wuapi.dll'
        }

        It 'Supports -WhatIf without stopping services or modifying folders' {
            Mock Stop-Service { throw 'Stop-Service must not be called under WhatIf' }
            Mock Rename-Item { throw 'Rename-Item must not be called under WhatIf' }
            Mock Start-Process { throw 'Start-Process must not be called under WhatIf' }

            $result = Reset-WindowsUpdateComponents -WhatIf
            $result.Operation | Should -Be 'Reset-WindowsUpdateComponents'
            $result.Success | Should -BeTrue
            $result.ServicesRestarted.Count | Should -Be 4
        }
    }

    Context 'Reset-NetworkStack Engine' {
        It 'Resets Winsock catalog, resets TCP/IP, and flushes DNS cache' {
            Mock Test-IsAdmin { return $true }
            $invokedCalls = [System.Collections.Generic.List[string]]::new()
            Mock Start-Process {
                $cmdArgs = ($ArgumentList -join ' ')
                $invokedCalls.Add($cmdArgs)
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Reset-NetworkStack
            $result.WinsockReset | Should -BeTrue
            $result.IpReset | Should -BeTrue
            $result.DnsFlushed | Should -BeTrue
            $result.Success | Should -BeTrue

            $invokedCalls | Should -Contain 'winsock reset'
            $invokedCalls | Should -Contain 'int ip reset'
            $invokedCalls | Should -Contain '/flushdns'
        }

        It 'Handles individual command failure gracefully' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process {
                if ($ArgumentList -contains 'winsock') {
                    return [PSCustomObject]@{ ExitCode = 0 }
                } elseif ($ArgumentList -contains 'ip') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                } else {
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
            }

            $result = Reset-NetworkStack
            $result.WinsockReset | Should -BeTrue
            $result.IpReset | Should -BeFalse
            $result.DnsFlushed | Should -BeTrue
            $result.Success | Should -BeFalse
        }

        It 'Supports -WhatIf simulation without running commands' {
            Mock Start-Process { throw 'Start-Process must not be called under WhatIf' }

            $result = Reset-NetworkStack -WhatIf
            $result.WinsockReset | Should -BeTrue
            $result.IpReset | Should -BeTrue
            $result.DnsFlushed | Should -BeTrue
            $result.Success | Should -BeTrue
        }
    }

    Context 'Repair-WmiRepository Engine' {
        It 'Executes Salvage action by default and passes /salvagerepository' {
            Mock Test-IsAdmin { return $true }
            $script:capturedFlag = $null
            Mock Start-Process {
                $script:capturedFlag = $ArgumentList[0]
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Repair-WmiRepository
            $result.Action | Should -Be 'Salvage'
            $result.ExitCode | Should -Be 0
            $result.Success | Should -BeTrue
            $result.Status | Should -Match 'completed successfully'
            $script:capturedFlag | Should -Be '/salvagerepository'
        }

        It 'Executes Verify action and passes /verifyrepository' {
            Mock Test-IsAdmin { return $true }
            $script:capturedFlag = $null
            Mock Start-Process {
                $script:capturedFlag = $ArgumentList[0]
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Repair-WmiRepository -Action 'Verify'
            $result.Action | Should -Be 'Verify'
            $script:capturedFlag | Should -Be '/verifyrepository'
        }

        It 'Executes Reset action and passes /resetrepository' {
            Mock Test-IsAdmin { return $true }
            $script:capturedFlag = $null
            Mock Start-Process {
                $script:capturedFlag = $ArgumentList[0]
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Repair-WmiRepository -Action 'Reset'
            $result.Action | Should -Be 'Reset'
            $script:capturedFlag | Should -Be '/resetrepository'
        }

        It 'Handles failure when winmgmt returns non-zero exit code' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            $result = Repair-WmiRepository -Action 'Salvage'
            $result.ExitCode | Should -Be 1
            $result.Success | Should -BeFalse
            $result.Status | Should -Match 'exit code 1'
        }

        It 'Supports -WhatIf simulation without calling Start-Process' {
            Mock Start-Process { throw 'Start-Process must not be called under WhatIf' }

            $result = Repair-WmiRepository -Action 'Reset' -WhatIf
            $result.Action | Should -Be 'Reset'
            $result.Status | Should -Match 'WhatIf'
            $result.Success | Should -BeTrue
        }
    }
}
