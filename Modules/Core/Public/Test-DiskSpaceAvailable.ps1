function Test-DiskSpaceAvailable {
<#
.SYNOPSIS
    Validates whether target drive volume has sufficient free disk space.
.DESCRIPTION
    Checks target drive or UNC network share for free space against RequiredBytes
    multiplied by SafetyMultiplier (default 1.2x headroom). Supports local drive letters,
    PSDrive mappings, network shares, and non-existent child directories.
.PARAMETER Path
    File or directory path to check. The volume hosting this path will be evaluated.
.PARAMETER RequiredBytes
    Required data size in bytes.
.PARAMETER SafetyMultiplier
    Safety margin factor. Default is 1.2 (20% headroom). Must be >= 1.0.
.PARAMETER PassThru
    Returns a detailed diagnostic object instead of a boolean.
.OUTPUTS
    [bool] True if available disk space meets or exceeds the required threshold; otherwise False.
.EXAMPLE
    Test-DiskSpaceAvailable -Path "D:\Backups\Outlook" -RequiredBytes 21474836480
.EXAMPLE
    Test-DiskSpaceAvailable -Path "\\server\share" -RequiredBytes 1073741824 -SafetyMultiplier 1.5 -PassThru
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateRange(0, [int64]::MaxValue)]
        [int64]$RequiredBytes,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1.0, 100.0)]
        [double]$SafetyMultiplier = 1.2,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    if ($RequiredBytes -le 0) {
        if ($PassThru) {
            return [PSCustomObject]@{
                Path             = $Path
                AvailableBytes   = [int64]::MaxValue
                RequiredBytes    = $RequiredBytes
                ThresholdBytes   = [int64]0
                SafetyMultiplier = $SafetyMultiplier
                Sufficient       = $true
            }
        }
        return $true
    }

    $thresholdBytes = [int64][Math]::Ceiling($RequiredBytes * $SafetyMultiplier)

    $resolvedPath = $Path
    try {
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        Write-Verbose "Could not resolve provider path for '$Path': $($_.Exception.Message)"
    }

    $availableBytes = [int64]-1

    # Strategy 1: Check PSDrive mappings (honors mock and mapped drives)
    try {
        $drives = @(Get-PSDrive -ErrorAction SilentlyContinue)
        if ($null -ne $drives -and $drives.Count -gt 0) {
            foreach ($d in $drives) {
                $matched = $false
                if ($d.PSObject.Properties['Root'] -and -not [string]::IsNullOrEmpty($d.Root)) {
                    if ($resolvedPath.StartsWith($d.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $matched = $true
                    }
                }
                if (-not $matched -and $d.PSObject.Properties['Name'] -and -not [string]::IsNullOrEmpty($d.Name)) {
                    if ($resolvedPath.StartsWith("$($d.Name):", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $matched = $true
                    }
                }

                if ($matched) {
                    if ($d.PSObject.Properties['FreeBytes'] -and $null -ne $d.FreeBytes) {
                        $availableBytes = [int64]$d.FreeBytes
                        break
                    }
                    elseif ($d.PSObject.Properties['Free'] -and $null -ne $d.Free) {
                        $availableBytes = [int64]$d.Free
                        break
                    }
                }
            }
        }
    } catch {
        Write-Verbose "PSDrive inspection failed: $($_.Exception.Message)"
    }

    # Strategy 2: Local Drive Letter (C:\, D:\) via System.IO.DriveInfo (quota-aware)
    if ($availableBytes -lt 0) {
        $pathRoot = [System.IO.Path]::GetPathRoot($resolvedPath)
        if ($pathRoot -match '^[a-zA-Z]:') {
            $driveLetter = $pathRoot.Substring(0, 1) + ":"
            try {
                $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $driveLetter
                $availableBytes = $drive.AvailableFreeSpace
            } catch {
                Write-Verbose "DriveInfo lookup failed for '$driveLetter': $($_.Exception.Message)"
            }
        }
    }

    # Strategy 3: P/Invoke Kernel32 GetDiskFreeSpaceEx for UNC paths on Windows NT
    if ($availableBytes -lt 0 -and [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            if (-not ([System.Management.Automation.PSTypeName]'IToolkit.NativeDiskHelper').Type) {
                Add-Type -TypeDefinition @"
                using System;
                using System.Runtime.InteropServices;
                namespace IToolkit {
                    public static class NativeDiskHelper {
                        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                        [return: MarshalAs(UnmanagedType.Bool)]
                        public static extern bool GetDiskFreeSpaceEx(
                            string lpDirectoryName,
                            out ulong lpFreeBytesAvailable,
                            out ulong lpTotalNumberOfBytes,
                            out ulong lpTotalNumberOfFreeBytes
                        );
                        public static long QueryFree(string path) {
                            ulong freeBytes = 0;
                            ulong totalBytes = 0;
                            ulong totalFree = 0;
                            if (GetDiskFreeSpaceEx(path, out freeBytes, out totalBytes, out totalFree)) {
                                return (long)freeBytes;
                            }
                            return -1;
                        }
                    }
                }
"@ -ErrorAction Stop
            }
            $queryDir = $resolvedPath
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                $queryDir = [System.IO.Path]::GetPathRoot($resolvedPath)
            }
            $nativeFree = [IToolkit.NativeDiskHelper]::QueryFree($queryDir)
            if ($nativeFree -ge 0) {
                $availableBytes = $nativeFree
            }
        } catch {
            Write-Verbose "Native GetDiskFreeSpaceEx lookup failed: $($_.Exception.Message)"
        }
    }

    # Strategy 4: Fallback for Unix/CI test environments
    if ($availableBytes -lt 0 -and [System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        try {
            $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList "/"
            $availableBytes = $drive.AvailableFreeSpace
        } catch {
            $availableBytes = [int64]::MaxValue
        }
    }

    if ($availableBytes -lt 0) {
        throw New-Object -TypeName System.IO.IOException -ArgumentList "Unable to determine available disk space for path: $Path"
    }

    $sufficient = ($availableBytes -ge $thresholdBytes)

    if ($PassThru) {
        return [PSCustomObject]@{
            Path             = $resolvedPath
            AvailableBytes   = $availableBytes
            RequiredBytes    = $RequiredBytes
            ThresholdBytes   = $thresholdBytes
            SafetyMultiplier = $SafetyMultiplier
            Sufficient       = $sufficient
        }
    }

    return [bool]$sufficient
}
