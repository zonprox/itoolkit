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
    $certCmdlets = @('Export-Certificate', 'Export-PfxCertificate', 'Import-Certificate', 'Import-PfxCertificate')
    foreach ($cmd in $certCmdlets) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
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

    Context 'Multi-Store Certificate Export Engine (Export-ToolkitCertificates)' {
        It 'Discovers and exports certificates across Root, CA, and My stores' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $secPwd = ConvertTo-SecureString 'Pass123!' -AsPlainText -Force

            Mock Get-ChildItem {
                param($Path)
                if ($Path -match '(?i)[\\/]Root$') {
                    return @([PSCustomObject]@{ Thumbprint = 'ROOT_01'; Subject = 'CN=Test Root CA'; HasPrivateKey = $false })
                }
                if ($Path -match '(?i)[\\/]CA$') {
                    return @([PSCustomObject]@{ Thumbprint = 'INT_01'; Subject = 'CN=Test Intermediate CA'; HasPrivateKey = $false })
                }
                if ($Path -match '(?i)[\\/]My$') {
                    return @([PSCustomObject]@{ Thumbprint = 'MY_01'; Subject = 'CN=Test User Cert'; HasPrivateKey = $true })
                }
                return @()
            }
            Mock Export-Certificate { }
            Mock Export-PfxCertificate { }

            try {
                $res = Export-ToolkitCertificates -DestinationPath $tempDir -StoreNames @('Root', 'CA', 'My') -StoreLocations @('LocalMachine') -Password $secPwd
                $res.Count | Should -Be 3
                ($res | Where-Object { $_.Store -eq 'Root' }).Format | Should -Be 'CER'
                ($res | Where-Object { $_.Store -eq 'CA' }).Format | Should -Be 'CER'
                ($res | Where-Object { $_.Store -eq 'My' }).Format | Should -Be 'PFX'
                ($res | Where-Object { $_.Store -eq 'Root' }).Success | Should -BeTrue
                ($res | Where-Object { $_.Store -eq 'My' }).Success | Should -BeTrue
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Exports public certificates (.cer) without requiring a password' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Thumbprint = 'PUB_01'; Subject = 'CN=Public Cert'; HasPrivateKey = $false })
            }
            Mock Export-Certificate { }

            try {
                $res = Export-ToolkitCertificates -DestinationPath $tempDir -StoreNames @('Root') -StoreLocations @('LocalMachine')
                $res.Count | Should -Be 1
                $res[0].Format | Should -Be 'CER'
                $res[0].Success | Should -BeTrue
                Assert-MockCalled Export-Certificate -Times 1
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Exports private key certificates (.pfx) using SecureString password' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $secPwd = ConvertTo-SecureString 'Secret123!' -AsPlainText -Force

            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Thumbprint = 'PRIV_01'; Subject = 'CN=Private Key Cert'; HasPrivateKey = $true })
            }
            Mock Export-PfxCertificate { }

            try {
                $res = Export-ToolkitCertificates -DestinationPath $tempDir -StoreNames @('My') -StoreLocations @('CurrentUser') -Password $secPwd
                $res.Count | Should -Be 1
                $res[0].Format | Should -Be 'PFX'
                $res[0].Success | Should -BeTrue
                Assert-MockCalled Export-PfxCertificate -Times 1
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Falls back to .cer when private key export throws an error' -Skip:(-not $isBackupAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $secPwd = ConvertTo-SecureString 'Secret123!' -AsPlainText -Force

            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Thumbprint = 'PRIV_FAIL'; Subject = 'CN=Non-Exportable Cert'; HasPrivateKey = $true })
            }
            Mock Export-PfxCertificate { throw "Key not exportable" }
            Mock Export-Certificate { }

            try {
                $res = Export-ToolkitCertificates -DestinationPath $tempDir -StoreNames @('My') -StoreLocations @('CurrentUser') -Password $secPwd
                $res.Count | Should -Be 1
                $res[0].Format | Should -Be 'CER'
                $res[0].Success | Should -BeTrue
                Assert-MockCalled Export-Certificate -Times 1
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Does not create subdirectories for stores containing zero certificates' -Skip:(-not $isBackupAvailable) {
            $emptyDest = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            Mock Get-ChildItem {
                param($Path)
                if ($Path -match '(?i)[\\/]Root$') {
                    return @([PSCustomObject]@{ Thumbprint = 'ROOT_EXISTS'; Subject = 'CN=Root'; HasPrivateKey = $false })
                }
                return @()
            }
            Mock Export-Certificate { }

            try {
                $res = Export-ToolkitCertificates -DestinationPath $emptyDest -StoreNames @('Root', 'CA', 'My') -StoreLocations @('LocalMachine')
                $res.Count | Should -Be 1
                Test-Path (Join-Path $emptyDest 'LocalMachine_Root') | Should -BeTrue
                Test-Path (Join-Path $emptyDest 'LocalMachine_CA') | Should -BeFalse
                Test-Path (Join-Path $emptyDest 'LocalMachine_My') | Should -BeFalse
            } finally {
                Remove-Item -Path $emptyDest -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Simulates certificate export under -WhatIf without executing export commands' -Skip:(-not $isBackupAvailable) {
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Thumbprint = 'WHATIF_01'; Subject = 'CN=WhatIf Cert'; HasPrivateKey = $false })
            }
            Mock Export-Certificate { }

            $res = Export-ToolkitCertificates -DestinationPath 'C:\Backups\Certs' -WhatIf
            $res.Count | Should -BeGreaterThan 0
            $res[0].Success | Should -BeTrue
            Assert-MockCalled Export-Certificate -Times 0
        }

        It 'Rejects invalid store names or locations via parameter validation' -Skip:(-not $isBackupAvailable) {
            { Export-ToolkitCertificates -StoreNames 'InvalidStore' } | Should -Throw
            { Export-ToolkitCertificates -StoreLocations 'InvalidLoc' } | Should -Throw
        }
    }

    Context 'Multi-Store Certificate Import Engine (Import-ToolkitCertificates)' {
        It 'Imports .cer certificates into target store' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $true }
            Mock Import-Certificate { return [PSCustomObject]@{ Thumbprint = 'IMP_CER_01'; Subject = 'CN=Imported Cert' } }

            $res = Import-ToolkitCertificates -Path 'C:\Backups\cert.cer' -StoreName 'Root' -StoreLocation 'LocalMachine'
            $res.Count | Should -Be 1
            $res[0].Success | Should -BeTrue
            $res[0].Thumbprint | Should -Be 'IMP_CER_01'
            $res[0].Store | Should -Be 'Root'
            Assert-MockCalled Import-Certificate -Times 1
        }

        It 'Imports .pfx certificates using SecureString password' -Skip:(-not $isBackupAvailable) {
            $secPwd = ConvertTo-SecureString 'Secret123!' -AsPlainText -Force
            Mock Test-Path { return $true }
            Mock Import-PfxCertificate { return [PSCustomObject]@{ Thumbprint = 'IMP_PFX_01'; Subject = 'CN=Imported PFX' } }

            $res = Import-ToolkitCertificates -Path 'C:\Backups\cert.pfx' -StoreName 'My' -StoreLocation 'CurrentUser' -Password $secPwd
            $res.Count | Should -Be 1
            $res[0].Success | Should -BeTrue
            $res[0].Thumbprint | Should -Be 'IMP_PFX_01'
            Assert-MockCalled Import-PfxCertificate -Times 1
        }

        It 'Automatically detects target store from path naming' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $true }
            Mock Import-Certificate { return [PSCustomObject]@{ Thumbprint = 'AUTO_01'; Subject = 'CN=Auto Cert' } }

            $resRoot = Import-ToolkitCertificates -Path 'C:\Backups\LocalMachine_Root\cert.cer' -StoreName 'Auto'
            $resRoot[0].Store | Should -Be 'Root'

            $resCA = Import-ToolkitCertificates -Path 'C:\Backups\LocalMachine_CA\cert.crt' -StoreName 'Auto'
            $resCA[0].Store | Should -Be 'CA'

            $resMy = Import-ToolkitCertificates -Path 'C:\Backups\cert.pfx' -StoreName 'Auto'
            $resMy[0].Store | Should -Be 'My'
        }

        It 'Falls back from LocalMachine to CurrentUser when session is non-elevated' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $true }
            Mock Test-IsAdmin { return $false }
            Mock Import-Certificate { return [PSCustomObject]@{ Thumbprint = 'FALLBACK_01'; Subject = 'CN=Fallback' } }

            $res = Import-ToolkitCertificates -Path 'C:\Backups\cert.cer' -StoreName 'Root' -StoreLocation 'LocalMachine'
            $res[0].Location | Should -Be 'CurrentUser'
        }

        It 'Simulates certificate import under -WhatIf without invoking import cmdlets' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $true }
            Mock Import-Certificate { }

            $res = Import-ToolkitCertificates -Path 'C:\Backups\cert.cer' -WhatIf
            $res.Count | Should -Be 1
            $res[0].Success | Should -BeTrue
            Assert-MockCalled Import-Certificate -Times 0
        }

        It 'Rejects invalid parameters' -Skip:(-not $isBackupAvailable) {
            { Import-ToolkitCertificates -Path '' } | Should -Throw
            { Import-ToolkitCertificates -Path $null } | Should -Throw
            { Import-ToolkitCertificates -Path 'C:\cert.cer' -StoreName 'InvalidStore' } | Should -Throw
            { Import-ToolkitCertificates -Path 'C:\cert.cer' -StoreLocation 'InvalidLoc' } | Should -Throw
        }

        It 'Returns structured error object when target path does not exist' -Skip:(-not $isBackupAvailable) {
            Mock Test-Path { return $false }

            $res = Import-ToolkitCertificates -Path 'C:\NonExistent\cert.cer'
            $res.Count | Should -Be 1
            $res[0].Success | Should -BeFalse
            $res[0].ErrorMessage | Should -Match 'does not exist'
        }
    }

    Context 'Backward Compatibility (Export-PersonalCertificates)' {
        It 'Maintains backward compatibility with optional multi-store parameters' -Skip:(-not $isBackupAvailable) {
            $secPwd = ConvertTo-SecureString 'Secret123!' -AsPlainText -Force
            Mock Get-ChildItem {
                return @([PSCustomObject]@{ Thumbprint = 'LEGACY_01'; Subject = 'CN=Legacy User'; HasPrivateKey = $false })
            }
            Mock Export-Certificate { }

            $res = Export-PersonalCertificates -DestinationPath 'C:\Backups\Certs' -Password $secPwd -StoreNames @('Root') -StoreLocations @('LocalMachine')
            $res.Count | Should -Be 1
            $res[0].Thumbprint | Should -Be 'LEGACY_01'
            $res[0].ExportFormat | Should -Be 'CER'
        }
    }
}

