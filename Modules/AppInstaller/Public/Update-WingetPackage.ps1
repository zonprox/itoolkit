function Update-WingetPackage {
<#
.SYNOPSIS
    Upgrades an individual application or all installed applications using Windows Package Manager (winget).
.DESCRIPTION
    Invokes winget upgrade for a specific package or batch upgrades all eligible applications (--all).
    Supports -WhatIf / SupportsShouldProcess.
.PARAMETER PackageId
    The unique identifier of the package to upgrade (e.g. 'Google.Chrome').
.PARAMETER All
    Upgrades all installed applications that have available updates (--all).
.PARAMETER Exact
    Enforces exact package ID matching (--exact). Default is true.
.PARAMETER Silent
    Enforces silent/unattended upgrade mode (--silent). Default is true.
.PARAMETER IncludeUnknown
    Includes packages with unknown/unversioned states in upgrade operations (--include-unknown).
.PARAMETER CustomArgs
    Optional additional flags or arguments passed directly to winget.
.OUTPUTS
    [PSCustomObject] containing UpgradedPackages, TotalUpgraded, Success, ErrorMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [switch]$Exact = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Silent = $true,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUnknown,

        [Parameter(Mandatory = $false)]
        [string]$CustomArgs
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        $isAll = $All -or [string]::IsNullOrWhiteSpace($PackageId)
        $targetDesc = if ($isAll) { "All eligible applications" } else { "Package ID: $PackageId" }

        if (-not $PSCmdlet.ShouldProcess($targetDesc, "Upgrade application(s) via Windows Package Manager (winget)")) {
            Write-AppInstallerLog -Message "ShouldProcess: Skipping winget upgrade for '$targetDesc' (WhatIf mode)." -Level 'DEBUG' -Component 'Update-WingetPackage'
            return [PSCustomObject]@{
                UpgradedPackages = @()
                TotalUpgraded    = 0
                Success          = $false
                ErrorMessage     = 'Operation skipped by ShouldProcess (-WhatIf).'
            }
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.Add('upgrade')
        if ($isAll) {
            $argList.Add('--all')
        } else {
            $argList.Add("--id $PackageId")
            if ($Exact) { $argList.Add('--exact') }
        }

        if ($Silent) { $argList.Add('--silent') }
        $argList.Add('--accept-package-agreements')
        $argList.Add('--accept-source-agreements')
        if ($IncludeUnknown) { $argList.Add('--include-unknown') }
        if (-not [string]::IsNullOrWhiteSpace($CustomArgs)) { $argList.Add($CustomArgs) }

        $argsString = ($argList -join ' ').Trim()

        Write-AppInstallerLog -Message "Executing winget upgrade: winget $argsString" -Level 'INFO' -Component 'Update-WingetPackage'

        try {
            $proc = Start-Process -FilePath "winget" -ArgumentList $argsString -Wait -PassThru -ErrorAction Stop
            $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
            $isSuccess = ($exitCode -eq 0)

            if ($isSuccess) {
                $upgradedList = if ($isAll) { @('All') } else { @($PackageId) }
                $count = $upgradedList.Count
                Write-AppInstallerLog -Message "winget upgrade completed successfully for '$targetDesc' (exit code: 0)." -Level 'INFO' -Component 'Update-WingetPackage'
                return [PSCustomObject]@{
                    UpgradedPackages = @($upgradedList)
                    TotalUpgraded    = $count
                    Success          = $true
                    ErrorMessage     = $null
                }
            } else {
                $err = "winget upgrade returned non-zero exit code: $exitCode."
                Write-AppInstallerLog -Message "winget upgrade failed for '$targetDesc': $err" -Level 'WARN' -Component 'Update-WingetPackage'
                return [PSCustomObject]@{
                    UpgradedPackages = @()
                    TotalUpgraded    = 0
                    Success          = $false
                    ErrorMessage     = $err
                }
            }
        } catch {
            $err = "Exception while executing winget upgrade for '$targetDesc': $($_.Exception.Message)"
            Write-AppInstallerLog -Message $err -Level 'ERROR' -Component 'Update-WingetPackage'
            return [PSCustomObject]@{
                UpgradedPackages = @()
                TotalUpgraded    = 0
                Success          = $false
                ErrorMessage     = $err
            }
        }
    }
}
