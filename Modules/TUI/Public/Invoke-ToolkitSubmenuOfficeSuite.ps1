<#
.SYNOPSIS
    Central Dispatcher Hub for Pillar 2: Office & Productivity Suite.
.DESCRIPTION
    Renders high-level administration categories and routes to dedicated submenus:
    [1] Office Suite & General Maintenance (Invoke-ToolkitSubmenuOfficeCommon)
    [2] Microsoft Word Repairs (Invoke-ToolkitSubmenuOfficeWord)
    [3] Microsoft Excel Repairs (Invoke-ToolkitSubmenuOfficeExcel)
    [4] Microsoft PowerPoint Repairs (Invoke-ToolkitSubmenuOfficePowerPoint)
    [5] Microsoft Outlook & Data Files (Invoke-ToolkitSubmenuOfficeOutlook)
    [0] Back to Main Menu
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (used for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Menu recursion depth. Default is 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$ExitImmediately,

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [int]$MenuDepth = 1
)

# 1. Dependency Resolution & Submenu Pre-Loading
if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path -LiteralPath $waitScript) { . $waitScript }
}
if (-not (Get-Command -Name 'Show-ToolkitHeader' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path -LiteralPath $headerScript) { . $headerScript }
}
if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
    $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
    if (Test-Path -LiteralPath $catScript) { . $catScript }
}
if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
    $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
    if (Test-Path -LiteralPath $tableScript) { . $tableScript }
}
if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
    $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
    if (Test-Path -LiteralPath $selectScript) { . $selectScript }
}
if (-not (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue)) {
    $statusScript = Join-Path $PSScriptRoot 'Write-ToolkitStatus.ps1'
    if (Test-Path -LiteralPath $statusScript) { . $statusScript }
}

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


# Pre-load dedicated submenus if not yet loaded in current session
$subCommon = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeCommon.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subCommon)) {
    . $subCommon
}
$subWord = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeWord.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subWord)) {
    . $subWord
}
$subExcel = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeExcel.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subExcel)) {
    . $subExcel
}
$subPowerPoint = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficePowerPoint.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subPowerPoint)) {
    . $subPowerPoint
}
$subOutlook = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeOutlook.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subOutlook)) {
    . $subOutlook
}

