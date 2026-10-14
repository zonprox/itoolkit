function Reset-ExcelUiCache {
<#
.SYNOPSIS
    Resets corrupted Excel workspace files, Ribbon customizations, QAT cache, and WebServiceCache.
.DESCRIPTION
    Safely renames Excel16.xlb and Excel15.xlb to timestamped backups (.bak).
    Quarantines Excel.officeUI (ribbon customizations) and Excel.qat (Quick Access Toolbar).
    Purges dynamic Office 16.0 WebServiceCache files.
    Optionally cleans rogue auto-start files in XLSTART directories via -CleanXlStart.
    Terminates active EXCEL.EXE processes prior to touching configuration files.
    Supports -WhatIf for safe dry-run preview.
.PARAMETER CleanXlStart
    When $true, also cleans corrupted auto-start files in the XLSTART directory. Default is $false.
.OUTPUTS
    [PSCustomObject] containing Status, QuarantinedFiles, RestoredBackup, and WebServiceCachePurged.
.EXAMPLE
    Reset-ExcelUiCache
.EXAMPLE
    Reset-ExcelUiCache -CleanXlStart $true
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$CleanXlStart = $false
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Excel UI Cache", "Reset Excel workspace, ribbon, QAT, and WebServiceCache")) {
            return [PSCustomObject]@{
                Status                = 'Simulated'
                QuarantinedFiles      = @('[Simulated - WhatIf]')
                RestoredBackup        = $null
                WebServiceCachePurged = 0
            }
        }

        # Step 1: Pre-flight: terminate active Excel processes
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'EXCEL') {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active EXCEL.EXE process prior to cache reset..." -Level 'WARN' -Component 'Reset-ExcelUiCache'
                    $null = Stop-ToolkitProcess -ProcessName 'EXCEL' -TimeoutSeconds 5 -Force
                }
                else {
                    Stop-Process -Name 'EXCEL' -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $quarantined = [System.Collections.Generic.List[string]]::new()
        $restoredBackup = $null
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

        # Resolve paths
        $appData = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { $env:APPDATA } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE 'AppData\Roaming' } else { [System.IO.Path]::GetTempPath() }
        $localAppData = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE 'AppData\Local' } else { [System.IO.Path]::GetTempPath() }

        $excelDir = Join-Path (Join-Path $appData 'Microsoft') 'Excel'

        # 1. Workspace Toolbar Files (.xlb)
        $xlbTargets = @('Excel16.xlb', 'Excel15.xlb')
        foreach ($xlbName in $xlbTargets) {
            $xlbPath = Join-Path $excelDir $xlbName
            if (Test-Path -LiteralPath $xlbPath) {
                $bakName = "$xlbName.bak.$timestamp"
                $bakPath = Join-Path $excelDir $bakName
                try {
                    Rename-Item -LiteralPath $xlbPath -NewName $bakName -Force -ErrorAction Stop
                    $quarantined.Add($xlbPath)
                    if ([string]::IsNullOrEmpty($restoredBackup)) {
                        $restoredBackup = $bakPath
                    }
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Quarantined Excel workspace '$xlbPath' -> '$bakName'" -Level 'INFO' -Component 'Reset-ExcelUiCache'
                    }
                }
                catch {
                    Write-Verbose "Could not rename '$xlbName': $($_.Exception.Message)"
                }
            }
        }

        # 2. Ribbon & QAT Customizations (.officeUI and .qat)
        $uiSearchDirs = @(
            (Join-Path $localAppData 'Microsoft\Office'),
            (Join-Path $appData 'Microsoft\Office')
        )
        foreach ($uDir in $uiSearchDirs) {
            if (-not (Test-Path -LiteralPath $uDir)) { continue }
            try {
                $uiFiles = @(Get-ChildItem -LiteralPath $uDir -File -Filter 'Excel.*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.officeUI', '.qat') })
                foreach ($f in $uiFiles) {
                    $uBak = "$($f.Name).bak.$timestamp"
                    try {
                        Rename-Item -LiteralPath $f.FullName -NewName $uBak -Force -ErrorAction Stop
                        $quarantined.Add($f.FullName)
                        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                            Write-ToolkitLog -Message "Quarantined Excel UI customization '$($f.FullName)'" -Level 'INFO' -Component 'Reset-ExcelUiCache'
                        }
                    }
                    catch {
                        Write-Verbose "Could not rename UI file '$($f.Name)': $($_.Exception.Message)"
                    }
                }
            }
            catch {
                Write-Verbose "Could not search UI directory '$uDir': $($_.Exception.Message)"
            }
        }

        # 3. WebServiceCache Purge
        $webServiceDir = Join-Path (Join-Path $localAppData 'Microsoft\Office\16.0') 'WebServiceCache'
        $purgedWebCount = 0
        if (Test-Path -LiteralPath $webServiceDir) {
            try {
                $wsFiles = @(Get-ChildItem -LiteralPath $webServiceDir -File -Recurse -ErrorAction SilentlyContinue)
                foreach ($wf in $wsFiles) {
                    try {
                        Remove-Item -LiteralPath $wf.FullName -Force -ErrorAction Stop
                        $purgedWebCount++
                    }
                    catch {
                        Write-Verbose "Could not purge WebServiceCache file '$($wf.FullName)': $($_.Exception.Message)"
                    }
                }
            }
            catch {
                Write-Verbose "Could not process WebServiceCache: $($_.Exception.Message)"
            }
        }

        # 4. Optional XLSTART cleanup for backward compatibility
        if ($CleanXlStart) {
            if (Get-Command -Name 'Clear-ExcelStartupFolder' -ErrorAction SilentlyContinue) {
                try {
                    $xlRes = Clear-ExcelStartupFolder -Force
                    if ($xlRes -and $xlRes.RemovedFiles) {
                        foreach ($rf in $xlRes.RemovedFiles) {
                            $quarantined.Add($rf)
                        }
                    }
                }
                catch {
                    Write-Verbose "Error executing Clear-ExcelStartupFolder: $($_.Exception.Message)"
                }
            }
            else {
                # Fallback inline logic matching existing cmdlet
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
        }

        return [PSCustomObject]@{
            Status                = 'Success'
            QuarantinedFiles      = @($quarantined)
            RestoredBackup        = $restoredBackup
            WebServiceCachePurged = $purgedWebCount
        }
    }
}
