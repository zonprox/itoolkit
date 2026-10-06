# ==============================================================================
# CrossVersionSyntax.Tests.ps1
# Abstract Syntax Tree (AST) validation for cross-version PowerShell compatibility.
# Enforces compatibility across Windows PowerShell 5.1 (.NET 4.8) and PowerShell 7+.
# Banned: Ternary (? :), Null-Coalescing (??, ??=), Pipeline Chains (&&, ||), Deprecated WMI.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

BeforeAll {
    # Helper: Parses PowerShell code string into AST
    function Parse-ToolkitCode {
        param([string]$Code)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
        return [PSCustomObject]@{
            Ast    = $ast
            Tokens = $tokens
            Errors = $errors
        }
    }

    # Helper: Finds banned AST nodes
    function Find-BannedSyntaxNodes {
        param([System.Management.Automation.Language.Ast]$Ast)
        
        $bannedNodes = [System.Collections.Generic.List[PSCustomObject]]::new()
        
        # 1. Ternary operator (? :)
        $ternaryNodes = $Ast.FindAll({
            param($node) $node.GetType().Name -eq 'TernaryExpressionAst'
        }, $true)
        foreach ($node in $ternaryNodes) {
            $bannedNodes.Add([PSCustomObject]@{
                Type    = 'TernaryExpression'
                Extent  = $node.Extent.Text
                Line    = $node.Extent.StartLineNumber
                Message = 'Ternary operator (? :) is not supported in Windows PowerShell 5.1. Use if/else construct.'
            })
        }

        # 2. Null-coalescing (?? and ??=)
        $nullCoalescingNodes = $Ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $node.Operator.ToString() -eq 'QuestionQuestion') -or
            ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Operator.ToString() -eq 'QuestionQuestionEquals')
        }, $true)
        foreach ($node in $nullCoalescingNodes) {
            $bannedNodes.Add([PSCustomObject]@{
                Type    = 'NullCoalescingExpression'
                Extent  = $node.Extent.Text
                Line    = $node.Extent.StartLineNumber
                Message = 'Null-coalescing operator (?? / ??=) is not supported in Windows PowerShell 5.1.'
            })
        }

        # 3. Pipeline chain operators (&& and ||)
        $chainNodes = $Ast.FindAll({
            param($node) $node.GetType().Name -eq 'PipelineChainAst'
        }, $true)
        foreach ($node in $chainNodes) {
            $bannedNodes.Add([PSCustomObject]@{
                Type    = 'PipelineChain'
                Extent  = $node.Extent.Text
                Line    = $node.Extent.StartLineNumber
                Message = 'Pipeline chain operators (&& / ||) are not supported in Windows PowerShell 5.1.'
            })
        }

        # 4. Deprecated WMI cmdlets
        $bannedCmdlets = @('Get-WmiObject', 'Set-WmiInstance', 'Invoke-WmiMethod', 'Remove-WmiObject', 'gwmi')
        $commandNodes = $Ast.FindAll({
            param($node) $node.GetType().Name -eq 'CommandAst'
        }, $true)
        foreach ($cmd in $commandNodes) {
            $cmdName = $cmd.GetCommandName()
            if ($cmdName -and $bannedCmdlets -contains $cmdName) {
                $bannedNodes.Add([PSCustomObject]@{
                    Type    = 'DeprecatedWmiCmdlet'
                    Extent  = $cmd.Extent.Text
                    Line    = $cmd.Extent.StartLineNumber
                    Message = "Deprecated WMI cmdlet '$cmdName' detected. Must use CIM equivalent (Get-CimInstance, etc.)."
                })
            }
        }

        # 5. Empty catch blocks
        $catchNodes = $Ast.FindAll({
            param($node) $node.GetType().Name -eq 'CatchClauseAst'
        }, $true)
        foreach ($catch in $catchNodes) {
            $bodyText = $catch.Body.Extent.Text.Trim()
            # Strip braces
            if ($bodyText.StartsWith('{') -and $bodyText.EndsWith('}')) {
                $bodyText = $bodyText.Substring(1, $bodyText.Length - 2).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($bodyText)) {
                $bannedNodes.Add([PSCustomObject]@{
                    Type    = 'EmptyCatchBlock'
                    Extent  = $catch.Extent.Text
                    Line    = $catch.Extent.StartLineNumber
                    Message = 'Empty catch block detected. Swallowing exceptions is prohibited.'
                })
            }
        }

        return $bannedNodes
    }
}

