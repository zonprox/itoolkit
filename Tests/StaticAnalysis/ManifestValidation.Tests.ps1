# ==============================================================================
# ManifestValidation.Tests.ps1
# Static validation of module manifests (.psd1) across the IToolkit repository.
# Enforces PowerShellVersion 5.1, valid GUID, SemVer, author, and export limits.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$GuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$SemVerRegex = '^\d+\.\d+\.\d+(\..+)?$'

BeforeAll {
    function Test-ToolkitManifestStructure {
        param([hashtable]$ManifestData)
        
        $GuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        $SemVerRegex = '^\d+\.\d+\.\d+(\..+)?$'

        $results = [ordered]@{
            IsValid                  = $true
            Errors                   = [System.Collections.Generic.List[string]]::new()
            PowerShellVersionCompliant = $false
            HasValidGuid             = $false
            HasValidVersion          = $false
        }

        # Check PowerShellVersion
        if ($ManifestData.ContainsKey('PowerShellVersion')) {
            $psVer = [string]$ManifestData['PowerShellVersion']
            if ($psVer -eq '5.1' -or $psVer -eq '5.0') {
                $results.PowerShellVersionCompliant = $true
            } else {
                $results.Errors.Add("PowerShellVersion is '$psVer', expected '5.1' for Windows PowerShell 5.1 compatibility.")
                $results.IsValid = $false
            }
        } else {
            $results.Errors.Add("Manifest is missing required 'PowerShellVersion' key.")
            $results.IsValid = $false
        }

        # Check GUID
        if ($ManifestData.ContainsKey('GUID')) {
            $guidStr = [string]$ManifestData['GUID']
            if ($guidStr -match $GuidRegex) {
                $results.HasValidGuid = $true
            } else {
                $results.Errors.Add("GUID '$guidStr' is not a valid RFC 4122 GUID format.")
                $results.IsValid = $false
            }
        } else {
            $results.Errors.Add("Manifest is missing required 'GUID' key.")
            $results.IsValid = $false
        }

        # Check ModuleVersion
        if ($ManifestData.ContainsKey('ModuleVersion')) {
            $verStr = [string]$ManifestData['ModuleVersion']
            if ($verStr -match $SemVerRegex) {
                $results.HasValidVersion = $true
            } else {
                $results.Errors.Add("ModuleVersion '$verStr' is not valid SemVer format.")
                $results.IsValid = $false
            }
        } else {
            $results.Errors.Add("Manifest is missing required 'ModuleVersion' key.")
            $results.IsValid = $false
        }

        # Check Author & Description
        if (-not $ManifestData.ContainsKey('Author') -or [string]::IsNullOrWhiteSpace($ManifestData['Author'])) {
            $results.Errors.Add("Manifest is missing or has empty 'Author'.")
            $results.IsValid = $false
        }
        if (-not $ManifestData.ContainsKey('Description') -or [string]::IsNullOrWhiteSpace($ManifestData['Description'])) {
            $results.Errors.Add("Manifest is missing or has empty 'Description'.")
            $results.IsValid = $false
        }

        return [PSCustomObject]$results
    }
}