# 2. Context Information Helper: Get-OfficeSuiteContextInfoLines
function Get-OfficeSuiteContextInfoLines {
    <#
    .SYNOPSIS
        Gathers comprehensive live environment context for the Main Office Suite Hub.
    .DESCRIPTION
        Detects Office Suite edition (Click-to-Run and MSI), architecture, build/version,
        update channel, license type, installed applications (Word, Excel, PowerPoint, Outlook,
        OneNote, Access, Publisher, Visio, Project), running Office processes, and default
        Outlook mail profile.
    #>
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Inspect Click-to-Run Configuration
    $c2rProps = $null
    foreach ($regPath in @('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration')) {
        if (Test-Path -LiteralPath $regPath -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                $c2rProps = $props
                break
            }
        }
    }

    $productReleaseIds = if ($c2rProps -and $c2rProps.ProductReleaseIds) { [string]$c2rProps.ProductReleaseIds } else { '' }
    $versionToReport   = if ($c2rProps) {
        if ($c2rProps.VersionToReport) { [string]$c2rProps.VersionToReport }
        elseif ($c2rProps.ClientVersionToReport) { [string]$c2rProps.ClientVersionToReport }
        else { '' }
    } else { '' }
    $platform          = if ($c2rProps -and $c2rProps.Platform) { [string]$c2rProps.Platform } else { '' }
    $updateChannel     = if ($c2rProps -and $c2rProps.UpdateChannel) { [string]$c2rProps.UpdateChannel } else { '' }
    $cdnBaseUrl        = if ($c2rProps -and $c2rProps.CDNBaseUrl) { [string]$c2rProps.CDNBaseUrl } else { '' }
    $installationPath  = if ($c2rProps -and $c2rProps.InstallationPath) { [string]$c2rProps.InstallationPath } else { '' }

    # 2. Inspect Uninstall Registry Keys
    $uninstallSuiteName = $null
    $uninstallVersion   = $null
    foreach ($uPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path -LiteralPath $uPath -ErrorAction SilentlyContinue) {
            try {
                $subKeys = Get-ChildItem -LiteralPath $uPath -ErrorAction SilentlyContinue
                foreach ($sk in $subKeys) {
                    $item = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($item.DisplayName)) {
                        $dn = [string]$item.DisplayName
                        if ($dn -match '(?i)Microsoft\s+(?:Office|365)' -and $dn -notmatch '(?i)Tools|Proofing|LanguagePack|MUI|Companion|Online') {
                            $uninstallSuiteName = $dn
                            if (-not [string]::IsNullOrWhiteSpace($item.DisplayVersion)) {
                                $uninstallVersion = [string]$item.DisplayVersion
                            }
                            break
                        }
                    }
                }
            } catch { $null = $_ }
        }
        if ($uninstallSuiteName) { break }
    }

    # 3. Map ProductReleaseIds into Human-Readable Suite & Edition
    $mapReleaseId = {
        param([string]$id)
        $clean = $id.Trim()
        switch -Regex ($clean) {
            '^ProPlus2024Volume$'        { return 'Microsoft Office LTSC Professional Plus 2024 [LTSC Volume]' }
            '^ProPlus2024Retail$'        { return 'Microsoft Office Professional Plus 2024 [Retail]' }
            '^ProPlus2021Volume$'        { return 'Microsoft Office LTSC Professional Plus 2021 [LTSC Volume]' }
            '^ProPlus2021Retail$'        { return 'Microsoft Office Professional Plus 2021 [Retail]' }
            '^ProPlus2019Volume$'        { return 'Microsoft Office Professional Plus 2019 [Volume]' }
            '^ProPlus2019Retail$'        { return 'Microsoft Office Professional Plus 2019 [Retail]' }
            '^ProPlusRetail$'            { return 'Microsoft 365 Apps for enterprise (ProPlus) [Retail]' }
            '^O365ProPlusRetail$'        { return 'Microsoft 365 Apps for enterprise (ProPlus)' }
            '^O365BusinessRetail$'       { return 'Microsoft 365 Apps for business' }
            '^O365HomePremRetail$'       { return 'Microsoft 365 Family / Personal' }
            '^Standard2024Volume$'       { return 'Microsoft Office LTSC Standard 2024 [LTSC Volume]' }
            '^Standard2021Volume$'       { return 'Microsoft Office LTSC Standard 2021 [LTSC Volume]' }
            '^Standard2019Volume$'       { return 'Microsoft Office Standard 2019 [Volume]' }
            '^StandardRetail$'           { return 'Microsoft Office Standard [Retail]' }
            '^HomeBusiness2024Retail$'   { return 'Microsoft Office Home & Business 2024 [Retail]' }
            '^HomeBusiness2021Retail$'   { return 'Microsoft Office Home & Business 2021 [Retail]' }
            '^HomeBusiness2019Retail$'   { return 'Microsoft Office Home & Business 2019 [Retail]' }
            '^HomeBusinessRetail$'       { return 'Microsoft Office Home & Business [Retail]' }
            '^HomeStudent2021Retail$'    { return 'Microsoft Office Home & Student 2021 [Retail]' }
            '^HomeStudent2019Retail$'    { return 'Microsoft Office Home & Student 2019 [Retail]' }
            '^HomeStudentRetail$'        { return 'Microsoft Office Home & Student [Retail]' }
            '^VisioPro2024Volume$'       { return 'Microsoft Visio LTSC Professional 2024 [LTSC Volume]' }
            '^VisioPro2021Volume$'       { return 'Microsoft Visio LTSC Professional 2021 [LTSC Volume]' }
            '^VisioPro2019Volume$'       { return 'Microsoft Visio Professional 2019 [Volume]' }
            '^VisioProRetail$'           { return 'Microsoft Visio Plan 2 / Pro [Retail]' }
            '^VisioStd2024Volume$'       { return 'Microsoft Visio LTSC Standard 2024 [LTSC Volume]' }
            '^VisioStd2021Volume$'       { return 'Microsoft Visio LTSC Standard 2021 [LTSC Volume]' }
            '^VisioStd2019Volume$'       { return 'Microsoft Visio Standard 2019 [Volume]' }
            '^VisioStdRetail$'           { return 'Microsoft Visio Standard [Retail]' }
            '^ProjectPro2024Volume$'     { return 'Microsoft Project LTSC Professional 2024 [LTSC Volume]' }
            '^ProjectPro2021Volume$'     { return 'Microsoft Project LTSC Professional 2021 [LTSC Volume]' }
            '^ProjectPro2019Volume$'     { return 'Microsoft Project Professional 2019 [Volume]' }
            '^ProjectProRetail$'         { return 'Microsoft Project Plan 3 / Pro [Retail]' }
            '^ProjectStd2024Volume$'     { return 'Microsoft Project LTSC Standard 2024 [LTSC Volume]' }
            '^ProjectStd2021Volume$'     { return 'Microsoft Project LTSC Standard 2021 [LTSC Volume]' }
            '^ProjectStd2019Volume$'     { return 'Microsoft Project Standard 2019 [Volume]' }
            '^ProjectStdRetail$'         { return 'Microsoft Project Standard [Retail]' }
            default {
                $isVol = $clean -match '(?i)Volume'
                $isRetail = $clean -match '(?i)Retail'
                $lic = if ($isVol) { '[Volume]' } elseif ($isRetail) { '[Retail]' } else { '' }
                if ($clean -match '(?i)O365|365') { return "Microsoft 365 ($clean) $lic".Trim() }
                if ($clean -match '(?i)ProPlus') { return "Microsoft Office Professional Plus ($clean) $lic".Trim() }
                if ($clean -match '(?i)Standard') { return "Microsoft Office Standard ($clean) $lic".Trim() }
                return "Microsoft Office ($clean) $lic".Trim()
            }
        }
    }

    $suiteTitle = $null
    if (-not [string]::IsNullOrWhiteSpace($productReleaseIds)) {
        $mappedList = [System.Collections.Generic.List[string]]::new()
        foreach ($relId in $productReleaseIds.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $mapped = & $mapReleaseId $relId
            if (-not [string]::IsNullOrWhiteSpace($mapped)) {
                $mappedList.Add($mapped)
            }
        }
        if ($mappedList.Count -gt 0) {
            $suiteTitle = $mappedList -join ', '
        }
    }

    if (-not $suiteTitle -and -not [string]::IsNullOrWhiteSpace($uninstallSuiteName)) {
        $suiteTitle = $uninstallSuiteName
    }
    if (-not $suiteTitle) {
        $suiteTitle = if ($c2rProps) { 'Microsoft Office [Click-to-Run]' } else { 'Not Detected [STANDBY]' }
    }

    $lines.Add("Office Suite   : $suiteTitle")

    # 4. Determine Version, Architecture, Deployment, Update Channel & License
    $c2rVer = if (-not [string]::IsNullOrWhiteSpace($versionToReport)) {
        $versionToReport
    } elseif (-not [string]::IsNullOrWhiteSpace($uninstallVersion)) {
        $uninstallVersion
    } else {
        '16.0'
    }

    $c2rArch = if (-not [string]::IsNullOrWhiteSpace($platform)) {
        $platform.ToLowerInvariant()
    } else {
        'x64'
    }

    $deployType = if ($c2rProps) {
        'Click-to-Run'
    } elseif ($uninstallSuiteName) {
        'MSI'
    } else {
        'Click-to-Run'
    }

    $channelStr = $null
    $rawChannel = if ($updateChannel) { $updateChannel } else { $cdnBaseUrl }
    if ($rawChannel) {
        if ($rawChannel -match '492350f6-3a01-4f97-b9c0-c7c6ddf67d60|(?i)Current') { $channelStr = 'Current Channel' }
        elseif ($rawChannel -match '64256afe-f5d9-4f86-8936-8840a6a4f5be|(?i)MonthlyEnterprise') { $channelStr = 'Monthly Enterprise Channel' }
        elseif ($rawChannel -match '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114|(?i)SemiAnnual|(?i)Deferred') { $channelStr = 'Semi-Annual Enterprise Channel' }
        elseif ($rawChannel -match 'b8f9b850-328d-4355-9145-c59439a0c433|(?i)Beta') { $channelStr = 'Beta Channel' }
        elseif ($rawChannel -match '5440fd1f-7372-4bfc-ac0a-0821e24ec870|(?i)CurrentPreview') { $channelStr = 'Current Preview' }
        elseif ($rawChannel -match 'f32ced47-09a4-4570-951d-b6182512f42a|(?i)Perpetual2021|(?i)2021Volume') { $channelStr = 'Perpetual 2021' }
        elseif ($rawChannel -match '503d4610-9b22-4530-910f-62463e26f8d0|(?i)Perpetual2019|(?i)2019Volume') { $channelStr = 'Perpetual 2019' }
        elseif ($rawChannel -match 'ea4a4090-de26-49d7-93c1-91bff9e53fc3|(?i)Perpetual2024|(?i)2024Volume') { $channelStr = 'Perpetual 2024' }
        else {
            $seg = ($rawChannel -split '[/\\]')[-1]
            if (-not [string]::IsNullOrWhiteSpace($seg)) { $channelStr = $seg }
        }
    }

    if (-not $channelStr) {
        if ($productReleaseIds -match '(?i)2024Volume') { $channelStr = 'Perpetual 2024' }
        elseif ($productReleaseIds -match '(?i)2021Volume') { $channelStr = 'Perpetual 2021' }
        elseif ($productReleaseIds -match '(?i)2019Volume') { $channelStr = 'Perpetual 2019' }
        elseif ($productReleaseIds -match '(?i)O365|365') { $channelStr = 'Current Channel' }
        elseif ($deployType -eq 'Click-to-Run') { $channelStr = 'Current Channel' }
    }

    $licStr = if ($productReleaseIds -match '(?i)Volume') {
        'Volume'
    } elseif ($productReleaseIds -match '(?i)Retail') {
        'Retail'
    } elseif ($productReleaseIds -match '(?i)O365|365') {
        'Subscription'
    } else {
        $null
    }

    $channelAndLic = if ($channelStr -and $licStr) {
        "$channelStr ($licStr)"
    } elseif ($channelStr) {
        $channelStr
    } elseif ($licStr) {
        $licStr
    } else {
        'Standard'
    }

    $lines.Add("Build & Channel: $c2rVer | $c2rArch | $deployType | $channelAndLic")

    # 5. Detect Individual Installed Applications
    $appExes = [ordered]@{
        'Word'       = 'WINWORD.EXE'
        'Excel'      = 'EXCEL.EXE'
        'PowerPoint' = 'POWERPNT.EXE'
        'Outlook'    = 'OUTLOOK.EXE'
        'OneNote'    = 'ONENOTE.EXE'
        'Access'     = 'MSACCESS.EXE'
        'Publisher'  = 'MSPUB.EXE'
        'Visio'      = 'VISIO.EXE'
        'Project'    = 'WINPROJ.EXE'
    }

    $candidateDirs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($installationPath)) {
        $candidateDirs.Add((Join-Path $installationPath 'root\Office16'))
        $candidateDirs.Add((Join-Path $installationPath 'Office16'))
        $candidateDirs.Add($installationPath)
    }
    if ($env:ProgramFiles) {
        $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'))
        $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\Office16'))
    }
    $prog86 = ${env:ProgramFiles(x86)}
    if ($prog86) {
        $candidateDirs.Add((Join-Path $prog86 'Microsoft Office\root\Office16'))
        $candidateDirs.Add((Join-Path $prog86 'Microsoft Office\Office16'))
    }

    $detectedApps = [System.Collections.Generic.List[string]]::new()
    foreach ($appKey in $appExes.Keys) {
        $exeName = $appExes[$appKey]
        $found = $false
        foreach ($dir in $candidateDirs) {
            $fullPath = Join-Path $dir $exeName
            if (Test-Path -LiteralPath $fullPath -ErrorAction SilentlyContinue) {
                $detectedApps.Add($appKey)
                $found = $true
                break
            }
        }
        if (-not $found) {
            foreach ($apRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')) {
                $apKey = "$apRoot\$exeName"
                try {
                    if (Test-Path -LiteralPath $apKey -ErrorAction SilentlyContinue) {
                        $detectedApps.Add($appKey)
                        $found = $true
                        break
                    }
                } catch { $null = $_ }
            }
        }
    }

    # Inferred fallback if no binaries are present on disk
    if ($detectedApps.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($productReleaseIds)) {
        $excludedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $c2rProps) {
            foreach ($p in $c2rProps.PSObject.Properties) {
                if ($p.Name -match '(?i)ExcludedApps' -and $p.Value) {
                    foreach ($ex in "$($p.Value)".Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)) {
                        $null = $excludedSet.Add($ex.Trim())
                    }
                }
            }
        }

        $defaultSuite = [System.Collections.Generic.List[string]]::new()
        foreach ($baseApp in @('Word', 'Excel', 'PowerPoint')) {
            $defaultSuite.Add($baseApp)
        }
        if ($productReleaseIds -notmatch '(?i)HomeStudent') {
            $defaultSuite.Add('Outlook')
        }
        $defaultSuite.Add('OneNote')
        if ($productReleaseIds -notmatch '(?i)HomeStudent|HomeBusiness|Standard') {
            $defaultSuite.Add('Access')
        }
        if ($productReleaseIds -notmatch '(?i)HomeStudent|HomeBusiness') {
            $defaultSuite.Add('Publisher')
        }
        if ($productReleaseIds -match '(?i)Visio') {
            $defaultSuite.Add('Visio')
        }
        if ($productReleaseIds -match '(?i)Project') {
            $defaultSuite.Add('Project')
        }

        foreach ($app in $defaultSuite) {
            if (-not $excludedSet.Contains($app)) {
                $detectedApps.Add($app)
            }
        }
    }

    $appsOutput = if ($detectedApps.Count -gt 0) {
        "$($detectedApps -join ', ') ($($detectedApps.Count))"
    } else {
        'None Detected [STANDBY]'
    }
    $lines.Add("Installed Apps : $appsOutput")

    # 6. Enumerate Running Office Applications
    $runningApps = [System.Collections.Generic.List[string]]::new()
    try {
        $allProcs = @(Get-Process -ErrorAction SilentlyContinue)
        if ($allProcs.Count -gt 0) {
            $targetNames = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'VISIO', 'WINPROJ'),
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $procCounts = @{}
            foreach ($p in $allProcs) {
                if ($p -and $p.ProcessName -and $targetNames.Contains($p.ProcessName)) {
                    $uName = $p.ProcessName.ToUpperInvariant()
                    $procCounts[$uName] = [int]$procCounts[$uName] + 1
                }
            }
            foreach ($name in @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'VISIO', 'WINPROJ')) {
                if ($procCounts.ContainsKey($name)) {
                    $runningApps.Add("$name ($($procCounts[$name]))")
                }
            }
        }
    } catch { $null = $_ }
    if ($runningApps.Count -eq 0) {
        foreach ($proc in @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'VISIO', 'WINPROJ')) {
            try {
                $procs = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
                if ($procs.Count -gt 0) { $runningApps.Add("$proc ($($procs.Count))") }
            } catch { $null = $_ }
        }
    }

    $activeStr = if ($runningApps.Count -gt 0) { $runningApps -join ', ' } else { 'None [STANDBY]' }
    $lines.Add("Active Suite   : $activeStr")

    # 7. Outlook Mail Profile
    $defProf = 'None'
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile)) {
                $defProf = $ctx.DefaultProfile
            }
        } catch { $null = $_ }
    }
    $lines.Add("Mail Profile   : Default Profile: $defProf")
    $lines.Add("Console Hub    : Pillar 2 Dispatcher | Pure Numeric 1-Handed Navigation [READY]")

    return $lines.ToArray()
}

