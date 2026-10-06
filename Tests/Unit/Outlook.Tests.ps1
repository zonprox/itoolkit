# ==============================================================================
# Outlook.Tests.ps1
# Unit test suite for Modules/Outlook
# Covers: Find-OutlookDataFiles, Move-OutlookDataFile, Update-OutlookProfilePath,
# Set-OutlookPstThreshold, Invoke-OutlookCompaction, Backup-OutlookPst, Restore-OutlookPst.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:OutlookManifest = Join-Path $ProjectRoot 'Modules/Outlook/Outlook.psd1'
$isOutlookAvailable = Test-Path $script:OutlookManifest

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
Describe 'Unit: Outlook Data Management Module' {

    Context 'PST & OST File Discovery' {
        It 'Find-OutlookDataFiles discovers PST and OST files with structured attributes' -Skip:(-not $isOutlookAvailable) {
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\Users\test\archive.pst'; Length = 42GB; Extension = '.pst'; LastWriteTime = (Get-Date) },
                    [PSCustomObject]@{ FullName = 'C:\Users\test\primary.ost'; Length = 15GB; Extension = '.ost'; LastWriteTime = (Get-Date) }
                )
            }
            $files = Find-OutlookDataFiles
            $files.Count | Should -Be 2
            $files[0].Type | Should -Be 'PST'
            $files[1].Type | Should -Be 'OST'
            $files[0].SizeGB | Should -BeGreaterThan 40
        }

        It 'Find-OutlookDataFiles returns empty list when no data files exist' -Skip:(-not $isOutlookAvailable) {
            Mock Get-ChildItem { return @() }
            $files = Find-OutlookDataFiles
            $files.Count | Should -Be 0
        }
    }

    Context 'Safe Data File Relocation' {
        It 'Move-OutlookDataFile verifies SHA-256 match before removing source' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Test-DiskSpaceAvailable { return $true }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            Mock Copy-Item { }
            Mock Get-FileHash { [PSCustomObject]@{ Hash = 'ABCDEF1234567890' } }
            Mock Remove-Item { }
            Mock Update-OutlookProfilePath { return $true }

            $res = Move-OutlookDataFile -SourcePath 'C:\Outlook\old.pst' -DestinationPath 'D:\Outlook\old.pst' -UpdateProfile
            $res.Success | Should -BeTrue
            $res.HashMatched | Should -BeTrue
            $res.ProfileUpdated | Should -BeTrue
        }

        It 'Move-OutlookDataFile aborts and retains source if checksum verification fails' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Test-DiskSpaceAvailable { return $true }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            Mock Copy-Item { }
            $script:call = 0
            Mock Get-FileHash {
                $script:call++
                if ($script:call -eq 1) { return [PSCustomObject]@{ Hash = 'ORIGINAL_HASH' } }
                return [PSCustomObject]@{ Hash = 'CORRUPTED_HASH' }
            }
            Mock Remove-Item { throw "Source must never be deleted if hash fails!" }

            $res = Move-OutlookDataFile -SourcePath 'C:\Outlook\old.pst' -DestinationPath 'D:\Outlook\old.pst'
            $res.Success | Should -BeFalse
            $res.HashMatched | Should -BeFalse
        }

        It 'Move-OutlookDataFile supports WhatIf dry run' -Skip:(-not $isOutlookAvailable) {
            $res = Move-OutlookDataFile -SourcePath 'C:\Outlook\old.pst' -DestinationPath 'D:\Outlook\old.pst' -WhatIf
            $res | Should -Not -BeNullOrEmpty
        }
    }

    Context 'MAPI Profile & Threshold Management' {
        It 'Update-OutlookProfilePath re-maps binary property to new location' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ChildItem { return @([PSCustomObject]@{ PSPath = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375e8691347ba11a89000aa00387402' }) }
            Mock Get-ItemProperty { return [PSCustomObject]@{ '001f6700' = [System.Text.Encoding]::Unicode.GetBytes("C:\Outlook\old.pst`0") } }
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ KeyPath = 'HKCU:\Software\Microsoft\Office'; NewValue = 'D:\Outlook\new.pst' } }
            $res = Update-OutlookProfilePath -ProfileName 'Outlook' -OldPath 'C:\Outlook\old.pst' -NewPath 'D:\Outlook\new.pst'
            $res | Should -BeTrue
        }

        It 'Set-OutlookPstThreshold sets MaxLargeFileSize and WarnLargeFileSize registry policies' -Skip:(-not $isOutlookAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PST.reg' } }
            $res = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
            $res.MaxLargeFileSizeMB | Should -Be 102400
            $res.WarnLargeFileSizeMB | Should -Be 97280
        }

        It 'Invoke-OutlookCompaction launches profile manager guidance' -Skip:(-not $isOutlookAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ Id = 99 } }
            { Invoke-OutlookCompaction } | Should -Not -Throw
        }
    }

    Context 'PST Backup & Restore' {
        It 'Backup-OutlookPst copies file with integrity hash' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Test-DiskSpaceAvailable { return $true }
            Mock Copy-Item { }
            Mock Get-FileHash { return [PSCustomObject]@{ Hash = 'HASH123' } }
            $res = Backup-OutlookPst -SourcePath 'C:\Data\archive.pst' -BackupDirectory 'D:\Backups'
            $res.Success | Should -BeTrue
            $res.Hash | Should -Be 'HASH123'
        }

        It 'Restore-OutlookPst validates hash before declaring success' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Copy-Item { }
            Mock Get-FileHash { return [PSCustomObject]@{ Hash = 'RESTORE_HASH' } }
            $res = Restore-OutlookPst -BackupPath 'D:\Backups\archive.pst' -DestinationPath 'C:\Data\archive.pst'
            $res.Success | Should -BeTrue
            $res.HashVerified | Should -BeTrue
        }
    }
}
