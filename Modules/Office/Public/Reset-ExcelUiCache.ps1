function Reset-ExcelUiCache {
<#
.SYNOPSIS
    Resets corrupted Excel workspace and printer cache configuration files.
.DESCRIPTION
    Safely renames Excel16.xlb to a timestamped backup (.bak) in the quarantine directory.
    Optionally cleans corrupted templates and add-in files from the XLSTART directory.
    Terminates active EXCEL.EXE processes prior to touching configuration files.
.PARAMETER CleanXlStart
    When $true, also cleans corrupted auto-start files in the XLSTART directory. Default is $false.
.OUTPUTS
    [PSCustomObject] containing QuarantinedFiles and RestoredBackup.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$CleanXlStart = $false
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Excel UI Cache", "Reset Excel16.xlb and UI cache")) {
            return [PSCustomObject]@{
                QuarantinedFiles = @('[Simulated - WhatIf]')
                RestoredBackup   = $null
            }
        }

        # Pre-flight: terminate active Excel processes to prevent file lock
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'EXCEL') {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active EXCEL.EXE process prior to cache reset..." -Level 'WARN' -Component 'Reset-ExcelUiCache'
                    $null = Stop-ToolkitProcess -ProcessName 'EXCEL' -TimeoutSeconds 5 -Force
                }
            }
        }

        $quarantined = [System.Collections.Generic.List[string]]::new()
        $restoredBackup = $null

        # Resolve AppData path
        $appData = $null
        if ($null -ne $env:APPDATA -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $appData = $env:APPDATA
        }
        elseif ($null -ne $env:USERPROFILE -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $appData = Join-Path $env:USERPROFILE 'AppData\Roaming'
        }
        else {
            $appData = [System.IO.Path]::GetTempPath()
        }

        $excelDir = Join-Path (Join-Path $appData 'Microsoft') 'Excel'
        $xlbFile = Join-Path $excelDir 'Excel16.xlb'
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

        if (Test-Path -LiteralPath $xlbFile) {
            $bakName = "Excel16.xlb.bak.$timestamp"
            $bakPath = Join-Path $excelDir $bakName
            try {
                Rename-Item -LiteralPath $xlbFile -NewName $bakName -Force -ErrorAction Stop
                $quarantined.Add($xlbFile)
                $restoredBackup = $bakPath
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Quarantined Excel UI cache '$xlbFile' -> '$bakName'" -Level 'INFO' -Component 'Reset-ExcelUiCache'
                }
            }
            catch {
                Write-Verbose "Could not rename Excel16.xlb: $($_.Exception.Message)"
            }
        }

        if ($CleanXlStart) {
            $xlstartDir = Join-Path $excelDir 'XLSTART'
            if (Test-Path -LiteralPath $xlstartDir) {
                try {
                    $xlstartFiles = @(Get-ChildItem -LiteralPath $xlstartDir -File -ErrorAction SilentlyContinue)
                    foreach ($f in $xlstartFiles) {
                        $fBakName = "$($f.Name).bak.$timestamp"
                        try {
                            Rename-Item -LiteralPath $f.FullName -NewName $fBakName -Force -ErrorAction Stop
                            $quarantined.Add($f.FullName)
                        }
                        catch {
                            Write-Verbose "Could not rename XLSTART file '$($f.Name)': $($_.Exception.Message)"
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not quarantine XLSTART files: $($_.Exception.Message)"
                }
            }
        }

        return [PSCustomObject]@{
            QuarantinedFiles = @($quarantined)
            RestoredBackup   = $restoredBackup
        }
    }
}
