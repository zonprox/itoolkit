function Invoke-OutlookCompaction {
<#
.SYNOPSIS
    Launches Outlook profile manager or guidance for PST compaction.
.DESCRIPTION
    Resolves Outlook executable path reliably across Office 16.0, 15.0, C2R, and MSI,
    launches profile management UI (/manageprofiles), and displays clear step-by-step
    guidance for data file compaction.
.PARAMETER FilePath
    Optional path to the specific PST/OST file to compact.
.OUTPUTS
    None.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$FilePath
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
                Write-ToolkitLog -Message "Preparing compaction for data file: '$FilePath'..." -Level 'INFO' -Component 'Outlook:Compaction'
            }
            Write-ToolkitLog -Message "Launching Outlook profile management dialog for compaction..." -Level 'INFO' -Component 'Outlook:Compaction'
        }

        # Locate OUTLOOK.EXE reliably across modern and legacy installations
        $outlookExe = 'outlook.exe'
        $appPathKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
            'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\InstallRoot',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Outlook\InstallRoot',
            'HKLM:\SOFTWARE\Microsoft\Office\15.0\Outlook\InstallRoot',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\15.0\Outlook\InstallRoot'
        )
        foreach ($k in $appPathKeys) {
            if (Test-Path -LiteralPath $k) {
                $prop = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
                if ($null -ne $prop) {
                    $candidate = $null
                    if ($prop.PSObject.Properties['(default)']) { $candidate = [string]$prop.'(default)' }
                    elseif ($prop.PSObject.Properties['Path']) { $candidate = Join-Path -Path ([string]$prop.Path) -ChildPath 'OUTLOOK.EXE' }

                    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                        $outlookExe = $candidate
                        break
                    }
                }
            }
        }

        if ($outlookExe -eq 'outlook.exe') {
            $commonPaths = @(
                'C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE',
                'C:\Program Files (x86)\Microsoft Office\root\Office16\OUTLOOK.EXE',
                'C:\Program Files\Microsoft Office\Office16\OUTLOOK.EXE',
                'C:\Program Files (x86)\Microsoft Office\Office16\OUTLOOK.EXE',
                'C:\Program Files\Microsoft Office\root\Office15\OUTLOOK.EXE',
                'C:\Program Files (x86)\Microsoft Office\root\Office15\OUTLOOK.EXE',
                'C:\Program Files\Microsoft Office\Office15\OUTLOOK.EXE',
                'C:\Program Files (x86)\Microsoft Office\Office15\OUTLOOK.EXE'
            )
            foreach ($cp in $commonPaths) {
                if (Test-Path -LiteralPath $cp) {
                    $outlookExe = $cp
                    break
                }
            }
        }

        $launched = $false
        try {
            $proc = Start-Process -FilePath $outlookExe -ArgumentList '/manageprofiles' -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                $launched = $true
            }
        }
        catch {
            Write-Verbose "Could not launch $outlookExe /manageprofiles: $($_.Exception.Message)"
        }

        # Fallback to control.exe mlcfg32.cpl if outlook.exe could not launch
        if (-not $launched) {
            try {
                $null = Start-Process -FilePath 'control.exe' -ArgumentList 'mlcfg32.cpl' -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "Could not launch mlcfg32.cpl: $($_.Exception.Message)"
            }
        }

        # Detailed step-by-step guidance
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
                $targetName = Split-Path -Path $FilePath -Leaf
                if ([string]::IsNullOrWhiteSpace($targetName) -or $targetName -match '[\\/]') {
                    $targetName = ($FilePath -split '[\\/]')[-1]
                }
                Write-ToolkitLog -Message "To compact '$targetName': 1. Click 'Data Files' -> 2. Select '$targetName' -> 3. Click 'Settings' -> 4. Click 'Compact Now'." -Level 'INFO' -Component 'Outlook:Compaction'
            }
            else {
                Write-ToolkitLog -Message "To compact data files: 1. Click 'Data Files' -> 2. Select file -> 3. Click 'Settings' -> 4. Click 'Compact Now'." -Level 'INFO' -Component 'Outlook:Compaction'
            }
        }
    }
}
