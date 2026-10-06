function Register-PrintSpoolerComponents {
<#
.SYNOPSIS
    Re-registers core print subsystem DLLs, recompiles WMI MOF, and restores service dependency.
.DESCRIPTION
    Runs regsvr32 on printui.dll and prntvpt.dll, recompiles prnprov.mof via mofcomp.exe,
    and configures the Spooler service dependency to RPCSS via sc.exe.
.OUTPUTS
    [PSCustomObject] containing DllsRegistered, WmiRecompiled, DependencyRestored.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param()

    process {
        if (-not $PSCmdlet.ShouldProcess("Print Spooler Subsystem", "Re-register print DLLs, recompile WMI MOF, and restore RPCSS dependency")) {
            return [PSCustomObject]@{
                DllsRegistered     = $false
                WmiRecompiled      = $false
                DependencyRestored = $false
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Re-registering print spooler subsystem components..." -Level 'INFO' -Component 'Register-PrintSpoolerComponents'
        }

        $dllsSuccess = $false
        $wmiSuccess  = $false
        $depSuccess  = $false

        # 1. Register Print DLLs
        try {
            $regui = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$env:SystemRoot\System32\printui.dll`"" -Wait -PassThru -ErrorAction SilentlyContinue
            $regvpt = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$env:SystemRoot\System32\prntvpt.dll`"" -Wait -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $regui -and $regui.ExitCode -eq 0 -and $null -ne $regvpt -and $regvpt.ExitCode -eq 0) {
                $dllsSuccess = $true
            }
        } catch {
            Write-Verbose "Error registering print DLLs: $($_.Exception.Message)"
        }

        # 2. Recompile WMI print provider MOF
        try {
            $mofFile = "$env:SystemRoot\System32\wbem\prnprov.mof"
            $mofProc = Start-Process -FilePath "$env:SystemRoot\System32\wbem\mofcomp.exe" -ArgumentList "`"$mofFile`"" -Wait -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $mofProc -and $mofProc.ExitCode -eq 0) {
                $wmiSuccess = $true
            }
        } catch {
            Write-Verbose "Error compiling prnprov.mof: $($_.Exception.Message)"
        }

        # 3. Restore Spooler service dependency to RPCSS
        try {
            $scProc = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config spooler depend= RPCSS start= auto" -Wait -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $scProc -and $scProc.ExitCode -eq 0) {
                $depSuccess = $true
            }
        } catch {
            Write-Verbose "Error executing sc.exe: $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            DllsRegistered     = [bool]$dllsSuccess
            WmiRecompiled      = [bool]$wmiSuccess
            DependencyRestored = [bool]$depSuccess
        }
    }
}
