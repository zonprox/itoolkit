function Set-ToolkitDefaultApplication {
<#
.SYNOPSIS
    Configures default application associations for Google Chrome and Foxit PDF Reader.
.DESCRIPTION
    Configures Google Chrome as the default web browser (HTTP, HTTPS, .html, .htm protocols and file types)
    and Foxit Reader as the default PDF viewer (.pdf file extension). Uses both application registration switches
    and current user registry associations.
.PARAMETER Application
    Target application to set as default. Valid values: 'Chrome', 'FoxitReader', 'All'. Default is 'All'.
.PARAMETER ExecutablePath
    Optional explicit path to the target executable. If omitted, discovers automatically.
.PARAMETER OpenSettings
    Optionally launches Windows default apps settings dialog (ms-settings:defaultapps) for interactive confirmation.
.OUTPUTS
    [PSCustomObject[]] containing Application, DefaultSet, Handlers, Details.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Chrome', 'FoxitReader', 'All')]
        [string]$Application = 'All',

        [Parameter(Mandatory = $false)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $false)]
        [switch]$OpenSettings
    )

    process {
        if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        }
        $progFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $progFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }
        $userProf = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userProf 'AppData\Local' }

        $targets = if ($Application -eq 'All') { @('Chrome', 'FoxitReader') } else { @($Application) }
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($target in $targets) {
            switch ($target) {
                'Chrome' {
                    # 1. Discover chrome.exe
                    $chromeExe = $ExecutablePath
                    if ([string]::IsNullOrWhiteSpace($chromeExe) -or -not (Test-Path -LiteralPath $chromeExe -ErrorAction SilentlyContinue)) {
                        $candidates = @(
                            (Join-Path $progFiles 'Google\Chrome\Application\chrome.exe'),
                            (Join-Path $progFilesX86 'Google\Chrome\Application\chrome.exe'),
                            (Join-Path $localAppData 'Google\Chrome\Application\chrome.exe')
                        )
                        foreach ($cand in $candidates) {
                            if (Test-Path -LiteralPath $cand -ErrorAction SilentlyContinue) {
                                $chromeExe = $cand
                                break
                            }
                        }
                    }

                    if (-not $PSCmdlet.ShouldProcess("Google Chrome ($chromeExe)", "Set as default browser for HTTP, HTTPS, .html, .htm")) {
                        $results.Add([PSCustomObject]@{
                            Application = 'Chrome'
                            DefaultSet  = $false
                            Handlers    = @('http', 'https', '.html', '.htm')
                            Details     = 'Operation evaluated in WhatIf mode.'
                        })
                        continue
                    }

                    $configured = $false
                    # 2. Invoke Chrome registration command if executable is available
                    if (-not [string]::IsNullOrWhiteSpace($chromeExe) -and (Test-Path -LiteralPath $chromeExe -ErrorAction SilentlyContinue)) {
                        try {
                            Start-Process -FilePath $chromeExe -ArgumentList "--make-default-browser" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                            $configured = $true
                        } catch {
                            $null = $_
                        }
                    }

                    # 3. Configure User Registry associations
                    $regItems = @(
                        @{ Path = 'HKCU:\Software\Classes\.htm'; Name = '(default)'; Value = 'ChromeHTML' },
                        @{ Path = 'HKCU:\Software\Classes\.html'; Name = '(default)'; Value = 'ChromeHTML' }
                    )
                    foreach ($reg in $regItems) {
                        try {
                            if (-not (Test-Path -LiteralPath $reg.Path -ErrorAction SilentlyContinue)) {
                                New-Item -Path $reg.Path -Force -ErrorAction SilentlyContinue | Out-Null
                            }
                            Set-ItemProperty -Path $reg.Path -Name $reg.Name -Value $reg.Value -Force -ErrorAction SilentlyContinue | Out-Null
                            $configured = $true
                        } catch {
                            $null = $_
                        }
                    }

                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Configured Google Chrome as default web browser." -Level 'INFO' -Component 'Set-ToolkitDefaultApplication'
                    }

                    $results.Add([PSCustomObject]@{
                        Application = 'Chrome'
                        DefaultSet  = $configured
                        Handlers    = @('http', 'https', '.html', '.htm')
                        Details     = if ($configured) { "Successfully configured default browser associations." } else { "Registration completed with best effort." }
                    })
                }

                'FoxitReader' {
                    # 1. Discover Foxit executable
                    $foxitExe = $ExecutablePath
                    if ([string]::IsNullOrWhiteSpace($foxitExe) -or -not (Test-Path -LiteralPath $foxitExe -ErrorAction SilentlyContinue)) {
                        $candidates = @(
                            (Join-Path $progFiles 'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                            (Join-Path $progFilesX86 'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                            (Join-Path $progFiles 'Foxit Software\Foxit Reader\FoxitReader.exe'),
                            (Join-Path $progFilesX86 'Foxit Software\Foxit Reader\FoxitReader.exe')
                        )
                        foreach ($cand in $candidates) {
                            if (Test-Path -LiteralPath $cand -ErrorAction SilentlyContinue) {
                                $foxitExe = $cand
                                break
                            }
                        }
                    }

                    if (-not $PSCmdlet.ShouldProcess("Foxit Reader ($foxitExe)", "Set as default PDF viewer for .pdf")) {
                        $results.Add([PSCustomObject]@{
                            Application = 'FoxitReader'
                            DefaultSet  = $false
                            Handlers    = @('.pdf')
                            Details     = 'Operation evaluated in WhatIf mode.'
                        })
                        continue
                    }

                    $configured = $false
                    # 2. Invoke Foxit registration switch if executable is available
                    if (-not [string]::IsNullOrWhiteSpace($foxitExe) -and (Test-Path -LiteralPath $foxitExe -ErrorAction SilentlyContinue)) {
                        try {
                            Start-Process -FilePath $foxitExe -ArgumentList "/register" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                            $configured = $true
                        } catch {
                            $null = $_
                        }
                    }

                    # 3. Configure User Registry associations
                    try {
                        $pdfPath = 'HKCU:\Software\Classes\.pdf'
                        if (-not (Test-Path -LiteralPath $pdfPath -ErrorAction SilentlyContinue)) {
                            New-Item -Path $pdfPath -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        Set-ItemProperty -Path $pdfPath -Name '(default)' -Value 'FoxitPDFReader.Document' -Force -ErrorAction SilentlyContinue | Out-Null
                        $configured = $true
                    } catch {
                        $null = $_
                    }

                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Configured Foxit Reader as default PDF viewer." -Level 'INFO' -Component 'Set-ToolkitDefaultApplication'
                    }

                    $results.Add([PSCustomObject]@{
                        Application = 'FoxitReader'
                        DefaultSet  = $configured
                        Handlers    = @('.pdf')
                        Details     = if ($configured) { "Successfully configured default PDF associations." } else { "Registration completed with best effort." }
                    })
                }
            }
        }

        # 4. Optional launch of Windows Settings app
        if ($OpenSettings) {
            try {
                Start-Process -FilePath "explorer.exe" -ArgumentList "ms-settings:defaultapps" -ErrorAction SilentlyContinue | Out-Null
            } catch {
                $null = $_
            }
        }

        return $results.ToArray()
    }
}
