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

        It 'Discovers legacy Windows Messaging Subsystem profile topology' -Skip:(-not $isOutlookAvailable) {
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
            $context.OfficeVersion | Should -Be 'Legacy'
            $context.Profiles | Should -Contain 'LegacyWMSProfile'
            $context.DefaultProfile | Should -Be 'LegacyWMSProfile'
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

    Context 'Private Helper: Get-OutlookComApplication' {
        It 'Safely handles platform detection without throwing' -Skip:(-not $isOutlookAvailable) {
            InModuleScope 'Outlook' {
                { Get-OutlookComApplication } | Should -Not -Throw
            }
        }
    }
}
