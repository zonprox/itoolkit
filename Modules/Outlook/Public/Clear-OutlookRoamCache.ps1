function Clear-OutlookRoamCache {
<#
.SYNOPSIS
    Selectively purges corrupted Outlook RoamCache stream files while strictly preserving AutoComplete nicknames.
.DESCRIPTION
    Purges cached stream files from %LOCALAPPDATA%\Microsoft\Outlook\RoamCache.
    By default (-PreserveAutocomplete $true), strictly preserves Stream_Autocomplete_*.dat
    to prevent user nickname contact data loss.
.PARAMETER PreserveAutocomplete
    Enforces strict preservation of Stream_Autocomplete_*.dat files. Default is $true.
.PARAMETER Force
    Terminates running OUTLOOK.EXE instances to release cache locks.
.OUTPUTS
    [PSCustomObject]@{ Status, PurgedCount, PreservedCount, TargetPath, PurgedFiles, PreservedAutocomplete, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$PreserveAutocomplete = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Process Check
        $isRunning = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($isRunning) {
            if ($Force) {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 500
            } else {
                $warnMsg = "Outlook is currently running. Close Outlook or specify -Force before purging RoamCache."
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Outlook:RoamCache'
                }
                return [PSCustomObject]@{
                    Status                = 'Warning'
                    PurgedCount           = 0
                    PreservedCount        = 0
                    TargetPath            = $null
                    PurgedFiles           = @()
                    PreservedAutocomplete = [bool]$PreserveAutocomplete
                    ErrorMessage          = $warnMsg
                }
            }
        }

        # 2. Locate RoamCache Directory
        $localAppData = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $env:LOCALAPPDATA
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Local'
        } else {
            $baseDir = if ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
            Join-Path -Path $baseDir -ChildPath 'AppData/Local'
        }
        $roamCacheDir = Join-Path -Path $localAppData -ChildPath 'Microsoft\Outlook\RoamCache'

        if (-not (Test-Path -LiteralPath $roamCacheDir)) {
            return [PSCustomObject]@{
                Status                = 'Success'
                PurgedCount           = 0
                PreservedCount        = 0
                TargetPath            = $roamCacheDir
                PurgedFiles           = @()
                PreservedAutocomplete = [bool]$PreserveAutocomplete
                ErrorMessage          = $null
            }
        }

        # 3. Classify and Purge Stream Files
        $rawFiles = Get-ChildItem -LiteralPath $roamCacheDir -File -ErrorAction SilentlyContinue
        $purgedList = [System.Collections.Generic.List[string]]::new()
        $preservedList = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $rawFiles) {
            $fName = $file.Name

            # CRITICAL SAFETY RULE: Autocomplete Preservation
            if ($PreserveAutocomplete -and ($fName -match '(?i)^Stream_Autocomplete_.*\.dat$')) {
                $preservedList.Add($fName)
                continue
            }

            if ($PSCmdlet.ShouldProcess($file.FullName, "Purge RoamCache stream")) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $purgedList.Add($fName)
                } catch {
                    Write-Verbose "Could not remove '$($file.FullName)': $($_.Exception.Message)"
                }
            } else {
                $purgedList.Add("[WhatIf] $fName")
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "RoamCache purge complete: $($purgedList.Count) stream(s) purged, $($preservedList.Count) AutoComplete file(s) preserved." -Level 'SUCCESS' -Component 'Outlook:RoamCache'
        }

        return [PSCustomObject]@{
            Status                = 'Success'
            PurgedCount           = $purgedList.Count
            PreservedCount        = $preservedList.Count
            TargetPath            = $roamCacheDir
            PurgedFiles           = $purgedList.ToArray()
            PreservedAutocomplete = [bool]$PreserveAutocomplete
            ErrorMessage          = $null
        }
    }
}
