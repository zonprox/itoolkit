<#
.SYNOPSIS
    Network Diagnostics & Repair module loader for IToolkit.
.DESCRIPTION
    Loads private internal helpers, dot-sources public cmdlets, registers cross-platform
    mock stubs and PSDrives, exposes global function definitions for session visibility,
    and exports authorized public network cmdlets.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+ Core across platforms.
#>
[CmdletBinding()]
param()

$moduleRoot = $PSScriptRoot

# 0. Cross-platform compatibility stubs for Windows-only cmdlets & tools (enables Pester mocking on non-Windows)
$windowsCmdlets = @(
    'Test-NetConnection',
    'Get-NetAdapter',
    'Restart-NetAdapter',
    'Get-NetIPAddress',
    'Get-NetIPConfiguration',
    'Get-NetConnectionProfile',
    'Set-NetConnectionProfile',
    'Clear-DnsClientCache',
    'Register-DnsClient',
    'Get-SmbClientConfiguration',
    'Set-SmbClientConfiguration',
    'Enable-NetFirewallRule',
    'Disable-NetFirewallRule',
    'Get-CimInstance',
    'Get-Service',
    'Restart-Service',
    'Start-Service',
    'Stop-Service',
    'Set-Service'
)
foreach ($cmdName in $windowsCmdlets) {
    if (-not (Get-Command -Name $cmdName -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:global:$cmdName" -Value {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromRemainingArguments = $true)]
                $RemainingArgs
            )
        }
    }
}

if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
}
if (-not (Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name 'D' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
}

# Ensure Test-IsAdmin is available if Core module is alongside
if (-not (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue)) {
    $coreAdminScript = Join-Path -Path $moduleRoot -ChildPath '../Core/Public/Test-IsAdmin.ps1'
    if (Test-Path -LiteralPath $coreAdminScript) {
        try {
            . $coreAdminScript
        }
        catch {
            Write-Verbose "Failed to dot-source Test-IsAdmin: $($_.Exception.Message)"
        }
    }
}

# 1. Dot-source Private helper scripts first (if any)
$privatePath = Join-Path -Path $moduleRoot -ChildPath 'Private'
if (Test-Path -LiteralPath $privatePath) {
    $privateScripts = Get-ChildItem -LiteralPath $privatePath -Filter '*.ps1' -File | Sort-Object -Property Name
    if ($null -ne $privateScripts) {
        foreach ($scriptFile in $privateScripts) {
            try {
                Write-Verbose "Loading private helper: $($scriptFile.Name)"
                . $scriptFile.FullName
                $fnName = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile.Name)
                if (Get-Command -Name $fnName -CommandType Function -ErrorAction SilentlyContinue) {
                    Set-Item -Path "function:global:$fnName" -Value (Get-Command -Name $fnName).ScriptBlock
                }
            }
            catch {
                throw "Failed to load private helper script '$($scriptFile.Name)': $($_.Exception.Message)"
            }
        }
    }
}

# 2. Dot-source Public function scripts
$publicPath = Join-Path -Path $moduleRoot -ChildPath 'Public'
$exportedFunctions = @()

if (Test-Path -LiteralPath $publicPath) {
    $publicScripts = Get-ChildItem -LiteralPath $publicPath -Filter '*.ps1' -File | Sort-Object -Property Name
    if ($null -ne $publicScripts) {
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
}

# 3. Export public functions explicitly
if ($exportedFunctions.Count -gt 0) {
    Export-ModuleMember -Function $exportedFunctions -Variable @()
}
