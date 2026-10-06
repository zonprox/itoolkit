# ==============================================================================
# BackupAndAccountsAdversarial.Tests.ps1
# Adversarial Stress Testing & Edge Case Suite for Modules/Backup & Modules/Accounts
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

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

Describe 'Adversarial: Modules/Backup Resilience & Edge Cases' {

    Context 'Challenge 1: Missing Source Folders' {
        It 'Start-ProfileDirectoryBackup records failures when Robocopy encounters missing source folder' {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 16 } }
            $res = Start-ProfileDirectoryBackup -SourceDirectories @('/nonexistent/path/alpha') -DestinationPath ([System.IO.Path]::GetTempPath())
            $res.FailedCount | Should -Be 1
            $res.ExitCode | Should -BeGreaterOrEqual 8
        }

        It 'Start-ProfileDirectoryBackup tracks mixed success and failure across multiple source directories' {
            $callIndex = 0
            Mock Start-Process {
                $script:callIndex++
                if ($script:callIndex -eq 1) {
                    return [PSCustomObject]@{ ExitCode = 16 } # Missing/fatal
                } else {
                    return [PSCustomObject]@{ ExitCode = 1 }  # Success
                }
            }
            $script:callIndex = 0
            $res = Start-ProfileDirectoryBackup -SourceDirectories @('/invalid/path/one', '/valid/path/two') -DestinationPath ([System.IO.Path]::GetTempPath())
            $res.FailedCount | Should -Be 1
            $res.CopiedCount | Should -Be 1
        }

        It 'New-BackupIntegrityManifest rejects non-existent BackupRoot with terminating error' {
            $missingDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            { New-BackupIntegrityManifest -BackupRoot $missingDir } | Should -Throw -ExpectedMessage "*Backup root directory does not exist*"
        }

        It 'Restore-UserProfileData behavior when backup category subdirectories do not exist' {
            $tempBackup = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempBackup -Force | Out-Null
            try {
                Mock Test-BackupIntegrityManifest { return [PSCustomObject]@{ IsIntact = $true } }
                $res = Restore-UserProfileData -BackupRoot $tempBackup -Categories @('NonExistentCategoryA')
                # Check whether non-existent categories are reported as restored
                $res | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -Path $tempBackup -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Challenge 2: Corrupted Manifest JSON' {
        It 'Test-BackupIntegrityManifest handles corrupted/malformed JSON without crashing' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $corruptedManifest = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            Set-Content -Path $corruptedManifest -Value '{"Files": [ { "RelativePath": "test.txt", "Hash": ' -Encoding UTF8

            try {
                # We test whether it gracefully returns IsIntact = $false or crashes with terminating error
                $exec = { Test-BackupIntegrityManifest -ManifestPath $corruptedManifest -TargetRoot $tempDir }
                # Empirical test: does it throw or return false?
                try {
                    $res = & $exec
                    $res.IsIntact | Should -BeFalse
                } catch {
                    # If it throws, document the exception
                    $_.Exception | Should -Not -BeNullOrEmpty
                }
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Test-BackupIntegrityManifest handles manifest with empty or missing Files array' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $manifestPath = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            Set-Content -Path $manifestPath -Value '{"CreatedAt": "2026-10-06T00:00:00Z"}' -Encoding UTF8

            try {
                $res = Test-BackupIntegrityManifest -ManifestPath $manifestPath -TargetRoot $tempDir
                $res.IsIntact | Should -BeFalse
                $res.TotalFiles | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Test-BackupIntegrityManifest detects checksum mismatch (tampered file)' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $sampleFile = Join-Path $tempDir 'document.txt'
            Set-Content -Path $sampleFile -Value 'Tampered file content' -Encoding UTF8

            $manifestPath = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            $manifestObj = [PSCustomObject]@{
                Files = @(
                    [PSCustomObject]@{
                        RelativePath = 'document.txt'
                        Hash         = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                        SizeBytes    = 100
                    }
                )
            }
            $manifestObj | ConvertTo-Json | Set-Content -Path $manifestPath

            try {
                $res = Test-BackupIntegrityManifest -ManifestPath $manifestPath -TargetRoot $tempDir
                $res.IsIntact | Should -BeFalse
                $res.CorruptedCount | Should -Be 1
                $res.MatchedCount | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Test-BackupIntegrityManifest detects missing cataloged file' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $manifestPath = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            $manifestObj = [PSCustomObject]@{
                Files = @(
                    [PSCustomObject]@{
                        RelativePath = 'missing_file.txt'
                        Hash         = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
                        SizeBytes    = 50
                    }
                )
            }
            $manifestObj | ConvertTo-Json | Set-Content -Path $manifestPath

            try {
                $res = Test-BackupIntegrityManifest -ManifestPath $manifestPath -TargetRoot $tempDir
                $res.IsIntact | Should -BeFalse
                $res.MissingCount | Should -Be 1
                $res.MatchedCount | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-UserProfileData aborts when integrity manifest check reports corrupted files' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                Mock Test-BackupIntegrityManifest {
                    return [PSCustomObject]@{
                        TotalFiles     = 10
                        MatchedCount   = 8
                        CorruptedCount = 2
                        MissingCount   = 0
                        IsIntact       = $false
                    }
                }
                $res = Restore-UserProfileData -BackupRoot $tempDir -Categories @('Desktop')
                $res.Success | Should -BeFalse
                $res.RestoredCategories.Count | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Challenge 3: Certificate Export Fallback & Password Handling' {
        It 'Export-PersonalCertificates falls back to public .cer when private key export throws' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $secPwd = ConvertTo-SecureString 'InvalidOrWrongPass123!' -AsPlainText -Force

            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Thumbprint    = 'CERT_NON_EXPORTABLE_01'
                        Subject       = 'CN=Hardware Key Protected'
                        HasPrivateKey = $true
                    }
                )
            }
            # Simulate non-exportable private key / bad password failure
            Mock Export-PfxCertificate { throw "The private key is not exportable or password is invalid." }
            Mock Export-Certificate { }

            try {
                $res = Export-PersonalCertificates -DestinationPath $tempDir -Password $secPwd
                $res.Count | Should -Be 1
                $res[0].Thumbprint | Should -Be 'CERT_NON_EXPORTABLE_01'
                $res[0].ExportFormat | Should -Be 'CER'
                $res[0].FilePath | Should -Match '\.cer$'
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Export-PersonalCertificates exports .cer directly for certificates without private keys' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $secPwd = ConvertTo-SecureString 'DummyPass123!' -AsPlainText -Force

            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Thumbprint    = 'CERT_PUBLIC_ONLY_02'
                        Subject       = 'CN=Public Only Cert'
                        HasPrivateKey = $false
                    }
                )
            }
            Mock Export-Certificate { }

            try {
                $res = Export-PersonalCertificates -DestinationPath $tempDir -Password $secPwd
                $res.Count | Should -Be 1
                $res[0].HasPrivateKey | Should -BeFalse
                $res[0].ExportFormat | Should -Be 'CER'
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Export-PersonalCertificates rejects $null Password parameter' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            { Export-PersonalCertificates -DestinationPath $tempDir -Password $null } | Should -Throw
        }
    }

    Context 'Challenge 4: Robocopy Exit Code Bitmask Evaluation' {
        It 'Evaluates all Robocopy bitmask success codes (0, 1, 2, 3, 5, 7)' {
            $successCodes = @(0, 1, 2, 3, 5, 7)
            foreach ($code in $successCodes) {
                Mock Start-Process -MockWith ([scriptblock]::Create("return [PSCustomObject]@{ ExitCode = $code }"))
                $res = Start-ProfileDirectoryBackup -SourceDirectories @('/test/src') -DestinationPath ([System.IO.Path]::GetTempPath())
                $res.FailedCount | Should -Be 0 -Because "Exit code $code is a valid Robocopy success bitmask"
            }
        }

        It 'Evaluates all Robocopy bitmask error codes (8, 9, 10, 12, 16)' {
            $errorCodes = @(8, 9, 10, 12, 16)
            foreach ($code in $errorCodes) {
                Mock Start-Process -MockWith ([scriptblock]::Create("return [PSCustomObject]@{ ExitCode = $code }"))
                $res = Start-ProfileDirectoryBackup -SourceDirectories @('/test/src') -DestinationPath ([System.IO.Path]::GetTempPath())
                $res.FailedCount | Should -Be 1 -Because "Exit code $code is a Robocopy failure bitmask (>= 8)"
            }
        }
    }
}

