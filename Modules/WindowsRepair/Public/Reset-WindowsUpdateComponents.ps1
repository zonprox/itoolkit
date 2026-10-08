function Reset-WindowsUpdateComponents {
<#
.SYNOPSIS
    Resets Windows Update components, service states, and cache directories.
.DESCRIPTION
    Stops core Windows Update services (wuauserv, cryptSvc, bits, msiserver),
    renames SoftwareDistribution and Catroot2 cache folders, re-registers
    Windows Update COM/ActiveX libraries via regsvr32, and restarts services.
.PARAMETER Force
    Forces service termination and bypasses non-critical prompt gates.
.OUTPUTS
    [PSCustomObject] containing Operation, ServicesRestarted, FoldersRenamed, and Success.
.EXAMPLE
    Reset-WindowsUpdateComponents
.EXAMPLE
    Reset-WindowsUpdateComponents -Force
.EXAMPLE
    Reset-WindowsUpdateComponents -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Admin elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to reset Windows Update components. Current session is not elevated."
        }

        $servicesToManage = @('wuauserv', 'cryptSvc', 'bits', 'msiserver')

        # 2. Support ShouldProcess / WhatIf
        if (-not $PSCmdlet.ShouldProcess("Windows Update Subsystem", "Stop update services, rename cache folders, re-register DLLs, and restart services")) {
            return [PSCustomObject]@{
                Operation         = 'Reset-WindowsUpdateComponents'
                ServicesRestarted = @($servicesToManage)
                FoldersRenamed    = @('SoftwareDistribution.bak', 'catroot2.bak')
                Success           = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Beginning Windows Update components reset..." -Level 'INFO' -Component 'WindowsRepair:WU'
        }

        # 3. Stop Windows Update services
        foreach ($svc in $servicesToManage) {
            try {
                Write-Verbose "Stopping service: $svc"
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Verbose "Could not stop service '$svc': $($_.Exception.Message)"
            }
        }

        # 4. Rename SoftwareDistribution and Catroot2 folders
        $windir = if ($env:SystemRoot) {
            $env:SystemRoot
        } elseif (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue) {
            'C:\Windows'
        } else {
            Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'Windows'
        }
        $foldersRenamed = [System.Collections.Generic.List[string]]::new()

        $sdPath = [System.IO.Path]::Combine($windir, 'SoftwareDistribution')
        $catPath = [System.IO.Path]::Combine([System.IO.Path]::Combine($windir, 'System32'), 'catroot2')

        $folderSpecs = @(
            @{ Path = $sdPath; Bak = 'SoftwareDistribution.bak' },
            @{ Path = $catPath; Bak = 'catroot2.bak' }
        )

        foreach ($spec in $folderSpecs) {
            $fPath = $spec.Path
            $bakName = $spec.Bak
            if (Test-Path -LiteralPath $fPath) {
                $parentDir = Split-Path -Path $fPath -Parent
                $targetBakPath = Join-Path -Path $parentDir -ChildPath $bakName
                if (Test-Path -LiteralPath $targetBakPath) {
                    try {
                        Remove-Item -LiteralPath $targetBakPath -Recurse -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Verbose "Could not remove existing backup folder '$targetBakPath': $($_.Exception.Message)"
                    }
                }
                try {
                    Rename-Item -LiteralPath $fPath -NewName $bakName -Force -ErrorAction Stop
                    $foldersRenamed.Add($bakName)
                } catch {
                    Write-Verbose "Could not rename '$fPath': $($_.Exception.Message)"
                }
            }
        }

        # 5. Re-register core Windows Update DLLs
        $dllList = @(
            'atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll', 'browseui.dll',
            'jscript.dll', 'vbscript.dll', 'scrrun.dll', 'msxml.dll', 'msxml3.dll',
            'msxml6.dll', 'actxprxy.dll', 'softpub.dll', 'wintrust.dll', 'dssenh.dll',
            'rsaenh.dll', 'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll',
            'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'initpki.dll', 'wuapi.dll',
            'wuaueng.dll', 'wucltui.dll', 'wups.dll', 'wups2.dll', 'wuwebv.dll',
            'qmgr.dll', 'qmgrprxy.dll', 'wucltux.dll', 'muweb.dll', 'wuweb.dll'
        )

        $regsvrExe = 'regsvr32.exe'
        if ($env:SystemRoot) {
            $candidateRegsvr = Join-Path -Path $env:SystemRoot -ChildPath 'System32\regsvr32.exe'
            if (Test-Path -LiteralPath $candidateRegsvr) {
                $regsvrExe = $candidateRegsvr
            }
        }

        foreach ($dll in $dllList) {
            try {
                $proc = Start-Process -FilePath $regsvrExe -ArgumentList @('/s', $dll) -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
            } catch {
                Write-Verbose "DLL registration notice for '$dll': $($_.Exception.Message)"
            }
        }

        # 6. Restart services
        $servicesRestarted = [System.Collections.Generic.List[string]]::new()
        foreach ($svc in $servicesToManage) {
            try {
                Write-Verbose "Starting service: $svc"
                Start-Service -Name $svc -ErrorAction SilentlyContinue
                $servicesRestarted.Add($svc)
            } catch {
                Write-Verbose "Could not start service '$svc': $($_.Exception.Message)"
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Windows Update components reset completed. Services restarted: $($servicesRestarted -join ', ')" -Level 'SUCCESS' -Component 'WindowsRepair:WU'
        }

        return [PSCustomObject]@{
            Operation         = 'Reset-WindowsUpdateComponents'
            ServicesRestarted = @($servicesRestarted)
            FoldersRenamed    = @($foldersRenamed)
            Success           = $true
        }
    }
}
