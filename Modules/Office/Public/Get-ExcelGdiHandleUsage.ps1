function Get-ExcelGdiHandleUsage {
<#
.SYNOPSIS
    Monitors running Excel processes and checks GDI handle consumption.
.DESCRIPTION
    Enumerates EXCEL processes and detects potential GDI/USER object handle leaks
    approaching the Windows process limit (10,000 handles) using Win32 GetGuiResources.
    Flags processes exceeding WarningThreshold with IsLeaking = $true.
    Includes safe fallback for Linux and mock-based test environments.
.PARAMETER WarningThreshold
    Threshold handle count above which an Excel process is marked as leaking. Default is 5000.
.OUTPUTS
    [PSCustomObject[]] containing PID, ProcessName, GdiHandles, UserHandles, MemoryMB, IsLeaking.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$WarningThreshold = 5000
    )

    process {
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Check platform for native Win32 P/Invoke capability
        $isWin32Platform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

        if ($isWin32Platform) {
            try {
                if (-not ([System.Management.Automation.PSTypeName]'IToolkit.NativeGuiHelper').Type) {
                    Add-Type -TypeDefinition @"
                    using System;
                    using System.Runtime.InteropServices;

                    namespace IToolkit {
                        public static class NativeGuiHelper {
                            [DllImport("user32.dll", SetLastError = true)]
                            public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);

                            public static int GetGdiHandles(IntPtr hProcess) {
                                return (int)GetGuiResources(hProcess, 0);
                            }

                            public static int GetUserHandles(IntPtr hProcess) {
                                return (int)GetGuiResources(hProcess, 1);
                            }
                        }
                    }
"@ -ErrorAction Stop
                }
            }
            catch {
                Write-Verbose "Could not compile Win32 NativeGuiHelper: $($_.Exception.Message)"
            }
        }

        try {
            $excelProcs = @(Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue)
            if ($null -ne $excelProcs -and $excelProcs.Count -gt 0) {
                foreach ($proc in $excelProcs) {
                    $pidVal = 0
                    if ($proc.PSObject.Properties['Id'] -and $null -ne $proc.Id) {
                        $pidVal = [int]$proc.Id
                    }

                    $nameVal = 'EXCEL'
                    if ($proc.PSObject.Properties['ProcessName'] -and $null -ne $proc.ProcessName) {
                        $nameVal = [string]$proc.ProcessName
                    }

                    $gdiHandles = 0
                    $userHandles = 0
                    $queriedWin32 = $false

                    # Authentic Win32 GetGuiResources lookup
                    if ($isWin32Platform -and ([System.Management.Automation.PSTypeName]'IToolkit.NativeGuiHelper').Type) {
                        try {
                            if ($proc.PSObject.Properties['Handle'] -and $null -ne $proc.Handle -and $proc.Handle -ne [IntPtr]::Zero) {
                                $nativeGdi = [IToolkit.NativeGuiHelper]::GetGdiHandles($proc.Handle)
                                $nativeUser = [IToolkit.NativeGuiHelper]::GetUserHandles($proc.Handle)
                                if ($nativeGdi -ge 0) {
                                    $gdiHandles = $nativeGdi
                                    $userHandles = if ($nativeUser -ge 0) { $nativeUser } else { 0 }
                                    $queriedWin32 = $true
                                }
                            }
                        }
                        catch {
                            Write-Verbose "Win32 GetGuiResources query failed on PID ${pidVal}: $($_.Exception.Message)"
                        }
                    }

                    # Safe fallback for Linux, mocked test objects, or unprivileged processes
                    if (-not $queriedWin32) {
                        if ($proc.PSObject.Properties['GdiHandles'] -and $null -ne $proc.GdiHandles) {
                            $gdiHandles = [int]$proc.GdiHandles
                        }
                        elseif ($proc.PSObject.Properties['HandleCount'] -and $null -ne $proc.HandleCount) {
                            $gdiHandles = [int]$proc.HandleCount
                        }

                        if ($proc.PSObject.Properties['UserHandles'] -and $null -ne $proc.UserHandles) {
                            $userHandles = [int]$proc.UserHandles
                        }
                    }

                    # Calculate memory MB
                    $memMb = 0.0
                    if ($proc.PSObject.Properties['WorkingSet64'] -and $null -ne $proc.WorkingSet64) {
                        $memMb = [Math]::Round([double]$proc.WorkingSet64 / 1048576.0, 2)
                    }

                    $isLeaking = ($gdiHandles -ge $WarningThreshold)

                    $results.Add([PSCustomObject]@{
                        PID         = $pidVal
                        ProcessName = $nameVal
                        GdiHandles  = $gdiHandles
                        UserHandles = $userHandles
                        MemoryMB    = $memMb
                        IsLeaking   = $isLeaking
                    })
                }
            }
        }
        catch {
            Write-Verbose "Failed to query Excel process handles: $($_.Exception.Message)"
        }

        return @($results)
    }
}
