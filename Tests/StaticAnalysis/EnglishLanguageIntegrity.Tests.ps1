# ==============================================================================
# EnglishLanguageIntegrity.Tests.ps1
# Static analysis test suite for 100% English language and ASCII integrity.
# Scans all .ps1, .psm1, .psd1 files across Modules/ and Tests/.
# Enforces zero foreign language script residue and ASCII compliance.
# Compatible with Windows PowerShell 5.1 (.NET 4.8) and PowerShell 7+ Core.
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:ModulesDir = Join-Path $script:ProjectRoot 'Modules'
    $script:TestsDir = Join-Path $script:ProjectRoot 'Tests'

    # Helper to scan a file for non-ASCII characters (code point > 127)
    function Test-AsciiFileIntegrity {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FilePath,

            [int[]]$AllowedExceptions = @()
        )

        $violations = [System.Collections.Generic.List[PSCustomObject]]::new()
        if (-not (Test-Path -LiteralPath $FilePath)) {
            return $violations
        }

        $lines = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            $chars = $line.ToCharArray()
            $colNum = 0
            foreach ($ch in $chars) {
                $colNum++
                $codePoint = [int][char]$ch
                if ($codePoint -gt 127) {
                    if ($AllowedExceptions -notcontains $codePoint) {
                        $violations.Add([PSCustomObject]@{
                            File      = $FilePath
                            Line      = $lineNum
                            Column    = $colNum
                            CodePoint = $codePoint
                            Char      = [string]$ch
                            LineText  = $line.Trim()
                        })
                    }
                }
            }
        }

        return $violations
    }

    # Helper to scan for foreign language characters using AST parsing
    function Test-ForeignLanguageScriptResidue {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FilePath
        )

        $violations = [System.Collections.Generic.List[PSCustomObject]]::new()
        if (-not (Test-Path -LiteralPath $FilePath)) {
            return $violations
        }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)

        # Regex detecting non-Latin/non-standard foreign scripts (CJK, Cyrillic, Arabic, Hebrew, Thai, etc.)
        # Unicode ranges:
        # \u0400-\u04FF: Cyrillic
        # \u0600-\u06FF: Arabic
        # \u0590-\u05FF: Hebrew
        # \u4E00-\u9FFF: CJK Unified Ideographs
        # \u3040-\u309F: Hiragana
        # \u30A0-\u30FF: Katakana
        # \uAC00-\uD7AF: Hangul Syllables
        # \u0E00-\u0E7F: Thai
        # \u0900-\u097F: Devanagari
        $foreignScriptRegex = '[\u0400-\u04FF\u0600-\u06FF\u0590-\u05FF\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF\uAC00-\uD7AF\u0E00-\u0E7F\u0900-\u097F]'

        if ($tokens) {
            foreach ($token in $tokens) {
                $checkText = $null
                if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
                    $checkText = $token.Text
                } elseif ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::StringLiteral -or
                          $token.Kind -eq [System.Management.Automation.Language.TokenKind]::StringExpandable) {
                    $checkText = $token.Text
                }

                if ($checkText -and $checkText -match $foreignScriptRegex) {
                    $violations.Add([PSCustomObject]@{
                        File    = $FilePath
                        Line    = $token.Extent.StartLineNumber
                        Column  = $token.Extent.StartColumnNumber
                        Snippet = $token.Text
                        Kind    = $token.Kind.ToString()
                    })
                }
            }
        }

        return $violations
    }

    # Discover target files
    $script:ModuleScriptFiles = @(Get-ChildItem -Path $script:ModulesDir -Filter '*.ps*' -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
    $script:TestSuiteFiles = @(Get-ChildItem -Path $script:TestsDir -Filter '*.Tests.ps1' -Recurse -File)
    $script:AllTestFiles = @(Get-ChildItem -Path $script:TestsDir -Filter '*.ps*' -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
}

Describe 'StaticAnalysis: English Language & Character Encoding Integrity' {

    Context 'Production Modules ASCII Enforcement (Modules/)' {
        It 'Found module script files to validate' {
            $script:ModuleScriptFiles.Count | Should -BeGreaterThan 0
        }

        It 'All production module scripts (.ps1, .psm1, .psd1) contain strictly ASCII characters (0-127)' {
            $allViolations = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($file in $script:ModuleScriptFiles) {
                $violations = Test-AsciiFileIntegrity -FilePath $file.FullName
                if ($violations.Count -gt 0) {
                    foreach ($v in $violations) {
                        $allViolations.Add($v)
                    }
                }
            }

            if ($allViolations.Count -gt 0) {
                $errReport = $allViolations | ForEach-Object {
                    "Non-ASCII char '$($_.Char)' (0x$($_.CodePoint.ToString('X4'))) at $($_.File):$($_.Line):$($_.Column)"
                } | Out-String
                Write-Host $errReport -ForegroundColor Red
            }

            $allViolations.Count | Should -Be 0
        }

        It 'All production module scripts have zero foreign language script residue in strings and comments' {
            $allForeign = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($file in $script:ModuleScriptFiles) {
                $foreign = Test-ForeignLanguageScriptResidue -FilePath $file.FullName
                if ($foreign.Count -gt 0) {
                    foreach ($f in $foreign) {
                        $allForeign.Add($f)
                    }
                }
            }

            $allForeign.Count | Should -Be 0
        }
    }

    Context 'Test Suites ASCII & Foreign Language Enforcement (Tests/)' {
        It 'Found test suite files to validate' {
            $script:TestSuiteFiles.Count | Should -BeGreaterThan 0
        }

        It 'All unit, static analysis, adversarial, and E2E test files contain strictly ASCII characters (0-127)' {
            $allViolations = [System.Collections.Generic.List[PSCustomObject]]::new()
            # Test files excluding the master test runner banner
            $testFilesOnly = @($script:TestSuiteFiles | Where-Object { $_.Name -ne 'IToolkit.Tests.ps1' })
            foreach ($file in $testFilesOnly) {
                $violations = Test-AsciiFileIntegrity -FilePath $file.FullName
                if ($violations.Count -gt 0) {
                    foreach ($v in $violations) {
                        $allViolations.Add($v)
                    }
                }
            }

            if ($allViolations.Count -gt 0) {
                $errReport = $allViolations | ForEach-Object {
                    "Non-ASCII char '$($_.Char)' (0x$($_.CodePoint.ToString('X4'))) at $($_.File):$($_.Line):$($_.Column)"
                } | Out-String
                Write-Host $errReport -ForegroundColor Red
            }

            $allViolations.Count | Should -Be 0
        }

        It 'Master test runner Tests/IToolkit.Tests.ps1 conforms to ASCII with standard typographical punctuation' {
            $runnerPath = Join-Path $script:TestsDir 'IToolkit.Tests.ps1'
            Test-Path -LiteralPath $runnerPath | Should -Be $true
            # Allow em-dash (0x2014) in banner display
            $violations = Test-AsciiFileIntegrity -FilePath $runnerPath -AllowedExceptions @(0x2014)
            $violations.Count | Should -Be 0
        }

        It 'All files across Tests/ have zero foreign language script residue in strings and comments' {
            $allForeign = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($file in $script:AllTestFiles) {
                $foreign = Test-ForeignLanguageScriptResidue -FilePath $file.FullName
                if ($foreign.Count -gt 0) {
                    foreach ($f in $foreign) {
                        $allForeign.Add($f)
                    }
                }
            }

            $allForeign.Count | Should -Be 0
        }

        It 'Master test runner Tests/IToolkit.Tests.ps1 contains zero foreign language script residue' {
            $runnerPath = Join-Path $script:TestsDir 'IToolkit.Tests.ps1'
            Test-Path -LiteralPath $runnerPath | Should -Be $true
            $foreign = Test-ForeignLanguageScriptResidue -FilePath $runnerPath
            $foreign.Count | Should -Be 0
        }
    }

    Context 'Root Launchers and Script Files' {
        It 'Start-IToolkit.ps1 contains strictly ASCII characters (0-127) and zero foreign script' {
            $launcherPath = Join-Path $script:ProjectRoot 'Start-IToolkit.ps1'
            if (Test-Path -LiteralPath $launcherPath) {
                $asciiViolations = Test-AsciiFileIntegrity -FilePath $launcherPath
                $asciiViolations.Count | Should -Be 0
                $foreignViolations = Test-ForeignLanguageScriptResidue -FilePath $launcherPath
                $foreignViolations.Count | Should -Be 0
            }
        }

        It 'IToolkit.psd1 manifest contains strictly ASCII characters (0-127) and zero foreign script' {
            $manifestPath = Join-Path $script:ProjectRoot 'IToolkit.psd1'
            if (Test-Path -LiteralPath $manifestPath) {
                $asciiViolations = Test-AsciiFileIntegrity -FilePath $manifestPath
                $asciiViolations.Count | Should -Be 0
                $foreignViolations = Test-ForeignLanguageScriptResidue -FilePath $manifestPath
                $foreignViolations.Count | Should -Be 0
            }
        }
    }
}
