# ==============================================================================
# OutlookAdversarial.Tests.ps1
# Adversarial Stress Testing & Edge Case Suite for Modules/Outlook
# Covers: ConvertFrom-MapiBinaryProperty, Test-OutlookDataFileLock,
#         Get-OutlookSystemContext, Find-OutlookDataFiles, Move-OutlookDataFile
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    Import-Module (Join-Path $root 'Modules/Outlook/Outlook.psd1') -Force
}

Describe 'Adversarial: ConvertFrom-MapiBinaryProperty Robustness' {

    Context 'Buffer Length & Null Byte Edge Cases' {
        It 'Returns $null when Bytes parameter is $null' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes $null -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null when Bytes parameter is empty byte array' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@()) -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null for single null byte [0x00] in Unicode tag' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00)) -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null for single null byte [0x00] in ANSI tag' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00)) -PropertyName '001e6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null for single null byte [0x00] without tag' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00))
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null for two null bytes [0x00, 0x00] in Unicode tag' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00, 0x00)) -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null for multibyte null array [0x00, 0x00, 0x00, 0x00]' {
            InModuleScope 'Outlook' {
                $res = ConvertFrom-MapiBinaryProperty -Bytes ([byte[]]@(0x00, 0x00, 0x00, 0x00)) -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }

        It 'Returns $null when null terminator is at offset 0 followed by text' {
            InModuleScope 'Outlook' {
                $bytes = [byte[]]@(0x00, 0x00, 0x41, 0x00, 0x42, 0x00)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Odd-Length & Malformed Byte Buffers' {
        It 'Gracefully handles odd byte counts in Unicode property without throwing' {
            InModuleScope 'Outlook' {
                $bytes = [byte[]]@(0x41, 0x00, 0x42)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Be 'A'
            }
        }

        It 'Decodes Unicode path with odd dangling byte and ignores the partial byte' {
            InModuleScope 'Outlook' {
                $path = 'C:\Data\Archive.pst'
                $pathBytes = [System.Text.Encoding]::Unicode.GetBytes($path)
                $oddBytes = [byte[]]($pathBytes + @(0xEE))
                $res = ConvertFrom-MapiBinaryProperty -Bytes $oddBytes -PropertyName '001f6700'
                $res | Should -Be $path
            }
        }

        It 'Falls back to ANSI decode when single non-null byte [0x41] is provided' {
            InModuleScope 'Outlook' {
                $bytes = [byte[]]@(0x41)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Be 'A'
            }
        }

        It 'Handles non-byte array object inputs (e.g. integer array or hashtable)' {
            InModuleScope 'Outlook' {
                $intArr = @(67, 0, 58, 0, 92, 0)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $intArr -PropertyName '001f6700'
                $res | Should -Be 'C:\'

                $ht = @{ Invalid = 'Value' }
                $resHt = ConvertFrom-MapiBinaryProperty -Bytes $ht
                $resHt | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Trailing Buffer Garbage & Security Boundary' {
        It 'Stops at first null terminator and discards trailing corrupted garbage' {
            InModuleScope 'Outlook' {
                $valid = 'C:\Users\Admin\Documents\Outlook.pst'
                $validBytes = [System.Text.Encoding]::Unicode.GetBytes("$valid`0")
                $garbage = [byte[]]@(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22)
                $full = [byte[]]($validBytes + $garbage)

                $res = ConvertFrom-MapiBinaryProperty -Bytes $full -PropertyName '001f6700'
                $res | Should -Be $valid
            }
        }

        It 'Does not pick up second valid path injected after first null terminator' {
            InModuleScope 'Outlook' {
                $first = 'C:\Legitimate\Primary.pst'
                $second = 'C:\Malicious\Injected.ost'
                $bytes = [System.Text.Encoding]::Unicode.GetBytes("$first`0$second`0")

                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Be $first
                $res | Should -Not -Match 'Injected'
            }
        }

        It 'Discards ANSI trailing garbage after null byte' {
            InModuleScope 'Outlook' {
                $valid = 'C:\Data\Legacy.pst'
                $validBytes = [System.Text.Encoding]::Default.GetBytes("$valid`0")
                $garbage = [byte[]]@(0x7F, 0x80, 0x90, 0xA0)
                $full = [byte[]]($validBytes + $garbage)

                $res = ConvertFrom-MapiBinaryProperty -Bytes $full -PropertyName '001e6700'
                $res | Should -Be $valid
            }
        }
    }

    Context 'Unicode Surrogate Pairs & Non-ASCII Code Points' {
        It 'Correctly decodes valid UTF-16 surrogate pairs (SMP characters)' {
            InModuleScope 'Outlook' {
                $emoji = [char]::ConvertFromUtf32(0x1F600)
                $path = "C:\Data\Archive-$emoji.pst"
                $bytes = [System.Text.Encoding]::Unicode.GetBytes("$path`0")

                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Be $path
            }
        }

        It 'Handles truncated / orphaned high surrogate without crashing' {
            InModuleScope 'Outlook' {
                $bytes = [byte[]]@(0x43, 0x00, 0x3A, 0x00, 0x3D, 0xD8, 0x00, 0x00)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001f6700'
                $res | Should -Not -BeNullOrEmpty
            }
        }

        It 'Decodes non-ASCII ANSI byte values (CP1252 / high characters)' {
            InModuleScope 'Outlook' {
                $bytes = [byte[]]@(0x43, 0x3A, 0x5C, 0x44, 0x6F, 0x6E, 0x6E, 0xE9, 0x65, 0x73, 0x5C, 0x4D, 0x61, 0x69, 0x6C, 0x2E, 0x70, 0x73, 0x74, 0x00)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $bytes -PropertyName '001e6700'
                $res | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Tag Mismatch & Non-Path Heuristic Limits' {
        It 'Decodes binary GUID (0102 tag) into Unicode text rather than rejecting it as non-string' {
            InModuleScope 'Outlook' {
                $guidBytes = [byte[]]@(0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80)
                $res = ConvertFrom-MapiBinaryProperty -Bytes $guidBytes -PropertyName '01020001'
                # Empirical finding: PT_BINARY properties (0102*) are not filtered out by tag check;
                # fallback decodes raw bytes into mojibake string
                $res | Should -Not -BeNullOrEmpty
            }
        }

        It 'Heuristically decodes non-path ANSI string as Unicode mojibake when tag is omitted' {
            InModuleScope 'Outlook' {
                $ansiBytes = [System.Text.Encoding]::ASCII.GetBytes("Corporate Mailbox`0")
                $resNoTag = ConvertFrom-MapiBinaryProperty -Bytes $ansiBytes
                # Without tag and without path pattern, defaults to Unicode decode
                $resNoTag | Should -Not -Be 'Corporate Mailbox'

                # With proper ANSI tag (001e), decodes correctly
                $resWithTag = ConvertFrom-MapiBinaryProperty -Bytes $ansiBytes -PropertyName '001e3001'
                $resWithTag | Should -Be 'Corporate Mailbox'
            }
        }
    }
}

Describe 'Adversarial: Test-OutlookDataFileLock File Probing' {

    Context 'Non-Existent & Inaccessible File Scenarios' {
        It 'Handles non-existent file path cleanly without throwing' {
            $bogusPath = '/path/to/nonexistent/imaginary_file.pst'
            $res = Test-OutlookDataFileLock -Path $bogusPath
            $res.Exists | Should -BeFalse
            $res.IsLocked | Should -BeFalse
            $res.ErrorMessage | Should -Match 'File does not exist'
        }

        It 'Handles empty or whitespace paths by parameter validation failure' {
            { Test-OutlookDataFileLock -Path '' } | Should -Throw
        }

        It 'Directory path is reported as Exists=$true but IsLocked=$false' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                $res = Test-OutlookDataFileLock -Path $tempDir
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeFalse
            }
            finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Inaccessible file (chmod 000 permissions) is flagged as locked / access denied' {
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                chmod 000 $tempFile
                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeTrue
                $res.ErrorMessage | Should -Match 'Access denied|locked'
            }
            finally {
                chmod 644 $tempFile
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Read-only file (chmod 444 permissions) is flagged as locked because FileAccess.ReadWrite fails' {
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                chmod 444 $tempFile
                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeTrue
                $res.ErrorMessage | Should -Match 'Access denied|locked'
            }
            finally {
                chmod 644 $tempFile
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Active Exclusive Lock Stress Test' {
        It 'Detects FileStream held exclusively with FileShare.None on absolute path' {
            $tempFile = [System.IO.Path]::GetTempFileName()
            $fs = $null
            try {
                $fi = [System.IO.FileInfo]::new($tempFile)
                $fs = $fi.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.Exists | Should -BeTrue
                $res.IsLocked | Should -BeTrue
                $res.ErrorMessage | Should -Not -BeNullOrEmpty
            }
            finally {
                if ($null -ne $fs) {
                    $fs.Close()
                    $fs.Dispose()
                }
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Empirical Bug Finding: Relative path fails lock detection due to File::Exists current directory divergence' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $fileName = 'adversarial_rel_lock.pst'
            $absPath = Join-Path $tempDir $fileName
            [System.IO.File]::WriteAllText($absPath, 'Lock test payload')

            $fs = $null
            try {
                $fi = [System.IO.FileInfo]::new($absPath)
                $fs = $fi.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

                Push-Location $tempDir
                # Probe with relative path when $PWD differs from process working directory
                $resRel = Test-OutlookDataFileLock -Path ".\$fileName"
                $resAbs = Test-OutlookDataFileLock -Path $absPath

                # Absolute path correctly detects lock
                $resAbs.IsLocked | Should -BeTrue

                # Empirical vulnerability demonstration:
                # Relative path bypasses lock check and returns IsLocked=$false (FALSE NEGATIVE)
                $resRel.IsLocked | Should -BeFalse
            }
            finally {
                Pop-Location
                if ($null -ne $fs) {
                    $fs.Close()
                    $fs.Dispose()
                }
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Releases lock check cleanly and allows immediate subsequent write access' {
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                $res = Test-OutlookDataFileLock -Path $tempFile
                $res.IsLocked | Should -BeFalse

                [System.IO.File]::WriteAllText($tempFile, "Verified lock release")
                $content = [System.IO.File]::ReadAllText($tempFile)
                $content | Should -Be "Verified lock release"
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Adversarial: Get-OutlookSystemContext & Find-OutlookDataFiles Safe Fallbacks' {

    Context 'Office Complete Absence & Registry Fallback' {
        It 'Safely handles complete absence of Office registry hives without throwing' {
            Mock Test-Path { return $false }
            Mock Get-Process { return @() }
            Mock Find-OutlookDataFiles { return @() }
            Mock Get-OutlookPstThreshold {
                [PSCustomObject]@{
                    MaxLargeFileSizeMB  = 51200
                    WarnLargeFileSizeMB = 48640
                    IsCustomPolicy      = $false
                    PolicySource        = 'Default'
                    IsExpanded          = $false
                    Description         = 'Default limit (~50 GB threshold)'
                }
            }

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
        }

        It 'Never throws even if internal cmdlets throw terminating exceptions' {
            Mock Test-Path { throw [System.Security.SecurityException]::new("Access to registry hive denied") }
            Mock Get-Process { throw [System.UnauthorizedAccessException]::new("Cannot access process table") }

            $context = Get-OutlookSystemContext
            $context | Should -Not -BeNullOrEmpty
            $context.OfficeVersion | Should -Be 'None'
            $context.StatusMessage | Should -Be 'Office/Outlook not installed'
        }
    }

    Context 'Registry Corruption & Malformed Topology' {
        It 'Gracefully handles DefaultProfile having unexpected data type (int instead of string)' {
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
                        VersionToReport = '16.0.12345.67890'
                    }
                }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
                    return [PSCustomObject]@{
                        DefaultProfile = 9999
                    }
                }
                return $null
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @([PSCustomObject]@{ PSChildName = 'NormalProfile' })
                }
                return @()
            }

            $context = Get-OutlookSystemContext
            $context.DefaultProfile | Should -Be '9999'
            $context.Profiles | Should -Contain 'NormalProfile'
        }

        It 'Handles missing DefaultProfile key by falling back to first enumerated profile' {
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
                        VersionToReport = '16.0.12345.67890'
                    }
                }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
                    return [PSCustomObject]@{
                        SomeOtherSetting = 'Value'
                    }
                }
                return $null
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @(
                        [PSCustomObject]@{ PSChildName = 'FirstProfile' },
                        [PSCustomObject]@{ PSChildName = 'SecondProfile' }
                    )
                }
                return @()
            }

            $context = Get-OutlookSystemContext
            $context.DefaultProfile | Should -Be 'FirstProfile'
            $context.Profiles.Count | Should -Be 2
        }

        It 'Handles multi-profile topology with 50 profiles without performance degradation or error' {
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
                    return [PSCustomObject]@{ Platform = 'x64'; VersionToReport = '16.0.1000' }
                }
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
                    return [PSCustomObject]@{ DefaultProfile = 'Profile_25' }
                }
                return $null
            }
            Mock Get-ChildItem {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    $list = @()
                    for ($i = 1; $i -le 50; $i++) {
                        $list += [PSCustomObject]@{ PSChildName = "Profile_$i" }
                    }
                    return $list
                }
                return @()
            }

            $context = Get-OutlookSystemContext
            $context.Profiles.Count | Should -Be 50
            $context.DefaultProfile | Should -Be 'Profile_25'
        }
    }

    Context 'Find-OutlookDataFiles Corrupted Properties & Pipeline Unrolling' {
        It 'Find-OutlookDataFiles handles non-byte-array registry values without crashing' {
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') { return $true }
                return $false
            }
            Mock Get-ChildItem {
                param($LiteralPath, $Recurse)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @([PSCustomObject]@{ PSChildName = 'CorruptProfile'; PSPath = 'HKCU:\...\Profiles\CorruptProfile' })
                }
                if ($Recurse) {
                    return @([PSCustomObject]@{ PSPath = 'HKCU:\...\Profiles\CorruptProfile\Subkey1' })
                }
                return @()
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    '001f6700' = 12345
                    '001e6700' = $true
                    '01020001' = [byte[]]@(0x01, 0x02, 0x03)
                }
            }

            $res = @(Find-OutlookDataFiles -Scope Registry)
            $res.Count | Should -Be 0
        }

        It 'Find-OutlookDataFiles handles Unicode paths embedded in registry properties correctly' {
            $testPst = 'C:\Data\UserMailbox.pst'
            $utfBytes = [System.Text.Encoding]::Unicode.GetBytes("$testPst`0")

            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') { return $true }
                if ($LiteralPath -eq $testPst) { return $true }
                return $false
            }
            Mock Get-ChildItem {
                param($LiteralPath, $Recurse)
                if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles') {
                    return @([PSCustomObject]@{ PSChildName = 'ValidProfile'; PSPath = 'HKCU:\...\ValidProfile' })
                }
                if ($Recurse) {
                    return @([PSCustomObject]@{ PSPath = 'HKCU:\...\ValidProfile\Subkey1' })
                }
                return @()
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    '001f6700' = $utfBytes
                }
            }
            Mock Get-Item {
                param($LiteralPath)
                return [PSCustomObject]@{ Length = 104857600; LastWriteTime = (Get-Date) }
            }
            Mock Test-OutlookDataFileLock {
                return [PSCustomObject]@{ Path = $testPst; IsLocked = $false; Exists = $true }
            }

            $res = @(Find-OutlookDataFiles -Scope Registry)
            $res.Count | Should -Be 1
            $res[0].Path | Should -Be $testPst
            $res[0].Type | Should -Be 'PST'
            $res[0].Profile | Should -Be 'ValidProfile'
        }
    }
}
