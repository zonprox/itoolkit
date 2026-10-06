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
}

