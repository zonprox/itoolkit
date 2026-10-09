<#
.SYNOPSIS
    Main interactive entry point and launcher for IToolkit with automatic UAC self-elevation.
.DESCRIPTION
    Launches the IToolkit administration suite. Checks for elevated Administrator privileges
    using Test-IsAdmin (or WindowsPrincipal security token inspection), automatically requests
    UAC elevation via Start-Process with -Verb RunAs if unelevated, imports the root IToolkit
    module, and invokes Start-IToolkitMenu.
    
    Compatible with Windows PowerShell 5.1 (.NET Framework 4.8) and PowerShell 7+ Core.
.PARAMETER SkipElevation
    Bypasses administrative privilege detection and self-elevation relaunch.
    Recommended for automated test suites, CI environments, or non-elevated diagnostics.
.PARAMETER NonInteractive
    Runs in headless / non-interactive mode, suppressing the interactive keyboard TUI menu.
.PARAMETER MenuOption
    Directly selects and executes a specific menu option or command (e.g. '1', '2', 'Q')
    without requiring interactive menu navigation.
.PARAMETER LogDirectory
    Custom directory path for session execution logs. Defaults to the Logs/ folder in project root.
.PARAMETER Force
    Forces execution and bypasses non-critical safety confirmation gates.
.EXAMPLE
    .\Start-IToolkit.ps1
    Launches IToolkit interactively, automatically elevating via UAC if not already running as Administrator.
.EXAMPLE
    .\Start-IToolkit.ps1 -SkipElevation -NonInteractive -MenuOption "1"
    Runs menu option 1 in non-interactive mode without prompting for elevation.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipElevation,

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [switch]$ExitImmediately,

    [Parameter(Mandatory = $false)]
    [string]$MenuOption,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Determine project root directory
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) {
    if ($null -ne $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } elseif ($null -ne $MyInvocation.MyCommand.Definition) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    } else {
        $scriptDir = (Get-Location).ProviderPath
    }
}

# Helper: Detect administrative privileges
function Test-IsAdminLocal {
    # If Test-IsAdmin cmdlet is already available in session, use it
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        return [bool](Test-IsAdmin)
    }

    # If Core module public function exists on disk, dot-source it
    $coreAdminScript = Join-Path -Path $scriptDir -ChildPath 'Modules/Core/Public/Test-IsAdmin.ps1'
    if (Test-Path -LiteralPath $coreAdminScript) {
        try {
            . $coreAdminScript
            if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
                return [bool](Test-IsAdmin)
            }
        } catch {
            Write-Verbose "Failed to dot-source Test-IsAdmin: $($_.Exception.Message)"
        }
    }

    # Non-Windows environment fallback (e.g. Linux/macOS CI test runners)
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        try {
            $uid = & id -u 2>$null
            if ($uid -eq 0 -or $uid -eq '0') {
                return $true
            } else {
                return $false
            }
        } catch {
            Write-Verbose "Non-Windows UID check failed: $($_.Exception.Message)"
            return $false
        }
    }

    # Windows .NET WindowsPrincipal security token inspection for Administrator role
    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Verbose "Administrative role check failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }
}

# 1. Check elevation status
$isAdmin = Test-IsAdminLocal

