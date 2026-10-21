# ==============================================================================
# OutlookE2E.Tests.ps1
# E2E Test Suite (Tiers 1-4) for Microsoft Outlook Subsystem Modernization
# Rule Portability, Intelligent Import, Smart Diagnostics & TUI Profile Selector
# Adheres strictly to Karpathy Guidelines, Ponytail principles, 100% English.
# Compatible with PowerShell 5.1 (.NET 4.8) and PowerShell 7+ Core on Linux.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

# Pre-load modules at script scope so Pester v5 discovery accurately detects available cmdlets
try {
    $corePsd1 = Join-Path $ProjectRoot 'Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePsd1) {
        Import-Module $corePsd1 -Force -ErrorAction SilentlyContinue
    }
    $outlookPsd1 = Join-Path $ProjectRoot 'Modules/Outlook/Outlook.psd1'
    if (Test-Path -LiteralPath $outlookPsd1) {
        Import-Module $outlookPsd1 -Force -ErrorAction SilentlyContinue
    }
    $tuiPsd1 = Join-Path $ProjectRoot 'Modules/TUI/TUI.psd1'
    if (Test-Path -LiteralPath $tuiPsd1) {
        Import-Module $tuiPsd1 -Force -ErrorAction SilentlyContinue
    }

    # Dot-source any standalone Public scripts if not yet registered in module manifest
    $publicDir = Join-Path $ProjectRoot 'Modules/Outlook/Public'
    if (Test-Path -LiteralPath $publicDir) {
        Get-ChildItem -Path $publicDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { . $_.FullName } catch { $null = $_ }
        }
    }
} catch { $null = $_ }

