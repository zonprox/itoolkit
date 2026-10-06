function Start-OfficeClickToRunRepair {
<#
.SYNOPSIS
    Invokes Microsoft Office Click-to-Run repair (Quick Repair or Online Repair).
.DESCRIPTION
    Launches OfficeClickToRun.exe with the specified repair scenario and display level.
    Detects Office bitness and culture configuration from the ClickToRun registry key.
.PARAMETER RepairType
    Type of repair to perform: 'Quick', 'Online', 'QuickRepair', or 'FullRepair'.
.PARAMETER DisplayMode
    User interface mode: 'Interactive' (GUI displayed) or 'Silent' (background). Default is 'Interactive'.
.OUTPUTS
    [PSCustomObject] containing RepairType, Launched, and ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Quick', 'Online', 'QuickRepair', 'FullRepair')]
        [string]$RepairType,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('Interactive', 'Silent')]
        [string]$DisplayMode = 'Interactive'
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Office ClickToRun", "Launch $RepairType repair")) {
            return [PSCustomObject]@{
                RepairType = $RepairType
                Launched   = $false
                ExitCode   = 0
            }
        }

        # Normalize repair type for ClickToRun CLI argument
        $c2rRepairType = 'FullRepair'
        if ($RepairType -match '(?i)Quick') {
            $c2rRepairType = 'QuickRepair'
        }

        $displayLevel = 'False'
        if ($DisplayMode -eq 'Interactive') {
            $displayLevel = 'True'
        }

        # Query C2R registry configuration if available
        $platform = 'x64'
        $culture = 'en-us'
        try {
            $c2rConfig = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($null -ne $c2rConfig) {
                if ($c2rConfig.Platform) {
                    $platform = $c2rConfig.Platform
                }
                if ($c2rConfig.ClientCulture) {
                    $culture = $c2rConfig.ClientCulture
                }
            }
        }
        catch {
            Write-Verbose "Could not query ClickToRun configuration: $($_.Exception.Message)"
        }

        # Locate OfficeClickToRun.exe
        $c2rPaths = @(
            'C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeClickToRun.exe',
            'C:\Program Files (x86)\Common Files\microsoft shared\ClickToRun\OfficeClickToRun.exe'
        )
        $c2rExe = 'OfficeClickToRun.exe'
        foreach ($p in $c2rPaths) {
            if (Test-Path -LiteralPath $p) {
                $c2rExe = $p
                break
            }
        }

        $argList = @(
            'scenario=Repair',
            "platform=$platform",
            "culture=$culture",
            "RepairType=$c2rRepairType",
            "DisplayLevel=$displayLevel",
            'forceappshutdown=True'
        )

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Launching Office ClickToRun repair ($RepairType, $DisplayMode)..." -Level 'INFO' -Component 'Start-OfficeClickToRunRepair'
        }

        $launched = $false
        $exitCode = 0

        try {
            $proc = Start-Process -FilePath $c2rExe -ArgumentList $argList -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                $launched = $true
                if ($proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
                    $exitCode = $proc.ExitCode
                }
            }
            else {
                $launched = $true
            }
        }
        catch {
            Write-Verbose "Start-Process failed: $($_.Exception.Message)"
            $launched = $false
            $exitCode = 1
        }

        return [PSCustomObject]@{
            RepairType = $RepairType
            Launched   = $launched
            ExitCode   = $exitCode
        }
    }
}