Describe 'StaticAnalysis: AST Cross-Version Syntax Rules' {
    
    Context 'AST Rule Engine Verification' {
        It 'Correctly flags ternary operator (? :) as banned' {
            $code = '$result = ($true) ? "Yes" : "No"'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'TernaryExpression'
        }

        It 'Correctly flags null-coalescing operator (??) as banned' {
            $code = '$val = $config ?? "default"'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'NullCoalescingExpression'
        }

        It 'Correctly flags pipeline chain operators (&& and ||) as banned' {
            $code = 'Get-Process && Write-Output "Success"'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'PipelineChain'
        }

        It 'Correctly flags deprecated Get-WmiObject cmdlet as banned' {
            $code = '$os = Get-WmiObject -Class Win32_OperatingSystem'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'DeprecatedWmiCmdlet'
        }

        It 'Correctly flags gwmi alias as banned' {
            $code = 'gwmi Win32_BIOS'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'DeprecatedWmiCmdlet'
        }

        It 'Correctly flags empty catch block as banned' {
            $code = 'try { Get-Item "C:\missing" } catch { }'
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -BeGreaterThan 0
            $violations.Type | Should -Contain 'EmptyCatchBlock'
        }

        It 'Passes fully compliant PowerShell 5.1 / 7 code without violations' {
            $code = @'
function Get-ToolkitInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($null -ne $os) {
            return [PSCustomObject]@{ Name = $Name; OS = $os.Caption }
        } else {
            return [PSCustomObject]@{ Name = $Name; OS = 'Unknown' }
        }
    } catch {
        Write-Error "Failed to get OS info: $_"
        throw $_
    }
}
'@
            $parsed = Parse-ToolkitCode -Code $code
            $violations = Find-BannedSyntaxNodes -Ast $parsed.Ast
            $violations.Count | Should -Be 0
            $parsed.Errors.Count | Should -Be 0
        }
    }

    Context 'Repository Files Cross-Version Syntax Audit' {
        It 'All discovered project script files have valid syntax with zero parser errors' {
            $targetExtensions = @('.ps1', '.psm1', '.psd1')
            $files = Get-ChildItem -Path $ProjectRoot -Recurse -File | Where-Object {
                $ext = $_.Extension.ToLower()
                $targetExtensions -contains $ext -and
                $_.FullName -notmatch '[\\/]\.agents[\\/]' -and
                $_.FullName -notmatch '[\\/]Tests[\\/]'
            }

            $failedFiles = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $files) {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
                if ($errors.Count -gt 0) {
                    $msg = ($errors | ForEach-Object { "$($_.Message) (Line $($_.Extent.StartLineNumber))" }) -join '; '
                    $failedFiles.Add("$($file.FullName.Substring($ProjectRoot.Length).TrimStart('/', '\')): $msg")
                }
            }
            if ($failedFiles.Count -gt 0) {
                Write-Error ($failedFiles -join "`n")
            }
            $failedFiles.Count | Should -Be 0
        }

        It 'All discovered project script files contain zero banned PS 7+ or deprecated WMI syntax' {
            $targetExtensions = @('.ps1', '.psm1', '.psd1')
            $files = Get-ChildItem -Path $ProjectRoot -Recurse -File | Where-Object {
                $ext = $_.Extension.ToLower()
                $targetExtensions -contains $ext -and
                $_.FullName -notmatch '[\\/]\.agents[\\/]' -and
                $_.FullName -notmatch '[\\/]Tests[\\/]'
            }

            $violationsReport = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $files) {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
                $violations = Find-BannedSyntaxNodes -Ast $ast
                if ($violations.Count -gt 0) {
                    $details = ($violations | ForEach-Object { "Line $($_.Line): $($_.Type) - $($_.Message)" }) -join '; '
                    $violationsReport.Add("$($file.FullName.Substring($ProjectRoot.Length).TrimStart('/', '\')): $details")
                }
            }
            if ($violationsReport.Count -gt 0) {
                Write-Error ($violationsReport -join "`n")
            }
            $violationsReport.Count | Should -Be 0
        }
    }

    Context 'Target Platform & Office Version Guardrails' {
        It 'Enforces target OS restriction: Windows 10 and 11 only (rejects Win 7/8/XP)' {
            $validateOS = {
                param([string]$OsCaption, [version]$OsVersion)
                # Windows 10 is 10.0.10240+, Windows 11 is 10.0.22000+
                if ($OsVersion.Major -lt 10) {
                    throw "Unsupported operating system: $OsCaption ($OsVersion). IToolkit exclusively supports Windows 10 and Windows 11."
                }
                return $true
            }

            # Windows 10 / 11 passes
            (& $validateOS -OsCaption 'Microsoft Windows 11 Pro' -OsVersion ([version]'10.0.22631')) | Should -BeTrue
            (& $validateOS -OsCaption 'Microsoft Windows 10 Enterprise' -OsVersion ([version]'10.0.19045')) | Should -BeTrue

            # Windows 7 / 8 / XP throws
            { & $validateOS -OsCaption 'Microsoft Windows 7 Professional' -OsVersion ([version]'6.1.7601') } | Should -Throw -ExpectedMessage '*Unsupported operating system*'
            { & $validateOS -OsCaption 'Microsoft Windows 8.1 Pro' -OsVersion ([version]'6.3.9600') } | Should -Throw -ExpectedMessage '*Unsupported operating system*'
        }

        It 'Enforces Office version restriction: Office 16.0 only (2016/2021/2024/C2R), disallowing 14.0/15.0' {
            $validateOffice = {
                param([string]$OfficeHiveVersion)
                if ($OfficeHiveVersion -ne '16.0') {
                    throw "Unsupported Office version '$OfficeHiveVersion'. Only Office 16.0 (Office 2016, 2021, 2024, LTSC, ClickToRun) is supported."
                }
                return $true
            }

            # Office 16.0 passes
            (& $validateOffice -OfficeHiveVersion '16.0') | Should -BeTrue

            # Legacy Office 2010 (14.0) and Office 2013 (15.0) rejected
            { & $validateOffice -OfficeHiveVersion '14.0' } | Should -Throw -ExpectedMessage '*Unsupported Office version*'
            { & $validateOffice -OfficeHiveVersion '15.0' } | Should -Throw -ExpectedMessage '*Unsupported Office version*'
        }
    }
}
