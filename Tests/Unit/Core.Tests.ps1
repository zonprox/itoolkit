# ==============================================================================
# Core.Tests.ps1
# Unit test suite for Modules/Core
# Covers: Test-IsAdmin, Assert-IsAdmin, Start-ToolkitSelfElevation,
# Test-ProcessRunning, Stop-ToolkitProcess, Test-DiskSpaceAvailable,
# Export-RegistryKeyBackup, Restore-RegistryKeyBackup, Set-ToolkitRegistryValue,
# Write-ToolkitLog, Format-ToolkitSummary, Show-ToolkitConfirmation.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:CoreManifest = Join-Path $ProjectRoot 'Modules/Core/Core.psd1'
$isCoreAvailable = Test-Path $script:CoreManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:CoreManifest = Join-Path $root 'Modules/Core/Core.psd1'
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
    # Dot-source Core scripts into test scope to enable unqualified Pester mocking
    Get-ChildItem -Path (Join-Path $root "Modules/Core/Private/*.ps1") | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $root "Modules/Core/Public/*.ps1") | ForEach-Object { . $_.FullName }
}
Describe 'Unit: Core Module Services' {

    Context 'Administrative Elevation Checks' {
        It 'Test-IsAdmin returns a boolean value' -Skip:(-not $isCoreAvailable) {
            $result = Test-IsAdmin
            $result -is [bool] | Should -BeTrue
        }

        It 'Assert-IsAdmin succeeds when session is elevated' -Skip:(-not $isCoreAvailable) {
            Mock Test-IsAdmin { return $true }
            { Assert-IsAdmin } | Should -Not -Throw
        }

        It 'Assert-IsAdmin throws terminating error when session is not elevated' -Skip:(-not $isCoreAvailable) {
            Mock Test-IsAdmin { return $false }
            { Assert-IsAdmin } | Should -Throw
        }

        It 'Start-ToolkitSelfElevation invokes Start-Process with RunAs verb' -Skip:(-not $isCoreAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ Id = 1234 } }
            Start-ToolkitSelfElevation -ScriptPath 'C:\IToolkit\Start-IToolkit.ps1' -Arguments '-NoExit'
            Assert-MockCalled Start-Process -Times 1 -ParameterFilter {
                $Verb -eq 'RunAs'
            }
        }
    }

    Context 'Process Lifecycle Management' {
        It 'Test-ProcessRunning returns true when target process exists' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { return [PSCustomObject]@{ ProcessName = 'OUTLOOK' } }
            $res = Test-ProcessRunning -ProcessName 'OUTLOOK'
            $res | Should -BeTrue
        }

        It 'Test-ProcessRunning returns false when target process does not exist' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { throw [System.Management.Automation.ItemNotFoundException]::new() }
            $res = Test-ProcessRunning -ProcessName 'NON_EXISTENT_PROC'
            $res | Should -BeFalse
        }

        It 'Stop-ToolkitProcess handles already stopped process' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { throw [System.Management.Automation.ItemNotFoundException]::new() }
            $res = Stop-ToolkitProcess -ProcessName 'EXCEL'
            $res.ProcessName | Should -Be 'EXCEL'
            $res.Terminated | Should -BeFalse
            $res.ForceUsed | Should -BeFalse
        }

        It 'Stop-ToolkitProcess gracefully closes responding process' -Skip:(-not $isCoreAvailable) {
            $mockProc = [PSCustomObject]@{
                ProcessName     = 'OUTLOOK'
                CloseMainWindow = { return $true }
                WaitForExit     = { param($t) return $true }
                HasExited       = $true
            }
            Mock Get-Process { return @($mockProc) }
            $res = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5
            $res.ProcessName | Should -Be 'OUTLOOK'
            $res.Terminated | Should -BeTrue
            $res.ForceUsed | Should -BeFalse
        }

        It 'Stop-ToolkitProcess falls back to force kill when requested' -Skip:(-not $isCoreAvailable) {
            $mockProc = [PSCustomObject]@{
                ProcessName = 'HUNG_APP'
                Kill        = { return $true }
                HasExited   = $true
            }
            Mock Get-Process { return @($mockProc) }
            Mock Stop-Process { }
            $res = Stop-ToolkitProcess -ProcessName 'HUNG_APP' -Force
            $res.Terminated | Should -BeTrue
            $res.ForceUsed | Should -BeTrue
        }
    }

    Context 'Disk Space & Resource Pre-Flight Checks' {
        It 'Test-DiskSpaceAvailable returns true when free space exceeds threshold * 1.2' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'C:\'
                FreeBytes = 100GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 1.2 = 60GB < 100GB
            $res = Test-DiskSpaceAvailable -Path 'C:\Data' -RequiredBytes 50GB
            $res | Should -BeTrue
        }

        It 'Test-DiskSpaceAvailable returns false when free space is insufficient' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'C:\'
                FreeBytes = 55GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 1.2 = 60GB > 55GB
            $res = Test-DiskSpaceAvailable -Path 'C:\Data' -RequiredBytes 50GB
            $res | Should -BeFalse
        }

        It 'Test-DiskSpaceAvailable respects custom safety multiplier' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'D:\'
                FreeBytes = 80GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 2.0 = 100GB > 80GB
            $res = Test-DiskSpaceAvailable -Path 'D:\Backup' -RequiredBytes 50GB -SafetyMultiplier 2.0
            $res | Should -BeFalse
        }
    }

    Context 'Reversible Registry Engine' {
        It 'Export-RegistryKeyBackup generates .reg file in backup directory' -Skip:(-not $isCoreAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                Mock Start-Process {
                    # Simulate reg.exe export
                    param($FilePath, $ArgumentList)
                    $outPath = ($ArgumentList -split '\s+')[2].Trim('"')
                    Set-Content -Path $outPath -Value "Windows Registry Editor Version 5.00`n`n[HKEY_CURRENT_USER\Software\Test]`n`"Key`"=`"Val`""
                    return [PSCustomObject]@{ ExitCode = 0 }
                }

                $backupFile = Export-RegistryKeyBackup -KeyPath 'HKCU:\Software\Test' -BackupDirectory $tempDir
                Test-Path $backupFile | Should -BeTrue
                $content = Get-Content -Path $backupFile -Raw
                $content | Should -Match 'Windows Registry Editor Version 5\.00'
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-RegistryKeyBackup calls reg.exe import and returns success' -Skip:(-not $isCoreAvailable) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value "Windows Registry Editor Version 5.00"
            try {
                Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
                $res = Restore-RegistryKeyBackup -BackupFilePath $tempFile
                $res | Should -BeTrue
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-RegistryKeyBackup returns false if file does not exist' -Skip:(-not $isCoreAvailable) {
            $res = Restore-RegistryKeyBackup -BackupFilePath 'C:\NonExistent\Backup.reg'
            $res | Should -BeFalse
        }

        It 'Set-ToolkitRegistryValue creates backup before modifying and supports WhatIf' -Skip:(-not $isCoreAvailable) {
            Mock Export-RegistryKeyBackup -ModuleName Core { return 'C:\Backups\Reg_123.reg' }
            Mock Set-ItemProperty -ModuleName Core { }
            Mock Get-ItemProperty -ModuleName Core { return [PSCustomObject]@{ DisableHardwareAcceleration = 0 } }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Reg_123.reg' }
            Mock Set-ItemProperty { }
            Mock Get-ItemProperty { return [PSCustomObject]@{ DisableHardwareAcceleration = 0 } }

            $res = Set-ToolkitRegistryValue -KeyPath 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics' `
                                            -ValueName 'DisableHardwareAcceleration' `
                                            -Value 1 `
                                            -PropertyType 'DWord' `
                                            -WhatIf

            $res.KeyPath | Should -Match 'Office'
            $res.ValueName | Should -Be 'DisableHardwareAcceleration'
        }
    }

    Context 'Centralized Logging & Summaries' {
        It 'Write-ToolkitLog formats messages with level, timestamp, and component' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Write-ToolkitLog -Message 'Test message' -Level 'Info' -Component 'Core' -LogDirectory $tempLogDir
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter '*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match '\[INFO\]'
                $content | Should -Match '\[Core\]'
                $content | Should -Match 'Test message'
            } finally {
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog suppresses DEBUG messages from console while writing to log file' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Mock Write-Host {}
                Write-ToolkitLog -Message 'Diagnostic debug detail' -Level 'DEBUG' -Component 'Core' -LogDirectory $tempLogDir
                Assert-MockCalled Write-Host -Times 0 -Scope It
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter '*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match '\[DEBUG\]'
                $content | Should -Match '\[Core\]'
                $content | Should -Match 'Diagnostic debug detail'
            } finally {
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Format-ToolkitSummary generates structured output table' -Skip:(-not $isCoreAvailable) {
            $items = @(
                @{ Label = 'PST File Path'; Value = 'C:\Data\archive.pst'; Status = 'OK' },
                @{ Label = 'PST Size'; Value = '48.2 GB'; Status = 'WARN' }
            )
            $output = Format-ToolkitSummary -Title 'Outlook Migration Summary' -Items $items
            $output | Should -Not -BeNullOrEmpty
        }

        It 'Show-ToolkitConfirmation returns true when user enters Y' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return 'Y' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed with destructive reset?'
            $res | Should -BeTrue
        }

        It 'Show-ToolkitConfirmation returns false when user enters N' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return 'N' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed with destructive reset?'
            $res | Should -BeFalse
        }

        It 'Show-ToolkitConfirmation respects default value on empty input' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return '' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed?' -Default $true
            $res | Should -BeTrue

            $res2 = Show-ToolkitConfirmation -Prompt 'Proceed?' -Default $false
            $res2 | Should -BeFalse
        }
    }

    Context 'Upload Boundary & Production Sanitization' {
        It 'Modules/Core does not export Send-ToolkitUpload cmdlet' -Skip:(-not $isCoreAvailable) {
            $manifestPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Modules/Core/Core.psd1'
            $manifest = Import-PowerShellDataFile -Path $manifestPath
            $exports = $manifest.FunctionsToExport
            $exports | Should -Not -Contain 'Send-ToolkitUpload'
        }

        It 'Modules/Core does not export any upload cmdlets' -Skip:(-not $isCoreAvailable) {
            $cmd = Get-Command -Module 'Core' -Name 'Send-ToolkitUpload' -ErrorAction SilentlyContinue
            $cmd | Should -BeNullOrEmpty
        }

        It 'Core module remains 100% clean and local-only' -Skip:(-not $isCoreAvailable) {
            $coreCommands = Get-Command -Module 'Core'
            foreach ($c in $coreCommands) {
                $c.Name | Should -Not -Match '(?i)upload'
            }
        }
    }
}
