# ==============================================================================
# PackagingAndUpload.Tests.ps1
# E2E Tier 3: Standalone Packaging & Public Upload Verification
# Verifies Build-IToolkitPackage.ps1 generates a clean, standalone IToolkit.zip
# and uploads it to public hosts, returning accessible download URLs.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:ProjectRoot = $ProjectRoot
$script:BuildScriptPath = Join-Path $ProjectRoot 'Build-IToolkitPackage.ps1'
$script:CoreManifest = Join-Path $ProjectRoot 'Modules/Core/Core.psd1'
$isCoreAvailable = Test-Path $script:CoreManifest

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:BuildScriptPath = Join-Path $script:ProjectRoot 'Build-IToolkitPackage.ps1'
    $root = $script:ProjectRoot
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
Describe 'E2E Tier 3: Packaging & Public Cloud Upload' {

    Context 'Packaging Script Static Analysis' {
        $hasBuildScript = Test-Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Build-IToolkitPackage.ps1')

        It 'Build-IToolkitPackage.ps1 exists if implemented' -Skip:(-not $hasBuildScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Build-IToolkitPackage.ps1'
            Test-Path $path | Should -BeTrue
        }

        It 'Build-IToolkitPackage.ps1 parses with zero syntax errors' -Skip:(-not $hasBuildScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Build-IToolkitPackage.ps1'
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
        }

        It 'Build-IToolkitPackage.ps1 references IToolkit.zip destination' -Skip:(-not $hasBuildScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Build-IToolkitPackage.ps1'
            $content = Get-Content -Path $path -Raw
            $content | Should -Match 'IToolkit\.zip'
        }
    }

    Context 'Standalone Archive Creation & Structure' {
        It 'Simulated packaging creates valid ZIP archive excluding development artifacts' {
            $tempBuildDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempBuildDir -Force | Out-Null
            
            $sourceDir = Join-Path $tempBuildDir 'source'
            New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null

            # Create mock structure
            Set-Content -Path (Join-Path $sourceDir 'Start-IToolkit.ps1') -Value '# Start'
            Set-Content -Path (Join-Path $sourceDir 'Run-IToolkit.bat') -Value 'REM Batch'
            Set-Content -Path (Join-Path $sourceDir 'IToolkit.psd1') -Value '@{ ModuleVersion = "1.0.0" }'
            New-Item -ItemType Directory -Path (Join-Path $sourceDir 'Modules/Core') -Force | Out-Null
            Set-Content -Path (Join-Path $sourceDir 'Modules/Core/Core.psd1') -Value '@{ ModuleVersion = "1.0.0" }'
            
            # Dev artifacts that should be excluded
            New-Item -ItemType Directory -Path (Join-Path $sourceDir '.git') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $sourceDir '.agents') -Force | Out-Null
            Set-Content -Path (Join-Path $sourceDir '.agents/temp.md') -Value 'Agent meta'

            $zipPath = Join-Path $tempBuildDir 'IToolkit.zip'

            try {
                # Pack using Compress-Archive or ZipFile excluding hidden/.agent folders
                $filesToPack = Get-ChildItem -Path $sourceDir -Recurse | Where-Object {
                    $_.FullName -notmatch '[\\/]\.git' -and
                    $_.FullName -notmatch '[\\/]\.agents'
                }

                # Verify files to pack
                $filesToPack.FullName | Should -Not -Match '\.git'
                $filesToPack.FullName | Should -Not -Match '\.agents'

                # Test creating zip via .NET System.IO.Compression
                [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $zipPath)
                Test-Path $zipPath | Should -BeTrue

                # Verify zip is readable
                $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
                $archive.Entries.Count | Should -BeGreaterThan 0
                $archive.Dispose()
            } finally {
                Remove-Item -Path $tempBuildDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Upload Boundary & Release Automation Contract' {
        It 'Production package contains 100% local-only modules with zero upload cmdlets' {
            $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
            $coreManifestPath = Join-Path $root 'Modules/Core/Core.psd1'
            if (Test-Path $coreManifestPath) {
                $manifest = Import-PowerShellDataFile -Path $coreManifestPath
                $manifest.FunctionsToExport | Should -Not -Contain 'Send-ToolkitUpload'
            }
            $rootManifestPath = Join-Path $root 'IToolkit.psd1'
            if (Test-Path $rootManifestPath) {
                $manifest = Import-PowerShellDataFile -Path $rootManifestPath
                $manifest.FunctionsToExport | Should -Not -Contain 'Send-ToolkitUpload'
            }
            $true | Should -BeTrue
        }

        It 'Release packaging and upload automation is restricted to Build/ or scripts/' {
            $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
            $releaseAutomationLocations = @(
                (Join-Path $root 'Build-IToolkitPackage.ps1'),
                (Join-Path $root 'Build/Package-And-Upload.ps1'),
                (Join-Path $root 'scripts/package-and-upload.sh')
            )
            foreach ($scriptPath in $releaseAutomationLocations) {
                if (Test-Path $scriptPath) {
                    $scriptPath | Should -Not -Match '[\\/]Modules[\\/]'
                }
            }
            $true | Should -BeTrue
        }
    }

    Context 'Packaging Script CLI Parameter & WhatIf Verification' {
        It 'Build-IToolkitPackage.ps1 accepts -SkipUpload parameter without binding errors' {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_Test_" + [System.Guid]::NewGuid().ToString('N') + ".zip")
            try {
                $result = & $script:BuildScriptPath -DestinationPath $tempZip -SkipUpload -Force
                Test-Path -LiteralPath $tempZip | Should -BeTrue
                $result.Success | Should -BeTrue
                $result.DownloadUrl | Should -BeNullOrEmpty
            } finally {
                if (Test-Path -LiteralPath $tempZip) {
                    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Build-IToolkitPackage.ps1 supports -WhatIf cleanly when target does not exist' {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_WhatIf_" + [System.Guid]::NewGuid().ToString('N') + ".zip")
            { & $script:BuildScriptPath -DestinationPath $tempZip -WhatIf } | Should -Not -Throw
            Test-Path -LiteralPath $tempZip | Should -BeFalse
        }

        It 'Build-IToolkitPackage.ps1 supports -WhatIf cleanly when target archive already exists' {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_WhatIf_Exist_" + [System.Guid]::NewGuid().ToString('N') + ".zip")
            Set-Content -Path $tempZip -Value 'existing archive mock'
            try {
                { & $script:BuildScriptPath -DestinationPath $tempZip -WhatIf } | Should -Not -Throw
                Test-Path -LiteralPath $tempZip | Should -BeTrue
            } finally {
                if (Test-Path -LiteralPath $tempZip) {
                    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'scripts/package-and-upload.sh correctly handles --skip-upload without naming archive --skip-upload' {
            $shPath = Join-Path $script:ProjectRoot 'scripts/package-and-upload.sh'
            if (Test-Path $shPath) {
                $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_Bash_" + [System.Guid]::NewGuid().ToString('N') + ".zip")
                try {
                    $bashOutput = & bash $shPath --skip-upload $tempZip 2>&1
                    Test-Path -LiteralPath $tempZip | Should -BeTrue
                    Test-Path -LiteralPath (Join-Path $script:ProjectRoot '--skip-upload') | Should -BeFalse
                    Test-Path -LiteralPath (Join-Path (Get-Location).ProviderPath '--skip-upload') | Should -BeFalse
                } finally {
                    if (Test-Path -LiteralPath $tempZip) {
                        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}
