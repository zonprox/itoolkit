<#
.SYNOPSIS
    Core module loader for IToolkit.
.DESCRIPTION
    Loads private internal helper scripts, dot-sources public cmdlets, and
    exports only authorized public functions while strictly hiding private helpers.
#>
[CmdletBinding()]
param()

$moduleRoot = $PSScriptRoot

# 1. Dot-source Private helper scripts first (available to public functions, not exported)
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
            $exportedFunctions += [System.IO.Path]::GetFileNameWithoutExtension($scriptFile.Name)
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