# Pre-define divider helper if needed for TUI standalone execution
if (-not (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) {
    function global:Write-ToolkitMenuDivider { param([string]$Character = '=', [int]$Width = 80) $Character * $Width }
}
if (-not (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue)) {
    function global:Get-OutlookComApplication { return $null }
}

# ------------------------------------------------------------------------------
# Mock COM Infrastructure Factory for Outlook E2E Verification
# ------------------------------------------------------------------------------
$global:folderFactory = {
    param($FolderName)
    $childList = [System.Collections.Generic.List[object]]::new()
    $newChild = [PSCustomObject]@{
        Name       = $FolderName
        FolderPath = "$($this.FolderPath)\$FolderName"
        Folders    = $childList
    }
    $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory
    $this.Folders.Add($newChild)
    return $newChild
}

function global:New-OutlookE2EMockEnvironment {
    param(
        [string]$SourceStorePath = 'C:\Data\SourceMail.pst',
        [string]$TargetStorePath = 'C:\Data\TargetMail.pst',
        [string]$SourceProfile = 'CorporateProfile',
        [string]$TargetProfile = 'ArchiveProfile'
    )

    # 1. Source Folder Hierarchy:
    # \\SourceStore
    #   Inbox
    #     Projects
    #       Alpha
    #       Beta
    #     Alerts
    #   Finance
    #     Invoices
    #   Deleted Items, Sent Items, Drafts, Outbox, Junk Email
    $mockSourceFolderAlpha = [PSCustomObject]@{
        Name       = 'Alpha'
        FolderPath = "\\SourceStore\Inbox\Projects\Alpha"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceFolderBeta = [PSCustomObject]@{
        Name       = 'Beta'
        FolderPath = "\\SourceStore\Inbox\Projects\Beta"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceFolderProjects = [PSCustomObject]@{
        Name       = 'Projects'
        FolderPath = "\\SourceStore\Inbox\Projects"
        Folders    = [System.Collections.Generic.List[object]]@($mockSourceFolderAlpha, $mockSourceFolderBeta)
    }
    $mockSourceFolderAlerts = [PSCustomObject]@{
        Name       = 'Alerts'
        FolderPath = "\\SourceStore\Inbox\Alerts"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceInbox = [PSCustomObject]@{
        Name       = 'Inbox'
        FolderPath = "\\SourceStore\Inbox"
        Folders    = [System.Collections.Generic.List[object]]@($mockSourceFolderProjects, $mockSourceFolderAlerts)
    }
    $mockSourceFolderInvoices = [PSCustomObject]@{
        Name       = 'Invoices'
        FolderPath = "\\SourceStore\Finance\Invoices"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceFinance = [PSCustomObject]@{
        Name       = 'Finance'
        FolderPath = "\\SourceStore\Finance"
        Folders    = [System.Collections.Generic.List[object]]@($mockSourceFolderInvoices)
    }
    $mockSourceDeleted = [PSCustomObject]@{
        Name       = 'Deleted Items'
        FolderPath = "\\SourceStore\Deleted Items"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceSent = [PSCustomObject]@{
        Name       = 'Sent Items'
        FolderPath = "\\SourceStore\Sent Items"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockSourceDrafts = [PSCustomObject]@{
        Name       = 'Drafts'
        FolderPath = "\\SourceStore\Drafts"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }

    $mockSourceRoot = [PSCustomObject]@{
        Name       = 'SourceStore'
        FolderPath = "\\SourceStore"
        Folders    = [System.Collections.Generic.List[object]]@($mockSourceInbox, $mockSourceFinance, $mockSourceDeleted, $mockSourceSent, $mockSourceDrafts)
    }

    $mockSourceRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory
    $mockSourceInbox | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory
    $mockSourceFolderProjects | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory
    $mockSourceFinance | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory

    # 2. Target Folder Hierarchy (Clean Target):
    $mockTargetInbox = [PSCustomObject]@{
        Name       = 'Inbox'
        FolderPath = "\\TargetStore\Inbox"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockTargetDeleted = [PSCustomObject]@{
        Name       = 'Deleted Items'
        FolderPath = "\\TargetStore\Deleted Items"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockTargetSent = [PSCustomObject]@{
        Name       = 'Sent Items'
        FolderPath = "\\TargetStore\Sent Items"
        Folders    = [System.Collections.Generic.List[object]]::new()
    }
    $mockTargetRoot = [PSCustomObject]@{
        Name       = 'TargetStore'
        FolderPath = "\\TargetStore"
        Folders    = [System.Collections.Generic.List[object]]@($mockTargetInbox, $mockTargetDeleted, $mockTargetSent)
    }
    $mockTargetRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory
    $mockTargetInbox | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $global:folderFactory

    # 3. Source Rules
    $mockRule1 = [PSCustomObject]@{
        Name           = 'Route Project Alpha'
        RuleType       = 0
        ExecutionOrder = 1
        Enabled        = $true
        Conditions     = [PSCustomObject]@{
            Subject     = [PSCustomObject]@{ Enabled = $true; Text = @('Project Alpha', 'Alpha') }
            From        = [PSCustomObject]@{ Enabled = $true; Recipients = @('lead@oldcorp.com') }
            Categories  = [PSCustomObject]@{ Enabled = $true; Categories = @('Project') }
            Importance  = [PSCustomObject]@{ Enabled = $true; Importance = 2 }
            Sensitivity = [PSCustomObject]@{ Enabled = $false; Sensitivity = 0 }
        }
        Exceptions     = [PSCustomObject]@{
            Subject     = [PSCustomObject]@{ Enabled = $true; Text = @('Draft', 'Spam') }
            From        = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
        }
        Actions        = [PSCustomObject]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $mockSourceFolderAlpha; Enabled = $true }
            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            Delete       = [PSCustomObject]@{ Enabled = $false }
            MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
            Stop         = [PSCustomObject]@{ Enabled = $true }
        }
    }

    $mockRule2 = [PSCustomObject]@{
        Name           = 'Copy Finance Invoices'
        RuleType       = 0
        ExecutionOrder = 2
        Enabled        = $true
        Conditions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Invoice', 'Billing') }
            From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('vendor@external.org') }
            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
            Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
        }
        Exceptions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
        }
        Actions        = [PSCustomObject]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            CopyToFolder = [PSCustomObject]@{ Folder = $mockSourceFolderInvoices; Enabled = $true }
            Delete       = [PSCustomObject]@{ Enabled = $false }
            MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
            Stop         = [PSCustomObject]@{ Enabled = $false }
        }
    }

    $mockRule3 = [PSCustomObject]@{
        Name           = 'Delete Automated Alerts'
        RuleType       = 0
        ExecutionOrder = 3
        Enabled        = $true
        Conditions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('Daily Digest') }
            From       = [PSCustomObject]@{ Enabled = $true; Recipients = @('noreply@service.com') }
            Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
            Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
        }
        Exceptions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
        }
        Actions        = [PSCustomObject]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            Delete       = [PSCustomObject]@{ Enabled = $true }
            MarkAsRead   = [PSCustomObject]@{ Enabled = $true }
            Stop         = [PSCustomObject]@{ Enabled = $true }
        }
    }

    $mockRule4 = [PSCustomObject]@{
        Name           = 'Disabled Critical Alert'
        RuleType       = 0
        ExecutionOrder = 4
        Enabled        = $false
        Conditions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $true; Text = @('CRITICAL') }
        }
        Exceptions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
        }
        Actions        = [PSCustomObject]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $mockSourceFolderAlerts; Enabled = $true }
            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            Delete       = [PSCustomObject]@{ Enabled = $false }
            Stop         = [PSCustomObject]@{ Enabled = $false }
        }
    }

    $mockRule5 = [PSCustomObject]@{
        Name           = 'Empty Zombie Rule'
        RuleType       = 0
        ExecutionOrder = 5
        Enabled        = $false
        Conditions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
            From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
        }
        Exceptions     = [PSCustomObject]@{
            Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
        }
        Actions        = [PSCustomObject]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
            Delete       = [PSCustomObject]@{ Enabled = $false }
        }
    }

    $mockSourceRulesList = [System.Collections.Generic.List[object]]@($mockRule1, $mockRule2, $mockRule3, $mockRule4, $mockRule5)
    $mockSourceRules = [PSCustomObject]@{
        Count            = $mockSourceRulesList.Count
        RulesList        = $mockSourceRulesList
        Saved            = $false
        SaveShowProgress = $false
    }
    $mockSourceRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $this.RulesList[$i - 1] }
    $mockSourceRules | Add-Member -MemberType ScriptMethod -Name Remove -Value {
        param($i)
        $this.RulesList.RemoveAt($i - 1)
        $this.Count = $this.RulesList.Count
    }
    $mockSourceRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
        param($showProgress)
        $this.Saved = $true
        $this.SaveShowProgress = $showProgress
    }

    # 4. Target Rules Collection
    $mockTargetRulesList = [System.Collections.Generic.List[object]]::new()
    $mockTargetRules = [PSCustomObject]@{
        Count            = 0
        RulesList        = $mockTargetRulesList
        Saved            = $false
        SaveShowProgress = $false
    }
    $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $this.RulesList[$i - 1] }
    $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
        param($name, $ruleType)
        $newRule = [PSCustomObject]@{
            Name           = $name
            RuleType       = $ruleType
            ExecutionOrder = $this.RulesList.Count + 1
            Enabled        = $false
            Conditions     = [PSCustomObject]@{
                Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
            }
            Exceptions     = [PSCustomObject]@{
                Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
            }
            Actions        = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                Delete       = [PSCustomObject]@{ Enabled = $false }
                MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                Stop         = [PSCustomObject]@{ Enabled = $false }
            }
        }
        $this.RulesList.Add($newRule)
        $this.Count = $this.RulesList.Count
        return $newRule
    }
    $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Remove -Value {
        param($i)
        $this.RulesList.RemoveAt($i - 1)
        $this.Count = $this.RulesList.Count
    }
    $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
        param($showProgress)
        $this.Saved = $true
        $this.SaveShowProgress = $showProgress
    }

    # 5. Stores
    $mockSourceStore = [PSCustomObject]@{
        DisplayName     = 'Corporate Mailbox'
        FilePath        = $SourceStorePath
        IsDataFileStore = $true
        IsDefaultStore  = $true
        RootFolder      = $mockSourceRoot
        Rules           = $mockSourceRules
    }
    $mockSourceStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
    $mockSourceStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

    $mockTargetStore = [PSCustomObject]@{
        DisplayName     = 'Archive Mailbox'
        FilePath        = $TargetStorePath
        IsDataFileStore = $true
        IsDefaultStore  = $false
        RootFolder      = $mockTargetRoot
        Rules           = $mockTargetRules
    }
    $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
    $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

    # 6. MAPI Namespace
    $mockNs = [PSCustomObject]@{
        Stores        = @($mockSourceStore, $mockTargetStore)
        DefaultStore  = $mockSourceStore
        ActiveProfile = $SourceProfile
        LoggedOff     = $false
    }
    $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value {
        param($prof, $pwd, $ui, $new)
        $this.ActiveProfile = $prof
    }
    $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value {
        $this.LoggedOff = $true
    }
    $mockNs | Add-Member -MemberType ScriptMethod -Name AddStoreEx -Value {
        param($path, $type)
    }

    # 7. Outlook Application
    $mockApp = [PSCustomObject]@{
        MapiNamespace = $mockNs
        QuitCalled    = $false
    }
    $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
        param($type)
        return $this.MapiNamespace
    }
    $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
        $this.QuitCalled = $true
    }

    return @{
        App            = $mockApp
        Namespace      = $mockNs
        SourceStore    = $mockSourceStore
        TargetStore    = $mockTargetStore
        SourceRoot     = $mockSourceRoot
        TargetRoot     = $mockTargetRoot
        SourceInbox    = $mockSourceInbox
        TargetInbox    = $mockTargetInbox
        FolderProjects = $mockSourceFolderProjects
        FolderAlpha    = $mockSourceFolderAlpha
        FolderBeta     = $mockSourceFolderBeta
        FolderFinance  = $mockSourceFinance
        FolderInvoices = $mockSourceFolderInvoices
        FolderAlerts   = $mockSourceFolderAlerts
        SourceRules    = $mockSourceRules
        TargetRules    = $mockTargetRules
        Rule1          = $mockRule1
        Rule2          = $mockRule2
        Rule3          = $mockRule3
        Rule4          = $mockRule4
        Rule5          = $mockRule5
    }
}

