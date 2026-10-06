<#
.SYNOPSIS
    Accounts module loader for IToolkit.
.DESCRIPTION
    Loads private internal helpers, dot-sources public cmdlets, registers global function
    definitions for cross-session/Pester discovery, and exports public cmdlets.
    Strictly compliant with Windows PowerShell 5.1 and PowerShell 7+ Core.
#>
[CmdletBinding()]
param()

$moduleRoot = $PSScriptRoot

# 0. Cross-platform compatibility stubs for Windows/AD cmdlets (enables Pester mocking on non-Windows)
$windowsCmdlets = @(
    'Get-CimInstance',
    'Invoke-CimMethod',
    'New-LocalUser',
    'Unlock-LocalUser',
    'Enable-LocalUser',
    'Disable-LocalUser',
    'Set-LocalUser',
    'Resolve-DnsName',
    'Test-NetConnection',
    'Get-ADUser',
    'Unlock-ADAccount',
    'Enable-ADAccount',
    'Disable-ADAccount'
)
foreach ($cmdName in $windowsCmdlets) {
    if (-not (Get-Command -Name $cmdName -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:global:$cmdName" -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
    }
}

# 1. Dot-source Private helper scripts first (if any)
$privatePath = Join-Path -Path $moduleRoot -ChildPath 'Private'
if (Test-Path -LiteralPath $privatePath) {
    $privateScripts = Get-ChildItem -LiteralPath $privatePath -Filter '*.ps1' -File | Sort-Object -Property Name
    foreach ($scriptFile in $privateScripts) {
        try {
            Write-Verbose "Loading private helper: $($scriptFile.Name)"
            . $scriptFile.FullName
        }
        catch {
            throw "Failed to load private helper script '$($scriptFile.Name)': $($_.Exception.Message)"
        }
    }
}

# 2. Dot-source Public function scripts
$publicPath = Join-Path -Path $moduleRoot -ChildPath 'Public'
$exportedFunctions = @()

if (Test-Path -LiteralPath $publicPath) {
    $publicScripts = Get-ChildItem -LiteralPath $publicPath -Filter '*.ps1' -File | Sort-Object -Property Name
    foreach ($scriptFile in $publicScripts) {
        try {
            Write-Verbose "Loading public cmdlet: $($scriptFile.Name)"
            . $scriptFile.FullName
            $fnName = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile.Name)
            $exportedFunctions += $fnName
            if (Get-Command -Name $fnName -CommandType Function -ErrorAction SilentlyContinue) {
                Set-Item -Path "function:global:$fnName" -Value (Get-Command -Name $fnName).ScriptBlock
            }
        }
        catch {
            throw "Failed to load public cmdlet script '$($scriptFile.Name)': $($_.Exception.Message)"
        }
    }
}

# 3. Export public functions explicitly
if ($exportedFunctions.Count -gt 0) {
    Export-ModuleMember -Function $exportedFunctions -Variable @()
}
