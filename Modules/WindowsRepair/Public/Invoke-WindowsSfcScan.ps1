function Invoke-WindowsSfcScan {
<#
.SYNOPSIS
    Executes Windows System File Checker (SFC) integrity scan.
.DESCRIPTION
    Runs 'sfc /scannow' to verify and repair corrupted or missing system files.
    Streams progress output to the console, captures execution logs, evaluates
    exit codes, and reports structured diagnostic results.
.OUTPUTS
    [PSCustomObject] containing Tool, ExitCode, Status, Output, and Success.
.EXAMPLE
    Invoke-WindowsSfcScan
.EXAMPLE
    Invoke-WindowsSfcScan -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Admin elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required for System File Checker (sfc /scannow). Current session is not elevated."
        }

        # 2. Support ShouldProcess / WhatIf
        if (-not $PSCmdlet.ShouldProcess("Local System", "Invoke System File Checker scan (sfc /scannow)")) {
            return [PSCustomObject]@{
                Tool     = 'SFC'
                ExitCode = 0
                Status   = 'Simulated - WhatIf'
                Output   = @('WhatIf: Execution of sfc /scannow was simulated.')
                Success  = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Starting Windows System File Checker scan (sfc /scannow)..." -Level 'INFO' -Component 'WindowsRepair:SFC'
        }

        # 3. Resolve executable path
        $sfcExe = 'sfc.exe'
        if ($env:SystemRoot) {
            $candidate = Join-Path -Path $env:SystemRoot -ChildPath 'System32\sfc.exe'
            if (Test-Path -LiteralPath $candidate) {
                $sfcExe = $candidate
            }
        }

        # 4. Execute and capture output
        $tempOut = [System.IO.Path]::GetTempFileName()
        $tempErr = [System.IO.Path]::GetTempFileName()
        $rawOutput = [System.Collections.Generic.List[string]]::new()
        $exitCode = 0

        try {
            $proc = Start-Process -FilePath $sfcExe -ArgumentList @('/scannow') -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr -Wait -PassThru -NoNewWindow -ErrorAction Stop
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
            Write-Warning "SFC scan process execution notice: $($_.Exception.Message)"
            $exitCode = 1
            $rawOutput.Add("Error: $($_.Exception.Message)")
        }
        finally {
            Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
        }

        # 5. Evaluate exit code and status
        $status = ''
        $success = $false
        if ($exitCode -eq 0) {
            $status = 'No integrity violations found'
            $success = $true
        }
        elseif ($exitCode -eq 1) {
            $status = 'Verification failure or unable to repair'
            $success = $false
        }
        else {
            $status = "Integrity scan completed with exit code $exitCode"
            $success = $false
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $logLevel = if ($success) { 'INFO' } else { 'WARN' }
            Write-ToolkitLog -Message "SFC scan finished with exit code $exitCode ($status)" -Level $logLevel -Component 'WindowsRepair:SFC'
        }

        return [PSCustomObject]@{
            Tool     = 'SFC'
            ExitCode = $exitCode
            Status   = $status
            Output   = @($rawOutput)
            Success  = $success
        }
    }
}
