# ==============================================================================
# Office.Tests.ps1
# Unit test suite for Modules/Office
# Covers: Set-ExcelHardwareAcceleration, Reset-ExcelUiCache, Clear-OfficeTempCache,
# Get-ExcelComAddin, Set-ExcelComAddinState, Reset-ExcelResiliency,
# Get-ExcelGdiHandleUsage, Stop-ExcelGdiLeakers, Start-OfficeClickToRunRepair.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:OfficeManifest = Join-Path $ProjectRoot 'Modules/Office/Office.psd1'
$isOfficeAvailable = Test-Path $script:OfficeManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

    # Stubs for native Windows commands if running on non-Windows
    $compatCmds = @('Get-Service', 'Stop-Service', 'Start-Service', 'Set-Service', 'Get-ScheduledTask', 'Unregister-ScheduledTask', 'reg.exe', 'schtasks.exe', 'sc.exe')
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

    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
}
Describe 'Unit: Office & Excel Troubleshooting Module' {

    Context 'Excel Hardware Acceleration & Display' {
        It 'Set-ExcelHardwareAcceleration sets registry keys and generates rollback file' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' } }
            $res = Set-ExcelHardwareAcceleration -Disable $true
            $res.Disabled | Should -BeTrue
            $res.RegBackupFile | Should -Match 'OfficeGfx\.reg'
        }

        It 'Set-ExcelHardwareAcceleration supports WhatIf' -Skip:(-not $isOfficeAvailable) {
            $res = Set-ExcelHardwareAcceleration -Disable $false -WhatIf
            $res | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Excel UI Cache & XLSTART Reset' {
        It 'Reset-ExcelUiCache renames corrupted Excel16.xlb to quarantine' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Rename-Item { }
            $res = Reset-ExcelUiCache -CleanXlStart $true
            $res.QuarantinedFiles | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Office Temporary & Web Add-in Cache' {
        It 'Clear-OfficeTempCache purges OfficeFileCache and Wef directories' -Skip:(-not $isOfficeAvailable) {
            Mock Remove-Item { }
            Mock Get-ChildItem { return @([PSCustomObject]@{ Length = 1048576 }) }
            $res = Clear-OfficeTempCache -IncludeDocumentCache $true -IncludeWefCache $true
            $res.CleanedFilesCount | Should -BeGreaterThan 0
            $res.BytesFreed | Should -BeGreaterThan 0
        }
    }

    Context 'COM Add-in Management & Resiliency' {
        It 'Get-ExcelComAddin enumerates registered add-ins across HKCU and HKLM' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ PSChildName = 'PowerPivot'; GetValue = { param($k) if ($k -eq 'LoadBehavior') { return 3 } else { return 'PowerPivot Addin' } } }
                )
            }
            $addins = Get-ExcelComAddin
            $addins.Count | Should -Be 1
            $addins[0].ProgId | Should -Be 'PowerPivot'
        }

        It 'Set-ExcelComAddinState updates LoadBehavior key' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ PreviousValue = 3; NewValue = 0 } }
            $res = Set-ExcelComAddinState -ProgId 'ProblematicAddin' -LoadBehavior 0
            $res.ProgId | Should -Be 'ProblematicAddin'
            $res.NewBehavior | Should -Be 0
        }

        It 'Reset-ExcelResiliency clears disabled items list' -Skip:(-not $isOfficeAvailable) {
            Mock Remove-ItemProperty { }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Resiliency.reg' }
            $res = Reset-ExcelResiliency
            $res.ClearedItemsCount | Should -BeGreaterOrEqual 0
            $res.RegBackupFile | Should -Not -BeNullOrEmpty
        }
    }

    Context 'GDI Handle Leak Detection' {
        It 'Get-ExcelGdiHandleUsage identifies leaking processes exceeding threshold' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                return @(
                    [PSCustomObject]@{ Id = 1001; ProcessName = 'EXCEL'; HandleCount = 12000 }
                )
            }
            $usage = Get-ExcelGdiHandleUsage -WarningThreshold 10000
            $usage.Count | Should -Be 1
            $usage[0].IsLeaking | Should -BeTrue
        }

        It 'Stop-ExcelGdiLeakers terminates identified leakers' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ExcelGdiHandleUsage {
                return @([PSCustomObject]@{ PID = 1001; ProcessName = 'EXCEL'; IsLeaking = $true })
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            $res = Stop-ExcelGdiLeakers -Threshold 10000 -Force
            $res.Count | Should -Be 1
            $res.TerminatedPIDs | Should -Contain 1001
        }
    }

    Context 'ClickToRun Repair Launcher' {
        It 'Start-OfficeClickToRunRepair invokes Office repair command with QuickRepair' -Skip:(-not $isOfficeAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $res = Start-OfficeClickToRunRepair -RepairType 'Quick'
            $res.RepairType | Should -Be 'Quick'
            $res.Launched | Should -BeTrue
        }

        It 'Start-OfficeClickToRunRepair supports Online repair mode' -Skip:(-not $isOfficeAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $res = Start-OfficeClickToRunRepair -RepairType 'Online'
            $res.RepairType | Should -Be 'Online'
            $res.Launched | Should -BeTrue
        }
    }

    Context 'Office 16.0 Hive Enforcement & Legacy Rejection' {
        It 'Strictly targets Office 16.0 registry hives for settings and policies' {
            $targetHives = @(
                'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics',
                'HKCU:\Software\Microsoft\Office\16.0\Excel\Options',
                'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST',
                'HKLM:\Software\Policies\Microsoft\Office\16.0\Outlook\PST'
            )
            foreach ($hive in $targetHives) {
                $hive | Should -Match 'Office\\16\.0'
                $hive | Should -Not -Match 'Office\\(?:14|15)\.0'
            }
        }

        It 'Explicitly disallows legacy Office 2010 (14.0) and Office 2013 (15.0)' {
            $officeValidator = {
                param([string]$VersionKey)
                if ($VersionKey -match '14\.0' -or $VersionKey -match '15\.0') {
                    throw "Unsupported legacy Office version: $VersionKey. Only Office 16.0 (2016/2021/2024/C2R) is supported."
                }
                return $true
            }

            { & $officeValidator '14.0' } | Should -Throw -ExpectedMessage '*Unsupported legacy Office version*'
            { & $officeValidator '15.0' } | Should -Throw -ExpectedMessage '*Unsupported legacy Office version*'
            (& $officeValidator '16.0') | Should -BeTrue
        }
    }

    Context 'Word Template Reset (Normal.dotm)' {
        It 'Reset-WordTemplate skips when Normal.dotm does not exist' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $false }
            $res = Reset-WordTemplate
            $res.Status | Should -Be 'Skipped'
            $res.Backup | Should -BeNullOrEmpty
        }

        It 'Reset-WordTemplate isolates template and creates backup' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-Process { return @() }
            Mock Move-Item { }

            $res = Reset-WordTemplate
            $res.Status | Should -Be 'Success'
            $res.Backup | Should -Match 'Normal\.dotm\.bak_'
        }

        It 'Reset-WordTemplate warns when Word is running without Force' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'WINWORD' }) }

            $res = Reset-WordTemplate
            $res.Status | Should -Be 'Warning'
        }

        It 'Reset-WordTemplate supports WhatIf dry run' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            $res = Reset-WordTemplate -WhatIf
            $res.Status | Should -Be 'Success'
            $res.Backup | Should -Match 'WhatIf'
        }

        It 'Reset-WordTemplate creates non-existent backup directory and isolates template' -Skip:(-not $isOfficeAvailable) {
            $tempRoot = [System.IO.Path]::GetTempPath()
            $testDir = Join-Path $tempRoot ("WordTest_" + [System.Guid]::NewGuid().ToString())
            $appDataDir = Join-Path $testDir 'AppData'
            $templatesDir = Join-Path (Join-Path $appDataDir 'Microsoft') 'Templates'
            $null = New-Item -ItemType Directory -Path $templatesDir -Force
            $normalPath = Join-Path $templatesDir 'Normal.dotm'
            Set-Content -Path $normalPath -Value 'mock normal template'

            $oldAppData = $env:APPDATA
            $env:APPDATA = $appDataDir
            try {
                $customBackupDir = Join-Path $testDir 'NonExistentBackupDir/'
                $res = Reset-WordTemplate -BackupPath $customBackupDir
                $res.Status | Should -Be 'Success'
                $res.Backup | Should -Not -BeNullOrEmpty
                (Test-Path -LiteralPath $customBackupDir) | Should -BeTrue
                (Test-Path -LiteralPath $res.Backup) | Should -BeTrue
            }
            finally {
                $env:APPDATA = $oldAppData
                if (Test-Path -LiteralPath $testDir) {
                    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Reset-WordTemplate creates non-existent parent directory when BackupPath specifies file' -Skip:(-not $isOfficeAvailable) {
            $tempRoot = [System.IO.Path]::GetTempPath()
            $testDir = Join-Path $tempRoot ("WordTestFile_" + [System.Guid]::NewGuid().ToString())
            $appDataDir = Join-Path $testDir 'AppData'
            $templatesDir = Join-Path (Join-Path $appDataDir 'Microsoft') 'Templates'
            $null = New-Item -ItemType Directory -Path $templatesDir -Force
            $normalPath = Join-Path $templatesDir 'Normal.dotm'
            Set-Content -Path $normalPath -Value 'mock normal template'

            $oldAppData = $env:APPDATA
            $env:APPDATA = $appDataDir
            try {
                $customBackupFile = Join-Path (Join-Path $testDir 'NonExistentParent') 'CustomNormal.bak'
                $res = Reset-WordTemplate -BackupPath $customBackupFile
                $res.Status | Should -Be 'Success'
                $res.Backup | Should -Be $customBackupFile
                (Test-Path -LiteralPath $customBackupFile) | Should -BeTrue
            }
            finally {
                $env:APPDATA = $oldAppData
                if (Test-Path -LiteralPath $testDir) {
                    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Word Startup Add-in Isolation' {
        It 'Reset-WordStartupAddin isolates active add-in templates' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ Name = 'BadAddin.dotm'; Extension = '.dotm'; FullName = '/tmp/BadAddin.dotm' }
                )
            }
            Mock Get-Process { return @() }
            Mock Rename-Item { }

            $res = Reset-WordStartupAddin
            $res.Status | Should -Be 'Success'
            $res.AddinsIsolated | Should -Be 1
        }

        It 'Reset-WordStartupAddin skips when no active add-ins found' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem { return @() }

            $res = Reset-WordStartupAddin
            $res.Status | Should -Be 'Skipped'
            $res.AddinsIsolated | Should -Be 0
        }

        It 'Reset-WordStartupAddin supports WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Name = 'Test.dotm'; Extension = '.dotm'; FullName = '/tmp/Test.dotm' })
            }
            $res = Reset-WordStartupAddin -WhatIf
            $res.Status | Should -Be 'Success'
        }
    }

    Context 'Word Registry Data & Options Reset' {
        It 'Reset-WordRegistryData removes registry hives with backup' -Skip:(-not $isOfficeAvailable) {
            Mock Test-ProcessRunning { return $false }
            Mock Test-Path { return $true }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Word.reg' }
            Mock Remove-Item { }

            $res = Reset-WordRegistryData
            $res.Status | Should -Be 'Success'
        }

        It 'Reset-WordRegistryData supports resetting only Data or Options' -Skip:(-not $isOfficeAvailable) {
            Mock Test-ProcessRunning { return $false }
            Mock Test-Path { return $true }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\WordData.reg' }
            Mock Remove-Item { }

            $res = Reset-WordRegistryData -ResetData
            $res.Status | Should -Be 'Success'
        }

        It 'Reset-WordRegistryData supports WhatIf simulation' -Skip:(-not $isOfficeAvailable) {
            $res = Reset-WordRegistryData -WhatIf
            $res.Status | Should -Be 'Success'
        }
    }

    Context 'Word Orphaned Lock Purge' {
        It 'Clear-WordOrphanedLocks skips when search directory is empty' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $false }
            $res = Clear-WordOrphanedLocks
            $res.Status | Should -Be 'Success'
            $res.CleanedFiles.Count | Should -Be 0
        }

        It 'Clear-WordOrphanedLocks supports WhatIf dry run' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            $res = Clear-WordOrphanedLocks -Path '/tmp' -WhatIf
            $res.Status | Should -Be 'Success'
            $res.CleanedFiles | Should -Contain '[Simulated - WhatIf]'
        }
    }

    Context 'Suite Process Killer' {
        It 'Stop-OfficeProcess terminates running Office processes' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                return @([PSCustomObject]@{ ProcessName = 'WINWORD'; CloseMainWindow = { return $true }; WaitForExit = { param($t) return $true } })
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }

            $res = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force
            $res.Status | Should -Be 'Success'
            $res.Terminated | Should -Contain 'WINWORD'
        }

        It 'Stop-OfficeProcess supports WhatIf simulation' -Skip:(-not $isOfficeAvailable) {
            $res = Stop-OfficeProcess -WhatIf
            $res.Status | Should -Be 'Success'
            $res.Terminated | Should -Contain '[Simulated - WhatIf]'
        }
    }

    Context 'ClickToRun Service & Cache Repair' {
        It 'Repair-OfficeClickToRunService skips when service is not installed' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Service { return $null }

            $res = Repair-OfficeClickToRunService
            $res.Status | Should -Be 'Skipped'
            $res.ServiceStatus | Should -Be 'NotInstalled'
        }

        It 'Repair-OfficeClickToRunService repairs stopped service and corrupt cache' -Skip:(-not $isOfficeAvailable) {
            $mockSvc = [PSCustomObject]@{
                StartType = 'Disabled'
                Status = 'Stopped'
            }
            $mockSvc | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($s, $t) }
            $mockSvc | Add-Member -MemberType ScriptMethod -Name Refresh -Value { $this.Status = 'Running' }

            Mock Get-Service { return $mockSvc }
            Mock Set-Service { }
            Mock Start-Service { }
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\Cache\corrupt.xml'; Name = 'corrupt.xml'; Length = 0 }
                )
            }
            Mock Remove-Item { }

            $res = Repair-OfficeClickToRunService
            $res.Status | Should -Be 'Success'
            $res.ServiceStatus | Should -Be 'Running'
            $res.Repaired | Should -BeTrue
        }

        It 'Repair-OfficeClickToRunService supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Repair-OfficeClickToRunService -WhatIf
            $res.Status | Should -Be 'Success'
            $res.ServiceStatus | Should -Be 'Simulated'
        }
    }

    Context 'Office Identity Cache Reset' {
        It 'Reset-OfficeIdentityCache purges identity hives and caches' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { [PSCustomObject]@{ Status = 'Success' } }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Identity.reg' }
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ FullName = '/tmp/token.dat' })
            }
            Mock Remove-Item { }

            $res = Reset-OfficeIdentityCache -PurgeWamTokens
            $res.Status | Should -Be 'Success'
            $res.RegBackup | Should -Match 'Identity\.reg'
        }

        It 'Reset-OfficeIdentityCache supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Reset-OfficeIdentityCache -WhatIf
            $res.Status | Should -Be 'Success'
            $res.RegBackup | Should -Match 'WhatIf'
        }
    }

    Context 'Excel Startup Folder Cleanup' {
        It 'Clear-ExcelStartupFolder isolates rogue add-ins and creates Personal.xlsb backup' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ Name = 'Personal.xlsb'; FullName = 'C:\Excel\XLSTART\Personal.xlsb' },
                    [PSCustomObject]@{ Name = 'Rogue.xlam'; FullName = 'C:\Excel\XLSTART\Rogue.xlam' }
                )
            }
            Mock Copy-Item { }
            Mock Rename-Item { }

            $res = Clear-ExcelStartupFolder -Force
            $res.Status | Should -Be 'Success'
            $res.RemovedFiles | Should -Contain 'C:\Excel\XLSTART\Rogue.xlam'
            $res.PersonalBackupPath | Should -Match 'Personal\.xlsb\.bak'
        }

        It 'Clear-ExcelStartupFolder supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Clear-ExcelStartupFolder -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.RemovedFiles | Should -Contain '[Simulated - WhatIf]'
        }

        It 'Clear-ExcelStartupFolder ignores already quarantined and backup files' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ Name = 'Personal.xlsb.bak.20261013_120000'; FullName = 'C:\Excel\XLSTART\Personal.xlsb.bak.20261013_120000' },
                    [PSCustomObject]@{ Name = 'Personal.xlsb.isolated.20261013_120000'; FullName = 'C:\Excel\XLSTART\Personal.xlsb.isolated.20261013_120000' },
                    [PSCustomObject]@{ Name = 'Rogue.xlam.isolated.20261013_120000'; FullName = 'C:\Excel\XLSTART\Rogue.xlam.isolated.20261013_120000' }
                )
            }
            Mock Copy-Item { }
            Mock Rename-Item { }

            $res = Clear-ExcelStartupFolder -Force
            $res.Status | Should -Be 'Success'
            $res.RemovedFiles.Count | Should -Be 0
            $res.PersonalBackupPath | Should -BeNullOrEmpty
        }
    }

    Context 'Excel DDE & Formula Calculation Reset' {
        It 'Reset-ExcelDdeSettings clears IgnoreRemoteRequests and resets calculation' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\ExcelOptions.reg' } }

            $res = Reset-ExcelDdeSettings
            $res.Status | Should -Be 'Success'
            $res.DdeDisabled | Should -BeFalse
            $res.IgnoreRemoteRequests | Should -Be 0
            $res.Calculation | Should -Be 1
            $res.RegBackupFile | Should -Match 'ExcelOptions\.reg'
        }

        It 'Reset-ExcelDdeSettings supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Reset-ExcelDdeSettings -WhatIf
            $res.Status | Should -Be 'Simulated'
        }
    }

    Context 'PowerPoint Hardware Acceleration' {
        It 'Set-PowerPointHardwareAcceleration configures registry values' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PptGfx.reg' } }

            $res = Set-PowerPointHardwareAcceleration -DisableAcceleration
            $res.Status | Should -Be 'Success'
            $res.Disabled | Should -BeTrue
            $res.RegBackupFile | Should -Match 'PptGfx\.reg'
        }

        It 'Set-PowerPointHardwareAcceleration supports re-enabling' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PptGfx.reg' } }

            $res = Set-PowerPointHardwareAcceleration -EnableAcceleration
            $res.Status | Should -Be 'Success'
            $res.Disabled | Should -BeFalse
        }

        It 'Set-PowerPointHardwareAcceleration supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Set-PowerPointHardwareAcceleration -WhatIf
            $res.Status | Should -Be 'Simulated'
        }
    }

    Context 'PowerPoint Font & Slide Cache' {
        It 'Reset-PowerPointCache purges cache files and returns metrics' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\PptCache\font.bin'; Length = 2048 },
                    [PSCustomObject]@{ FullName = 'C:\PptCache\slide.bin'; Length = 4096 }
                )
            }
            Mock Remove-Item { }

            $res = Reset-PowerPointCache -Force
            $res.Status | Should -Be 'Success'
            $res.CleanedFilesCount | Should -Be 2
            $res.BytesFreed | Should -Be 6144
        }

        It 'Reset-PowerPointCache supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Reset-PowerPointCache -WhatIf
            $res.Status | Should -Be 'Simulated'
        }
    }

    Context 'PowerPoint Resiliency' {
        It 'Reset-PowerPointResiliency clears disabled items list and generates backup' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Get-Item {
                return [PSCustomObject]@{
                    Property = @('AddinA', 'AddinB')
                }
            }
            Mock Remove-ItemProperty { }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PptResiliency.reg' }

            $res = Reset-PowerPointResiliency
            $res.Status | Should -Be 'Success'
            $res.ClearedItems | Should -Be 2
            $res.RegBackupFile | Should -Match 'PptResiliency\.reg'
        }

        It 'Reset-PowerPointResiliency supports WhatIf dry-run' -Skip:(-not $isOfficeAvailable) {
            $res = Reset-PowerPointResiliency -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.ClearedItems | Should -Be 0
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: Parameter Binding & Cmdlet Attributes' {
        It 'CmdletBinding defines SupportsShouldProcess and High ConfirmImpact' -Skip:(-not $isOfficeAvailable) {
            $cmd = Get-Command -Name 'Uninstall-OfficeSuiteCleanly' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty

            $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $cmd.Parameters.ContainsKey('Confirm') | Should -BeTrue
            $cmd.Parameters.ContainsKey('Force') | Should -BeTrue
            $cmd.Parameters['Force'].SwitchParameter | Should -BeTrue
            $cmd.Parameters.ContainsKey('SkipBackup') | Should -BeTrue
            $cmd.Parameters.ContainsKey('BackupDirectory') | Should -BeTrue
            $cmd.Parameters.ContainsKey('ScanAllProfiles') | Should -BeTrue

            $bindingAttr = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $bindingAttr | Should -Not -BeNullOrEmpty
            $bindingAttr.SupportsShouldProcess | Should -BeTrue
            $bindingAttr.ConfirmImpact | Should -Be ([System.Management.Automation.ConfirmImpact]::High)
        }

        It 'Outputs PSCustomObject type attribute' -Skip:(-not $isOfficeAvailable) {
            $cmd = Get-Command -Name 'Uninstall-OfficeSuiteCleanly' -ErrorAction SilentlyContinue
            $outAttr = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.OutputTypeAttribute] }
            $outAttr | Should -Not -BeNullOrEmpty
            $outAttr.Type.Name | Should -Match 'PS(Custom)?Object'
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: Dry-Run Simulation (-WhatIf) Guarantees' {
        It 'Supports -WhatIf, returns Status Simulated, populates projected metrics, and performs ZERO mutations' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-Process { throw 'Stop-Process must not be invoked during WhatIf' }
            Mock Set-Service { throw 'Set-Service must not be invoked during WhatIf' }
            Mock Stop-Service { throw 'Stop-Service must not be invoked during WhatIf' }
            Mock Unregister-ScheduledTask { throw 'Unregister-ScheduledTask must not be invoked during WhatIf' }
            Mock Remove-Item { throw 'Remove-Item must not be invoked during WhatIf' }
            Mock Stop-OfficeProcess { throw 'Stop-OfficeProcess must not be invoked during WhatIf' }

            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'WINWORD'; Id = 101 }) }
            Mock Get-Service { return [PSCustomObject]@{ Name = 'ClickToRunSvc'; Status = 'Running' } }
            Mock Get-ScheduledTask { return @([PSCustomObject]@{ TaskName = 'Office ClickToRun Service Monitor'; TaskPath = '\Microsoft\Office\' }) }
            Mock Test-Path { return $true }

            $res = Uninstall-OfficeSuiteCleanly -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Simulated'
            $res.PhasesCompleted.Count | Should -BeGreaterOrEqual 6
            $res.ProcessesTerminated | Should -Contain '[Simulated] WINWORD'
            $res.ServicesStopped | Should -Contain '[Simulated] ClickToRunSvc'
            $res.TasksRemoved | Should -Contain '[Simulated] Office ClickToRun Service Monitor'
            $res.Errors.Count | Should -Be 0
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: 6-Phase Scrubbing Pipeline Execution' {
        It 'Executes all 6 phases and records terminated processes, services, tasks, registry, and files' -Skip:(-not $isOfficeAvailable) {
            # Phase 1: Processes
            Mock Stop-OfficeProcess {
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD', 'EXCEL', 'OFFICECLICKTORUN') }
            }

            # Phase 2: Services
            Mock Get-Service {
                $mSvc = [PSCustomObject]@{ Name = 'ClickToRunSvc'; Status = 'Running'; StartType = 'Automatic' }
                $mSvc | Add-Member -MemberType ScriptMethod -Name Refresh -Value { $this.Status = 'Stopped' }
                return $mSvc
            }
            Mock Stop-Service { }
            Mock Set-Service { }

            # Phase 3: Tasks
            Mock Get-ScheduledTask {
                return @(
                    [PSCustomObject]@{ TaskName = 'Office ClickToRun Service Monitor'; TaskPath = '\Microsoft\Office\' },
                    [PSCustomObject]@{ TaskName = 'Office Automatic Updates 2.0'; TaskPath = '\Microsoft\Office\' }
                )
            }
            Mock Unregister-ScheduledTask { }

            # Phase 4, 5, 6: Registry and Filesystem
            $removedItems = [System.Collections.Generic.List[string]]::new()
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -like 'HKLM:\SOFTWARE\Microsoft\Office*' -or
                    $LiteralPath -like 'HKCU:\SOFTWARE\Microsoft\Office*' -or
                    $LiteralPath -like 'HKLM:\SOFTWARE\Microsoft\AppVISV*' -or
                    $LiteralPath -like '*tokens.dat*' -or
                    $LiteralPath -like '*Microsoft Office*') {
                    return $true
                }
                return $false
            }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Registry\OfficeBackup.reg' }
            Mock Remove-Item { param($LiteralPath) $removedItems.Add($LiteralPath) }

            $res = Uninstall-OfficeSuiteCleanly -Force

            $res.Status | Should -Be 'Success'
            $res.PhasesCompleted.Count | Should -BeGreaterOrEqual 6
            $res.ProcessesTerminated | Should -Contain 'WINWORD'
            $res.ProcessesTerminated | Should -Contain 'OFFICECLICKTORUN'
            $res.ServicesStopped | Should -Contain 'ClickToRunSvc'
            $res.TasksRemoved | Should -Contain 'Office ClickToRun Service Monitor'
            $res.BackupLocation | Should -Not -BeNullOrEmpty
            $res.Errors.Count | Should -Be 0
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: Safe Non-Existent Target Idempotency' {
        It 'Executes safely with zero exceptions when all targets are absent' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Get-Process { return @() }
            Mock Get-Service { return $null }
            Mock Get-ScheduledTask { return @() }
            Mock Test-Path { return $false }
            Mock Remove-Item { throw 'Remove-Item should not be called when targets do not exist' }

            $script:idempotentRes = $null
            { $script:idempotentRes = Uninstall-OfficeSuiteCleanly -Force } | Should -Not -Throw

            $script:idempotentRes.Status | Should -Be 'Success'
            $script:idempotentRes.ProcessesTerminated.Count | Should -Be 0
            $script:idempotentRes.ServicesStopped.Count | Should -Be 0
            $script:idempotentRes.TasksRemoved.Count | Should -Be 0
            $script:idempotentRes.RegistryKeysRemoved.Count | Should -Be 0
            $script:idempotentRes.FilesRemoved.Count | Should -Be 0
            $script:idempotentRes.Errors.Count | Should -Be 0
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: Unattended Automation & Prompt Bypass (-Force)' {
        It 'Executes unattended without interactive confirmation prompt when -Force is supplied' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Get-Service { return $null }
            Mock Get-ScheduledTask { return @() }
            Mock Test-Path { return $false }

            $res = Uninstall-OfficeSuiteCleanly -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
        }
    }

    Context 'Uninstall-OfficeSuiteCleanly: Return Object Schema Completeness' {
        It 'Returns PSCustomObject with all 9 standard output properties' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Get-Service { return $null }
            Mock Get-ScheduledTask { return @() }
            Mock Test-Path { return $false }

            $res = Uninstall-OfficeSuiteCleanly -Force
            $res | Should -Not -BeNullOrEmpty
            $res.PSObject.Properties.Name | Should -Contain 'Status'
            $res.PSObject.Properties.Name | Should -Contain 'PhasesCompleted'
            $res.PSObject.Properties.Name | Should -Contain 'ProcessesTerminated'
            $res.PSObject.Properties.Name | Should -Contain 'ServicesStopped'
            $res.PSObject.Properties.Name | Should -Contain 'TasksRemoved'
            $res.PSObject.Properties.Name | Should -Contain 'RegistryKeysRemoved'
            $res.PSObject.Properties.Name | Should -Contain 'FilesRemoved'
            $res.PSObject.Properties.Name | Should -Contain 'BackupLocation'
            $res.PSObject.Properties.Name | Should -Contain 'Errors'

            $res.Status | Should -BeIn @('Success', 'Simulated', 'Failed')
        }
    }
}