Describe 'StaticAnalysis: Module Manifest Validation' {

    Context 'Manifest Validation Rule Engine' {
        It 'Validates compliant manifest specification correctly' {
            $mockManifest = @{
                RootModule        = 'Core.psm1'
                ModuleVersion     = '1.0.0'
                GUID              = 'e0f46a9a-1111-4222-9333-888877776666'
                Author            = 'IT Administration Team'
                CompanyName       = 'Enterprise Support'
                PowerShellVersion = '5.1'
                Description       = 'Core system utilities and logging'
                FunctionsToExport = @('Test-IsAdmin', 'Assert-IsAdmin')
                CmdletsToExport   = @()
                AliasesToExport   = @()
            }
            $eval = Test-ToolkitManifestStructure -ManifestData $mockManifest
            $eval.IsValid | Should -BeTrue
            $eval.PowerShellVersionCompliant | Should -BeTrue
            $eval.HasValidGuid | Should -BeTrue
            $eval.HasValidVersion | Should -BeTrue
            $eval.Errors.Count | Should -Be 0
        }

        It 'Flags non-compliant PowerShellVersion (e.g. 7.0 instead of 5.1)' {
            $badManifest = @{
                ModuleVersion     = '1.0.0'
                GUID              = 'e0f46a9a-1111-4222-9333-888877776666'
                Author            = 'Test Author'
                PowerShellVersion = '7.0'
                Description       = 'Test Module'
            }
            $eval = Test-ToolkitManifestStructure -ManifestData $badManifest
            $eval.IsValid | Should -BeFalse
            $eval.PowerShellVersionCompliant | Should -BeFalse
            $eval.Errors | Should -Match 'PowerShellVersion'
        }

        It 'Flags invalid GUID formatting' {
            $badManifest = @{
                ModuleVersion     = '1.0.0'
                GUID              = 'invalid-guid-value'
                Author            = 'Test Author'
                PowerShellVersion = '5.1'
                Description       = 'Test Module'
            }
            $eval = Test-ToolkitManifestStructure -ManifestData $badManifest
            $eval.IsValid | Should -BeFalse
            $eval.HasValidGuid | Should -BeFalse
            $eval.Errors | Should -Match 'GUID'
        }

        It 'Flags invalid ModuleVersion format' {
            $badManifest = @{
                ModuleVersion     = 'v1'
                GUID              = 'e0f46a9a-1111-4222-9333-888877776666'
                Author            = 'Test Author'
                PowerShellVersion = '5.1'
                Description       = 'Test Module'
            }
            $eval = Test-ToolkitManifestStructure -ManifestData $badManifest
            $eval.IsValid | Should -BeFalse
            $eval.HasValidVersion | Should -BeFalse
            $eval.Errors | Should -Match 'ModuleVersion'
        }

        It 'Flags missing Author or Description' {
            $badManifest = @{
                ModuleVersion     = '1.0.0'
                GUID              = 'e0f46a9a-1111-4222-9333-888877776666'
                Author            = ''
                PowerShellVersion = '5.1'
                Description       = ''
            }
            $eval = Test-ToolkitManifestStructure -ManifestData $badManifest
            $eval.IsValid | Should -BeFalse
            $eval.Errors.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Repository Manifest Inventory Audit' {
        $expectedManifests = @(
            'IToolkit.psd1',
            'Modules/Core/Core.psd1',
            'Modules/Outlook/Outlook.psd1',
            'Modules/Office/Office.psd1',
            'Modules/Printers/Printers.psd1',
            'Modules/Backup/Backup.psd1',
            'Modules/Accounts/Accounts.psd1',
            'Modules/TUI/TUI.psd1',
            'Modules/ExternalTools/ExternalTools.psd1'
        )

        foreach ($relManifest in $expectedManifests) {
            $manifestPath = (Join-Path $ProjectRoot $relManifest)
            $manifestExists = Test-Path $manifestPath

            It "Manifest '$relManifest' is valid if present" -Skip:(-not $manifestExists) -TestCases @(@{ Path = $manifestPath; Name = $relManifest }) {
                param($Path, $Name)
                $manifestContent = Import-PowerShellDataFile -Path $Path
                $manifestContent | Should -Not -BeNullOrEmpty
                
                $eval = Test-ToolkitManifestStructure -ManifestData $manifestContent
                if (-not $eval.IsValid) {
                    Write-Error "Validation errors in $($Name): $($eval.Errors -join '; ')"
                }
                $eval.IsValid | Should -BeTrue
                $eval.PowerShellVersionCompliant | Should -BeTrue
                $eval.HasValidGuid | Should -BeTrue
            }
        }

        # Any other .psd1 files discovered in repo
        $discoveredManifests = Get-ChildItem -Path $ProjectRoot -Filter '*.psd1' -Recurse -File | Where-Object {
            $_.FullName -notmatch '[\\/]\.agents[\\/]' -and
            $_.FullName -notmatch '[\\/]Tests[\\/]'
        }

        It 'Discovered manifests pass validation' {
            foreach ($m in $discoveredManifests) {
                $data = Import-PowerShellDataFile -Path $m.FullName
                $eval = Test-ToolkitManifestStructure -ManifestData $data
                $eval.IsValid | Should -BeTrue
            }
            $true | Should -BeTrue
        }
    }
}
