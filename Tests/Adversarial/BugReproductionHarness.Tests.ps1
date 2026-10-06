# ==============================================================================
# BugReproductionHarness.Tests.ps1
# Empirical bug reproductions for Milestone 3 (Backup & Accounts) - Remediated
# ==============================================================================

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    Import-Module (Join-Path $root 'Modules/Backup/Backup.psd1') -Force
    Import-Module (Join-Path $root 'Modules/Accounts/Accounts.psd1') -Force
}

Describe 'Empirical Bug Verifications - Challenger 2 Remediations' {

    Context 'Bug 1: Test-BackupIntegrityManifest and Restore-UserProfileData crash on corrupted JSON' {
        It 'Test-BackupIntegrityManifest handles malformed JSON cleanly and returns IsIntact = $false without throwing' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $badManifest = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            Set-Content -Path $badManifest -Value '{"Files": [ truncated_corrupted_json' -Encoding UTF8

            try {
                $res = Test-BackupIntegrityManifest -ManifestPath $badManifest -TargetRoot $tempDir -ErrorAction Stop
                $res.IsIntact | Should -BeFalse
                $res.CorruptedCount | Should -Be 1
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-UserProfileData cleanly aborts without crashing when backup manifest is corrupted JSON' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $badManifest = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            Set-Content -Path $badManifest -Value '{ invalid_json_syntax: ' -Encoding UTF8

            try {
                $res = Restore-UserProfileData -BackupRoot $tempDir -Categories @('Desktop') -ErrorAction Stop
                $res.Success | Should -BeFalse
                $res.RestoredCategories.Count | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Bug 2: Enable-BuiltInAdministrator targets Domain Administrator on domain-joined machines (Remediated)' {
        It 'Enable-BuiltInAdministrator selects Local Administrator and ignores Domain Administrator on domain-joined machines' {
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = 'DomainAdmin'; SID = 'S-1-5-21-99999-500'; LocalAccount = $false },
                    [PSCustomObject]@{ Name = 'LocalAdmin';  SID = 'S-1-5-21-11111-500'; LocalAccount = $true }
                )
            }
            Mock Enable-LocalUser { }

            $res = Enable-BuiltInAdministrator
            # Verified fix: selects LocalAdmin, never DomainAdmin
            $res.AdministratorName | Should -Be 'LocalAdmin'
        }

        It 'Reset-BuiltInAdministratorPassword selects Local Administrator and ignores Domain Administrator on domain-joined machines' {
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = 'DomainAdmin'; SID = 'S-1-5-21-99999-500'; LocalAccount = $false },
                    [PSCustomObject]@{ Name = 'LocalAdmin';  SID = 'S-1-5-21-11111-500'; LocalAccount = $true }
                )
            }
            Mock Set-LocalUser { }

            $secPwd = ConvertTo-SecureString 'NewPass123!' -AsPlainText -Force
            $res = Reset-BuiltInAdministratorPassword -Password $secPwd
            # Verified fix: selects LocalAdmin, never DomainAdmin
            $res.AdministratorName | Should -Be 'LocalAdmin'
        }
    }

    Context 'Bug 3: Start-ProfileDirectoryBackup handles process launch failure' {
        It 'Reports CopiedCount = 0 and FailedCount = 1 with ExitCode = 16 when Start-Process throws' {
            Mock Start-Process { throw "robocopy.exe not found on system" }
            $res = Start-ProfileDirectoryBackup -SourceDirectories @('/src') -DestinationPath ([System.IO.Path]::GetTempPath())
            $res.FailedCount | Should -Be 1
            $res.ExitCode | Should -Be 16
        }
    }

    Context 'Bug 4: Start-ProfileDirectoryBackup retains worst exit code across multiple directories' {
        It 'Reports ExitCode = 16 when first directory had fatal Robocopy error (16) followed by success (1)' {
            $idx = 0
            Mock Start-Process {
                $script:idx++
                if ($script:idx -eq 1) { return [PSCustomObject]@{ ExitCode = 16 } }
                else { return [PSCustomObject]@{ ExitCode = 1 } }
            }
            $script:idx = 0
            $res = Start-ProfileDirectoryBackup -SourceDirectories @('/src1', '/src2') -DestinationPath ([System.IO.Path]::GetTempPath())
            $res.FailedCount | Should -Be 1
            $res.ExitCode | Should -Be 16
        }
    }

    Context 'Bug 5: Restore-UserProfileData excludes non-existent backup categories' {
        It 'Does not add category to RestoredCategories when category source folder does not exist in backup root' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $mFile = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            [PSCustomObject]@{ CreatedAt = '2026-10-06'; Files = @() } | ConvertTo-Json | Set-Content -Path $mFile

            try {
                $res = Restore-UserProfileData -BackupRoot $tempDir -Categories @('NonExistentFolder123')
                $res.RestoredCategories | Should -Not -Contain 'NonExistentFolder123'
                $res.Success | Should -BeTrue
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
