<#
.SYNOPSIS
    Root module loader for IToolkit.
.DESCRIPTION
    Initializes session environment, auto-discovers and imports all nested modules
    located under the Modules/ subdirectory, and exposes public toolkit commands.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+ Core.
#>
[CmdletBinding()]
param()

# Strict error handling within module initialization
$ErrorActionPreference = 'Stop'

# Module session state
$script:IToolkitRoot         = $PSScriptRoot
$script:LoadedSubModules     = @()
$script:IToolkitVersion      = '1.0.0'
$script:IToolkitDryRun       = $false

Write-Verbose "Initializing IToolkit v$script:IToolkitVersion from: $script:IToolkitRoot"

# Auto-discover and import nested modules under Modules/
$modulesFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Modules'

if (Test-Path -LiteralPath $modulesFolder) {
    # Scan immediate child directories for module manifests
    $subDirs = Get-ChildItem -LiteralPath $modulesFolder -Directory -ErrorAction SilentlyContinue

    if ($null -ne $subDirs) {
        foreach ($dir in $subDirs) {
            $manifestPath = Join-Path -Path $dir.FullName -ChildPath "$($dir.Name).psd1"

            if (Test-Path -LiteralPath $manifestPath) {
                $moduleName = $dir.Name
                
                # Check if module is already imported into the session
                $existing = Get-Module -Name $moduleName -ErrorAction SilentlyContinue
                if ($null -eq $existing) {
                    try {
                        Write-Verbose "Importing nested module: $moduleName ($manifestPath)"
                        # Note: Use -Global switch for universal PS 5.1 & PS 7+ compatibility
                        Import-Module -Name $manifestPath -Global -DisableNameChecking -ErrorAction Stop
                        $script:LoadedSubModules += $moduleName
                    }
                    catch {
                        Write-Warning "Failed to import nested module '$moduleName': $($_.Exception.Message)"
                    }
                }
                else {
                    $script:LoadedSubModules += $moduleName
                }
            }
        }
    }
}
else {
    Write-Warning "Modules directory not found at: $modulesFolder"
}

# Ensure WindowsCleanup nested module is imported via fallback if not already loaded
if (-not (Get-Module -Name 'WindowsCleanup' -ErrorAction SilentlyContinue)) {
    $windowsCleanupManifest = Join-Path -Path $modulesFolder -ChildPath 'WindowsCleanup/WindowsCleanup.psd1'
    if (Test-Path -LiteralPath $windowsCleanupManifest) {
        try {
            Write-Verbose "Importing nested module via fallback: WindowsCleanup ($windowsCleanupManifest)"
            Import-Module -Name $windowsCleanupManifest -Global -DisableNameChecking -ErrorAction Stop
            if (-not ($script:LoadedSubModules -contains 'WindowsCleanup')) {
                $script:LoadedSubModules += 'WindowsCleanup'
            }
        }
        catch {
            Write-Warning "Failed to import fallback module 'WindowsCleanup': $($_.Exception.Message)"
        }
    }
}

# Export functions defined in or imported through IToolkit
Export-ModuleMember -Function * -Variable @()
