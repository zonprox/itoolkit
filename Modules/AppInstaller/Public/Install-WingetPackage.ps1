function Install-WingetPackage {
<#
.SYNOPSIS
    Installs a software package using Windows Package Manager (winget).
.DESCRIPTION
    Invokes winget install with silent flags, source/package agreement acceptance, and exact package matching.
    Supports -WhatIf / SupportsShouldProcess.
.PARAMETER PackageId
    The unique identifier of the package in the winget repository (e.g. 'Google.Chrome', 'RARLab.WinRAR').
.PARAMETER Exact
    Enforces exact package ID matching (--exact). Default is true.
.PARAMETER Silent
    Enforces silent/unattended installation mode (--silent). Default is true.
.PARAMETER Force
    Adds --force flag to install even if already installed.
.PARAMETER CustomArgs
    Optional additional flags or arguments passed directly to winget.
.OUTPUTS
    [PSCustomObject] containing PackageId, Installed, Success, ErrorMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [switch]$Exact = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Silent = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$CustomArgs
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        if (-not $PSCmdlet.ShouldProcess("Package ID: $PackageId", "Install package via Windows Package Manager (winget)")) {
            Write-AppInstallerLog -Message "ShouldProcess: Skipping package install for '$PackageId' (WhatIf mode)." -Level 'DEBUG' -Component 'Install-WingetPackage'
            return [PSCustomObject]@{
                PackageId    = $PackageId
                Installed    = $false
                Success      = $false
                ErrorMessage = 'Operation skipped by ShouldProcess (-WhatIf).'
            }
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.Add('install')
        $argList.Add("--id $PackageId")
        if ($Exact) { $argList.Add('--exact') }
        if ($Silent) { $argList.Add('--silent') }
        $argList.Add('--accept-package-agreements')
        $argList.Add('--accept-source-agreements')
        if ($Force) { $argList.Add('--force') }
        if (-not [string]::IsNullOrWhiteSpace($CustomArgs)) { $argList.Add($CustomArgs) }

        $argsString = ($argList -join ' ').Trim()

        Write-AppInstallerLog -Message "Executing winget: winget $argsString" -Level 'INFO' -Component 'Install-WingetPackage'

        try {
            $proc = Start-Process -FilePath "winget" -ArgumentList $argsString -Wait -PassThru -ErrorAction Stop
            $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
            $isSuccess = ($exitCode -eq 0)

            if ($isSuccess) {
                Write-AppInstallerLog -Message "Successfully installed package '$PackageId' via winget (exit code: 0)." -Level 'INFO' -Component 'Install-WingetPackage'
                return [PSCustomObject]@{
                    PackageId    = $PackageId
                    Installed    = $true
                    Success      = $true
                    ErrorMessage = $null
                }
            } else {
                $err = "winget install returned non-zero exit code: $exitCode."
                Write-AppInstallerLog -Message "Failed installing package '$PackageId': $err" -Level 'WARN' -Component 'Install-WingetPackage'
                return [PSCustomObject]@{
                    PackageId    = $PackageId
                    Installed    = $false
                    Success      = $false
                    ErrorMessage = $err
                }
            }
        } catch {
            $err = "Exception while executing winget for '$PackageId': $($_.Exception.Message)"
            Write-AppInstallerLog -Message $err -Level 'ERROR' -Component 'Install-WingetPackage'
            return [PSCustomObject]@{
                PackageId    = $PackageId
                Installed    = $false
                Success      = $false
                ErrorMessage = $err
            }
        }
    }
}
