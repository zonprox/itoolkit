function Clear-OfficeTempCache {
<#
.SYNOPSIS
    Purges Office Document Cache and modern Web Add-in cache directories.
.DESCRIPTION
    Scans and cleans Office Document Cache (%LOCALAPPDATA%\Microsoft\Office\16.0\OfficeFileCache)
    and Web Add-in cache (%LOCALAPPDATA%\Microsoft\Office\16.0\Wef).
    Calculates total files cleaned and total bytes freed only for files successfully deleted.
.PARAMETER IncludeDocumentCache
    When $true, clears OfficeFileCache. Default is $true.
.PARAMETER IncludeWefCache
    When $true, clears Web Add-in cache (Wef). Default is $true.
.PARAMETER Force
    Terminates active Office processes prior to purging temporary cache files.
.OUTPUTS
    [PSCustomObject] containing Status, CleanedFilesCount, and BytesFreed.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$IncludeDocumentCache = $true,

        [Parameter(Mandatory = $false)]
        [bool]$IncludeWefCache = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Office Temporary Cache", "Purge Office document and Web Add-in cache")) {
            return [PSCustomObject]@{
                Status            = 'Simulated'
                CleanedFilesCount = 0
                BytesFreed        = [int64]0
            }
        }

        # Pre-execution process guard
        $targetProcs = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK')
        $activeProcs = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $targetProcs) {
            $running = @(Get-Process -Name $p -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                $activeProcs.Add($p)
            }
        }

        if ($activeProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active Office processes ($($activeProcs -join ', ')) prior to cache cleanup..." -Level 'WARN' -Component 'Clear-OfficeTempCache'
                }
                if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-OfficeProcess -ProcessNames @($activeProcs) -Force:$true -TimeoutSeconds 5
                } else {
                    foreach ($procName in $activeProcs) {
                        Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
                    }
                }
            } else {
                $warnMsg = "Active Office process(es) detected: $($activeProcs -join ', '). Close running Office applications or specify -Force to terminate."
                Write-Warning $warnMsg
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Clear-OfficeTempCache'
                }
                return [PSCustomObject]@{
                    Status            = 'Warning'
                    CleanedFilesCount = 0
                    BytesFreed        = [int64]0
                    ErrorMessage      = "Active Office process(es) detected: $($activeProcs -join ', '). Mutating cache while running causes lock conflicts or file deletion errors."
                }
            }
        }

        $cleanedCount = 0
        $bytesFreed = [int64]0

        $localAppData = $null
        if ($null -ne $env:LOCALAPPDATA -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $localAppData = $env:LOCALAPPDATA
        }
        elseif ($null -ne $env:USERPROFILE -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
        }
        else {
            $localAppData = [System.IO.Path]::GetTempPath()
        }

        $targets = [System.Collections.Generic.List[string]]::new()
        if ($IncludeDocumentCache) {
            $targets.Add((Join-Path (Join-Path (Join-Path $localAppData 'Microsoft') 'Office') '16.0\OfficeFileCache'))
        }
        if ($IncludeWefCache) {
            $targets.Add((Join-Path (Join-Path (Join-Path $localAppData 'Microsoft') 'Office') '16.0\Wef'))
        }

        foreach ($target in $targets) {
            try {
                $items = @(Get-ChildItem -Path $target -Recurse -ErrorAction SilentlyContinue)
                if ($null -ne $items -and $items.Count -gt 0) {
                    foreach ($item in $items) {
                        $itemPath = if ($item.PSObject.Properties['FullName'] -and -not [string]::IsNullOrWhiteSpace($item.FullName)) {
                            $item.FullName
                        }
                        elseif ($item.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($item.Name)) {
                            Join-Path -Path $target -ChildPath $item.Name
                        }
                        else {
                            Join-Path -Path $target -ChildPath 'cache_item.tmp'
                        }

                        try {
                            Remove-Item -Path $itemPath -Force -Recurse -ErrorAction Stop
                            $cleanedCount++
                            if ($item.PSObject.Properties['Length'] -and $null -ne $item.Length) {
                                $bytesFreed += [int64]$item.Length
                            }
                        }
                        catch {
                            Write-Verbose "Could not remove cache item '$itemPath': $($_.Exception.Message)"
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Scanning cache directory '$target' encountered error: $($_.Exception.Message)"
            }
        }

        $freedFormatted = if (Get-Command -Name 'Format-ByteSize' -ErrorAction SilentlyContinue) {
            Format-ByteSize -Bytes ([int64]$bytesFreed)
        } else {
            "$([math]::Round($bytesFreed / 1KB, 2)) KB"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Office cache cleanup completed: Cleaned $cleanedCount files, freed $freedFormatted." -Level 'INFO' -Component 'Clear-OfficeTempCache'
        }

        return [PSCustomObject]@{
            Status            = 'Success'
            CleanedFilesCount = $cleanedCount
            BytesFreed        = $bytesFreed
            FormattedSize     = $freedFormatted
        }
    }
}
