function Get-ToolkitWingetStatus {
<#
.SYNOPSIS
    Evaluates the availability, version, path, and source repository health of Windows Package Manager (winget).
.DESCRIPTION
    Inspects system PATH and App Execution Aliases for winget.exe, verifies runtime version availability,
    and tests repository source connectivity (winget source list). Returns a structured status object.
    Supports cross-platform environments and mock stubs gracefully without unhandled exceptions.
.OUTPUTS
    [PSCustomObject] containing Available, Version, Path, Healthy, SourcesHealthy, ErrorMessage.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        Write-AppInstallerLog -Message "Inspecting Windows Package Manager (winget) status..." -Level 'DEBUG' -Component 'Get-ToolkitWingetStatus'

        $available = $false
        $version = $null
        $resolvedPath = $null
        $sourcesHealthy = $false
        $healthy = $false
        $errorMessage = $null

        # 1. Check for winget.exe via Get-Command and App Execution Alias
        $aliasDir = if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        } else {
            $null
        }
        $aliasPath = if ($aliasDir) {
            Join-Path $aliasDir 'winget.exe'
        } else {
            $null
        }

        $cmd = Get-Command -Name 'winget' -ErrorAction SilentlyContinue
        if ($cmd) {
            $available = $true
            if ($cmd.Source) {
                $resolvedPath = $cmd.Source
            } elseif ($cmd.Path) {
                $resolvedPath = $cmd.Path
            } else {
                $resolvedPath = 'winget'
            }
        } elseif ($aliasPath -and (Test-Path -LiteralPath $aliasPath)) {
            $available = $true
            $resolvedPath = $aliasPath
        }

        if (-not $available) {
            $errorMessage = "Windows Package Manager (winget.exe) is not found in PATH or App Execution Aliases."
            Write-AppInstallerLog -Message $errorMessage -Level 'DEBUG' -Component 'Get-ToolkitWingetStatus'
            return [PSCustomObject]@{
                Available      = $false
                Version        = $null
                Path           = $null
                Healthy        = $false
                SourcesHealthy = $false
                ErrorMessage   = $errorMessage
            }
        }

        # 2. Query winget version
        try {
            $verOutput = $null
            # If winget can be invoked directly (works for functions, aliases, native commands)
            $rawVer = & winget --version 2>&1
            $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
            if ($exitCode -eq 0 -or $rawVer) {
                $verOutput = [string]($rawVer | Out-String).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($verOutput)) {
                if ($verOutput -match 'v?(\d+\.\d+[\.\d+]*)') {
                    $version = $Matches[0]
                } else {
                    $version = $verOutput.Split("`r`n")[0].Trim()
                }
            }
        } catch {
            Write-AppInstallerLog -Message "Could not execute 'winget --version': $($_.Exception.Message)" -Level 'DEBUG' -Component 'Get-ToolkitWingetStatus'
        }

        # 3. Validate repository source health (winget source list)
        try {
            $rawSources = & winget source list 2>&1
            $srcExitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
            $srcText = [string]($rawSources | Out-String).Trim()

            if ($srcExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($srcText) -or $rawSources)) {
                $sourcesHealthy = $true
            } else {
                $sourcesHealthy = $false
                $errorMessage = "winget repository source check failed with exit code $srcExitCode."
            }
        } catch {
            $sourcesHealthy = $false
            if (-not $errorMessage) {
                $errorMessage = "Failed to query winget sources: $($_.Exception.Message)"
            }
        }

        # 4. Synthesize overall health
        if ($available -and $sourcesHealthy -and (-not [string]::IsNullOrWhiteSpace($version))) {
            $healthy = $true
            $errorMessage = $null
        } elseif ($available -and (-not $sourcesHealthy)) {
            $healthy = $false
            if (-not $errorMessage) {
                $errorMessage = "winget is installed ($version) but repository sources are unreachable or unconfigured."
            }
        } elseif ($available -and [string]::IsNullOrWhiteSpace($version)) {
            $healthy = $false
            if (-not $errorMessage) {
                $errorMessage = "winget executable found but failed to report valid version."
            }
        }

        Write-AppInstallerLog -Message "winget status: Available=$available, Version=$version, Healthy=$healthy, SourcesHealthy=$sourcesHealthy" -Level 'DEBUG' -Component 'Get-ToolkitWingetStatus'

        return [PSCustomObject]@{
            Available      = $available
            Version        = $version
            Path           = $resolvedPath
            Healthy        = $healthy
            SourcesHealthy = $sourcesHealthy
            ErrorMessage   = $errorMessage
        }
    }
}