function Get-OfficeContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

# 3. Main Dispatcher Function: Invoke-ToolkitSubmenuOfficeSuite
function Invoke-ToolkitSubmenuOfficeSuite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Office Suite Hub launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeSuiteContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & PRODUCTIVITY SUITE' `
            -Subtitle 'Central Administration Hub: Suite Health, Word, Excel, PowerPoint & Outlook' `
            -ClearScreen:$clear `
            -InfoLines $officeInfo

        $actions = @(
            @{ Key = '1'; Label = 'Office Suite & General Maintenance'; Description = 'Suite-wide C2R service repair, WAM tokens, hardware acceleration, and scrubber' },
            @{ Key = '2'; Label = 'Microsoft Word Repairs'; Description = 'Normal.dotm template recovery, STARTUP add-in isolation, and lock cleanup' },
            @{ Key = '3'; Label = 'Microsoft Excel Repairs'; Description = 'XLSTART isolation, UI toolbar cache reset, DDE freeze, and GDI audit' },
            @{ Key = '4'; Label = 'Microsoft PowerPoint Repairs'; Description = 'Font/slide preview cache reset, and COM add-in resiliency unblocking' },
            @{ Key = '5'; Label = 'Microsoft Outlook & Data Files'; Description = 'PST/OST management, quick mail repair, rules migration, and profile selector' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu'; Description = 'Return to the primary IToolkit console' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'PRODUCTIVITY SUITE DOMAINS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Office & Productivity Suite'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Office & Productivity Suite'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '0')
        $promptText = "  Select Office Module [1-5], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"
        $subParams = @{
            NonInteractive  = $NonInteractive
            ExitImmediately = $ExitImmediately
            MenuDepth       = $MenuDepth + 1
        }

        switch ($actionKey) {
            '1' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeCommon @subParams
                } else {
                    Write-ToolkitStatus -Message "Office Suite Common submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '2' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeWord @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Word submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '3' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeExcel @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Excel submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '4' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficePowerPoint @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft PowerPoint submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '5' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeOutlook @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Outlook submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '0' {
                return
            }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


# 4. Backward Compatibility Aliases
function Invoke-ToolkitSubmenuOffice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
}

function Invoke-ToolkitSubmenuOutlook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue) {
        Invoke-ToolkitSubmenuOfficeOutlook @PSBoundParameters
    } else {
        Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
    }
}

# 5. Global Session Scope Exports
if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeSuiteContextInfoLines' -Value (Get-Command -Name 'Get-OfficeSuiteContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeContextInfoLines' -Value (Get-Command -Name 'Get-OfficeContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeSuite' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOffice' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOffice' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOffice').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOutlook' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook').ScriptBlock
}
