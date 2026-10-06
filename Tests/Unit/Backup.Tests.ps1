# ==============================================================================
# Backup.Tests.ps1
# Unit test suite for Modules/Backup
# Covers: Get-UserProfileDirectoryMap, Export-BrowserBookmarks,
# Export-PersonalCertificates, Start-ProfileDirectoryBackup,
# New-BackupIntegrityManifest, Test-BackupIntegrityManifest, Restore-UserProfileData.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:BackupManifest = Join-Path $ProjectRoot 'Modules/Backup/Backup.psd1'
$isBackupAvailable = Test-Path $script:BackupManifest

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
Describe 'Unit: User Data Backup & Migration Module' {

    Context 'Profile Directory Discovery & Redirection' {
        It 'Get-UserProfileDirectoryMap resolves standard user paths and detects OneDrive' -Skip:(-not $isBackupAvailable) {
            Mock Get-ItemProperty { return [PSCustomObject]@{ 'Personal' = 'C:\Users\test\OneDrive - Corp\Documents' } }
            $map = Get-UserProfileDirectoryMap
            $map.Documents | Should -Match 'Documents'
            $map.IsOneDriveRedirected | Should -BeTrue
        }
    }

    Context 'Browser Bookmarks & Certificate Export' {
        It 'Export-BrowserBookmarks extracts Chrome and Edge bookmark JSON' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $true }
            Mock Copy-Item { }
            Mock Get-FileHash { return [PSCustomObject]@{ Hash = 'BM_HASH_123' } }

            $res = Export-BrowserBookmarks -DestinationPath 'C:\Backups\Bookmarks'
            $res.Count | Should -BeGreaterThan 0
            $res[0].Hash | Should -Be 'BM_HASH_123'
        }

        It 'Export-PersonalCertificates exports certificates using SecureString password' -Skip:(-not $isBackupAvailable) {
            $secPwd = ConvertTo-SecureString 'P@ssw0rdCert!' -AsPlainText -Force
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ Thumbprint = 'THUMB123'; Subject = 'CN=Test User'; HasPrivateKey = $true }
                )
            }
            Mock Export-PfxCertificate { }

            $res = Export-PersonalCertificates -DestinationPath 'C:\Backups\Certs' -Password $secPwd
            $res.Count | Should -Be 1
            $res[0].Thumbprint | Should -Be 'THUMB123'
        }
    }

    Context 'Robocopy Multithreaded Execution' {
        It 'Start-ProfileDirectoryBackup invokes robocopy and evaluates bitmask exit code' -Skip:(-not $isBackupAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } } # Exit code 1 = Successful copy
            $res = Start-ProfileDirectoryBackup -SourceDirectories @('C:\Users\test\Desktop') -DestinationPath 'D:\Backup\Desktop' -Threads 16
            $res.ExitCode | Should -Be 1
            $res.FailedCount | Should -Be 0
        }
    }

    Context 'Cryptographic Integrity Manifest & Verification' {
        It 'New-BackupIntegrityManifest generates JSON manifest of SHA-256 hashes' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            Set-Content -Path (Join-Path $tempDir 'sample.txt') -Value 'Hello World'
            try {
                $manifestPath = New-BackupIntegrityManifest -BackupRoot $tempDir
                Test-Path $manifestPath | Should -BeTrue
                $json = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
                $json.Files.Count | Should -Be 1
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Test-BackupIntegrityManifest verifies file checksums against manifest' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $sampleFile = Join-Path $tempDir 'sample.txt'
            Set-Content -Path $sampleFile -Value 'Integrity Test Content'
            $hash = (Get-FileHash -Path $sampleFile -Algorithm SHA256).Hash

            $manifestPath = Join-Path $tempDir 'IToolkit_Backup_Manifest.json'
            $manifestData = [PSCustomObject]@{
                Files = @(
                    [PSCustomObject]@{ RelativePath = 'sample.txt'; Hash = $hash; SizeBytes = 22 }
                )
            }
            $manifestData | ConvertTo-Json | Set-Content -Path $manifestPath

            try {
                $result = Test-BackupIntegrityManifest -ManifestPath $manifestPath -TargetRoot $tempDir
                $result.IsIntact | Should -BeTrue
                $result.MatchedCount | Should -Be 1
                $result.CorruptedCount | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-UserProfileData restores categories with integrity validation' -Skip:(-not $isBackupAvailable) {
            Mock Test-BackupIntegrityManifest { return [PSCustomObject]@{ IsIntact = $true } }
            Mock Copy-Item { }

            $res = Restore-UserProfileData -BackupRoot 'D:\Backups' -Categories @('Desktop', 'Documents')
            $res.Success | Should -BeTrue
        }
    }
}
