# ==============================================================================
# ProcessSafePreExecutionGuardsStress.Tests.ps1
# Challenger Stress Test Harness: Process-Safe Pre-Execution Guards & File/Registry Contention
# Milestone 1 - Challenger 2 Empirical Verification
# Covers:
# 1. Process guards in Reset-ExcelDdeSettings, Reset-ExcelResiliency,
#    Reset-PowerPointResiliency, and Clear-OfficeTempCache.
# 2. Zero-mutation guarantees when active processes exist without -Force.
# 3. Proper invocation of Stop-OfficeProcess with -Force.
# 4. Multi-process contention (EXCEL, POWERPNT, WINWORD, OUTLOOK).
# 5. Locked file handling (IOException) and nonexistent directories in Clear-OfficeTempCache.
# 6. Missing registry key and registry contention resilience.
# 7. Composite quick repair cascades under process contention.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:OfficeManifest = Join-Path $ProjectRoot 'Modules/Office/Office.psd1'
$isOfficeAvailable = Test-Path $script:OfficeManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

    # Native command stubs for cross-platform compatibility
    $compatCmds = @('Get-Service', 'Stop-Service', 'Start-Service', 'Set-Service', 'Get-ScheduledTask', 'Unregister-ScheduledTask', 'reg.exe', 'schtasks.exe', 'sc.exe')
    foreach ($cmd in $compatCmds) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
    }

    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    $manifests = Get-ChildItem -Path (Join-Path $root 'Modules') -Filter '*.psd1' -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
}