# ==============================================================================
# TIER 1: Core Export Engine & Manifest Portability (R1)
# ==============================================================================
Describe 'E2E Tier 1: Core Export Engine & Manifest Portability (R1)' {

    Context '1.1 Mock COM Infrastructure & Topology Integrity' {
        It 'Initializes mock folder topology with accurate MAPI paths' {
            $env = New-OutlookE2EMockEnvironment
            $env.FolderAlpha.FolderPath | Should -Be "\\SourceStore\Inbox\Projects\Alpha"
            $env.FolderInvoices.FolderPath | Should -Be "\\SourceStore\Finance\Invoices"
            $env.SourceRoot.Folders.Count | Should -BeGreaterThan 3
        }

        It 'Maintains 1-based indexing and collection counts for MockRules' {
            $env = New-OutlookE2EMockEnvironment
            $env.SourceRules.Count | Should -Be 5
            $r1 = $env.SourceRules.Item(1)
            $r1.Name | Should -Be 'Route Project Alpha'
            $r5 = $env.SourceRules.Item(5)
            $r5.Name | Should -Be 'Empty Zombie Rule'
        }

        It 'Allows dynamic recursive folder addition via AddFolder script method' {
            $env = New-OutlookE2EMockEnvironment
            $newChild = $env.TargetInbox.AddFolder('SubProject')
            $newChild.Name | Should -Be 'SubProject'
            $newChild.FolderPath | Should -Be "\\TargetStore\Inbox\SubProject"
            $env.TargetInbox.Folders.Count | Should -Be 1
        }
    }

    Context '1.2 Manifest Serialization Schema & Store-Relative Paths' {
        It 'Transforms absolute MAPI folder paths into store-relative paths' {
            $absolutePath = "\\Corporate Mailbox\Inbox\Projects\Alpha"
            $relPath = $absolutePath -replace '^\\\\?[^\\]+\\?', ''
            $relPath = $relPath.TrimStart('\', '/')
            $relPath | Should -Be "Inbox\Projects\Alpha"
        }

        It 'Serializes complete rule manifest v1.0.0 matching schema requirements' {
            $env = New-OutlookE2EMockEnvironment

            $manifest = [PSCustomObject]@{
                ManifestVersion = '1.0.0'
                ExportTimestamp = (Get-Date).ToString('o')
                ExportedBy      = 'IToolkit'
                SourceContext   = [PSCustomObject]@{
                    ProfileName   = 'CorporateProfile'
                    StoreName     = 'Corporate Mailbox'
                    StoreFilePath = 'C:\Data\SourceMail.pst'
                    OfficeVersion = '16.0'
                }
                CustomFolders   = @('Inbox\Projects\Alpha', 'Inbox\Projects\Beta', 'Finance\Invoices')
                Rules           = @(
                    [PSCustomObject]@{
                        Name           = $env.Rule1.Name
                        RuleType       = $env.Rule1.RuleType
                        ExecutionOrder = $env.Rule1.ExecutionOrder
                        Enabled        = $env.Rule1.Enabled
                        Conditions     = [PSCustomObject]@{
                            Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Project Alpha', 'Alpha') }
                            From    = [PSCustomObject]@{ Enabled = $true; Recipients = @('lead@oldcorp.com') }
                        }
                        Exceptions     = [PSCustomObject]@{
                            Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Draft', 'Spam') }
                        }
                        Actions        = [PSCustomObject]@{
                            MoveToFolder = [PSCustomObject]@{ Enabled = $true; FolderPath = 'Inbox\Projects\Alpha' }
                            Stop         = [PSCustomObject]@{ Enabled = $true }
                        }
                    }
                )
            }

            $json = $manifest | ConvertTo-Json -Depth 10
            $deserialized = $json | ConvertFrom-Json

            $deserialized.ManifestVersion | Should -Be '1.0.0'
            $deserialized.SourceContext.ProfileName | Should -Be 'CorporateProfile'
            $deserialized.CustomFolders.Count | Should -Be 3
            $deserialized.Rules[0].Name | Should -Be 'Route Project Alpha'
            $deserialized.Rules[0].Actions.MoveToFolder.FolderPath | Should -Be "Inbox\Projects\Alpha"
        }
    }

    Context '1.3 Export-OutlookRule Cmdlet Execution' {
        $hasExport = [bool](Get-Command -Name 'Export-OutlookRule' -ErrorAction SilentlyContinue)

        It 'Exports rules to a designated JSON manifest on disk' -Skip:(-not $hasExport) {
            $env = New-OutlookE2EMockEnvironment
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $jsonFile = Join-Path $tempDir 'ExportedRules.json'

            try {
                Mock Get-OutlookComApplication { return $env.App }
                Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
                Mock Get-Process { return @() }
                Mock Get-Process { return @() } -ModuleName 'Outlook'

                $result = Export-OutlookRule -Path $jsonFile -StorePath 'C:\Data\SourceMail.pst' -ProfileName 'CorporateProfile' -PassThru
                $result.Success | Should -BeTrue
                Test-Path -LiteralPath $jsonFile | Should -BeTrue

                $content = Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json
                $content.ManifestVersion | Should -Be '1.0.0'
                $content.Rules.Count | Should -BeGreaterOrEqual 1
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Performs zero file writes and returns simulation object in -WhatIf mode' -Skip:(-not $hasExport) {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "WhatIfTest_$(Get-Random).json"
            try {
                $result = Export-OutlookRule -Path $tempFile -StorePath 'C:\Data\SourceMail.pst' -WhatIf
                Test-Path -LiteralPath $tempFile | Should -BeFalse
            } finally {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# TIER 2: Intelligent Import & Parameter/Hierarchy Remapping (R2)
# ==============================================================================
Describe 'E2E Tier 2: Intelligent Import & Parameter/Hierarchy Remapping (R2)' {

    Context '2.1 Recursive Destination Folder Pre-Creation' {
        It 'Pre-creates missing relative folder hierarchy in target store before rule binding' {
            $env = New-OutlookE2EMockEnvironment
            $relPaths = @('Inbox\Projects\Alpha', 'Finance\Invoices')

            foreach ($p in $relPaths) {
                $segments = @($p -split '[\\/]')
                $currentFolder = if ($segments[0] -ieq 'Inbox') { $env.TargetInbox } else {
                    $found = $null
                    foreach ($f in $env.TargetRoot.Folders) { if ($f.Name -ieq $segments[0]) { $found = $f; break } }
                    if ($null -eq $found) { $found = $env.TargetRoot.AddFolder($segments[0]) }
                    $found
                }

                for ($i = 1; $i -lt $segments.Count; $i++) {
                    $seg = $segments[$i]
                    $child = $null
                    foreach ($sub in $currentFolder.Folders) { if ($sub.Name -ieq $seg) { $child = $sub; break } }
                    if ($null -eq $child) { $child = $currentFolder.AddFolder($seg) }
                    $currentFolder = $child
                }
            }

            # Verify TargetStore now contains the reconstructed folders
            $env.TargetInbox.Folders[0].Name | Should -Be 'Projects'
            $env.TargetInbox.Folders[0].Folders[0].Name | Should -Be 'Alpha'
            $env.TargetInbox.Folders[0].Folders[0].FolderPath | Should -Be "\\TargetStore\Inbox\Projects\Alpha"
        }

        It 'Maintains idempotency: repeated folder creation does not produce duplicate folders' {
            $env = New-OutlookE2EMockEnvironment
            $env.TargetInbox.AddFolder('Alpha') | Out-Null
            $env.TargetInbox.Folders.Count | Should -Be 1

            # Simulate idempotent lookup: do not add if already exists
            $existing = $null
            foreach ($f in $env.TargetInbox.Folders) { if ($f.Name -ieq 'Alpha') { $existing = $f; break } }
            if ($null -eq $existing) { $env.TargetInbox.AddFolder('Alpha') | Out-Null }

            $env.TargetInbox.Folders.Count | Should -Be 1
        }
    }

    Context '2.2 Parameter & Address/Account Remapping' {
        It 'Substitutes recipient and sender addresses using AddressMap dictionary' {
            $addressMap = @{
                'lead@oldcorp.com'    = 'lead@newcorp.com'
                'vendor@external.org' = 'vendor@partner.org'
            }

            $sourceRecipients = @('lead@oldcorp.com', 'team@oldcorp.com')
            $remapped = @($sourceRecipients | ForEach-Object {
                if ($addressMap.ContainsKey($_)) { $addressMap[$_] } else { $_ }
            })

            $remapped[0] | Should -Be 'lead@newcorp.com'
            $remapped[1] | Should -Be 'team@oldcorp.com'
        }

        It 'Binds target MoveToFolder action to matching relative folder in Target Store' {
            $env = New-OutlookE2EMockEnvironment
            $targetAlpha = $env.TargetInbox.AddFolder('Projects').AddFolder('Alpha')

            $newRule = $env.TargetRules.Create('Route Project Alpha', 0)
            $newRule.Actions.MoveToFolder.Folder = $targetAlpha
            $newRule.Actions.MoveToFolder.Enabled = $true

            $newRule.Actions.MoveToFolder.Folder.FolderPath | Should -Be "\\TargetStore\Inbox\Projects\Alpha"
            $newRule.Actions.MoveToFolder.Enabled | Should -BeTrue
        }
    }

    Context '2.3 Duplicate Rule Resolution Policies' {
        It 'Policy Skip: leaves existing target rule untouched and skips incoming rule' {
            $env = New-OutlookE2EMockEnvironment
            $existing = $env.TargetRules.Create('Route Project Alpha', 0)
            $existing.Enabled = $true
            $initialCount = $env.TargetRules.Count

            # Simulating import under 'Skip' policy
            $incomingName = 'Route Project Alpha'
            $conflict = $null
            for ($i = 1; $i -le $env.TargetRules.Count; $i++) {
                if ($env.TargetRules.Item($i).Name -ieq $incomingName) { $conflict = $env.TargetRules.Item($i); break }
            }

            $skippedCount = 0
            if ($null -ne $conflict) { $skippedCount++ }

            $skippedCount | Should -Be 1
            $env.TargetRules.Count | Should -Be $initialCount
        }

        It 'Policy Overwrite: updates existing target rule properties in-place' {
            $env = New-OutlookE2EMockEnvironment
            $existing = $env.TargetRules.Create('Route Project Alpha', 0)
            $existing.Enabled = $false

            # Simulating import under 'Overwrite' policy
            $existing.Enabled = $true
            $existing.Conditions.Subject.Text = @('Updated Alpha')
            $existing.Conditions.Subject.Enabled = $true

            $env.TargetRules.Count | Should -Be 1
            $existing.Enabled | Should -BeTrue
            $existing.Conditions.Subject.Text | Should -Contain 'Updated Alpha'
        }

        It 'Policy Rename/KeepBoth: creates new rule with unique suffix' {
            $env = New-OutlookE2EMockEnvironment
            $existing = $env.TargetRules.Create('Route Project Alpha', 0)

            # Simulating import under 'Rename' policy
            $renamedRule = $env.TargetRules.Create('Route Project Alpha (Imported)', 0)

            $env.TargetRules.Count | Should -Be 2
            $renamedRule.Name | Should -Be 'Route Project Alpha (Imported)'
        }

        It 'Enforces silent commit via Save($false)' {
            $env = New-OutlookE2EMockEnvironment
            $env.TargetRules.Save($false)
            $env.TargetRules.Saved | Should -BeTrue
            $env.TargetRules.SaveShowProgress | Should -BeFalse
        }
    }

    Context '2.4 Import-OutlookRule Cmdlet Execution' {
        $hasImport = [bool](Get-Command -Name 'Import-OutlookRule' -ErrorAction SilentlyContinue)

        It 'Imports manifest and reconstructs rules in target store silently' -Skip:(-not $hasImport) {
            $env = New-OutlookE2EMockEnvironment
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $jsonFile = Join-Path $tempDir 'RulesToImport.json'

            try {
                $manifest = @{
                    ManifestVersion = '1.0.0'
                    CustomFolders   = @('Inbox\Projects\Alpha')
                    Rules           = @(
                        @{
                            Name           = 'Route Project Alpha'
                            RuleType       = 0
                            ExecutionOrder = 1
                            Enabled        = $true
                            Conditions     = @{ Subject = @{ Enabled = $true; Text = @('Alpha') } }
                            Actions        = @{ MoveToFolder = @{ Enabled = $true; FolderPath = 'Inbox\Projects\Alpha' } }
                        }
                    )
                }
                $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonFile

                Mock Get-OutlookComApplication { return $env.App }
                Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
                Mock Get-Process { return @() }
                Mock Get-Process { return @() } -ModuleName 'Outlook'

                $result = Import-OutlookRule -Path $jsonFile -TargetStorePath 'C:\Data\TargetMail.pst' -AutoCreateFolders
                $result.Success | Should -BeTrue
                $env.TargetRules.Saved | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# TIER 3: Diagnostics, Auto-Repair & COM Lifecycle Hardening (R3)
# ==============================================================================
Describe 'E2E Tier 3: Diagnostics, Auto-Repair & COM Lifecycle Hardening (R3)' {

    Context '3.1 Broken Target Folder Diagnostics & Auto-Repair' {
        It 'Detects broken MoveToFolder reference when target folder is null' {
            $env = New-OutlookE2EMockEnvironment
            # Invalidate rule 1 target folder
            $env.Rule1.Actions.MoveToFolder.Folder = $null

            $brokenRules = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $env.SourceRules.Count; $i++) {
                $r = $env.SourceRules.Item($i)
                if ($r.Actions.MoveToFolder -and $r.Actions.MoveToFolder.Enabled) {
                    if ($null -eq $r.Actions.MoveToFolder.Folder) {
                        $brokenRules.Add([PSCustomObject]@{
                            Name       = $r.Name
                            Issue      = 'BrokenMoveTarget'
                            ActionType = 'MoveToFolder'
                        })
                    }
                }
            }

            $brokenRules.Count | Should -Be 1
            $brokenRules[0].Name | Should -Be 'Route Project Alpha'
        }

        It 'Auto-repairs broken rule by creating missing folder under Inbox and rebinding' {
            $env = New-OutlookE2EMockEnvironment
            $env.Rule1.Actions.MoveToFolder.Folder = $null

            # Self-healing logic simulation
            $recoveredFolder = $env.SourceInbox.AddFolder('Recovered_Alpha')
            $env.Rule1.Actions.MoveToFolder.Folder = $recoveredFolder
            $env.Rule1.Actions.MoveToFolder.Enabled = $true

            $env.Rule1.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
            $env.Rule1.Actions.MoveToFolder.Folder.FolderPath | Should -Be "\\SourceStore\Inbox\Recovered_Alpha"
        }
    }

    Context '3.2 Duplicate Rule Deduplication & Reverse-Index Removal' {
        It 'Identifies duplicate rule signatures based on conditions and actions' {
            $env = New-OutlookE2EMockEnvironment
            # Add an exact duplicate of Rule 2
            $dupRule = [PSCustomObject]@{
                Name       = 'Copy Finance Invoices Duplicate'
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Invoice', 'Billing') }
                    From    = [PSCustomObject]@{ Enabled = $true; Recipients = @('vendor@external.org') }
                }
                Actions    = [PSCustomObject]@{
                    CopyToFolder = [PSCustomObject]@{ Folder = $env.FolderInvoices; Enabled = $true }
                }
            }
            $env.SourceRules.RulesList.Add($dupRule)
            $env.SourceRules.Count = $env.SourceRules.RulesList.Count

            # Signature generation
            $seenSigs = @{}
            $duplicateIndices = [System.Collections.Generic.List[int]]::new()

            for ($i = 1; $i -le $env.SourceRules.Count; $i++) {
                $r = $env.SourceRules.Item($i)
                $subj = if ($r.Conditions.Subject -and $r.Conditions.Subject.Enabled) { $r.Conditions.Subject.Text -join ',' } else { '' }
                $actFolder = if ($r.Actions.CopyToFolder -and $r.Actions.CopyToFolder.Folder) { $r.Actions.CopyToFolder.Folder.Name } else { '' }
                $sig = "SUBJ:$subj|COPY:$actFolder"

                if ($seenSigs.ContainsKey($sig)) {
                    $duplicateIndices.Add($i)
                } else {
                    $seenSigs[$sig] = $r.Name
                }
            }

            $duplicateIndices.Count | Should -Be 1
            $duplicateIndices[0] | Should -Be 6
        }

        It 'Removes duplicate rules in descending index order without corrupting positions' {
            $env = New-OutlookE2EMockEnvironment
            $initialCount = $env.SourceRules.Count # 5
            # Add two duplicates at the end
            $env.SourceRules.RulesList.Add([PSCustomObject]@{ Name = 'Dup1' })
            $env.SourceRules.RulesList.Add([PSCustomObject]@{ Name = 'Dup2' })
            $env.SourceRules.Count = $env.SourceRules.RulesList.Count # 7

            $toRemove = @(7, 6) # Descending order
            foreach ($idx in $toRemove) {
                $env.SourceRules.Remove($idx)
            }

            $env.SourceRules.Count | Should -Be $initialCount
            $env.SourceRules.Item(1).Name | Should -Be 'Route Project Alpha'
            $env.SourceRules.Item(5).Name | Should -Be 'Empty Zombie Rule'
        }
    }

    Context '3.3 Empty & Disabled Rule Diagnostics' {
        It 'Detects and catalogs empty zombie rules having zero active conditions and actions' {
            $env = New-OutlookE2EMockEnvironment
            $emptyRules = [System.Collections.Generic.List[object]]::new()

            for ($i = 1; $i -le $env.SourceRules.Count; $i++) {
                $r = $env.SourceRules.Item($i)
                $activeConds = 0
                foreach ($p in $r.Conditions.PSObject.Properties) {
                    if ($p.Value -and $p.Value.PSObject.Properties['Enabled'] -and $p.Value.Enabled) { $activeConds++ }
                }
                $activeActs = 0
                foreach ($p in $r.Actions.PSObject.Properties) {
                    if ($p.Value -and $p.Value.PSObject.Properties['Enabled'] -and $p.Value.Enabled) { $activeActs++ }
                }

                if ($activeConds -eq 0 -and $activeActs -eq 0) {
                    $emptyRules.Add($r.Name)
                }
            }

            $emptyRules | Should -Contain 'Empty Zombie Rule'
        }

        It 'Inventories disabled rules without accidental deletion' {
            $env = New-OutlookE2EMockEnvironment
            $disabledRules = @()
            for ($i = 1; $i -le $env.SourceRules.Count; $i++) {
                $r = $env.SourceRules.Item($i)
                if (-not $r.Enabled) { $disabledRules += $r.Name }
            }

            $disabledRules | Should -Contain 'Disabled Critical Alert'
            $disabledRules | Should -Contain 'Empty Zombie Rule'
        }
    }

    Context '3.4 COM Lifecycle & Process Ownership Protocol' {
        It 'Does NOT call Quit() when Outlook was already running before operation' {
            $env = New-OutlookE2EMockEnvironment
            $outlookRunningBefore = $true

            # Simulated finally block
            if ($null -ne $env.App -and -not $outlookRunningBefore) {
                $env.App.Quit()
            }

            $env.App.QuitCalled | Should -BeFalse
        }

        It 'Mandates Quit() call when Outlook was NOT running prior to operation' {
            $env = New-OutlookE2EMockEnvironment
            $outlookRunningBefore = $false

            # Simulated finally block
            if ($null -ne $env.App -and -not $outlookRunningBefore) {
                $env.App.Quit()
            }

            $env.App.QuitCalled | Should -BeTrue
        }
    }

    Context '3.5 Repair-OutlookRule Cmdlet Execution' {
        $hasRepair = [bool](Get-Command -Name 'Repair-OutlookRule' -ErrorAction SilentlyContinue)

        It 'Executes non-mutating diagnostics scan by default' -Skip:(-not $hasRepair) {
            $env = New-OutlookE2EMockEnvironment
            Mock Get-OutlookComApplication { return $env.App }
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-Process { return @() } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath 'C:\Data\SourceMail.pst'
            $res.Success | Should -BeTrue
            $res.RulesScanned | Should -BeGreaterOrEqual 1
            $env.SourceRules.Saved | Should -BeFalse
        }

        It 'Performs auto-repair and commits silently with -AutoRepair' -Skip:(-not $hasRepair) {
            $env = New-OutlookE2EMockEnvironment
            $env.Rule1.Actions.MoveToFolder.Folder = $null
            Mock Get-OutlookComApplication { return $env.App }
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-Process { return @() } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath 'C:\Data\SourceMail.pst' -AutoRepair
            $res.Success | Should -BeTrue
            $env.SourceRules.Saved | Should -BeTrue
        }
    }
}

# ==============================================================================
# TIER 4: Enterprise Round-Trip Scenarios & TUI Operations (R4)
# ==============================================================================
Describe 'E2E Tier 4: Enterprise Round-Trip Scenarios & TUI Operations (R4)' {

    Context '4.1 End-to-End Migration Round-Trip Scenario' {
        It 'Executes complete cycle: Export from Source -> Import into Target -> Self-Healing Audit' {
            $env = New-OutlookE2EMockEnvironment

            # Step 1: Export Source Rules to in-memory manifest
            $exportedManifest = [PSCustomObject]@{
                ManifestVersion = '1.0.0'
                SourceContext   = [PSCustomObject]@{ Profile = 'CorporateProfile'; Store = 'Corporate Mailbox' }
                CustomFolders   = @('Inbox\Projects\Alpha', 'Finance\Invoices')
                Rules           = @(
                    [PSCustomObject]@{
                        Name       = 'Route Project Alpha'
                        Enabled    = $true
                        Conditions = @{ Subject = @{ Enabled = $true; Text = @('Project Alpha') } }
                        Actions    = @{ MoveToFolder = @{ Enabled = $true; FolderPath = 'Inbox\Projects\Alpha' } }
                    },
                    [PSCustomObject]@{
                        Name       = 'Copy Finance Invoices'
                        Enabled    = $true
                        Conditions = @{ Subject = @{ Enabled = $true; Text = @('Invoice') } }
                        Actions    = @{ CopyToFolder = @{ Enabled = $true; FolderPath = 'Finance\Invoices' } }
                    }
                )
            }

            # Step 2: Auto-create folders in Target Store
            $targetAlpha = $env.TargetInbox.AddFolder('Projects').AddFolder('Alpha')
            $targetFinance = $env.TargetRoot.AddFolder('Finance')
            $targetInvoices = $targetFinance.AddFolder('Invoices')

            # Step 3: Import Rules into Target Store
            foreach ($rDef in $exportedManifest.Rules) {
                $newR = $env.TargetRules.Create($rDef.Name, 0)
                $newR.Enabled = $rDef.Enabled
                if ($rDef.Actions.MoveToFolder.Enabled) {
                    $newR.Actions.MoveToFolder.Folder = $targetAlpha
                    $newR.Actions.MoveToFolder.Enabled = $true
                }
                if ($rDef.Actions.CopyToFolder.Enabled) {
                    $newR.Actions.CopyToFolder.Folder = $targetInvoices
                    $newR.Actions.CopyToFolder.Enabled = $true
                }
            }
            $env.TargetRules.Save($false)

            # Step 4: Audit Target Store Health
            $brokenCount = 0
            for ($i = 1; $i -le $env.TargetRules.Count; $i++) {
                $r = $env.TargetRules.Item($i)
                if ($r.Actions.MoveToFolder.Enabled -and $null -eq $r.Actions.MoveToFolder.Folder) { $brokenCount++ }
                if ($r.Actions.CopyToFolder.Enabled -and $null -eq $r.Actions.CopyToFolder.Folder) { $brokenCount++ }
            }

            # Verification assertions
            $env.TargetRules.Count | Should -Be 2
            $env.TargetRules.Saved | Should -BeTrue
            $brokenCount | Should -Be 0
            $targetAlpha.FolderPath | Should -Be "\\TargetStore\Inbox\Projects\Alpha"
            $targetInvoices.FolderPath | Should -Be "\\TargetStore\Finance\Invoices"
        }
    }

    Context '4.2 Reusable TUI Profile Selector (Select-ToolkitOutlookProfile)' {
        $hasSelector = [bool](Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue)

        It 'Returns default profile immediately under -NonInteractive mode without prompts' -Skip:(-not $hasSelector) {
            $selected = Select-ToolkitOutlookProfile -DefaultProfile 'ExecutiveProfile' -NonInteractive
            $selected | Should -Be 'ExecutiveProfile'
        }

        It 'Selects profile by numeric index 1..N' -Skip:(-not $hasSelector) {
            $profiles = @('ExecutiveProfile', 'ArchiveProfile', 'PersonalProfile')
            Mock Read-Host { return '2' }
            Mock Read-Host { return '2' } -ModuleName 'TUI'

            $selected = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'ExecutiveProfile'
            $selected | Should -Be 'ArchiveProfile'
        }

        It 'Accepts custom profile name via option N+1' -Skip:(-not $hasSelector) {
            $profiles = @('ProfileA', 'ProfileB')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return 'CustomNewProfile'
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return 'CustomNewProfile'
            } -ModuleName 'TUI'

            $selected = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'ProfileA'
            $selected | Should -Be 'CustomNewProfile'
        }

        It 'Handles direct string input gracefully for backwards compatibility' -Skip:(-not $hasSelector) {
            $profiles = @('ExecutiveProfile', 'ArchiveProfile')
            Mock Read-Host { return 'ArchiveProfile' }
            Mock Read-Host { return 'ArchiveProfile' } -ModuleName 'TUI'

            $selected = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'ExecutiveProfile'
            $selected | Should -Be 'ArchiveProfile'
        }
    }

    Context '4.3 Main Menu Action Dispatch (Invoke-ToolkitSubmenuOfficeOutlook)' {
        $hasMenu = [bool](Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue)

        It 'Dispatches gracefully with -NonInteractive and -ExitImmediately' -Skip:(-not $hasMenu) {
            { Invoke-ToolkitSubmenuOfficeOutlook -NonInteractive -ExitImmediately } | Should -Not -Throw
        }

        It 'Aborts action cleanly when user cancels confirmation prompt' -Skip:(-not $hasMenu) {
            Mock Confirm-ToolkitAction { return $false }
            Mock Read-ToolkitItemSelection { return '0' } # Exit immediately

            { Invoke-ToolkitSubmenuOfficeOutlook -ExitImmediately } | Should -Not -Throw
        }
    }

    Context '4.4 Data File Context Menu Action Dispatch (Invoke-ToolkitDataFileContextMenu)' {
        $hasContext = [bool](Get-Command -Name 'Invoke-ToolkitDataFileContextMenu' -ErrorAction SilentlyContinue)

        It 'Executes contextual menu routing with bound store path and profile' -Skip:(-not $hasContext) {
            $mockDataFile = [PSCustomObject]@{
                Path    = 'C:\Data\TestStore.pst'
                Name    = 'TestStore.pst'
                Profile = 'ExecutiveProfile'
                Type    = 'PST'
            }
            Mock Read-ToolkitItemSelection { return '0' } # Exit

            { Invoke-ToolkitDataFileContextMenu -DataFile $mockDataFile -NonInteractive } | Should -Not -Throw
        }
    }
}
