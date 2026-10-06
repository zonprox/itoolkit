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
.OUTPUTS
    [PSCustomObject] containing CleanedFilesCount and BytesFreed.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$IncludeDocumentCache = $true,

        [Parameter(Mandatory = $false)]
        [bool]$IncludeWefCache = $true
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Office Temporary Cache", "Purge Office document and Web Add-in cache")) {
            return [PSCustomObject]@{
                CleanedFilesCount = 0
                BytesFreed        = [int64]0
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

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Office cache cleanup completed: Cleaned $cleanedCount files, freed $bytesFreed bytes." -Level 'INFO' -Component 'Clear-OfficeTempCache'
        }

        return [PSCustomObject]@{
            CleanedFilesCount = $cleanedCount
            BytesFreed        = $bytesFreed
        }
    }
}
