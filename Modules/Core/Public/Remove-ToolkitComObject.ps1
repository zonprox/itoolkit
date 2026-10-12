function Remove-ToolkitComObject {
<#
.SYNOPSIS
    Deterministically releases COM object references and triggers garbage collection.
.DESCRIPTION
    Safely iterates through an array of COM objects, verifies each is an active
    Runtime Callable Wrapper (RCW) via Marshal::IsComObject, and decrements or
    releases the unmanaged COM reference count. Suppresses release exceptions and
    triggers garbage collection and finalizer cycles to prevent zombie background processes.
.PARAMETER ComObject
    One or more COM object instances to release. Accepts pipeline input.
.PARAMETER SkipGarbageCollection
    Suppresses immediate [System.GC] collection cycles if performing batch operations.
.EXAMPLE
    Remove-ToolkitComObject -ComObject $outlookApp
.EXAMPLE
    Remove-ToolkitComObject -ComObject $rootFolder, $store, $stores, $ns, $comApp
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [Alias('ComObjects')]
        [object[]]$ComObject,

        [Parameter(Mandatory = $false)]
        [switch]$SkipGarbageCollection
    )

    process {
        if ($null -ne $ComObject) {
            foreach ($item in $ComObject) {
                if ($null -ne $item -and [System.Runtime.InteropServices.Marshal]::IsComObject($item)) {
                    try {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
                    }
                    catch {
                        # Suppress expected release exceptions (e.g. disconnected or already released RCW)
                    }
                }
            }
        }

        if (-not $SkipGarbageCollection) {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
        }
    }
}