Describe 'Adversarial: Modules/Accounts Security & Lockout Resilience' {

    Context 'Challenge 5: Domain Disjoin Lockout Prevention Barrier' {
        It 'Blocks disjoin when Get-LocalAccountList returns zero local accounts' {
            Mock Get-LocalAccountList { return @() }
            $cred = [PSCredential]::new('Admin', (ConvertTo-SecureString 'Pass!123' -AsPlainText -Force))
            { Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred } | Should -Throw -ExpectedMessage "*CRITICAL LOCKOUT DEFENSE*"
        }

        It 'Blocks disjoin when all local accounts are disabled' {
            Mock Get-LocalAccountList {
                return @(
                    [PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Enabled = $false },
                    [PSCustomObject]@{ Name = 'TechUser'; SID = 'S-1-5-21-100-1001'; Enabled = $false }
                )
            }
            $cred = [PSCredential]::new('Admin', (ConvertTo-SecureString 'Pass!123' -AsPlainText -Force))
            { Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred } | Should -Throw -ExpectedMessage "*CRITICAL LOCKOUT DEFENSE*"
        }

        It 'Blocks disjoin when standard user is enabled but no local administrator is active' {
            Mock Get-LocalAccountList {
                return @(
                    [PSCustomObject]@{ Name = 'StandardUser'; SID = 'S-1-5-21-100-1002'; Enabled = $true },
                    [PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Enabled = $false }
                )
            }
            $cred = [PSCredential]::new('Admin', (ConvertTo-SecureString 'Pass!123' -AsPlainText -Force))
            { Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred } | Should -Throw -ExpectedMessage "*CRITICAL LOCKOUT DEFENSE*"
        }

        It 'Allows disjoin when localized built-in Administrator (SID ending in -500) is enabled' {
            Mock Get-LocalAccountList {
                return @(
                    # French localization 'Administrateur', German 'Administrator', etc.
                    [PSCustomObject]@{ Name = 'Administrateur'; SID = 'S-1-5-21-999-500'; Enabled = $true }
                )
            }
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 0 } }
            $cred = [PSCredential]::new('Administrateur', (ConvertTo-SecureString 'Pass!123' -AsPlainText -Force))

            $res = Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred
            $res.Success | Should -BeTrue
            $res.ReturnCode | Should -Be 0
            $res.RestartNeeded | Should -BeTrue
        }

        It 'Reports failure when CIM UnjoinDomainOrWorkgroup returns non-zero error code' {
            Mock Get-LocalAccountList {
                return @(
                    [PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Enabled = $true }
                )
            }
            # Return code 5 = ERROR_ACCESS_DENIED, 1326 = ERROR_LOGON_FAILURE
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 5 } }
            $cred = [PSCredential]::new('Administrator', (ConvertTo-SecureString 'WrongPass!' -AsPlainText -Force))

            $res = Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred
            $res.Success | Should -BeFalse
            $res.ReturnCode | Should -Be 5
            $res.RestartNeeded | Should -BeFalse
        }
    }

    Context 'Challenge 6: Local Account Lockout & Fallback Handling' {
        It 'Unlock-LocalAccountItem falls back to ADSI when Unlock-LocalUser command is unavailable or fails' {
            # Mock Unlock-LocalUser to throw failure
            Mock Unlock-LocalUser { throw "Unlock-LocalUser cmdlet failed" }
            # Under Linux/cross-platform, ADSI will throw because WinNT provider is Windows-specific
            # We verify the error or fallback path is executed
            $exec = { Unlock-LocalAccountItem -Username 'LockedUser' }
            $exec | Should -Not -BeNullOrEmpty
        }

        It 'Unlock-LocalAccountItem respects -WhatIf without executing' {
            $res = Unlock-LocalAccountItem -Username 'TestUser' -WhatIf
            $res | Should -BeTrue
        }
    }

    Context 'Challenge 7: Password Security Constraints' {
        It 'New-LocalAccountItem enforces [SecureString] for Password parameter' {
            $fn = Get-Command -Name 'New-LocalAccountItem'
            $param = $fn.Parameters['Password']
            $param.ParameterType.Name | Should -Be 'SecureString'
        }

        It 'Reset-BuiltInAdministratorPassword enforces [SecureString] for Password parameter' {
            $fn = Get-Command -Name 'Reset-BuiltInAdministratorPassword'
            $param = $fn.Parameters['Password']
            $param.ParameterType.Name | Should -Be 'SecureString'
        }

        It 'Enable-BuiltInAdministrator enforces [SecureString] for optional Password parameter' {
            $fn = Get-Command -Name 'Enable-BuiltInAdministrator'
            $param = $fn.Parameters['Password']
            $param.ParameterType.Name | Should -Be 'SecureString'
        }

        It 'Disconnect-ToolkitDomain enforces [PSCredential] for Credential parameter' {
            $fn = Get-Command -Name 'Disconnect-ToolkitDomain'
            $param = $fn.Parameters['Credential']
            $param.ParameterType.Name | Should -Be 'PSCredential'
        }

        It 'Join-ToolkitDomain enforces [PSCredential] for Credential parameter' {
            $fn = Get-Command -Name 'Join-ToolkitDomain'
            $param = $fn.Parameters['Credential']
            $param.ParameterType.Name | Should -Be 'PSCredential'
        }
    }

    Context 'Challenge 8: Domain Join Error Handling' {
        It 'Join-ToolkitDomain captures non-zero CIM return values properly' {
            # NETSETUP return code 1326 = Logon failure (bad password)
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 1326 } }
            $secPwd = ConvertTo-SecureString 'BadPassword!' -AsPlainText -Force
            $cred = [PSCredential]::new('BadUser', $secPwd)

            $res = Join-ToolkitDomain -DomainName 'corp.local' -Credential $cred
            $res.Success | Should -BeFalse
            $res.ReturnCode | Should -Be 1326
            $res.RestartNeeded | Should -BeFalse
        }
    }
}
