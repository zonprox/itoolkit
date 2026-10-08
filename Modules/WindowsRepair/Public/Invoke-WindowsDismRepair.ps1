function Invoke-WindowsDismRepair {
<#
.SYNOPSIS
    Performs Windows Deployment Image Servicing and Management (DISM) repair operations.
.DESCRIPTION
    Runs DISM.exe /Online /Cleanup-Image with CheckHealth, ScanHealth, or RestoreHealth.
    Supports specifying alternate WIM/ESD source paths and limiting access to Windows Update.
.PARAMETER Mode
    The DISM repair operation mode. Valid options are CheckHealth, ScanHealth, and RestoreHealth.
    Defaults to RestoreHealth.
.PARAMETER SourcePath
    Optional path to known-good repair source files (e.g. WIM, ESD, or mounted ISO folder).
.PARAMETER LimitAccess
    Prevents DISM from contacting Windows Update for repair files when using SourcePath.
.OUTPUTS
    [PSCustomObject] containing Tool, Mode, ExitCode, Status, Output, and Success.
.EXAMPLE
    Invoke-WindowsDismRepair -Mode CheckHealth
.EXAMPLE
    Invoke-WindowsDismRepair -Mode RestoreHealth -SourcePath "D:\Sources\install.wim" -LimitAccess
.EXAMPLE
    Invoke-WindowsDismRepair -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('CheckHealth', 'ScanHealth', 'RestoreHealth')]
        [string]$Mode = 'RestoreHealth',

        [Parameter(Mandatory = $false)]
        [string]$SourcePath,

        [Parameter(Mandatory = $false)]
        [switch]$LimitAccess
    )

    process {
        # 1. Admin elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required for DISM repair ($Mode). Current session is not elevated."
        }

        # 2. Build argument list
        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.Add('/Online')
        $argList.Add('/Cleanup-Image')
        $argList.Add("/$Mode")

        if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
            $argList.Add("/Source:$SourcePath")
        }
        if ($LimitAccess) {
            $argList.Add('/LimitAccess')
        }

        $argDisplay = $argList -join ' '

        # 3. Support ShouldProcess / WhatIf
        if (-not $PSCmdlet.ShouldProcess("Local Windows Image", "Execute DISM.exe $argDisplay")) {
            return [PSCustomObject]@{
                Tool     = 'DISM'
                Mode     = $Mode
                ExitCode = 0
                Status   = 'Simulated - WhatIf'
                Output   = @("WhatIf: Execution of DISM.exe $argDisplay was simulated.")
                Success  = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Executing DISM repair: DISM.exe $argDisplay" -Level 'INFO' -Component 'WindowsRepair:DISM'
        }

        # 4. Resolve executable path
        $dismExe = 'DISM.exe'
        if ($env:SystemRoot) {
            $candidate = Join-Path -Path $env:SystemRoot -ChildPath 'System32\DISM.exe'
            if (Test-Path -LiteralPath $candidate) {
                $dismExe = $candidate
            }
        }

        # 5. Execute and capture output
        $tempOut = [System.IO.Path]::GetTempFileName()
        $tempErr = [System.IO.Path]::GetTempFileName()
        $rawOutput = [System.Collections.Generic.List[string]]::new()
        $exitCode = 0

        try {
            $proc = Start-Process -FilePath $dismExe -ArgumentList $argList -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($null -ne $proc -and $null -ne $proc.ExitCode) {
                $exitCode = $proc.ExitCode
            }

            if (Test-Path -LiteralPath $tempOut) {
                $lines = Get-Content -LiteralPath $tempOut -ErrorAction SilentlyContinue
                if ($null -ne $lines) {
                    foreach ($l in $lines) {
                        $rawOutput.Add($l)
                        Write-Host $l
                    }
                }
            }

            if (Test-Path -LiteralPath $tempErr) {
                $errLines = Get-Content -LiteralPath $tempErr -ErrorAction SilentlyContinue
                if ($null -ne $errLines) {
                    foreach ($el in $errLines) {
                        $rawOutput.Add($el)
                        Write-Warning $el
                    }
                }
            }
        }
        catch {
            Write-Warning "DISM process execution notice: $($_.Exception.Message)"
            $exitCode = 1
            $rawOutput.Add("Error: $($_.Exception.Message)")
        }
        finally {
            Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
        }

        # 6. Evaluate exit code and status
        $status = ''
        $success = $false
        if ($exitCode -eq 0) {
            $status = 'Operation completed successfully'
            $success = $true
        }
        elseif ($exitCode -eq 3010) {
            $status = 'Operation completed successfully. A system restart is required.'
            $success = $true
        }
        else {
            $status = "DISM completed with exit code $exitCode"
            $success = $false
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $logLevel = if ($success) { 'INFO' } else { 'WARN' }
            Write-ToolkitLog -Message "DISM $Mode finished with exit code $exitCode ($status)" -Level $logLevel -Component 'WindowsRepair:DISM'
        }

        return [PSCustomObject]@{
            Tool     = 'DISM'
            Mode     = $Mode
            ExitCode = $exitCode
            Status   = $status
            Output   = @($rawOutput)
            Success  = $success
        }
    }
}
