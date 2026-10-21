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
    Configures the data file as the default data file. Auto-bundles 100GB PST threshold expansion, folder hierarchy cloning, and rule migration unless explicitly disabled.
.PARAMETER CloneFolderHierarchy
    Switch to clone custom folder structures from the source store. Alias: PreserveHierarchy.
.PARAMETER MigrateRules
    Switch to migrate and remap Inbox rules from the source store. Alias: PreserveRules.
.PARAMETER SourceStorePath
    Optional explicit path to the source store. Defaults to the default delivery store.
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
        [Alias('PreserveHierarchy')]
        [switch]$CloneFolderHierarchy,

        [Parameter(Mandatory = $false)]
        [Alias('PreserveRules')]
        [switch]$MigrateRules,

        [Parameter(Mandatory = $false)]
        [string]$SourceStorePath,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # Determine whether to clone folders and migrate rules
        # When -SetAsDefault is passed, auto-enable unless explicitly set to false
        $shouldClone = if ($PSBoundParameters.ContainsKey('CloneFolderHierarchy')) {
            [bool]$CloneFolderHierarchy
        } elseif ($SetAsDefault) {
            $true
        } else {
            $false
        }

        $shouldMigrate = if ($PSBoundParameters.ContainsKey('MigrateRules')) {
            [bool]$MigrateRules
        } elseif ($SetAsDefault) {
            $true
        } else {
            $false
        }
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

        # 5b. Bundle Threshold Expansion for Default Store
        if ($SetAsDefault) {
            if (-not (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue)) {
                $setThresholdScript = Join-Path -Path $PSScriptRoot -ChildPath 'Set-OutlookPstThreshold.ps1'
                if (Test-Path -LiteralPath $setThresholdScript) { . $setThresholdScript }
            }
            if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                try {
                    $null = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Bundled PST threshold expansion to 100GB (Warn: 95GB) for default store." -Level 'INFO' -Component 'Outlook:NewPst'
                    }
                } catch {
                    Write-Verbose "Could not expand PST threshold: $($_.Exception.Message)"
                }
            }
        }

        # 6. Attempt COM Automation
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $store = $null
        $rootFolder = $null
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
                                $stores = $ns.Stores
                                if ($null -ne $stores) {
                                    foreach ($s in $stores) {
                                        if ($s.FilePath -eq $resolvedPath) {
                                            $store = $s
                                            $rootFolder = $store.GetRootFolder()
                                            if ($null -ne $rootFolder) {
                                                $rootFolder.Name = $DisplayName
                                            }
                                            break
                                        }
                                    }
                                }
                            }
                        } catch {
                            Write-Verbose "Could not set store display name: $($_.Exception.Message)"
                        }
                    }

                    # Clone folder hierarchy and migrate rules if requested
                    $folderMap = @{}
                    if ($shouldClone) {
                        try {
                            if (-not (Get-Command -Name 'Copy-OutlookFolderHierarchy' -ErrorAction SilentlyContinue)) {
                                $copyHierScript = Join-Path -Path $PSScriptRoot -ChildPath 'Copy-OutlookFolderHierarchy.ps1'
                                if (Test-Path -LiteralPath $copyHierScript) { . $copyHierScript }
                            }
                            if (Get-Command -Name 'Copy-OutlookFolderHierarchy' -ErrorAction SilentlyContinue) {
                                $hierParams = @{
                                    TargetStorePath = $resolvedPath
                                }
                                if (-not [string]::IsNullOrWhiteSpace($SourceStorePath)) {
                                    $hierParams['SourceStorePath'] = $SourceStorePath
                                }
                                if (-not [string]::IsNullOrWhiteSpace($targetProfile)) {
                                    $hierParams['ProfileName'] = $targetProfile
                                }
                                $hierRes = Copy-OutlookFolderHierarchy @hierParams
                                if ($null -ne $hierRes -and $null -ne $hierRes.FolderMap) {
                                    $folderMap = $hierRes.FolderMap
                                }
                            }
                        } catch {
                            Write-Verbose "Hierarchy cloning notice: $($_.Exception.Message)"
                        }
                    }

                    if ($shouldMigrate) {
                        try {
                            if (-not (Get-Command -Name 'Copy-OutlookRule' -ErrorAction SilentlyContinue)) {
                                $copyRuleScript = Join-Path -Path $PSScriptRoot -ChildPath 'Copy-OutlookRule.ps1'
                                if (Test-Path -LiteralPath $copyRuleScript) { . $copyRuleScript }
                            }
                            if (Get-Command -Name 'Copy-OutlookRule' -ErrorAction SilentlyContinue) {
                                $ruleParams = @{
                                    TargetStorePath = $resolvedPath
                                    FolderMap       = $folderMap
                                }
                                if (-not [string]::IsNullOrWhiteSpace($SourceStorePath)) {
                                    $ruleParams['SourceStorePath'] = $SourceStorePath
                                }
                                if (-not [string]::IsNullOrWhiteSpace($targetProfile)) {
                                    $ruleParams['ProfileName'] = $targetProfile
                                }
                                $null = Copy-OutlookRule @ruleParams
                            }
                        } catch {
                            Write-Verbose "Rule migration notice: $($_.Exception.Message)"
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
            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try {
                    $comApp.Quit()
                } catch { $null = $_ }
            }

            $objectsToRelease = @($rootFolder, $store, $stores, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $objectsToRelease
            }
            else {
                foreach ($obj in $objectsToRelease) {
                    if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                        try {
                            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
                        } catch { $null = $_ }
                    }
                }
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
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