Describe 'Stress: Process-Safe Pre-Execution Guards & Contention' {

    Context '1. Reset-ExcelDdeSettings Process Guard & Zero Registry Mutation' {
        It 'Emits warning, returns Status Warning, and mutates zero registry keys when EXCEL is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') {
                    return @([PSCustomObject]@{ Id = 1010; ProcessName = 'EXCEL' })
                }
                return @()
            }
            $script:setRegCalled = 0
            Mock Set-ToolkitRegistryValue {
                $script:setRegCalled++
                throw "REGISTRY MUTATION VIOLATION: Set-ToolkitRegistryValue must not be called when active process is detected without -Force"
            }

            $warnList = [System.Collections.Generic.List[string]]::new()
            Mock Write-Warning {
                param($Message)
                $warnList.Add($Message)
            }

            $res = Reset-ExcelDdeSettings
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active EXCEL process detected'
            $res.IgnoreRemoteRequests | Should -BeNullOrEmpty
            $res.Calculation | Should -BeNullOrEmpty
            $res.RegBackupFile | Should -BeNullOrEmpty
            $script:setRegCalled | Should -Be 0
            $warnList.Count | Should -BeGreaterThan 0
            $warnList[0] | Should -Match 'Active EXCEL process detected'
        }

        It 'Invokes Stop-OfficeProcess and executes registry mutations when -Force is specified' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') {
                    return @([PSCustomObject]@{ Id = 1010; ProcessName = 'EXCEL' })
                }
                return @()
            }
            $script:stopOfficeCalled = 0
            $script:stopOfficeArgs = $null
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                $script:stopOfficeCalled++
                $script:stopOfficeArgs = [PSCustomObject]@{
                    ProcessNames   = $ProcessNames
                    Force          = $Force
                    TimeoutSeconds = $TimeoutSeconds
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') }
            }
            $script:setRegCalled = 0
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $script:setRegCalled++
                return [PSCustomObject]@{
                    RegBackupFile = 'C:\Backups\ExcelOptions.reg'
                    KeyPath       = $KeyPath
                    ValueName     = $ValueName
                    Value         = $Value
                }
            }

            $res = Reset-ExcelDdeSettings -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.IgnoreRemoteRequests | Should -Be 0
            $res.Calculation | Should -Be 1
            $res.RegBackupFile | Should -Be 'C:\Backups\ExcelOptions.reg'
            $script:stopOfficeCalled | Should -Be 1
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'EXCEL'
            $script:stopOfficeArgs.Force | Should -BeTrue
            $script:setRegCalled | Should -Be 2
        }

        It 'Gracefully handles registry write failures without unhandled exceptions' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Set-ToolkitRegistryValue {
                throw [System.UnauthorizedAccessException]::new("Access to registry key denied")
            }

            $script:resDde = $null
            { $script:resDde = Reset-ExcelDdeSettings } | Should -Not -Throw
            $script:resDde | Should -Not -BeNullOrEmpty
            $script:resDde.Status | Should -Be 'Success'
            $script:resDde.IgnoreRemoteRequests | Should -Be 0
        }
    }

    Context '2. Reset-ExcelResiliency Process Guard & Zero Property Mutation' {
        It 'Emits warning, returns Status Warning, and removes zero registry properties when EXCEL is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') {
                    return @([PSCustomObject]@{ Id = 2020; ProcessName = 'EXCEL' })
                }
                return @()
            }
            $script:removePropCalled = 0
            Mock Remove-ItemProperty {
                $script:removePropCalled++
                throw "REGISTRY MUTATION VIOLATION: Remove-ItemProperty must not be called when active process is detected without -Force"
            }
            $script:exportBackupCalled = 0
            Mock Export-RegistryKeyBackup {
                $script:exportBackupCalled++
                throw "BACKUP VIOLATION: Export-RegistryKeyBackup should not run on aborted execution"
            }

            $warnList = [System.Collections.Generic.List[string]]::new()
            Mock Write-Warning {
                param($Message)
                $warnList.Add($Message)
            }

            $res = Reset-ExcelResiliency
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active EXCEL process detected'
            $res.ClearedItemsCount | Should -Be 0
            $res.RegBackupFile | Should -BeNullOrEmpty
            $script:removePropCalled | Should -Be 0
            $script:exportBackupCalled | Should -Be 0
            $warnList.Count | Should -BeGreaterThan 0
            $warnList[0] | Should -Match 'Active EXCEL process detected'
        }

        It 'Invokes Stop-OfficeProcess and clears resiliency items when -Force is specified' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') {
                    return @([PSCustomObject]@{ Id = 2020; ProcessName = 'EXCEL' })
                }
                return @()
            }
            $script:stopOfficeCalled = 0
            $script:stopOfficeArgs = $null
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                $script:stopOfficeCalled++
                $script:stopOfficeArgs = [PSCustomObject]@{
                    ProcessNames   = $ProcessNames
                    Force          = $Force
                    TimeoutSeconds = $TimeoutSeconds
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') }
            }
            Mock Test-Path { return $true }
            Mock Get-Item {
                return [PSCustomObject]@{
                    Property = @('CorruptedAddin1', 'CrashingAddin2')
                }
            }
            $script:removedProps = [System.Collections.Generic.List[string]]::new()
            Mock Remove-ItemProperty {
                param($LiteralPath, $Name, $Force)
                $script:removedProps.Add($Name)
            }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\ExcelResiliency.reg' }

            $res = Reset-ExcelResiliency -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.ClearedItemsCount | Should -Be 2
            $res.RegBackupFile | Should -Be 'C:\Backups\ExcelResiliency.reg'
            $script:stopOfficeCalled | Should -Be 1
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'EXCEL'
            $script:stopOfficeArgs.Force | Should -BeTrue
            $script:removedProps | Should -Contain 'CorruptedAddin1'
            $script:removedProps | Should -Contain 'CrashingAddin2'
        }

        It 'Succeeds safely with 0 cleared items when resiliency key does not exist' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $false }
            Mock Export-RegistryKeyBackup { return $null }

            $res = Reset-ExcelResiliency
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.ClearedItemsCount | Should -Be 0
        }
    }

    Context '3. Reset-PowerPointResiliency Process Guard & Zero Property Mutation' {
        It 'Emits warning, returns Status Warning, and mutates zero properties when POWERPNT is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'POWERPNT') {
                    return @([PSCustomObject]@{ Id = 3030; ProcessName = 'POWERPNT' })
                }
                return @()
            }
            $script:removePropCalled = 0
            Mock Remove-ItemProperty {
                $script:removePropCalled++
                throw "REGISTRY MUTATION VIOLATION: Remove-ItemProperty must not be called when active process is detected without -Force"
            }
            $script:exportBackupCalled = 0
            Mock Export-RegistryKeyBackup {
                $script:exportBackupCalled++
                throw "BACKUP VIOLATION: Export-RegistryKeyBackup should not run on aborted execution"
            }

            $warnList = [System.Collections.Generic.List[string]]::new()
            Mock Write-Warning {
                param($Message)
                $warnList.Add($Message)
            }

            $res = Reset-PowerPointResiliency
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active POWERPNT process detected'
            $res.ClearedItems | Should -Be 0
            $res.RegBackupFile | Should -BeNullOrEmpty
            $script:removePropCalled | Should -Be 0
            $script:exportBackupCalled | Should -Be 0
            $warnList.Count | Should -BeGreaterThan 0
            $warnList[0] | Should -Match 'Active POWERPNT process detected'
        }

        It 'Invokes Stop-OfficeProcess and clears resiliency items when -Force is specified' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'POWERPNT') {
                    return @([PSCustomObject]@{ Id = 3030; ProcessName = 'POWERPNT' })
                }
                return @()
            }
            $script:stopOfficeCalled = 0
            $script:stopOfficeArgs = $null
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                $script:stopOfficeCalled++
                $script:stopOfficeArgs = [PSCustomObject]@{
                    ProcessNames   = $ProcessNames
                    Force          = $Force
                    TimeoutSeconds = $TimeoutSeconds
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') }
            }
            Mock Test-Path { return $true }
            Mock Get-Item {
                return [PSCustomObject]@{
                    Property = @('DisabledPptAddinA')
                }
            }
            $script:removedProps = [System.Collections.Generic.List[string]]::new()
            Mock Remove-ItemProperty {
                param($LiteralPath, $Name, $Force)
                $script:removedProps.Add($Name)
            }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PptResiliency.reg' }

            $res = Reset-PowerPointResiliency -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.ClearedItems | Should -Be 1
            $res.RegBackupFile | Should -Be 'C:\Backups\PptResiliency.reg'
            $script:stopOfficeCalled | Should -Be 1
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'POWERPNT'
            $script:stopOfficeArgs.Force | Should -BeTrue
            $script:removedProps | Should -Contain 'DisabledPptAddinA'
        }

        It 'Succeeds safely with 0 cleared items when PowerPoint resiliency key does not exist' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Test-Path { return $false }
            Mock Export-RegistryKeyBackup { return $null }

            $res = Reset-PowerPointResiliency
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.ClearedItems | Should -Be 0
        }
    }

    Context '4. Clear-OfficeTempCache Process Guard Across All 4 Target Office Processes' {
        It 'Aborts with Status Warning and deletes zero files when WINWORD is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'WINWORD') { return @([PSCustomObject]@{ Id = 4001; ProcessName = 'WINWORD' }) }
                return @()
            }
            $script:removeCalled = 0
            Mock Remove-Item {
                $script:removeCalled++
                throw "FILE MUTATION VIOLATION: Remove-Item must not be called when active process is detected without -Force"
            }

            $res = Clear-OfficeTempCache
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'WINWORD'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
            $script:removeCalled | Should -Be 0
        }

        It 'Aborts with Status Warning and deletes zero files when EXCEL is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') { return @([PSCustomObject]@{ Id = 4002; ProcessName = 'EXCEL' }) }
                return @()
            }
            $script:removeCalled = 0
            Mock Remove-Item {
                $script:removeCalled++
                throw "FILE MUTATION VIOLATION: Remove-Item must not be called when active process is detected without -Force"
            }

            $res = Clear-OfficeTempCache
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'EXCEL'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
            $script:removeCalled | Should -Be 0
        }

        It 'Aborts with Status Warning and deletes zero files when POWERPNT is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'POWERPNT') { return @([PSCustomObject]@{ Id = 4003; ProcessName = 'POWERPNT' }) }
                return @()
            }
            $script:removeCalled = 0
            Mock Remove-Item {
                $script:removeCalled++
                throw "FILE MUTATION VIOLATION: Remove-Item must not be called when active process is detected without -Force"
            }

            $res = Clear-OfficeTempCache
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'POWERPNT'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
            $script:removeCalled | Should -Be 0
        }

        It 'Aborts with Status Warning and deletes zero files when OUTLOOK is active without -Force' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'OUTLOOK') { return @([PSCustomObject]@{ Id = 4004; ProcessName = 'OUTLOOK' }) }
                return @()
            }
            $script:removeCalled = 0
            Mock Remove-Item {
                $script:removeCalled++
                throw "FILE MUTATION VIOLATION: Remove-Item must not be called when active process is detected without -Force"
            }

            $res = Clear-OfficeTempCache
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'OUTLOOK'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
            $script:removeCalled | Should -Be 0
        }

        It 'Aborts with Status Warning enumerating all active processes when WINWORD, EXCEL, POWERPNT, and OUTLOOK are all active' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                return @([PSCustomObject]@{ Id = 5000; ProcessName = $Name })
            }
            $script:removeCalled = 0
            Mock Remove-Item {
                $script:removeCalled++
                throw "FILE MUTATION VIOLATION: Remove-Item must not be called when active processes are detected without -Force"
            }

            $res = Clear-OfficeTempCache
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'WINWORD'
            $res.ErrorMessage | Should -Match 'EXCEL'
            $res.ErrorMessage | Should -Match 'POWERPNT'
            $res.ErrorMessage | Should -Match 'OUTLOOK'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
            $script:removeCalled | Should -Be 0
        }

        It 'Invokes Stop-OfficeProcess with all active process names when -Force is supplied' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                param($Name)
                if ($Name -in @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK')) {
                    return @([PSCustomObject]@{ Id = 6000; ProcessName = $Name })
                }
                return @()
            }
            $script:stopOfficeCalled = 0
            $script:stopOfficeArgs = $null
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                $script:stopOfficeCalled++
                $script:stopOfficeArgs = [PSCustomObject]@{
                    ProcessNames   = $ProcessNames
                    Force          = $Force
                    TimeoutSeconds = $TimeoutSeconds
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = $ProcessNames }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\Temp\file1.tmp'; Length = 2048 },
                    [PSCustomObject]@{ FullName = 'C:\Temp\file2.tmp'; Length = 4096 }
                )
            }
            $script:deletedFiles = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Item {
                param($Path, $Force, $Recurse)
                $script:deletedFiles.Add($Path)
            }

            $res = Clear-OfficeTempCache -Force
            $res.Status | Should -Be 'Success'
            $script:stopOfficeCalled | Should -Be 1
            $script:stopOfficeArgs.Force | Should -BeTrue
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'WINWORD'
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'EXCEL'
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'POWERPNT'
            $script:stopOfficeArgs.ProcessNames | Should -Contain 'OUTLOOK'
            $res.CleanedFilesCount | Should -Be 4 # 2 files per each target cache directory (OfficeFileCache + Wef)
            $res.BytesFreed | Should -Be 12288
        }
    }

    Context '5. Clear-OfficeTempCache File Contention & Locked File Resilience' {
        It 'Survives partially locked files without aborting and only tallies successfully deleted files' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\Cache\clean_alpha.dat'; Length = 1000 },
                    [PSCustomObject]@{ FullName = 'C:\Cache\contended_beta.dat'; Length = 2000 },
                    [PSCustomObject]@{ FullName = 'C:\Cache\clean_gamma.dat'; Length = 3000 },
                    [PSCustomObject]@{ FullName = 'C:\Cache\contended_delta.dat'; Length = 4000 }
                )
            }
            Mock Remove-Item {
                param($Path, $Force, $Recurse)
                if ($Path -like '*contended*') {
                    throw [System.IO.IOException]::new("The process cannot access the file '$Path' because it is being used by another process.")
                }
            }

            $res = Clear-OfficeTempCache -IncludeWefCache $false
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            # 2 clean files removed out of 4 total items
            $res.CleanedFilesCount | Should -Be 2
            # Bytes freed: 1000 + 3000 = 4000 bytes
            $res.BytesFreed | Should -Be 4000
        }

        It 'Survives 100% locked directory without throwing, returning 0 count and 0 bytes' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{ FullName = 'C:\Cache\contended_a.dat'; Length = 5000 },
                    [PSCustomObject]@{ FullName = 'C:\Cache\contended_b.dat'; Length = 7000 }
                )
            }
            Mock Remove-Item {
                param($Path, $Force, $Recurse)
                throw [System.IO.IOException]::new("File locked by process")
            }

            $script:resLocked = $null
            { $script:resLocked = Clear-OfficeTempCache -IncludeWefCache $false } | Should -Not -Throw
            $script:resLocked | Should -Not -BeNullOrEmpty
            $script:resLocked.Status | Should -Be 'Success'
            $script:resLocked.CleanedFilesCount | Should -Be 0
            $script:resLocked.BytesFreed | Should -Be 0
        }

        It 'Handles directory items without Length property cleanly without throwing' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Get-ChildItem {
                return @(
                    # A directory item has no Length property
                    [PSCustomObject]@{ FullName = 'C:\Cache\SubDir'; PSIsContainer = $true },
                    [PSCustomObject]@{ FullName = 'C:\Cache\normal_file.dat'; Length = 8192 }
                )
            }
            Mock Remove-Item { }

            $script:resDir = $null
            { $script:resDir = Clear-OfficeTempCache -IncludeWefCache $false } | Should -Not -Throw
            $script:resDir | Should -Not -BeNullOrEmpty
            $script:resDir.Status | Should -Be 'Success'
            $script:resDir.CleanedFilesCount | Should -Be 2
            $script:resDir.BytesFreed | Should -Be 8192
        }
    }

    Context '6. Clear-OfficeTempCache Nonexistent Directories & Environment Fallbacks' {
        It 'Handles completely nonexistent cache directories gracefully' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Get-ChildItem {
                # Nonexistent directory causes Get-ChildItem to return empty/null with SilentlyContinue
                return @()
            }

            $res = Clear-OfficeTempCache
            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }

        It 'Operates safely with zero actions when both IncludeDocumentCache and IncludeWefCache are false' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process { return @() }
            Mock Get-ChildItem { throw "Get-ChildItem should not be called when both cache targets are disabled" }

            $res = Clear-OfficeTempCache -IncludeDocumentCache $false -IncludeWefCache $false
            $res.Status | Should -Be 'Success'
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }

        It 'Falls back to USERPROFILE AppData Local when LOCALAPPDATA environment variable is missing' -Skip:(-not $isOfficeAvailable) {
            $origLocalAppData = $env:LOCALAPPDATA
            $origUserProfile = $env:USERPROFILE
            try {
                $env:LOCALAPPDATA = $null
                $env:USERPROFILE = 'C:\Users\ChallengerTest'

                Mock Get-Process { return @() }
                $searchedPaths = [System.Collections.Generic.List[string]]::new()
                Mock Get-ChildItem {
                    param($Path)
                    $searchedPaths.Add($Path)
                    return @()
                }

                $res = Clear-OfficeTempCache
                $res.Status | Should -Be 'Success'
                $searchedPaths.Count | Should -Be 2
                $normalizedPath = $searchedPaths[0] -replace '\\', '/'
                $normalizedPath | Should -Match 'C:/Users/ChallengerTest/AppData/Local/Microsoft/Office/16\.0/OfficeFileCache'
            }
            finally {
                $env:LOCALAPPDATA = $origLocalAppData
                $env:USERPROFILE = $origUserProfile
            }
        }
    }

    Context '7. Quick App Repairs Cascade Behavior Under Contention' {
        It 'Invoke-WordQuickRepair handles process termination failure gracefully' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess {
                return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Unable to terminate WINWORD' }
            }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }

            $res = Invoke-WordQuickRepair -Force
            $res | Should -Not -BeNullOrEmpty
            # Overall status reports Warning when process termination had warning
            $res.Status | Should -Be 'Warning'
            $res.ProcessStopped.Status | Should -Be 'Warning'
        }

        It 'Invoke-ExcelQuickRepair reports Warning status if DDE or Resiliency reset aborts on process guard' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') } }
            Mock Clear-ExcelStartupFolder { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-ExcelDdeSettings {
                return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Active EXCEL process detected' }
            }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Success' } }

            $res = Invoke-ExcelQuickRepair
            $res.Status | Should -Be 'Warning'
            $res.DdeReset.Status | Should -Be 'Warning'
        }

        It 'Invoke-PowerPointQuickRepair reports Warning status if Resiliency reset encounters warning' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') } }
            Mock Reset-PowerPointCache { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-PowerPointResiliency {
                return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Active POWERPNT process detected' }
            }

            $res = Invoke-PowerPointQuickRepair
            $res.Status | Should -Be 'Warning'
            $res.ResiliencyReset.Status | Should -Be 'Warning'
        }
    }
}