# 2. Perform automatic UAC self-elevation if not elevated
if ((-not $SkipElevation) -and (-not $isAdmin)) {
    $isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if ($isWin) {
        Write-Host '[IToolkit] Administrative privileges required. Re-launching with elevation...' -ForegroundColor Yellow

        # Determine PowerShell host executable
        $psExe = 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $psExe = 'pwsh.exe'
        }
        if (-not (Get-Command -Name $psExe -ErrorAction SilentlyContinue)) {
            $psExe = 'powershell.exe'
        }

        # Resolve script path
        $targetScript = $PSCommandPath
        if ([string]::IsNullOrEmpty($targetScript)) {
            $targetScript = Join-Path -Path $scriptDir -ChildPath 'Start-IToolkit.ps1'
        }

        # Assemble argument tokens preserving CLI parameters
        $argTokens = [System.Collections.Generic.List[string]]::new()
        $argTokens.Add('-NoProfile')
        $argTokens.Add('-ExecutionPolicy')
        $argTokens.Add('Bypass')
        $argTokens.Add('-File')
        $argTokens.Add("`"$targetScript`"")

        if ($ExitImmediately) {
            $argTokens.Add('-ExitImmediately')
        }
        if ($NonInteractive) {
            $argTokens.Add('-NonInteractive')
        }
        if (-not [string]::IsNullOrEmpty($MenuOption)) {
            $argTokens.Add('-MenuOption')
            $argTokens.Add("`"$MenuOption`"")
        }
        if (-not [string]::IsNullOrEmpty($LogDirectory)) {
            $argTokens.Add('-LogDirectory')
            $argTokens.Add("`"$LogDirectory`"")
        }
        if ($Force) {
            $argTokens.Add('-Force')
        }
        if ($VerbosePreference -eq 'Continue') {
            $argTokens.Add('-Verbose')
        }

        $argString = $argTokens -join ' '

        try {
            Write-Verbose "Launching elevated process: $psExe $argString"
            Start-Process -FilePath $psExe -ArgumentList $argString -Verb RunAs
            exit 0
        } catch {
            Write-Warning "UAC elevation prompt was cancelled or failed: $($_.Exception.Message)"
            exit 1
        }
    } else {
        Write-Warning 'Elevation via RunAs is supported on Windows NT only. Continuing in current context.'
    }
}

# 3. Import root module and submodules
$rootManifest = Join-Path -Path $scriptDir -ChildPath 'IToolkit.psd1'
if (Test-Path -LiteralPath $rootManifest) {
    try {
        Write-Verbose "Importing IToolkit root module: $rootManifest"
        Import-Module -Name $rootManifest -DisableNameChecking -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed importing IToolkit root module: $($_.Exception.Message)"
    }
} else {
    Write-Warning "IToolkit root manifest not found at: $rootManifest"
}

# Ensure WindowsRepair module is imported if not loaded via root manifest
$windowsRepairManifest = Join-Path -Path $scriptDir -ChildPath 'Modules/WindowsRepair/WindowsRepair.psd1'
if (Test-Path -LiteralPath $windowsRepairManifest) {
    if (-not (Get-Module -Name 'WindowsRepair' -ErrorAction SilentlyContinue)) {
        try {
            Write-Verbose "Importing WindowsRepair module: $windowsRepairManifest"
            Import-Module -Name $windowsRepairManifest -DisableNameChecking -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Failed importing WindowsRepair module directly: $($_.Exception.Message)"
        }
    }
}

# Ensure AppInstaller module is imported if not loaded via root manifest
$appInstallerManifest = Join-Path -Path $scriptDir -ChildPath 'Modules/AppInstaller/AppInstaller.psd1'
if (Test-Path -LiteralPath $appInstallerManifest) {
    if (-not (Get-Module -Name 'AppInstaller' -ErrorAction SilentlyContinue)) {
        try {
            Write-Verbose "Importing AppInstaller module: $appInstallerManifest"
            Import-Module -Name $appInstallerManifest -DisableNameChecking -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Failed importing AppInstaller module directly: $($_.Exception.Message)"
        }
    }
}

# Ensure WindowsCleanup module is imported if not loaded via root manifest
$windowsCleanupManifest = Join-Path -Path $scriptDir -ChildPath 'Modules/WindowsCleanup/WindowsCleanup.psd1'
if (Test-Path -LiteralPath $windowsCleanupManifest) {
    if (-not (Get-Module -Name 'WindowsCleanup' -ErrorAction SilentlyContinue)) {
        try {
            Write-Verbose "Importing WindowsCleanup module: $windowsCleanupManifest"
            Import-Module -Name $windowsCleanupManifest -DisableNameChecking -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Failed importing WindowsCleanup module directly: $($_.Exception.Message)"
        }
    }
}

# 4. Handle non-interactive execution or immediate exit
if ($ExitImmediately) {
    if (Get-Command -Name 'Start-IToolkitMenu' -ErrorAction SilentlyContinue) {
        $menuCmd = Get-Command -Name 'Start-IToolkitMenu'
        $menuParams = @{}
        if ($menuCmd.Parameters.ContainsKey('ExitImmediately')) {
            $menuParams['ExitImmediately'] = $true
        }
        if (-not [string]::IsNullOrEmpty($MenuOption)) {
            if ($menuCmd.Parameters.ContainsKey('MenuOption')) {
                $menuParams['MenuOption'] = $MenuOption
            } elseif ($menuCmd.Parameters.ContainsKey('Option')) {
                $menuParams['Option'] = $MenuOption
            }
        }
        if ($NonInteractive -and $menuCmd.Parameters.ContainsKey('NonInteractive')) {
            $menuParams['NonInteractive'] = $true
        }
        Start-IToolkitMenu @menuParams
    }
    exit 0
}

if ($NonInteractive) {
    Write-Host '[IToolkit] Initialized in non-interactive mode.' -ForegroundColor Green
    if (Get-Command -Name 'Start-IToolkitMenu' -ErrorAction SilentlyContinue) {
        $menuCmd = Get-Command -Name 'Start-IToolkitMenu'
        $menuParams = @{}
        if (-not [string]::IsNullOrEmpty($MenuOption)) {
            Write-Host "[IToolkit] Executing option: $MenuOption" -ForegroundColor Cyan
            if ($menuCmd.Parameters.ContainsKey('MenuOption')) {
                $menuParams['MenuOption'] = $MenuOption
            } elseif ($menuCmd.Parameters.ContainsKey('Option')) {
                $menuParams['Option'] = $MenuOption
            }
        }
        if ($menuCmd.Parameters.ContainsKey('NonInteractive')) {
            $menuParams['NonInteractive'] = $true
        }
        Start-IToolkitMenu @menuParams
    }
    exit 0
}

# 5. Launch interactive TUI menu
if (Get-Command -Name 'Start-IToolkitMenu' -ErrorAction SilentlyContinue) {
    $menuCmd = Get-Command -Name 'Start-IToolkitMenu'
    $menuParams = @{}
    if ($ExitImmediately -and $menuCmd.Parameters.ContainsKey('ExitImmediately')) {
        $menuParams['ExitImmediately'] = $true
    }
    if (-not [string]::IsNullOrEmpty($MenuOption)) {
        if ($menuCmd.Parameters.ContainsKey('MenuOption')) {
            $menuParams['MenuOption'] = $MenuOption
        } elseif ($menuCmd.Parameters.ContainsKey('Option')) {
            $menuParams['Option'] = $MenuOption
        }
    }
    Start-IToolkitMenu @menuParams
} else {
    Write-Host '[IToolkit] Core modules loaded successfully.' -ForegroundColor Green
    Write-Host '[IToolkit] Ready for administration commands.' -ForegroundColor Cyan
}
