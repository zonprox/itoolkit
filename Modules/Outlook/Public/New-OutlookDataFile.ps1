function New-OutlookDataFile {
<#
.SYNOPSIS
    Creates a new Outlook PST data file and attaches it to an Outlook profile.
.DESCRIPTION
    Creates a new Unicode PST data file at the specified location and registers it
    with the target or active Outlook profile. Uses Outlook COM automation when available,
    and gracefully falls back to guided profile manager (/manageprofiles or mlcfg32.cpl)
    if COM is restricted or inactive. Supports -SetAsDefault, -Force, and -WhatIf.
.PARAMETER Path
    Target path for the .pst data file.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active or default profile.
.PARAMETER DisplayName
    Optional friendly display name for the folder tree.
.PARAMETER SetAsDefault
    Configures the data file as the default data file.
.PARAMETER Force
    Allows attaching if the target file already exists.
.OUTPUTS
    [PSCustomObject]@{ Path, Profile, DisplayName, Created, Attached, IsDefault, Method, FallbackTriggered, Success, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [switch]$SetAsDefault,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Path & Extension Validation
        if ($Path -notmatch '(?i)\.pst$') {
            throw "The data file path must have a .pst extension: '$Path'"
        }

        $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
        if (-not ($resolvedPath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
            try {
                $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
            } catch { $null = $_ }
        }

        # 2. Resolve Target Profile
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            $targetProfile = 'Outlook'
        }

        # 3. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Create Outlook PST and attach to profile '$targetProfile'")) {
            return [PSCustomObject]@{
                Path              = $resolvedPath
                Profile           = $targetProfile
                DisplayName       = $DisplayName
                Created           = $false
                Attached          = $false
                IsDefault         = [bool]$SetAsDefault
                Method            = 'WhatIf'
                FallbackTriggered = $false
                Success           = $true
                ErrorMessage      = $null
            }
        }

        # 4. Check for Existing File & Lock Status
        $fileExists = Test-Path -LiteralPath $resolvedPath
        if ($fileExists -and -not $Force) {
            $msg = "Data file already exists at '$resolvedPath'. Use -Force to attach existing PST."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $msg -Level 'WARN' -Component 'Outlook:NewPst'
            }
            return [PSCustomObject]@{
                Path              = $resolvedPath
                Profile           = $targetProfile
                DisplayName       = $DisplayName
                Created           = $false
                Attached          = $false
                IsDefault         = $false
                Method            = 'None'
                FallbackTriggered = $false
                Success           = $false
                ErrorMessage      = $msg
            }
        }

        if ($fileExists -and (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue)) {
            $lockCheck = Test-OutlookDataFileLock -Path $resolvedPath
            if ($lockCheck.IsLocked) {
                $msg = "Target file is locked by an external process: $($lockCheck.ErrorMessage)"
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $msg -Level 'ERROR' -Component 'Outlook:NewPst'
                }
                return [PSCustomObject]@{
                    Path              = $resolvedPath
                    Profile           = $targetProfile
                    DisplayName       = $DisplayName
                    Created           = $false
                    Attached          = $false
                    IsDefault         = $false
                    Method            = 'None'
                    FallbackTriggered = $false
                    Success           = $false
                    ErrorMessage      = $msg
                }
            }
        }

        # 5. Ensure Parent Directory Exists
        $parentDir = Split-Path -Path $resolvedPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
            try {
                $null = New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop
            } catch {
                Write-Verbose "Could not create directory '$parentDir': $($_.Exception.Message)"
            }
        }

        # 6. Attempt COM Automation
        $comApp = $null
        $comSuccess = $false
        $comError = $null

        try {
            if (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue) {
                $comApp = Get-OutlookComApplication
            }
            else {
                $outlookMod = Get-Module -Name 'Outlook'
                if ($null -ne $outlookMod) {
                    $comApp = & $outlookMod { Get-OutlookComApplication }
                }
                else {
                    $privCom = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/Get-OutlookComApplication.ps1'
                    if (Test-Path -LiteralPath $privCom) {
                        . $privCom
                        $comApp = Get-OutlookComApplication
                    }
                }
            }

            if ($null -ne $comApp) {
                $ns = $comApp.GetNamespace('MAPI')
                if ($null -ne $ns) {
                    # AddStoreEx: 1 = olStoreUnicode
                    $null = $ns.AddStoreEx($resolvedPath, 1)
                    $comSuccess = $true
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Successfully created and attached PST via COM: '$resolvedPath'" -Level 'SUCCESS' -Component 'Outlook:NewPst'
                    }

                    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
                        try {
                            if ($ns.PSObject.Properties['Stores']) {
                                foreach ($store in $ns.Stores) {
                                    if ($store.FilePath -eq $resolvedPath) {
                                        $rootFolder = $store.GetRootFolder()
                                        if ($null -ne $rootFolder) {
                                            $rootFolder.Name = $DisplayName
                                        }
                                        break
                                    }
                                }
                            }
                        } catch {
                            Write-Verbose "Could not set store display name: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        catch {
            $comError = $_.Exception.Message
            Write-Verbose "COM store addition failed: $comError"
        }
        finally {
            if ($null -ne $comApp -and [System.Runtime.InteropServices.Marshal]::IsComObject($comApp)) {
                try {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($comApp) | Out-Null
                } catch { $null = $_ }
            }
        }

        # 7. Guided Fallback If COM Unavailable / Inactive
        $fallbackTriggered = $false
        if (-not $comSuccess) {
            $fallbackTriggered = $true
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Outlook COM automation unavailable. Launching guided profile manager for PST creation..." -Level 'INFO' -Component 'Outlook:NewPst'
            }

            # Locate Outlook executable
            $outlookExe = 'outlook.exe'
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $sys = Get-OutlookSystemContext
                    if ($null -ne $sys -and -not [string]::IsNullOrWhiteSpace($sys.OutlookPath)) {
                        $outlookExe = $sys.OutlookPath
                    }
                } catch { $null = $_ }
            }

            $launched = $false
            try {
                $p = Start-Process -FilePath $outlookExe -ArgumentList '/manageprofiles' -PassThru -ErrorAction SilentlyContinue
                if ($null -ne $p) { $launched = $true }
            } catch { $null = $_ }

            if (-not $launched) {
                try {
                    $p = Start-Process -FilePath 'control.exe' -ArgumentList 'mlcfg32.cpl' -PassThru -ErrorAction SilentlyContinue
                    if ($null -ne $p) { $launched = $true }
                } catch { $null = $_ }
            }

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "To add PST: 1. Click 'Data Files...' -> 2. Click 'Add...' -> 3. Specify '$resolvedPath' -> 4. Click 'OK'." -Level 'INFO' -Component 'Outlook:NewPst'
            }
        }

        # 8. Set as Default Data File (if requested)
        $isDefault = $false
        if ($SetAsDefault) {
            if (-not (Get-Command -Name 'Set-OutlookDefaultDataFile' -ErrorAction SilentlyContinue)) {
                $setDefScript = Join-Path -Path $PSScriptRoot -ChildPath 'Set-OutlookDefaultDataFile.ps1'
                if (Test-Path -LiteralPath $setDefScript) { . $setDefScript }
            }
            if (Get-Command -Name 'Set-OutlookDefaultDataFile' -ErrorAction SilentlyContinue) {
                $defResult = Set-OutlookDefaultDataFile -Path $resolvedPath -ProfileName $targetProfile
                if ($null -ne $defResult) {
                    $isDefault = [bool]$defResult.Success
                }
            }
        }

        $method = if ($comSuccess) { 'COM' } else { 'GuidedFallback' }
        $success = ($comSuccess -or $fallbackTriggered)

        return [PSCustomObject]@{
            Path              = $resolvedPath
            Profile           = $targetProfile
            DisplayName       = $DisplayName
            Created           = ($comSuccess -and (-not $fileExists))
            Attached          = $comSuccess
            IsDefault         = $isDefault
            Method            = $method
            FallbackTriggered = $fallbackTriggered
            Success           = $success
            ErrorMessage      = $comError
        }
    }
}
