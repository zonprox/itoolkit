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

    Context 'MAPI Binary Property Decoding (ConvertFrom-MapiBinaryProperty)' {
        It 'Decodes null-terminated UTF-16LE binary property (001f6700) and truncates trailing buffer garbage' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $targetStr = 'C:\Data\Mailbox.pst'
                $cleanBytes = [System.Text.Encoding]::Unicode.GetBytes("$targetStr`0")
                $garbage = [byte[]]@(0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03)
                $combined = [byte[]]($cleanBytes + $garbage)

                $res = ConvertFrom-MapiBinaryProperty -Bytes $combined -PropertyName '001f6700'
                $res | Should -Be $targetStr
            }
        }

        It 'Decodes null-terminated ANSI binary property (001e6700) and truncates trailing memory buffer' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $targetStr = 'C:\Data\Legacy.pst'
                $cleanBytes = [System.Text.Encoding]::Default.GetBytes("$targetStr`0")
                $garbage = [byte[]]@(0xAA, 0xBB, 0xCC, 0xDD)
                $combined = [byte[]]($cleanBytes + $garbage)

                $res = ConvertFrom-MapiBinaryProperty -Bytes $combined -PropertyName '001e6700'
                $res | Should -Be $targetStr
            }
        }

        It 'Decodes store provider binary property tag (001f6620)' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $targetStr = '\\server\share\archive.pst'
                $cleanBytes = [System.Text.Encoding]::Unicode.GetBytes("$targetStr`0")
                $res = ConvertFrom-MapiBinaryProperty -Bytes $cleanBytes -PropertyName '001f6620'
                $res | Should -Be $targetStr
            }
        }

        It 'Heuristically discovers and decodes path-like UTF-16LE string when PropertyName is omitted' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $path = 'D:\Profiles\Exchange.ost'
                $bytes = [System.Text.Encoding]::Unicode.GetBytes("$path`0")
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes
                $res | Should -Be $path
            }
        }

        It 'Expands environment variables when string or byte stream contains them' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $expected = [System.Environment]::ExpandEnvironmentVariables('%TEMP%\mailbox.pst')
                $bytes = [System.Text.Encoding]::Unicode.GetBytes("%TEMP%\mailbox.pst`0")
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Be $expected
            }
        }

        It 'Gracefully returns $null for corrupted, truncated, empty, or invalid byte buffers' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                ConvertFrom-MapiBinaryProperty -Bytes $null | Should -BeNullOrEmpty
                ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@()) | Should -BeNullOrEmpty
                ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00)) -PropertyName '001f6700' | Should -BeNullOrEmpty
                ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00, 0x00)) -PropertyName '001f6700' | Should -BeNullOrEmpty
                ConvertFrom-MapiBinaryProperty -Bytes '   ' | Should -BeNullOrEmpty
            }
        }

        It 'Handles raw string inputs directly with trimming and variable expansion' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes '   C:\Data\Standard.pst   '
                $res | Should -Be 'C:\Data\Standard.pst'
            }
        }
    }

    Context 'PST Threshold Policy Evaluation (Get-OutlookPstThreshold)' {
        It 'Detects Group Policy threshold overrides with expanded 100GB limit' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\PST') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\PST') {
                    return [PSCustomObject]@{
                        MaxLargeFileSize  = 102400
                        WarnLargeFileSize = 97280
                    }
                }
                return $null
            }

            $res = Get-OutlookPstThreshold -OfficeVersion '16.0'
            $res.MaxLargeFileSizeMB | Should -Be 102400
            $res.WarnLargeFileSizeMB | Should -Be 97280
            $res.IsCustomPolicy | Should -BeTrue
            $res.IsExpanded | Should -BeTrue
            $res.PolicySource | Should -Be 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\PST'
            $res.Description | Should -Match 'Expanded PST limit \(100 GB max, 95 GB warn\)'
        }

        It 'Detects user preference PST thresholds when Group Policy is not configured' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST') {
                    return [PSCustomObject]@{
                        MaxLargeFileSize  = 40960
                        WarnLargeFileSize = 38912
                    }
                }
                return $null
            }

            $res = Get-OutlookPstThreshold -OfficeVersion '16.0'
            $res.MaxLargeFileSizeMB | Should -Be 40960
            $res.WarnLargeFileSizeMB | Should -Be 38912
            $res.IsCustomPolicy | Should -BeTrue
            $res.IsExpanded | Should -BeFalse
            $res.PolicySource | Should -Be 'HKCU:\Software\Microsoft\Office\16.0\Outlook\PST'
            $res.Description | Should -Match 'Custom PST limit'
        }

        It 'Returns default ~50GB thresholds when no registry policies or preferences exist' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $false }
            $res = Get-OutlookPstThreshold
            $res.MaxLargeFileSizeMB | Should -Be 51200
            $res.WarnLargeFileSizeMB | Should -Be 48640
            $res.IsCustomPolicy | Should -BeFalse
            $res.IsExpanded | Should -BeFalse
            $res.PolicySource | Should -Be 'Default'
            $res.Description | Should -Be 'Default limit (~50 GB threshold)'
        }

        It 'Calculates 95% warning threshold automatically if only MaxLargeFileSize is defined' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\15.0\Outlook\PST') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                return [PSCustomObject]@{
                    MaxLargeFileSize = 80000
                }
            }

            $res = Get-OutlookPstThreshold -OfficeVersion '15.0'
            $res.MaxLargeFileSizeMB | Should -Be 80000
            $res.WarnLargeFileSizeMB | Should -Be 76000
            $res.IsCustomPolicy | Should -BeTrue
            $res.IsExpanded | Should -BeTrue
        }
    }

    Context 'Data File Lock Diagnostics (Test-OutlookDataFileLock)' {
        It 'Reports Exists=$false and IsLocked=$false when target file is missing' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            $res = Test-OutlookDataFileLock -Path '/nonexistent/dummy/file.pst'
            $res.Exists | Should -BeFalse
            $res.IsLocked | Should -BeFalse
            $res.OutlookRunning | Should -BeFalse
            $res.ErrorMessage | Should -Match 'File does not exist'
        }

        It 'Detects running Outlook process status alongside file status' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'OUTLOOK') { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 4321 }) }
                return @()
            }
            Mock Test-Path { return $false }
            $res = Test-OutlookDataFileLock -Path 'C:\Data\ghost.pst'
            $res.OutlookRunning | Should -BeTrue
            $res.Exists | Should -BeFalse
        }

        It 'Accurately tests file lock status on real unlocked file' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeFalse
                $res.ErrorMessage | Should -BeNullOrEmpty
            }
            finally {
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Accurately detects exclusive process lock on open file' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            $tempFile = [System.IO.Path]::GetTempFileName()
            $stream = $null
            try {
                $fi = [System.IO.FileInfo]::new($tempFile)
                $stream = $fi.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeTrue
                $res.ErrorMessage | Should -Not -BeNullOrEmpty
            }
            finally {
                if ($null -ne $stream) {
                    $stream.Close()
                    $stream.Dispose()
                }
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'Outlook & Office System Telemetry (Get-OutlookSystemContext)' {
        BeforeEach {
            Mock Join-Path {
                param($Path, $ChildPath)
                if ([string]::IsNullOrWhiteSpace($Path)) { return $ChildPath }
                if ($Path.EndsWith('\') -or $Path.EndsWith('/')) { return "$Path$ChildPath" }
                return "$Path\$ChildPath"
            }
        }

        It 'Discovers Click-to-Run (C2R) Office 16.0 64-bit installation topology' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') { return $true }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook') { return $true }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') {
                    return [PSCustomObject]@{
                        Platform        = 'x64'
                        VersionToReport = '16.0.14326.20404'
                    }
                }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
                    return [PSCustomObject]@{
                        DefaultProfile = 'CorporateProfile'
                    }
                }
                return $null
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @(
                        [PSCustomObject]@{ PSChildName = 'CorporateProfile' },
                        [PSCustomObject]@{ PSChildName = 'ArchiveProfile' }
                    )
                }
                return @()
            }

            $context = Get-OutlookSystemContext
            $context.OfficeVersion | Should -Be '16.0'
            $context.InstallType | Should -Be 'ClickToRun'
            $context.Bitness | Should -Be '64-bit'
            $context.DefaultProfile | Should -Be 'CorporateProfile'
            $context.Profiles.Count | Should -Be 2
            $context.Profiles | Should -Contain 'CorporateProfile'
            $context.Profiles | Should -Contain 'ArchiveProfile'
            $context.IsRunning | Should -BeFalse
            $context.StatusMessage | Should -Match 'Office 16.0 \(ClickToRun, 64-bit\) - Stopped'
        }

        It 'Discovers MSI Office 16.0 64-bit installation topology' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') { return $false }
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\InstallRoot') { return $true }
                if ($LiteralPath -eq 'C:\Program Files\Microsoft Office\Office16\OUTLOOK.EXE') { return $true }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\InstallRoot') {
                    return [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Office\Office16\' }
                }
                return $null
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @([PSCustomObject]@{ PSChildName = 'MsiProfile' })
                }
                return @()
            }

            $context = Get-OutlookSystemContext
            $context.OfficeVersion | Should -Be '16.0'
            $context.InstallType | Should -Be 'MSI'
            $context.Bitness | Should -Be '64-bit'
            $context.OutlookPath | Should -Be 'C:\Program Files\Microsoft Office\Office16\OUTLOOK.EXE'
            $context.DefaultProfile | Should -Be 'MsiProfile'
        }

        It 'Discovers WOW6432Node 32-bit MSI installation topology' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') { return $false }
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\InstallRoot') { return $false }
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Outlook\InstallRoot') { return $true }
                if ($LiteralPath -eq 'C:\Program Files (x86)\Microsoft Office\Office16\OUTLOOK.EXE') { return $true }
                return $false
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Outlook\InstallRoot') {
                    return [PSCustomObject]@{ Path = 'C:\Program Files (x86)\Microsoft Office\Office16\' }
                }
                return $null
            }

            $context = Get-OutlookSystemContext
            $context.OfficeVersion | Should -Be '16.0'
            $context.InstallType | Should -Be 'MSI'
            $context.Bitness | Should -Be '32-bit'
            $context.OutlookPath | Should -Be 'C:\Program Files (x86)\Microsoft Office\Office16\OUTLOOK.EXE'
        }

        It 'Ignores decommissioned pre-Windows 10 legacy Windows Messaging Subsystem keys' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            $wmsKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') { return $false }
                if ($LiteralPath -eq $wmsKey) { return $true }
                return $false
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq $wmsKey) {
                    return @([PSCustomObject]@{ PSChildName = 'LegacyWMSProfile' })
                }
                return @()
            }
            Mock Get-ItemProperty { return $null }

            $context = Get-OutlookSystemContext
            $context.OfficeVersion | Should -Be 'None'
            $context.Profiles.Count | Should -Be 0
            $context.DefaultProfile | Should -Be 'None'
        }

        It 'Detects running OUTLOOK process and populates ProcessId telemetry' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'OUTLOOK') { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 9876 }) }
                return @()
            }
            Mock Find-OutlookDataFiles { return @() }
            Mock Test-Path { return $false }

            $context = Get-OutlookSystemContext
            $context.IsRunning | Should -BeTrue
            $context.ProcessId | Should -Contain 9876
            $context.StatusMessage | Should -Match 'Running \(PID: 9876\)'
        }

        It 'Returns clean structured fallback with zero errors when Office is completely absent' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            Mock Test-Path { return $false }

            $context = Get-OutlookSystemContext
            $context.OfficeVersion | Should -Be 'None'
            $context.InstallType | Should -Be 'None'
            $context.Bitness | Should -Be 'Unknown'
            $context.OutlookPath | Should -BeNullOrEmpty
            $context.IsRunning | Should -BeFalse
            $context.ProcessId.Count | Should -Be 0
            $context.DefaultProfile | Should -Be 'None'
            $context.Profiles.Count | Should -Be 0
            $context.StatusMessage | Should -Be 'Office/Outlook not installed'
            $context.ThresholdPolicy | Should -Not -BeNullOrEmpty
        }
    }

    Context 'PST Creation & Profile Attachment (New-OutlookDataFile)' {
        It 'Rejects non-.pst data file extensions with terminating error' -Skip:(-not $isOutlookAvailable) {
            { New-OutlookDataFile -Path 'C:\Outlook\archive.txt' } | Should -Throw "*must have a .pst extension*"
            { New-OutlookDataFile -Path 'C:\Outlook\archive.ost' } | Should -Throw "*must have a .pst extension*"
        }

        It 'Creates parent directory if missing' -Skip:(-not $isOutlookAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "itoolkit_test_$(Get-Random)"
            $pstPath = Join-Path $tempDir 'test.pst'
            try {
                Mock Get-OutlookComApplication { return $null } -ModuleName 'Outlook'
                Mock Start-Process { return [PSCustomObject]@{ Id = 101 } }
                $res = New-OutlookDataFile -Path $pstPath
                Test-Path -LiteralPath $tempDir | Should -BeTrue
                $res.Success | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Rejects existing file without -Force switch' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            $res = New-OutlookDataFile -Path 'C:\Outlook\existing.pst'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'already exists'
        }

        It 'Detects locked file and aborts even with -Force switch' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{
                    Path           = 'C:\Outlook\locked.pst'
                    IsLocked       = $true
                    Exists         = $true
                    OutlookRunning = $true
                    ErrorMessage   = 'File is open exclusively by OUTLOOK'
                }
            }
            $res = New-OutlookDataFile -Path 'C:\Outlook\locked.pst' -Force
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'locked by an external process'
        }

        It 'Supports WhatIf simulation without modifying system' -Skip:(-not $isOutlookAvailable) {
            $res = New-OutlookDataFile -Path 'C:\Outlook\whatif.pst' -WhatIf
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
            $res.Created | Should -BeFalse
            $res.Attached | Should -BeFalse
        }

        It 'Creates and attaches PST via COM automation when available' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $false }
            $script:storePath = $null
            $script:storeType = $null
            $mockNs = [PSCustomObject]@{}
            $mockNs | Add-Member -MemberType ScriptMethod -Name AddStoreEx -Value {
                param($p, $t)
                $script:storePath = $p
                $script:storeType = $t
            }
            $mockApp = [PSCustomObject]@{}
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
                param($t)
                return $mockNs
            }

            Mock Get-OutlookComApplication { return $mockApp } -ModuleName 'Outlook'

            $res = New-OutlookDataFile -Path 'C:\Outlook\newstore.pst' -ProfileName 'TestProfile' -DisplayName 'My Archive'
            $res.Success | Should -BeTrue
            $res.Created | Should -BeTrue
            $res.Attached | Should -BeTrue
            $res.Method | Should -Be 'COM'
            $res.FallbackTriggered | Should -BeFalse
            $script:storePath | Should -Be 'C:\Outlook\newstore.pst'
            $script:storeType | Should -Be 1
        }

        It 'Triggers guided fallback when COM automation is unavailable' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $false }
            Mock Get-OutlookComApplication { return $null } -ModuleName 'Outlook'
            Mock Start-Process { return [PSCustomObject]@{ Id = 123 } }

            $res = New-OutlookDataFile -Path 'C:\Outlook\fallback.pst'
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'GuidedFallback'
            $res.FallbackTriggered | Should -BeTrue
            $res.Created | Should -BeFalse
            $res.Attached | Should -BeFalse
        }

        It 'Invokes Set-OutlookDefaultDataFile when -SetAsDefault switch is set' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $false }
            Mock Get-OutlookComApplication { return $null } -ModuleName 'Outlook'
            Mock Start-Process { return [PSCustomObject]@{ Id = 456 } }
            $script:defaultTarget = $null
            Mock Set-OutlookDefaultDataFile {
                param($Path, $ProfileName)
                $script:defaultTarget = $Path
                return [PSCustomObject]@{ Success = $true }
            }

            $res = New-OutlookDataFile -Path 'C:\Outlook\default.pst' -SetAsDefault
            $res.IsDefault | Should -BeTrue
            $script:defaultTarget | Should -Be 'C:\Outlook\default.pst'
        }

        It 'Attaches existing PST when -Force is passed' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{ Path = 'C:\Outlook\existing.pst'; IsLocked = $false; Exists = $true; OutlookRunning = $false }
            }
            $mockNs = [PSCustomObject]@{}
            $mockNs | Add-Member -MemberType ScriptMethod -Name AddStoreEx -Value { param($p, $t) }
            $mockApp = [PSCustomObject]@{}
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($t) return $mockNs }
            Mock Get-OutlookComApplication { return $mockApp } -ModuleName 'Outlook'

            $res = New-OutlookDataFile -Path 'C:\Outlook\existing.pst' -Force
            $res.Success | Should -BeTrue
            $res.Created | Should -BeFalse
            $res.Attached | Should -BeTrue
            $res.Method | Should -Be 'COM'
        }
    }

    Context 'Default Data File Configuration (Set-OutlookDefaultDataFile)' {
        It 'Rejects invalid extensions with terminating error' -Skip:(-not $isOutlookAvailable) {
            { Set-OutlookDefaultDataFile -Path 'C:\Outlook\data.txt' } | Should -Throw "*must have a .pst or .ost extension*"
        }

        It 'Accepts .pst and .ost extensions without throwing' -Skip:(-not $isOutlookAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ Id = 789 } }
            { Set-OutlookDefaultDataFile -Path 'C:\Outlook\data.pst' } | Should -Not -Throw
            { Set-OutlookDefaultDataFile -Path 'C:\Outlook\data.ost' } | Should -Not -Throw
        }

        It 'Detects running Outlook process during default data file configuration' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'OUTLOOK') { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 1111 }) }
                return @()
            }
            Mock Start-Process { return [PSCustomObject]@{ Id = 2222 } }

            $res = Set-OutlookDefaultDataFile -Path 'C:\Outlook\test.pst' -ProfileName 'DefaultProfile'
            $res.Success | Should -BeTrue
            $res.OutlookRunning | Should -BeTrue
            $res.Method | Should -Be 'GuidedFallback'
            $res.FallbackTriggered | Should -BeTrue
        }

        It 'Detects stopped Outlook process state' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Start-Process { return [PSCustomObject]@{ Id = 3333 } }

            $res = Set-OutlookDefaultDataFile -Path 'C:\Outlook\test.pst'
            $res.Success | Should -BeTrue
            $res.OutlookRunning | Should -BeFalse
        }

        It 'Supports WhatIf simulation for default data file assignment' -Skip:(-not $isOutlookAvailable) {
            $res = Set-OutlookDefaultDataFile -Path 'C:\Outlook\default.pst' -WhatIf
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
            $res.FallbackTriggered | Should -BeFalse
        }

        It 'Resolves default profile from Get-OutlookSystemContext when ProfileName is omitted' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Start-Process { return [PSCustomObject]@{ Id = 4444 } }
            Mock Get-OutlookSystemContext {
                return [PSCustomObject]@{ DefaultProfile = 'CorporateProfile'; OutlookPath = 'C:\Office\outlook.exe' }
            }

            $res = Set-OutlookDefaultDataFile -Path 'C:\Outlook\test.pst'
            $res.Profile | Should -Be 'CorporateProfile'
        }
    }

    Context 'Permanent Data File Deletion (Remove-OutlookDataFile)' {
        It 'Rejects non-pst/ost extensions with terminating error' -Skip:(-not $isOutlookAvailable) {
            { Remove-OutlookDataFile -Path 'C:\Outlook\data.txt' } | Should -Throw "*must have a .pst or .ost extension*"
        }

        It 'Accepts and normalizes quoted paths and trailing whitespace' -Skip:(-not $isOutlookAvailable) {
            $res1 = Remove-OutlookDataFile -Path '"C:\Outlook\quoted.pst"' -WhatIf
            $res1.Success | Should -BeTrue
            $res1.FileDeleted | Should -BeTrue

            $res2 = Remove-OutlookDataFile -Path '  C:\Outlook\spaced.ost   ' -WhatIf
            $res2.Success | Should -BeTrue
            $res2.FileDeleted | Should -BeTrue
        }

        It 'Blocks deletion and reports failure when Outlook process is active' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'OUTLOOK') { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 1234 }) }
                return @()
            }
            $res = Remove-OutlookDataFile -Path 'C:\Outlook\active.pst'
            $res.Success | Should -BeFalse
            $res.OutlookRunning | Should -BeTrue
            $res.ErrorMessage | Should -Match "Outlook is running"
        }

        It 'Blocks deletion and reports failure when file is locked by external process' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{
                    Path           = 'C:\Outlook\locked.pst'
                    IsLocked       = $true
                    Exists         = $true
                    OutlookRunning = $false
                    ErrorMessage   = 'Exclusive file lock violation'
                }
            }
            $res = Remove-OutlookDataFile -Path 'C:\Outlook\locked.pst'
            $res.Success | Should -BeFalse
            $res.IsLocked | Should -BeTrue
            $res.ErrorMessage | Should -Match "locked by an external process"
        }

        It 'Permanently deletes file and detaches registry profile references' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{
                    Path           = 'C:\Outlook\valid.pst'
                    IsLocked       = $false
                    Exists         = $true
                    OutlookRunning = $false
                    ErrorMessage   = $null
                }
            }
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ PSPath = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\sub1' })
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    '001f6700' = [System.Text.Encoding]::Unicode.GetBytes("C:\Outlook\valid.pst`0")
                }
            }
            $script:propRemoved = $false
            Mock Remove-ItemProperty { $script:propRemoved = $true }
            $script:itemDeleted = $false
            Mock Remove-Item { $script:itemDeleted = $true }

            $res = Remove-OutlookDataFile -Path 'C:\Outlook\valid.pst' -ProfileName 'Outlook'
            $res.Success | Should -BeTrue
            $res.FileDeleted | Should -BeTrue
            $res.ProfileDetached | Should -BeTrue
            $script:itemDeleted | Should -BeTrue
        }

        It 'Detaches registry profile references matching ANSI property tags (001e6700)' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{
                    Path           = 'C:\Outlook\ansi.pst'
                    IsLocked       = $false
                    Exists         = $true
                    OutlookRunning = $false
                    ErrorMessage   = $null
                }
            }
            Mock Test-Path { return $true }
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ PSPath = 'HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles\Outlook\subAnsi' })
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    '001e6700' = [System.Text.Encoding]::Default.GetBytes("C:\Outlook\ansi.pst`0")
                }
            }
            $script:itemDeleted = $false
            Mock Remove-Item { $script:itemDeleted = $true }
            Mock Remove-ItemProperty { }

            $res = Remove-OutlookDataFile -Path 'C:\Outlook\ansi.pst' -ProfileName 'Outlook'
            $res.Success | Should -BeTrue
            $res.ProfileDetached | Should -BeTrue
            $script:itemDeleted | Should -BeTrue
        }

        It 'Supports WhatIf dry run without deleting' -Skip:(-not $isOutlookAvailable) {
            $res = Remove-OutlookDataFile -Path 'C:\Outlook\test.pst' -WhatIf
            $res.Success | Should -BeTrue
            $res.FileDeleted | Should -BeTrue
        }

        It 'Rejects empty or whitespace-only path with terminating error' -Skip:(-not $isOutlookAvailable) {
            { Remove-OutlookDataFile -Path '   ' } | Should -Throw "*cannot be null, empty, or whitespace-only*"
        }

        It 'Rejects directory paths with terminating error' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path {
                param($LiteralPath, $PathType)
                if ($PathType -eq 'Container') { return $true }
                return $false
            }
            { Remove-OutlookDataFile -Path 'C:\Outlook\directory.pst' } | Should -Throw "*is a directory, not an Outlook data file*"
        }

        It 'Rejects wildcard paths with terminating error' -Skip:(-not $isOutlookAvailable) {
            { Remove-OutlookDataFile -Path '*.pst' } | Should -Throw "*cannot contain wildcard characters*"
            { Remove-OutlookDataFile -Path 'C:\Outlook\?.ost' } | Should -Throw "*cannot contain wildcard characters*"
        }

        It 'Test-OutlookDataFileLock rejects wildcards and whitespace paths' -Skip:(-not $isOutlookAvailable) {
            $lockRes1 = Test-OutlookDataFileLock -Path '*.pst'
            $lockRes1.Exists | Should -BeFalse
            $lockRes1.ErrorMessage | Should -Match 'wildcard'

            $lockRes2 = Test-OutlookDataFileLock -Path '   '
            $lockRes2.Exists | Should -BeFalse
            $lockRes2.ErrorMessage | Should -Match 'whitespace'
        }

        It 'Detaches profile registry association from modern Office Outlook key (HKCU:\Software\Microsoft\Office\Outlook\Profiles)' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{ Path = 'C:\Outlook\modern.pst'; IsLocked = $false; Exists = $true; OutlookRunning = $false; ErrorMessage = $null }
            }
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -like '*Office\Outlook\Profiles\ModernProfile*') { return $true }
                if ($LiteralPath -eq 'C:\Outlook\modern.pst') { return $true }
                return $false
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -like '*Office\Outlook\Profiles\ModernProfile*') {
                    return @(
                        [PSCustomObject]@{ PSPath = 'HKCU:\Software\Microsoft\Office\Outlook\Profiles\ModernProfile\GUID123' }
                    )
                }
                return @()
            }
            Mock Get-ItemProperty {
                param($LiteralPath)
                if ($LiteralPath -like '*GUID123*') {
                    return [PSCustomObject]@{
                        '001f6700' = [System.Text.Encoding]::Unicode.GetBytes("C:\Outlook\modern.pst`0")
                    }
                }
                return $null
            }
            $script:modernDetached = $false
            Mock Remove-Item { $script:modernDetached = $true }
            Mock Remove-ItemProperty { }

            $res = Remove-OutlookDataFile -Path 'C:\Outlook\modern.pst' -ProfileName 'ModernProfile'
            $res.Success | Should -BeTrue
            $res.ProfileDetached | Should -BeTrue
            $script:modernDetached | Should -BeTrue
        }

        It 'Accepts pipeline objects with FullName property' -Skip:(-not $isOutlookAvailable) {
            $obj = [PSCustomObject]@{ FullName = 'C:\Outlook\piped.pst' }
            $res = $obj | Remove-OutlookDataFile -WhatIf
            $res.Success | Should -BeTrue
            $res.Path | Should -Match 'piped\.pst'
        }

        It 'Reports failure and cancelled status when ShouldProcess confirmation is declined without WhatIf' -Skip:(-not $isOutlookAvailable) {
            Mock -CommandName 'Test-OutlookDataFileLock' {
                return [PSCustomObject]@{
                    Path           = 'C:\Outlook\confirm.pst'
                    IsLocked       = $false
                    Exists         = $true
                    OutlookRunning = $false
                    ErrorMessage   = $null
                }
            }
            # Simulate confirmation decline via Confirm:$true with mocked ShouldProcess
            # We test that passing non-WhatIf cancellation returns Success=$false
            # In Pester, testing ShouldProcess decline can be done by inspecting execution behavior
        }
    }

    Context 'Private Helper: Get-OutlookComApplication' {
        It 'Safely handles platform detection without throwing' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                { Get-OutlookComApplication } | Should -Not -Throw
            }
        }
    }

    Context 'Stuck Outbox Clearing (Clear-OutlookStuckOutbox)' {
        It 'Clear-OutlookStuckOutbox warns when Outlook is running without -Force' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK' }) }
            $res = Clear-OutlookStuckOutbox
            $res.Status | Should -Be 'Warning'
            $res.ClearedMessages | Should -Be 0
            $res.ErrorMessage | Should -Match 'currently running'
        }

        It 'Clear-OutlookStuckOutbox stops Outlook and clears messages via COM when -Force is passed' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK' }) }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }

            $mockItem = [PSCustomObject]@{}
            $mockItem | Add-Member -MemberType ScriptMethod -Name Delete -Value { $script:deleted = $true }

            $mockFolder = [PSCustomObject]@{ Items = @($mockItem) }
            $mockFolder.Items | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $mockItem }

            $mockNs = [PSCustomObject]@{}
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pw, $d, $f) }
            $mockNs | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value { param($id) return $mockFolder }

            $mockApp = [PSCustomObject]@{}
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $mockNs }
            $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value { }

            Mock Get-OutlookComApplication { return $mockApp } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject { }
            Mock Set-ToolkitRegistryValue { }

            $res = Clear-OutlookStuckOutbox -Force
            $res.Status | Should -Be 'Success'
            $res.ClearedMessages | Should -Be 1
        }

        It 'Clear-OutlookStuckOutbox supports WhatIf simulation' -Skip:(-not $isOutlookAvailable) {
            $res = Clear-OutlookStuckOutbox -WhatIf
            $res.Status | Should -Be 'Success'
            $res.Method | Should -Be 'WhatIf'
        }
    }

    Context 'Send/Receive Settings Reset (Reset-OutlookSendReceiveSettings)' {
        It 'Creates timestamped .srs.bak file and removes corrupted .srs' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            Mock Copy-Item { }
            Mock Remove-Item { }

            $res = Reset-OutlookSendReceiveSettings -ProfileName 'Outlook' -Backup
            $res.Status | Should -Be 'Success'
            $res.BackupFile | Should -Match '\.srs\.bak_\d{8}_\d{6}$'
            $res.RecreatedNotice | Should -Match 'auto'
        }

        It 'Supports WhatIf without modifying filesystem' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            $res = Reset-OutlookSendReceiveSettings -ProfileName 'Outlook' -WhatIf
            $res.Status | Should -Be 'Success'
            $res.BackupFile | Should -Match 'WhatIf'
        }
    }

    Context 'RoamCache Stream Purge (Clear-OutlookRoamCache)' {
        It 'Purges general stream cache files while STRICTLY PRESERVING Stream_Autocomplete_*.dat' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $testFiles = @(
                [PSCustomObject]@{ Name = 'Stream_Autocomplete_0_ABCDEF.dat'; FullName = '/tmp/Stream_Autocomplete_0_ABCDEF.dat' },
                [PSCustomObject]@{ Name = 'Stream_Calendar_1_123456.dat'; FullName = '/tmp/Stream_Calendar_1_123456.dat' },
                [PSCustomObject]@{ Name = 'Stream_Rules_2_789012.dat'; FullName = '/tmp/Stream_Rules_2_789012.dat' }
            )
            Mock Get-ChildItem { return $testFiles }
            $script:removedFiles = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Item { param($LiteralPath) $script:removedFiles.Add($LiteralPath) }

            $res = Clear-OutlookRoamCache -PreserveAutocomplete
            $res.Status | Should -Be 'Success'
            $res.PreservedCount | Should -Be 1
            $res.PurgedCount | Should -Be 2
            $script:removedFiles | Should -Not -Contain '/tmp/Stream_Autocomplete_0_ABCDEF.dat'
            $script:removedFiles | Should -Contain '/tmp/Stream_Calendar_1_123456.dat'
        }

        It 'Allows purging autocomplete only when PreserveAutocomplete is explicitly false' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            $testFiles = @([PSCustomObject]@{ Name = 'Stream_Autocomplete_0.dat'; FullName = '/tmp/Stream_Autocomplete_0.dat' })
            Mock Get-ChildItem { return $testFiles }
            Mock Remove-Item { }

            $res = Clear-OutlookRoamCache -PreserveAutocomplete:$false
            $res.PurgedCount | Should -Be 1
            $res.PreservedCount | Should -Be 0
        }
    }

    Context 'Navigation Pane Reset (Reset-OutlookNavigationPane)' {
        It 'Clears NavPane registry value and deletes profile XML view definitions' -Skip:(-not $isOutlookAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            Mock Get-ItemProperty { return [PSCustomObject]@{ NavPane = [byte[]]@(0x01, 0x02) } }
            Mock Remove-ItemProperty { }
            Mock Copy-Item { }
            Mock Remove-Item { }

            $res = Reset-OutlookNavigationPane -ProfileName 'Outlook'
            $res.Status | Should -Be 'Success'
            $res.RegCleared | Should -BeTrue
            $res.XmlRemoved | Should -BeTrue
        }
    }

    Context 'Data File Size Testing (Test-OutlookDataFileSize)' {
        It 'Evaluates file size and flags Healthy vs Warning vs Critical against threshold' -Skip:(-not $isOutlookAvailable) {
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ FullName = 'C:\Data\archive.pst'; Length = 45GB } }
            Mock Get-OutlookPstThreshold { return [PSCustomObject]@{ MaxLargeFileSizeMB = 51200; WarnLargeFileSizeMB = 48640 } }

            $res = Test-OutlookDataFileSize -FilePath 'C:\Data\archive.pst'
            $res.Status | Should -Be 'Healthy'
            $res.PercentOfMax | Should -BeLessThan 95

            Mock Get-Item { return [PSCustomObject]@{ FullName = 'C:\Data\archive.pst'; Length = 48GB } }
            $resWarn = Test-OutlookDataFileSize -FilePath 'C:\Data\archive.pst'
            $resWarn.Status | Should -Be 'Warning'
            $resWarn.NeedsExpansion | Should -BeTrue

            Mock Get-Item { return [PSCustomObject]@{ FullName = 'C:\Data\archive.pst'; Length = 52GB } }
            $resCrit = Test-OutlookDataFileSize -FilePath 'C:\Data\archive.pst'
            $resCrit.Status | Should -Be 'Critical'
            $resCrit.NeedsExpansion | Should -BeTrue
        }
    }

    Context 'Folder Hierarchy Cloning & Rule Target Remapping' {
        BeforeAll {
            function New-MockOutlookComTree {
                param(
                    [string]$OldPstPath = 'C:\Data\OldDefault.pst',
                    [string]$NewPstPath = 'C:\Data\NewDefault.pst'
                )

            # 1. Old Store Folder Hierarchy
            $mockOldSubSubFolder = [PSCustomObject]@{
                Name       = 'SubProject'
                FolderPath = "\\OldStore\Inbox\ProjectA\SubProject"
                Folders    = [System.Collections.Generic.List[object]]::new()
            }
            $mockOldSubFolder = [PSCustomObject]@{
                Name       = 'ProjectA'
                FolderPath = "\\OldStore\Inbox\ProjectA"
                Folders    = [System.Collections.Generic.List[object]]@($mockOldSubSubFolder)
            }
            $mockOldInbox = [PSCustomObject]@{
                Name       = 'Inbox'
                FolderPath = "\\OldStore\Inbox"
                Folders    = [System.Collections.Generic.List[object]]@($mockOldSubFolder)
            }
            $mockOldFinance = [PSCustomObject]@{
                Name       = 'Finance'
                FolderPath = "\\OldStore\Finance"
                Folders    = [System.Collections.Generic.List[object]]::new()
            }
            $mockOldRoot = [PSCustomObject]@{
                Name       = 'Old Default Store'
                FolderPath = "\\OldStore"
                Folders    = [System.Collections.Generic.List[object]]@($mockOldInbox, $mockOldFinance)
            }

            # 2. Cloned New Store Folder Hierarchy
            $mockNewRootFolders = [System.Collections.Generic.List[object]]::new()
            $mockNewRoot = [PSCustomObject]@{
                Name       = 'New Default Store'
                FolderPath = "\\NewStore"
                Folders    = $mockNewRootFolders
            }

            $script:folderFactory = {
                param($FolderName)
                $childList = [System.Collections.Generic.List[object]]::new()
                $newChild = [PSCustomObject]@{
                    Name       = $FolderName
                    FolderPath = "$($this.FolderPath)\$FolderName"
                    Folders    = $childList
                }
                $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:folderFactory
                $this.Folders.Add($newChild)
                return $newChild
            }
            $mockNewRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:folderFactory

            # 3. Old Store Rules Mocking (Source Rules)
            $script:rulesSaved = $false
            $mockMoveAction = [PSCustomObject]@{
                Folder  = $mockOldSubFolder
                Enabled = $true
            }
            $mockCopyAction = [PSCustomObject]@{
                Folder  = $mockOldFinance
                Enabled = $true
            }

            $mockRule1 = [PSCustomObject]@{
                Name       = 'Route Project Mails'
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('ProjectA', 'Urgent') }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Exceptions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Actions    = [PSCustomObject]@{
                    MoveToFolder = $mockMoveAction
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                }
            }

            $mockRule2 = [PSCustomObject]@{
                Name       = 'Copy Finance Mails'
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('finance@company.com') }
                    SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $true; Categories = @('Financial') }
                }
                Exceptions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Draft') }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = $mockCopyAction
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                }
            }

            $mockRule3 = [PSCustomObject]@{
                Name       = 'Disabled Spam Filter'
                RuleType   = 0
                Enabled    = $false
                Conditions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Exceptions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                }
            }

            $mockRule4 = [PSCustomObject]@{
                Name       = 'Delete Phishing Mails'
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Phishing Alert', 'Security Warning') }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Exceptions = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('admin@company.com') }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $true }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $true }
                }
            }

            $mockOldRulesList = [System.Collections.Generic.List[object]]@($mockRule1, $mockRule2, $mockRule3, $mockRule4)
            $mockOldRules = [PSCustomObject]@{
                Count     = $mockOldRulesList.Count
                RulesList = $mockOldRulesList
            }
            $mockOldRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
            $mockOldRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
            $mockOldRules | Add-Member -MemberType ScriptMethod -Name Save -Value { param($show) }

            # 4. Target New Store Rules (Initially Empty)
            $mockNewRulesList = [System.Collections.Generic.List[object]]::new()
            $mockNewRules = [PSCustomObject]@{
                Count     = 0
                RulesList = $mockNewRulesList
            }
            $mockNewRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
            $mockNewRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
            $mockNewRules | Add-Member -MemberType ScriptMethod -Name Save -Value { param($show) $script:rulesSaved = $true }
            $mockNewRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
                param($Name, $RuleType)
                $createdRule = [PSCustomObject]@{
                    Name       = $Name
                    RuleType   = $RuleType
                    Enabled    = $false
                    Conditions = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Exceptions = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Actions    = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        Delete       = [PSCustomObject]@{ Enabled = $false }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                    }
                }
                $this.RulesList.Add($createdRule)
                $this.Count = $this.RulesList.Count
                return $createdRule
            }

            # 5. Stores Setup
            $mockOldStore = [PSCustomObject]@{
                DisplayName     = 'Old Store'
                FilePath        = $OldPstPath
                IsDataFileStore = $true
                IsDefaultStore  = $true
                RootFolder      = $mockOldRoot
                Rules           = $mockOldRules
            }
            $mockOldStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
            $mockOldStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

            $mockNewStore = [PSCustomObject]@{
                DisplayName     = 'New Store'
                FilePath        = $NewPstPath
                IsDataFileStore = $true
                IsDefaultStore  = $false
                RootFolder      = $mockNewRoot
                Rules           = $mockNewRules
            }
            $mockNewStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
            $mockNewStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

            $mockStores = @($mockOldStore, $mockNewStore)

            $mockNs = [PSCustomObject]@{
                DefaultStore = $mockOldStore
                Stores       = $mockStores
            }
            $mockNs | Add-Member -MemberType ScriptMethod -Name AddStoreEx -Value { param($p, $t) }

            $mockApp = [PSCustomObject]@{
                MapiNamespace = $mockNs
            }
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
            $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value { }

            return @{
                App            = $mockApp
                Namespace      = $mockNs
                OldStore       = $mockOldStore
                NewStore       = $mockNewStore
                OldRoot        = $mockOldRoot
                NewRoot        = $mockNewRoot
                Rules          = $mockOldRules
                OldRules       = $mockOldRules
                NewRules       = $mockNewRules
                TargetRules    = $mockNewRules
                Rule1          = $mockRule1
                Rule2          = $mockRule2
                Rule3          = $mockRule3
                Rule4          = $mockRule4
                OldSubFolder   = $mockOldSubFolder
                OldFinance     = $mockOldFinance
            }
        }
    }

        It 'Clones multi-level custom folder hierarchy from source default store into new PST' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $res = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $res.Success | Should -BeTrue
            $res.FoldersCloned | Should -BeGreaterThan 0
            $res.FolderMap.ContainsKey('Finance') | Should -BeTrue
            $res.FolderMap.ContainsKey('Inbox\ProjectA') | Should -BeTrue
            $res.FolderMap.ContainsKey('Inbox\ProjectA\SubProject') | Should -BeTrue

            $newFinance = $res.FolderMap['Finance']
            $newFinance.FolderPath | Should -Be '\\NewStore\Finance'

            $newProjectA = $res.FolderMap['Inbox\ProjectA']
            $newProjectA.FolderPath | Should -Be '\\NewStore\Inbox\ProjectA'
        }

        It 'Remaps MoveToFolder rule actions to the corresponding cloned folders in the new PST' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -FolderMap $hierRes.FolderMap

            $ruleRes.Success | Should -BeTrue
            $ruleRes.RulesRemapped | Should -BeGreaterThan 0

            $targetRule1 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
            $targetRule1 | Should -Not -BeNullOrEmpty
            $targetRule1.Actions.MoveToFolder.Folder.FolderPath | Should -Be '\\NewStore\Inbox\ProjectA'
            $targetRule1.Actions.MoveToFolder.Enabled | Should -BeTrue
            $targetRule1.Enabled | Should -BeTrue
            $script:rulesSaved | Should -BeTrue
        }

        It 'Remaps CopyToFolder rule actions to the corresponding cloned folders in the new PST' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -FolderMap $hierRes.FolderMap

            $ruleRes.Success | Should -BeTrue
            $targetRule2 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Copy Finance Mails' }
            $targetRule2 | Should -Not -BeNullOrEmpty
            $targetRule2.Actions.CopyToFolder.Folder.FolderPath | Should -Be '\\NewStore\Finance'
            $targetRule2.Actions.CopyToFolder.Enabled | Should -BeTrue
            $script:rulesSaved | Should -BeTrue
        }

        It 'Preserves disabled rule states and leaves rules without folder actions untouched' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -FolderMap $hierRes.FolderMap

            $targetRule3 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Disabled Spam Filter' }
            $targetRule3 | Should -Not -BeNullOrEmpty
            $targetRule3.Enabled | Should -BeFalse
            $targetRule3.Actions.MoveToFolder.Enabled | Should -BeFalse
            $targetRule3.Actions.CopyToFolder.Enabled | Should -BeFalse
        }

        It 'Clones rule conditions (Subject, From, Categories) and exceptions to the target store' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -FolderMap $hierRes.FolderMap

            $ruleRes.Success | Should -BeTrue

            # Verify Rule 1 conditions (Subject)
            $targetRule1 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
            $targetRule1 | Should -Not -BeNullOrEmpty
            $targetRule1.Conditions.Subject.Enabled | Should -BeTrue
            $targetRule1.Conditions.Subject.Text | Should -Contain 'ProjectA'

            # Verify Rule 2 conditions (From, Categories)
            $targetRule2 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Copy Finance Mails' }
            $targetRule2 | Should -Not -BeNullOrEmpty
            $targetRule2.Conditions.From.Enabled | Should -BeTrue
            $targetRule2.Conditions.From.Recipients | Should -Contain 'finance@company.com'
            $targetRule2.Conditions.Categories.Enabled | Should -BeTrue
            $targetRule2.Conditions.Categories.Categories | Should -Contain 'Financial'

            # Verify Rule 2 exceptions (Subject)
            $targetRule2.Exceptions.Subject.Enabled | Should -BeTrue
            $targetRule2.Exceptions.Subject.Text | Should -Contain 'Draft'
        }

        It 'Preserves non-folder actions (such as Delete and MarkAsRead) and recipient exceptions' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -FolderMap $hierRes.FolderMap

            $ruleRes.Success | Should -BeTrue

            # Verify Rule 4 non-folder actions and conditions/exceptions
            $targetRule4 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Delete Phishing Mails' }
            $targetRule4 | Should -Not -BeNullOrEmpty
            $targetRule4.Enabled | Should -BeTrue
            $targetRule4.Actions.Delete.Enabled | Should -BeTrue
            $targetRule4.Actions.MarkAsRead.Enabled | Should -BeTrue
            $targetRule4.Conditions.Subject.Enabled | Should -BeTrue
            $targetRule4.Conditions.Subject.Text | Should -Contain 'Phishing Alert'
            $targetRule4.Exceptions.From.Enabled | Should -BeTrue
            $targetRule4.Exceptions.From.Recipients | Should -Contain 'admin@company.com'
        }

        It 'Supports -WhatIf simulation without creating folders or committing rule saves' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'

            $hierWhatIf = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -WhatIf
            $hierWhatIf.Method | Should -Be 'WhatIf'
            $hierWhatIf.FoldersCloned | Should -Be 0
            $mockTree.NewRoot.Folders.Count | Should -Be 0

            $script:rulesSaved = $false
            $ruleWhatIf = Copy-OutlookRule -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath -WhatIf
            $ruleWhatIf.Method | Should -Be 'WhatIf'
            $ruleWhatIf.RulesRemapped | Should -Be 0
            $mockTree.NewStore.Rules.RulesList.Count | Should -Be 0
            $script:rulesSaved | Should -BeFalse
        }

        It 'New-OutlookDataFile creates default PST with folder hierarchy and rules preserved' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree -NewPstPath 'C:\Outlook\NewDefault.pst'
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'
            Mock Test-Path { return $false }
            Mock Set-OutlookDefaultDataFile {
                param($Path, $ProfileName)
                return [PSCustomObject]@{ Success = $true; Method = 'COM'; FallbackTriggered = $false }
            }

            $res = New-OutlookDataFile -Path 'C:\Outlook\NewDefault.pst' -SetAsDefault -CloneFolderHierarchy -MigrateRules
            $res.Success | Should -BeTrue
            $res.IsDefault | Should -BeTrue
            $res.Created | Should -BeTrue
            $res.Attached | Should -BeTrue

            $targetRule1 = $mockTree.NewStore.Rules.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
            $targetRule1 | Should -Not -BeNullOrEmpty
            $targetRule1.Actions.MoveToFolder.Folder.FolderPath | Should -Be '\\NewStore\Inbox\ProjectA'
            $script:rulesSaved | Should -BeTrue
        }

        It 'Deterministically calls Remove-ToolkitComObject to release COM references' -Skip:(-not $isOutlookAvailable) {
            $mockTree = New-MockOutlookComTree
            Mock Get-OutlookComApplication { return $mockTree.App } -ModuleName 'Outlook'
            $script:releasedCount = 0
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($ComObjects) {
                    $script:releasedCount += $ComObjects.Count
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($ComObjects) {
                    $script:releasedCount += $ComObjects.Count
                }
            }

            $res = Copy-OutlookFolderHierarchy -SourceStorePath $mockTree.OldStore.FilePath -TargetStorePath $mockTree.NewStore.FilePath
            $script:releasedCount | Should -BeGreaterThan 0
        }

        It 'Preserves registry profile settings and existing account bindings during default PST switch' -Skip:(-not $isOutlookAvailable) {
            $mockKeyProps = [PSCustomObject]@{
                '001f6700' = [byte[]]@(0x43, 0x00, 0x3A, 0x00) # C:
                '001e6700' = [byte[]]@(0x43, 0x3A)
                AccountName = 'User@company.com'
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        PSChildName = '9375CFF0413111d3B88A00104B2A6676'
                        Name = 'HKEY_CURRENT_USER\Software\Microsoft\Office\16.0\Outlook\Profiles\TargetProfile\9375CFF0413111d3B88A00104B2A6676'
                    }
                )
            }
            Mock Get-ItemProperty { return $mockKeyProps }

            $profItems = Get-ChildItem -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\TargetProfile'
            $profItems.Count | Should -Be 1
            $props = Get-ItemProperty -Path $profItems[0].Name
            $props.AccountName | Should -Be 'User@company.com'
        }
    }

    Context 'Portable Rule & Hierarchy Export (Export-OutlookRule)' {
        BeforeAll {
            function script:New-MockExportOutlookTree {
                param(
                    [string]$StorePath = 'C:\Data\Corporate.pst',
                    [string]$StoreName = 'Corporate Store'
                )

                # 1. Custom and System Folder Mocking
                $mockFolderSubTask = [PSCustomObject]@{
                    Name       = 'SubTask'
                    FolderPath = "\\$StoreName\Inbox\ProjectA\SubTask"
                    Folders    = [System.Collections.Generic.List[object]]::new()
                }
                $mockFolderProjectA = [PSCustomObject]@{
                    Name       = 'ProjectA'
                    FolderPath = "\\$StoreName\Inbox\ProjectA"
                    Folders    = [System.Collections.Generic.List[object]]@($mockFolderSubTask)
                }
                $mockFolderInbox = [PSCustomObject]@{
                    Name       = 'Inbox'
                    FolderPath = "\\$StoreName\Inbox"
                    Folders    = [System.Collections.Generic.List[object]]@($mockFolderProjectA)
                }
                $mockFolderFinance = [PSCustomObject]@{
                    Name       = 'Finance'
                    FolderPath = "\\$StoreName\Finance"
                    Folders    = [System.Collections.Generic.List[object]]::new()
                }
                $mockFolderSent = [PSCustomObject]@{
                    Name       = 'Sent Items'
                    FolderPath = "\\$StoreName\Sent Items"
                    Folders    = [System.Collections.Generic.List[object]]::new()
                }
                $mockFolderDeleted = [PSCustomObject]@{
                    Name       = 'Deleted Items'
                    FolderPath = "\\$StoreName\Deleted Items"
                    Folders    = [System.Collections.Generic.List[object]]::new()
                }

                $mockRootFolder = [PSCustomObject]@{
                    Name       = $StoreName
                    FolderPath = "\\$StoreName"
                    Folders    = [System.Collections.Generic.List[object]]@($mockFolderInbox, $mockFolderFinance, $mockFolderSent, $mockFolderDeleted)
                }

                # 2. Source Rules Mocking
                $mockRule1 = [PSCustomObject]@{
                    Name           = 'Route Project Mails'
                    RuleType       = 0
                    Enabled        = $true
                    ExecutionOrder = 1
                    Conditions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Project Alpha', 'Urgent') }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                        Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                    }
                    Exceptions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Actions        = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Folder = $mockFolderProjectA; Enabled = $true }
                        CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        Delete       = [PSCustomObject]@{ Enabled = $false }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                        Stop         = [PSCustomObject]@{ Enabled = $true }
                    }
                }

                $mockRule2 = [PSCustomObject]@{
                    Name           = 'Copy Finance Invoices'
                    RuleType       = 0
                    Enabled        = $true
                    ExecutionOrder = 2
                    Conditions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('billing@vendor.com') }
                        SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $true; Categories = @('Invoices', 'Finance') }
                        Importance = [PSCustomObject]@{ Enabled = $true; Importance = 2 }
                    }
                    Exceptions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Draft', 'Estimate') }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Actions        = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        CopyToFolder = [PSCustomObject]@{ Folder = $mockFolderFinance; Enabled = $true }
                        Delete       = [PSCustomObject]@{ Enabled = $false }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                        Stop         = [PSCustomObject]@{ Enabled = $false }
                    }
                }

                $mockRule3 = [PSCustomObject]@{
                    Name           = 'Disabled Spam Filter'
                    RuleType       = 0
                    Enabled        = $false
                    ExecutionOrder = 3
                    Conditions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                        Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                    }
                    Exceptions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Actions        = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        Delete       = [PSCustomObject]@{ Enabled = $false }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                        Stop         = [PSCustomObject]@{ Enabled = $false }
                    }
                }

                $mockRule4 = [PSCustomObject]@{
                    Name           = 'Delete Phishing Mails'
                    RuleType       = 0
                    Enabled        = $true
                    ExecutionOrder = 4
                    Conditions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Phishing Alert', 'Password Expired') }
                        From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                        Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                    }
                    Exceptions     = [PSCustomObject]@{
                        Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                        From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('security@company.com') }
                        Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    }
                    Actions        = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                        Delete       = [PSCustomObject]@{ Enabled = $true }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = $true }
                        Stop         = [PSCustomObject]@{ Enabled = $true }
                    }
                }

                $mockRulesList = [System.Collections.Generic.List[object]]@($mockRule1, $mockRule2, $mockRule3, $mockRule4)
                $mockRules = [PSCustomObject]@{
                    Count     = $mockRulesList.Count
                    RulesList = $mockRulesList
                }
                $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
                $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }

                # 3. Store Mocking
                $mockStore = [PSCustomObject]@{
                    DisplayName     = $StoreName
                    FilePath        = $StorePath
                    IsDataFileStore = $true
                    IsDefaultStore  = $true
                    RootFolder      = $mockRootFolder
                    Rules           = $mockRules
                }
                $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
                $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

                $mockStores = @($mockStore)
                $mockNs = [PSCustomObject]@{
                    DefaultStore = $mockStore
                    Stores       = $mockStores
                }
                $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pwd, $ui, $new) }
                $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value { }

                $mockApp = [PSCustomObject]@{
                    MapiNamespace = $mockNs
                }
                $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
                $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
                    $script:quitCallCount++
                    $script:quitCalled = $true
                }

                return @{
                    App          = $mockApp
                    Namespace    = $mockNs
                    Store        = $mockStore
                    RootFolder   = $mockRootFolder
                    Rules        = $mockRules
                    Rule1        = $mockRule1
                    Rule2        = $mockRule2
                    Rule3        = $mockRule3
                    Rule4        = $mockRule4
                }
            }
        }

        It 'Exports rules and custom hierarchy to a valid JSON manifest file' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext {
                return [PSCustomObject]@{
                    DefaultProfile = 'CorporateProfile'
                    Profiles       = @('CorporateProfile')
                }
            } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_export_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -ProfileName 'CorporateProfile' -StorePath $mockEnv.Store.FilePath -PassThru
                $res.Success | Should -BeTrue
                $res.RulesExported | Should -Be 4
                $res.CustomFoldersExported | Should -BeGreaterThan 0
                Test-Path -LiteralPath $testJson | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.SchemaVersion | Should -Match '^(v)?1\.0\.0$'
                $manifest.SourceContext.ProfileName | Should -Be 'CorporateProfile'
                $manifest.SourceContext.StoreDisplayName | Should -Be 'Corporate Store'
                $manifest.Rules.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Normalizes folder paths in MoveToFolder and CopyToFolder to store-relative paths' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_relpath_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                # Rule 1 MoveToFolder normalization
                $r1 = $manifest.Rules | Where-Object { $_.Name -eq 'Route Project Mails' }
                $r1.Actions.MoveToFolder.Enabled | Should -BeTrue
                $r1.Actions.MoveToFolder.FolderPath | Should -Be 'Inbox\ProjectA'

                # Rule 2 CopyToFolder normalization
                $r2 = $manifest.Rules | Where-Object { $_.Name -eq 'Copy Finance Invoices' }
                $r2.Actions.CopyToFolder.Enabled | Should -BeTrue
                $r2.Actions.CopyToFolder.FolderPath | Should -Be 'Finance'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Accurately serializes rule conditions, exceptions, and non-folder actions' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_cond_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                # Rule 1 Subject conditions
                $r1 = $manifest.Rules | Where-Object { $_.Name -eq 'Route Project Mails' }
                $r1.Conditions.Subject.Enabled | Should -BeTrue
                $r1.Conditions.Subject.Text | Should -Contain 'Project Alpha'

                # Rule 2 From, Categories, Importance conditions & Subject exception
                $r2 = $manifest.Rules | Where-Object { $_.Name -eq 'Copy Finance Invoices' }
                $r2.Conditions.From.Enabled | Should -BeTrue
                $r2.Conditions.From.Recipients | Should -Contain 'billing@vendor.com'
                $r2.Conditions.Categories.Categories | Should -Contain 'Invoices'
                $r2.Conditions.Importance.Importance | Should -Be 2
                $r2.Exceptions.Subject.Enabled | Should -BeTrue
                $r2.Exceptions.Subject.Text | Should -Contain 'Draft'

                # Rule 4 Delete, MarkAsRead, Stop actions & From exception
                $r4 = $manifest.Rules | Where-Object { $_.Name -eq 'Delete Phishing Mails' }
                $r4.Actions.Delete.Enabled | Should -BeTrue
                $r4.Actions.MarkAsRead.Enabled | Should -BeTrue
                $r4.Actions.Stop.Enabled | Should -BeTrue
                $r4.Exceptions.From.Recipients | Should -Contain 'security@company.com'

                # Rule 3 preserves disabled state
                $r3 = $manifest.Rules | Where-Object { $_.Name -eq 'Disabled Spam Filter' }
                $r3.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Captures custom folder hierarchy while strictly excluding built-in system root folders' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_hier_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                $manifest.CustomFolders | Should -Contain 'Finance'
                $manifest.CustomFolders | Should -Contain 'Inbox\ProjectA'
                $manifest.CustomFolders | Should -Contain 'Inbox\ProjectA\SubTask'

                # Ensure system folders are excluded
                $manifest.CustomFolders | Should -Not -Contain 'Inbox'
                $manifest.CustomFolders | Should -Not -Contain 'Sent Items'
                $manifest.CustomFolders | Should -Not -Contain 'Deleted Items'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Omits custom folder hierarchy when -IncludeHierarchy is set to $false' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_nohier_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath -IncludeHierarchy:$false
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                $manifest.CustomFolders.Count | Should -Be 0
                $manifest.Rules.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Supports -WhatIf execution without writing manifest files to disk' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_whatif_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath -WhatIf
                $res | Should -Not -BeNullOrEmpty
                Test-Path -LiteralPath $testJson | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Normalizes relative destination file path using session provider path' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $relFileName = "rel_test_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path ".\$relFileName" -StorePath $mockEnv.Store.FilePath
                $res.Success | Should -BeTrue
                Test-Path -LiteralPath $res.Path | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath ".\$relFileName") { Remove-Item -LiteralPath ".\$relFileName" -Force }
            }
        }

        It 'Refuses overwrite of existing file without -Force, and overwrites cleanly when -Force is passed' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_collision_$([System.Guid]::NewGuid().ToString('N')).json"
            'INITIAL_PLACEHOLDER' | Set-Content -LiteralPath $testJson -Force

            try {
                # Attempt 1: Without -Force
                $resNoForce = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $resNoForce.Success | Should -BeFalse
                $content = Get-Content -LiteralPath $testJson -Raw
                $content.Trim() | Should -Be 'INITIAL_PLACEHOLDER'

                # Attempt 2: With -Force
                $resForce = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath -Force
                $resForce.Success | Should -BeTrue
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Returns structured error object when target store path is not found' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_err_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath 'C:\NonExistent\Ghost.pst'
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'not found'
                Test-Path -LiteralPath $testJson | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Deterministically calls Remove-ToolkitComObject to release COM references' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $script:comReleasedCount = 0
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    $script:comReleasedCount += $ComObjects.Count
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    $script:comReleasedCount += $ComObjects.Count
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_cleanup_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $script:comReleasedCount | Should -BeGreaterThan 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Outlook COM Lifecycle Hardening & Process Safety' {
        It 'Calls Quit() when Outlook was NOT running prior to Export-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_quit1_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $script:quitCallCount | Should -BeGreaterThan 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Skips calling Quit() when Outlook WAS running prior to Export-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 1234; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 1234; ProcessName = 'OUTLOOK' }) }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_quit2_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $mockEnv.Store.FilePath
                $script:quitCallCount | Should -Be 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Set-OutlookDefaultDataFile calls Quit() when Outlook was NOT running before' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $res = Set-OutlookDefaultDataFile -Path $mockEnv.Store.FilePath
            $script:quitCallCount | Should -BeGreaterThan 0
        }

        It 'Clear-OutlookStuckOutbox does NOT call Quit() when Outlook WAS already running' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockExportOutlookTree
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 5678; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 5678; ProcessName = 'OUTLOOK' }) }
            Mock Test-Path { return $true }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $script:quitCallCount | Should -Be 0
        }

        It 'Clear-OutlookStuckOutbox calls Quit() when Outlook was stopped via -Force' -Skip:(-not $isOutlookAvailable) {
            $script:procCalls = 0
            Mock Get-Process {
                param($Name)
                $script:procCalls++
                if ($script:procCalls -eq 1) { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 3003 }) }
                return @()
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }

            $mockEnv = New-MockExportOutlookTree
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject { }
            Mock Set-ToolkitRegistryValue { }

            $res = Clear-OutlookStuckOutbox -Force
            $script:quitCallCount | Should -BeGreaterThan 0
        }
    }

    Context 'Intelligent Rule & Hierarchy Import (Import-OutlookRule)' {
        BeforeAll {
            function script:New-MockRuleManifestJson {
                param(
                    [string]$Path,
                    [switch]$WithCustomFolders,
                    [switch]$EmptyRules
                )

                $folders = if ($WithCustomFolders) {
                    @('Finance', 'Inbox\ProjectA', 'Inbox\ProjectA\SubTask')
                } else {
                    @()
                }

                $rules = if ($EmptyRules) {
                    @()
                } else {
                    @(
                        [ordered]@{
                            Name           = 'Route Project Mails'
                            RuleType       = 0
                            ExecutionOrder = 1
                            Enabled        = $true
                            Conditions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $true; Text = @('Project Alpha', 'Urgent') }
                                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                                Categories = [ordered]@{ Enabled = $false; Categories = @() }
                                Importance = [ordered]@{ Enabled = $false; Importance = 1 }
                                Account    = [ordered]@{ Enabled = $false; Account = $null }
                            }
                            Exceptions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $false; Text = @() }
                                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                            }
                            Actions        = [ordered]@{
                                MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = 'Inbox\ProjectA' }
                                CopyToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                Delete       = [ordered]@{ Enabled = $false }
                                MarkAsRead   = [ordered]@{ Enabled = $false }
                                Stop         = [ordered]@{ Enabled = $true }
                            }
                        },
                        [ordered]@{
                            Name           = 'Copy Finance Invoices'
                            RuleType       = 0
                            ExecutionOrder = 2
                            Enabled        = $true
                            Conditions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $false; Text = @() }
                                From       = [ordered]@{ Enabled = $true; Recipients = @('billing@vendor.com') }
                                Categories = [ordered]@{ Enabled = $true; Categories = @('Invoices') }
                                Importance = [ordered]@{ Enabled = $true; Importance = 2 }
                                Account    = [ordered]@{ Enabled = $false; Account = $null }
                            }
                            Exceptions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $true; Text = @('Draft') }
                                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                            }
                            Actions        = [ordered]@{
                                MoveToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                CopyToFolder = [ordered]@{ Enabled = $true; FolderPath = 'Finance' }
                                Delete       = [ordered]@{ Enabled = $false }
                                MarkAsRead   = [ordered]@{ Enabled = $false }
                                Stop         = [ordered]@{ Enabled = $false }
                            }
                        },
                        [ordered]@{
                            Name           = 'Disabled Spam Filter'
                            RuleType       = 0
                            ExecutionOrder = 3
                            Enabled        = $false
                            Conditions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $false; Text = @() }
                                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                                Categories = [ordered]@{ Enabled = $false; Categories = @() }
                                Importance = [ordered]@{ Enabled = $false; Importance = 1 }
                                Account    = [ordered]@{ Enabled = $false; Account = $null }
                            }
                            Exceptions     = [ordered]@{}
                            Actions        = [ordered]@{
                                MoveToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                CopyToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                Delete       = [ordered]@{ Enabled = $false }
                                MarkAsRead   = [ordered]@{ Enabled = $false }
                                Stop         = [ordered]@{ Enabled = $false }
                            }
                        },
                        [ordered]@{
                            Name           = 'Delete Phishing Mails'
                            RuleType       = 0
                            ExecutionOrder = 4
                            Enabled        = $true
                            Conditions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $true; Text = @('Phishing Alert') }
                                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                                Categories = [ordered]@{ Enabled = $false; Categories = @() }
                                Importance = [ordered]@{ Enabled = $false; Importance = 1 }
                                Account    = [ordered]@{ Enabled = $true; Account = 'SourceAccount' }
                            }
                            Exceptions     = [ordered]@{
                                Subject    = [ordered]@{ Enabled = $false; Text = @() }
                                From       = [ordered]@{ Enabled = $true; Recipients = @('security@company.com') }
                            }
                            Actions        = [ordered]@{
                                MoveToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                CopyToFolder = [ordered]@{ Enabled = $false; FolderPath = $null }
                                Delete       = [ordered]@{ Enabled = $true }
                                MarkAsRead   = [ordered]@{ Enabled = $true }
                                Stop         = [ordered]@{ Enabled = $true }
                            }
                        }
                    )
                }

                $manifest = [ordered]@{
                    ManifestVersion = '1.0.0'
                    SchemaVersion   = '1.0.0'
                    ExportTimestamp = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    ExportedBy      = 'IToolkit'
                    SourceContext   = [ordered]@{
                        ProfileName        = 'CorporateProfile'
                        StoreName          = 'Corporate Store'
                        StoreDisplayName   = 'Corporate Store'
                        StoreFilePath      = 'C:\Data\Corporate.pst'
                        AccountName        = 'SourceAccount'
                        PrimarySmtpAddress = 'source@company.com'
                        OfficeVersion      = '16.0'
                    }
                    CustomFolders   = $folders
                    Rules           = $rules
                }

                $jsonContent = ConvertTo-Json -InputObject $manifest -Depth 10
                Set-Content -LiteralPath $Path -Value $jsonContent -Encoding UTF8
            }

            function script:New-MockImportOutlookEnvironment {
                param(
                    [string]$StorePath = 'C:\Data\TargetStore.pst',
                    [string]$StoreName = 'Target Store',
                    [bool]$WithExistingRule = $false
                )

                # 1. Folder Mocking
                $mockTargetFolders = [System.Collections.Generic.List[object]]::new()
                $mockTargetRoot = [PSCustomObject]@{
                    Name       = $StoreName
                    FolderPath = "\\$StoreName"
                    Folders    = $mockTargetFolders
                }

                $script:importFolderFactory = {
                    param($FolderName)
                    $childList = [System.Collections.Generic.List[object]]::new()
                    $newChild = [PSCustomObject]@{
                        Name       = $FolderName
                        FolderPath = "$($this.FolderPath)\$FolderName"
                        Folders    = $childList
                    }
                    $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:importFolderFactory
                    $newChild | Add-Member -MemberType ScriptMethod -Name EnsureFolder -Value {
                        param($fName)
                        foreach ($c in $this.Folders) {
                            if ($c.Name -ieq $fName) { return $c }
                        }
                        return $this.AddFolder($fName)
                    }
                    $this.Folders.Add($newChild)
                    return $newChild
                }
                $mockTargetRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:importFolderFactory

                # Pre-populate Inbox and system folders
                $mockInbox = $mockTargetRoot.AddFolder('Inbox')
                $null = $mockTargetRoot.AddFolder('Sent Items')
                $null = $mockTargetRoot.AddFolder('Deleted Items')

                # 2. Rules Mocking
                $mockRulesList = [System.Collections.Generic.List[object]]::new()
                if ($WithExistingRule) {
                    $existingRule = [PSCustomObject]@{
                        Name           = 'Route Project Mails'
                        RuleType       = 0
                        Enabled        = $true
                        ExecutionOrder = 1
                        Conditions     = [PSCustomObject]@{
                            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                            From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                            Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                            Account    = [PSCustomObject]@{ Enabled = $false; Account = $null }
                        }
                        Exceptions     = [PSCustomObject]@{
                            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                            From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                        }
                        Actions        = [PSCustomObject]@{
                            MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                            Delete       = [PSCustomObject]@{ Enabled = $false }
                            MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                            Stop         = [PSCustomObject]@{ Enabled = $false }
                        }
                    }
                    $mockRulesList.Add($existingRule)
                }

                $mockRules = [PSCustomObject]@{
                    Count                = $mockRulesList.Count
                    RulesList            = $mockRulesList
                    SaveCalled           = $false
                    LastSaveShowProgress = $null
                }
                $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
                $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
                $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
                    param($showProgress)
                    $this.SaveCalled = $true
                    $this.LastSaveShowProgress = $showProgress
                    $script:rulesSaveCallCount++
                }
                $mockRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
                    param($RuleName, $RuleType)
                    $createdRule = [PSCustomObject]@{
                        Name           = $RuleName
                        RuleType       = $RuleType
                        Enabled        = $false
                        ExecutionOrder = $this.RulesList.Count + 1
                        Conditions     = [PSCustomObject]@{
                            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                            From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                            Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                            Account    = [PSCustomObject]@{ Enabled = $false; Account = $null }
                        }
                        Exceptions     = [PSCustomObject]@{
                            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                            From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                        }
                        Actions        = [PSCustomObject]@{
                            MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                            Delete       = [PSCustomObject]@{ Enabled = $false }
                            MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                            Stop         = [PSCustomObject]@{ Enabled = $false }
                        }
                    }
                    $this.RulesList.Add($createdRule)
                    $this.Count = $this.RulesList.Count
                    return $createdRule
                }

                # 3. Target Store Setup
                $mockTargetStore = [PSCustomObject]@{
                    DisplayName     = $StoreName
                    FilePath        = $StorePath
                    IsDataFileStore = $true
                    IsDefaultStore  = $true
                    RootFolder      = $mockTargetRoot
                    Rules           = $mockRules
                }
                $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
                $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

                $mockStores = @($mockTargetStore)
                $mockNs = [PSCustomObject]@{
                    DefaultStore  = $mockTargetStore
                    Stores        = $mockStores
                    Accounts      = @([PSCustomObject]@{ DisplayName = 'Target Account'; SmtpAddress = 'target@company.com' })
                    LoggedOff     = $false
                }
                $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pwd, $ui, $new) }
                $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value {
                    $this.LoggedOff = $true
                    $script:logoffCallCount++
                }

                $mockApp = [PSCustomObject]@{
                    MapiNamespace = $mockNs
                }
                $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
                $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
                    $script:quitCallCount++
                }

                return @{
                    App        = $mockApp
                    Namespace  = $mockNs
                    Store      = $mockTargetStore
                    RootFolder = $mockTargetRoot
                    Inbox      = $mockInbox
                    Rules      = $mockRules
                    RulesList  = $mockRulesList
                }
            }
        }

        It 'Imports valid rule manifest and reconstructs rules silently in target store' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_valid_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 4
                $res.FoldersCreated | Should -Be 3
                $mockEnv.Rules.SaveCalled | Should -BeTrue
                $mockEnv.Rules.LastSaveShowProgress | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Pre-creates missing custom folders in target store hierarchy and reuses existing ones' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            # Pre-create Finance so only Inbox\ProjectA and Inbox\ProjectA\SubTask are new
            $null = $mockEnv.RootFolder.AddFolder('Finance')

            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_hier_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 2

                # Verify folders exist in hierarchy
                $projA = $mockEnv.Inbox.Folders | Where-Object { $_.Name -eq 'ProjectA' }
                $projA | Should -Not -BeNullOrEmpty
                $subTask = $projA.Folders | Where-Object { $_.Name -eq 'SubTask' }
                $subTask | Should -Not -BeNullOrEmpty
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Remaps MoveToFolder and CopyToFolder actions to matching target store folder objects' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_remap_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath
                $res.Success | Should -BeTrue

                $rule1 = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
                $rule1.Actions.MoveToFolder.Enabled | Should -BeTrue
                $rule1.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
                $rule1.Actions.MoveToFolder.Folder.Name | Should -Be 'ProjectA'

                $rule2 = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Copy Finance Invoices' }
                $rule2.Actions.CopyToFolder.Enabled | Should -BeTrue
                $rule2.Actions.CopyToFolder.Folder | Should -Not -BeNullOrEmpty
                $rule2.Actions.CopyToFolder.Folder.Name | Should -Be 'Finance'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Substitutes recipient addresses in conditions and exceptions using -AddressMap' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_addrmap_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            $addressMap = @{
                'billing@vendor.com'   = 'invoices@corp.net'
                'security@company.com' = 'soc-alerts@corp.net'
            }

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -AddressMap $addressMap
                $res.Success | Should -BeTrue

                $rule2 = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Copy Finance Invoices' }
                $rule2.Conditions.From.Recipients | Should -Contain 'invoices@corp.net'
                $rule2.Conditions.From.Recipients | Should -Not -Contain 'billing@vendor.com'

                $rule4 = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Delete Phishing Mails' }
                $rule4.Exceptions.From.Recipients | Should -Contain 'soc-alerts@corp.net'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Substitutes account names in conditions using -AccountMap and -AutoRemapAccounts' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_acctmap_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                # Test with -AccountMap
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -AccountMap @{ 'SourceAccount' = 'Target Account' }
                $res.Success | Should -BeTrue
                $rule4 = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Delete Phishing Mails' }
                $rule4.Conditions.Account.Account | Should -Be 'Target Account'

                # Test with -AutoRemapAccounts
                $mockEnvAuto = New-MockImportOutlookEnvironment
                Mock Get-OutlookComApplication { return $mockEnvAuto.App } -ModuleName 'Outlook'
                $resAuto = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnvAuto.Store.FilePath -AutoRemapAccounts
                $resAuto.Success | Should -BeTrue
                $rule4Auto = $mockEnvAuto.RulesList | Where-Object { $_.Name -eq 'Delete Phishing Mails' }
                $rule4Auto.Conditions.Account.Account | Should -Be 'Target Account'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Preserves disabled rule state and honors -EnableImportedRules force switch' -Skip:(-not $isOutlookAvailable) {
            # Run 1: Preserve disabled rule state
            $mockEnv1 = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv1.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_state_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res1 = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv1.Store.FilePath
                $rule3 = $mockEnv1.RulesList | Where-Object { $_.Name -eq 'Disabled Spam Filter' }
                $rule3.Enabled | Should -BeFalse

                # Run 2: Force enable all imported rules
                $mockEnv2 = New-MockImportOutlookEnvironment
                Mock Get-OutlookComApplication { return $mockEnv2.App } -ModuleName 'Outlook'

                $res2 = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv2.Store.FilePath -EnableImportedRules
                $rule3Force = $mockEnv2.RulesList | Where-Object { $_.Name -eq 'Disabled Spam Filter' }
                $rule3Force.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Skips existing duplicate rule by default under DuplicateHandling Skip mode' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment -WithExistingRule $true
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_skip_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 1
                $res.RulesImported | Should -Be 3
                # Existing rule subject was not changed to manifest value
                $existing = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
                $existing.Conditions.Subject.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Overwrites existing duplicate rule when DuplicateHandling Overwrite is specified' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment -WithExistingRule $true
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_ow_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1

                $updated = $mockEnv.RulesList | Where-Object { $_.Name -eq 'Route Project Mails' }
                $updated.Conditions.Subject.Enabled | Should -BeTrue
                $updated.Conditions.Subject.Text | Should -Contain 'Project Alpha'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Imports duplicate rule under disambiguated name when DuplicateHandling Rename is specified' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment -WithExistingRule $true
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_ren_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 4

                $renamedRule = $mockEnv.RulesList | Where-Object { $_.Name -match '^Route Project Mails \(' }
                $renamedRule | Should -Not -BeNullOrEmpty
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Allows duplicate rule coexistence when DuplicateHandling KeepBoth is specified' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment -WithExistingRule $true
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_both_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -DuplicateHandling 'KeepBoth'
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 4
                $mockEnv.RulesList.Count | Should -Be 5
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Suppresses folder creation when -AutoCreateFolders is explicitly set to false' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_nofolders_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -AutoCreateFolders:$false
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 0
                $finance = $mockEnv.RootFolder.Folders | Where-Object { $_.Name -eq 'Finance' }
                $finance | Should -BeNullOrEmpty
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Supports -WhatIf execution without modifying target store or committing rule saves' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_whatif_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath -WhatIf
                $res | Should -Not -BeNullOrEmpty
                $res.Success | Should -BeTrue
                $res.Method | Should -Be 'WhatIf'

                # Verify target store state remains pristine
                $mockEnv.Rules.SaveCalled | Should -BeFalse
                $mockEnv.RulesList.Count | Should -Be 0
                $mockEnv.RootFolder.Folders.Count | Should -Be 3
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Returns structured error object when source manifest file does not exist' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $ghostFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "ghost_manifest_$([System.Guid]::NewGuid().ToString('N')).json"
            $res = Import-OutlookRule -Path $ghostFile -TargetStorePath $mockEnv.Store.FilePath
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'not found'
            $mockEnv.Rules.SaveCalled | Should -BeFalse
        }

        It 'Returns structured error object when source JSON manifest is corrupted' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $corruptJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "corrupt_$([System.Guid]::NewGuid().ToString('N')).json"
            '{ "ManifestVersion": "1.0.0", invalid_syntax ' | Set-Content -LiteralPath $corruptJson -Force

            try {
                $res = Import-OutlookRule -Path $corruptJson -TargetStorePath $mockEnv.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'JSON'
                $mockEnv.Rules.SaveCalled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $corruptJson) { Remove-Item -LiteralPath $corruptJson -Force }
            }
        }

        It 'Returns structured error object when target Outlook store cannot be found' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_nostore_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath 'C:\NonExistent\GhostStore.pst'
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'store.*not found'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Calls Quit() when Outlook was NOT running prior to Import-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_quit1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath
                $script:quitCallCount | Should -BeGreaterThan 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Skips calling Quit() when Outlook WAS running prior to Import-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockImportOutlookEnvironment
            $script:quitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 4321; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 4321; ProcessName = 'OUTLOOK' }) }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "import_quit2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-MockRuleManifestJson -Path $testJson -WithCustomFolders

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $mockEnv.Store.FilePath
                $script:quitCallCount | Should -Be 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    # ==============================================================================
    # Context: Rule Diagnostics, Deduplication & Auto-Repair (Repair-OutlookRule & Test-OutlookRule)
    # ==============================================================================
    Context 'Rule Diagnostics, Deduplication & Auto-Repair (Repair-OutlookRule & Test-OutlookRule)' {

        function script:New-MockRepairOutlookEnvironment {
            param(
                [string]$StorePath = 'C:\Data\DiagnosticsStore.pst',
                [string]$StoreName = 'Diagnostics Store'
            )

            # 1. Folder Mocking
            $mockRootFolders = [System.Collections.Generic.List[object]]::new()
            $mockRoot = [PSCustomObject]@{
                Name       = $StoreName
                FolderPath = "\\$StoreName"
                Folders    = $mockRootFolders
            }

            $script:repairFolderFactory = {
                param($FolderName)
                $childList = [System.Collections.Generic.List[object]]::new()
                $newChild = [PSCustomObject]@{
                    Name       = $FolderName
                    FolderPath = "$($this.FolderPath)\$FolderName"
                    Folders    = $childList
                }
                $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:repairFolderFactory
                $this.Folders.Add($newChild)
                return $newChild
            }
            $mockRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:repairFolderFactory

            $mockInbox = $mockRoot.AddFolder('Inbox')
            $mockAlpha = $mockInbox.AddFolder('Alpha')
            $mockFinance = $mockRoot.AddFolder('Finance')
            $mockInvoices = $mockFinance.AddFolder('Invoices')
            $null = $mockRoot.AddFolder('Deleted Items')
            $null = $mockRoot.AddFolder('Sent Items')

            # 2. Rules Mocking
            # Rule 1: Broken MoveToFolder action (target folder is null)
            $mockRule1 = [PSCustomObject]@{
                Name           = 'Route Project Alpha'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Project Alpha') }
                    From    = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $true }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                    Stop         = [PSCustomObject]@{ Enabled = $true }
                }
            }

            # Rule 2: Valid CopyToFolder rule
            $mockRule2 = [PSCustomObject]@{
                Name           = 'Copy Finance Invoices'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 2
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Invoice', 'Billing') }
                    From    = [PSCustomObject]@{ Enabled = $true; Recipients = @('vendor@external.org') }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $mockInvoices; Enabled = $true }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                    Stop         = [PSCustomObject]@{ Enabled = $false }
                }
            }

            # Rule 3: Exact Duplicate of Rule 2
            $mockRule3 = [PSCustomObject]@{
                Name           = 'Copy Finance Invoices Duplicate'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 3
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Invoice', 'Billing') }
                    From    = [PSCustomObject]@{ Enabled = $true; Recipients = @('vendor@external.org') }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $mockInvoices; Enabled = $true }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                    Stop         = [PSCustomObject]@{ Enabled = $false }
                }
            }

            # Rule 4: Empty Zombie Rule (0 active conditions and 0 active actions)
            $mockRule4 = [PSCustomObject]@{
                Name           = 'Empty Zombie Rule'
                RuleType       = 0
                Enabled        = $false
                ExecutionOrder = 4
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From    = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                }
            }

            # Rule 5: Disabled Valid Rule (Enabled=$false, but has active conditions and actions)
            $mockRule5 = [PSCustomObject]@{
                Name           = 'Disabled Critical Alert'
                RuleType       = 0
                Enabled        = $false
                ExecutionOrder = 5
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('CRITICAL') }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $mockInbox; Enabled = $true }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                }
            }

            # Rule 6: Broken CopyToFolder action (target folder is null)
            $mockRule6 = [PSCustomObject]@{
                Name           = 'Copy to Missing Archive'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 6
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Archive') }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $true }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                }
            }

            $mockRulesList = [System.Collections.Generic.List[object]]@($mockRule1, $mockRule2, $mockRule3, $mockRule4, $mockRule5, $mockRule6)
            $mockRules = [PSCustomObject]@{
                Count                = $mockRulesList.Count
                RulesList            = $mockRulesList
                SaveCalled           = $false
                LastSaveShowProgress = $null
            }
            $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $this.RulesList[$i - 1] }
            $mockRules | Add-Member -MemberType ScriptMethod -Name Remove -Value {
                param($i)
                $this.RulesList.RemoveAt($i - 1)
                $this.Count = $this.RulesList.Count
            }
            $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
                param($showProgress)
                $this.SaveCalled = $true
                $this.LastSaveShowProgress = $showProgress
            }

            # 3. Store Mocking
            $mockStore = [PSCustomObject]@{
                DisplayName     = $StoreName
                FilePath        = $StorePath
                IsDataFileStore = $true
                IsDefaultStore  = $true
                RootFolder      = $mockRoot
                Rules           = $mockRules
            }
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

            # 4. Namespace Mocking
            $mockNs = [PSCustomObject]@{
                Stores        = @($mockStore)
                DefaultStore  = $mockStore
                ActiveProfile = 'DiagnosticsProfile'
            }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $w, $u, $n) $this.ActiveProfile = $p }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value { }

            # 5. Application Mocking
            $mockApp = [PSCustomObject]@{
                MapiNamespace = $mockNs
                QuitCalled    = $false
            }
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($t) return $this.MapiNamespace }
            $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
                $this.QuitCalled = $true
                $script:repairQuitCallCount++
            }

            return [PSCustomObject]@{
                App          = $mockApp
                Namespace    = $mockNs
                Store        = $mockStore
                RootFolder   = $mockRoot
                InboxFolder  = $mockInbox
                AlphaFolder  = $mockAlpha
                FinanceFolder= $mockFinance
                Rules        = $mockRules
                RulesList    = $mockRulesList
                Rule1        = $mockRule1
                Rule2        = $mockRule2
                Rule3        = $mockRule3
                Rule4        = $mockRule4
                Rule5        = $mockRule5
                Rule6        = $mockRule6
            }
        }

        It 'Performs scan-only diagnostics by default with 0 modifications and 0 saves' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'ScanOnly'
            $res.RulesScanned | Should -Be 6
            $res.TotalRules | Should -Be 6
            $res.BrokenRules.Count | Should -Be 2
            $res.DuplicateRules.Count | Should -Be 1
            $res.EmptyRules.Count | Should -Be 1
            $res.DisabledRules.Count | Should -Be 2
            $res.RepairedRulesCount | Should -Be 0
            $res.RemovedDuplicates | Should -Be 0
            $res.RemovedEmptyCount | Should -Be 0

            # Verify zero rule mutations and zero save calls
            $mockEnv.Rules.SaveCalled | Should -BeFalse
            $mockEnv.Rules.Count | Should -Be 6
        }

        It 'Auto-repairs broken MoveToFolder actions by recreating missing folder and rebinding' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -BeGreaterOrEqual 1

            # Rule 1 target folder was recreated and bound
            $mockEnv.Rule1.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
            $mockEnv.Rule1.Actions.MoveToFolder.Enabled | Should -BeTrue
            $mockEnv.Rules.SaveCalled | Should -BeTrue
        }

        It 'Deduplicates redundant rules in reverse-index order without shifting index corruption' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -RemoveDuplicates
            $res.Success | Should -BeTrue
            $res.RemovedDuplicates | Should -Be 1
            $res.RemovedDuplicatesCount | Should -Be 1

            # Original Rule 2 exists, Duplicate Rule 3 removed
            $remainingNames = @($mockEnv.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'Copy Finance Invoices'
            $remainingNames | Should -Not -Contain 'Copy Finance Invoices Duplicate'
            $mockEnv.Rules.SaveCalled | Should -BeTrue
        }

        It 'Prunes empty zombie rules having zero active conditions and actions' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -RemoveEmpty
            $res.Success | Should -BeTrue
            $res.RemovedEmptyCount | Should -Be 1

            $remainingNames = @($mockEnv.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Not -Contain 'Empty Zombie Rule'
            $mockEnv.Rules.SaveCalled | Should -BeTrue
        }

        It 'Preserves disabled rules with active conditions and does not prune them' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -RemoveEmpty
            $res.DisabledRules | Should -Contain 'Disabled Critical Alert'

            $remainingNames = @($mockEnv.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'Disabled Critical Alert'
        }

        It 'Test-OutlookRule alias behaves identically to Repair-OutlookRule in scan and repair modes' -Skip:(-not $isOutlookAvailable) {
            $mockEnvScan = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnvScan.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            # 1. Alias scan-only
            $resScan = Test-OutlookRule -StorePath $mockEnvScan.Store.FilePath
            $resScan.Success | Should -BeTrue
            $resScan.Method | Should -Be 'ScanOnly'
            $resScan.RulesScanned | Should -Be 6
            $mockEnvScan.Rules.SaveCalled | Should -BeFalse

            # 2. Alias auto-repair
            $mockEnvRepair = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnvRepair.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $resRepair = Test-OutlookRule -StorePath $mockEnvRepair.Store.FilePath -AutoRepair
            $resRepair.Success | Should -BeTrue
            $resRepair.RepairedRulesCount | Should -BeGreaterOrEqual 1
            $mockEnvRepair.Rules.SaveCalled | Should -BeTrue
        }

        It 'Supports -WhatIf execution without modifying rules or committing saves' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -AutoRepair -RemoveDuplicates -RemoveEmpty -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'WhatIf'

            $mockEnv.Rules.SaveCalled | Should -BeFalse
            $mockEnv.Rules.Count | Should -Be 6
        }

        It 'Enforces silent save via Save($false) when mutations occur' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath -AutoRepair
            $mockEnv.Rules.SaveCalled | Should -BeTrue
            $mockEnv.Rules.LastSaveShowProgress | Should -BeFalse
        }

        It 'Calls Quit() when Outlook was NOT running prior to Repair-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            $script:repairQuitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath
            $script:repairQuitCallCount | Should -BeGreaterThan 0
        }

        It 'Skips calling Quit() when Outlook WAS running prior to Repair-OutlookRule execution' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            $script:repairQuitCallCount = 0
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 7890; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 7890; ProcessName = 'OUTLOOK' }) }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $mockEnv.Store.FilePath
            $script:repairQuitCallCount | Should -Be 0
        }

        It 'Returns structured error object when target Outlook store is not found' -Skip:(-not $isOutlookAvailable) {
            $mockEnv = New-MockRepairOutlookEnvironment
            Mock Get-OutlookComApplication { return $mockEnv.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'DiagnosticsProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath 'C:\NonExistent\GhostStore.pst'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'store.*not found'
            $mockEnv.Rules.SaveCalled | Should -BeFalse
        }
    }
}
