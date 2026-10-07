# ==============================================================================
# TUI.Tests.ps1
# Unit test suite for Modules/TUI
# Covers: Show-ToolkitHeader, Show-ToolkitMenuOption, Read-ToolkitMenuChoice,
# Write-ToolkitStatus, Start-IToolkitMenu.
# ==============================================================================

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
$isTUIAvailable = Test-Path $script:TUIManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:ProjectRoot = $root
    $script:TUIManifest = Join-Path $root 'Modules/TUI/TUI.psd1'
    if (-not (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) {
        function global:Write-ToolkitMenuDivider { param([int]$Width = 78) Write-Host ('  ' + ('-' * [math]::Max(20, $Width - 2))) }
    }
    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
    if (-not (Get-Command -Name 'Get-CimInstance' -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName) }
    }
    $tuiMod = Get-Module -Name 'TUI'
    if ($tuiMod) {
        & $tuiMod {
            if (-not (Get-Command -Name 'Get-CimInstance' -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
                function script:Get-CimInstance { param($ClassName) }
            }
        }
    }
}
Describe 'Unit: Interactive Console TUI Menu Module' {

    Context 'Header & Banner Rendering' {
        It 'Show-ToolkitHeader renders banner title and subtitle' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitHeader -Title 'IToolkit Main Menu' -Subtitle 'Enterprise IT Support' } | Should -Not -Throw
        }
    }

    Context 'Menu Options & Choice Reading' {
        It 'Show-ToolkitMenuOption displays menu key and label' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Management' -Status 'OK' } | Should -Not -Throw
        }

        It 'Read-ToolkitMenuChoice accepts valid key choice' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '1' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be '1'
        }

        It 'Read-ToolkitMenuChoice is case-insensitive for exit keys' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'q' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice.ToUpper() | Should -Be 'Q'
        }

        It 'Read-ToolkitMenuChoice returns Default value when input is empty string' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q') -Default 'Q'
            $choice | Should -Be 'Q'
        }

        It 'Read-ToolkitMenuChoice safely handles null/EOF without throwing' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice terminates after max attempts on repeated empty input' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice retries after invalid input and returns subsequent valid choice' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'invalid_choice' }
                return '2'
            }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be '2'
        }
    }

    Context 'Start-IToolkitMenu Execution Modes & Non-Interactive Contract' {
        It 'Start-IToolkitMenu returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -ExitImmediately } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive without MenuOption cleanly' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive with Exit options (Q and X)' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -MenuOption 'Q' -NonInteractive } | Should -Not -Throw
            { Start-IToolkitMenu -MenuOption 'X' -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu lists category options without prompting when -NonInteractive is specified' -Skip:(-not $isTUIAvailable) {
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat -NonInteractive } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on EOF ($null) without infinite looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on empty string input fallback without looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus exit back to caller when Back key (B) is selected' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'B' }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }
    }

    Context 'Submenu Invocations: Non-Interactive & Immediate Exit Contract' {
        It 'Invoke-ToolkitSubmenuOutlook renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuOutlook -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuOutlook returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuOutlook -ExitImmediately } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuOffice renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuOffice -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuOffice returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuOffice -ExitImmediately } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuPrinters renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuPrinters -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuPrinters returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuPrinters -ExitImmediately } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuBackup renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuBackup -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuBackup returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuBackup -ExitImmediately } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuAccounts renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuAccounts -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuAccounts returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuAccounts -ExitImmediately } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuExternalTools renders and terminates cleanly with -NonInteractive' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuExternalTools -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuExternalTools returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Invoke-ToolkitSubmenuExternalTools -ExitImmediately } | Should -Not -Throw
        }
    }

    Context 'Headless Menu Invocation & Telemetry Extraction' {
        It 'Start-IToolkitMenu extracts system telemetry without prompting for user interaction' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { throw "Read-Host should never be invoked in non-interactive headless mode" }
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu extracts category telemetry across all submenus in headless mode' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { throw "Read-Host should never be invoked in non-interactive headless mode" }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat -NonInteractive } | Should -Not -Throw
            }
        }
    }

    Context 'Status Indicators' {
        It 'Write-ToolkitStatus prints OK, WARN, and FAIL indicators' -Skip:(-not $isTUIAvailable) {
            { Write-ToolkitStatus -Message 'Operation succeeded' -Type 'OK' } | Should -Not -Throw
            { Write-ToolkitStatus -Message 'Drive space low' -Type 'WARN' } | Should -Not -Throw
            { Write-ToolkitStatus -Message 'Spooler crashed' -Type 'FAIL' } | Should -Not -Throw
        }
    }

    Context 'Deep Hardware & System Telemetry Collection & UI/UX' {
        It 'Get-MainSystemInfoLines returns formatted array containing all required telemetry sections' -Skip:(-not $isTUIAvailable) {
            $lines = Get-MainSystemInfoLines
            $lines.Count | Should -BeGreaterOrEqual 8
            $lines[0] | Should -Match '^OS & Build\s*:'
            $lines[1] | Should -Match '^Hardware Model\s*:'
            $lines[2] | Should -Match '^Processor & RAM\s*:'
            $lines[3] | Should -Match '^Storage Space\s*:'
            $lines[4] | Should -Match '^Network Status\s*:'
            $lines[5] | Should -Match '^Security & Env\s*:'
            $lines[6] | Should -Match '^User & Host\s*:'
            $lines[7] | Should -Match '^User Profile\s*:'
        }

        It 'Get-ToolkitTelemetryData queries CPU marketing name from Registry' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    ProcessorNameString = '12th Gen Intel(R) Core(TM) i7-12700H'
                }
            } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' } -ModuleName TUI
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    ProcessorNameString = '12th Gen Intel(R) Core(TM) i7-12700H'
                }
            } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' }

            $data = Get-ToolkitTelemetryData
            $data.CPUDisplay | Should -Match '12th Gen Intel\(R\) Core\(TM\) i7-12700H'
        }

        It 'Get-ToolkitTelemetryData reflects physical installed memory in GB correctly' -Skip:(-not $isTUIAvailable) {
            $cimMock = {
                param($ClassName)
                if ($ClassName -eq 'Win32_ComputerSystem') {
                    return [PSCustomObject]@{ TotalPhysicalMemory = 17179869184 }
                }
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    return [PSCustomObject]@{ FreePhysicalMemory = 8388608 }
                }
                return $null
            }
            Mock Get-CimInstance $cimMock -ModuleName TUI
            Mock Get-CimInstance $cimMock

            $data = Get-ToolkitTelemetryData
            $data.RAMDisplay | Should -Match '16(\.0)? GB'
            $data.RAMDisplay | Should -Match '8(\.0)? GB Free'
        }

        It 'Get-ToolkitTelemetryData identifies Windows 11 builds (>= 22000) with UBR and DisplayVersion' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
            $regMock = {
                return [PSCustomObject]@{
                    ProductName        = 'Windows 10 Pro'
                    DisplayVersion     = '23H2'
                    CurrentBuildNumber = '22631'
                    UBR                = 3296
                }
            }
            Mock Get-ItemProperty $regMock -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Get-ItemProperty $regMock -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }

            $data = Get-ToolkitTelemetryData
            $data.OSDisplay | Should -Match 'Windows 11 Pro'
            $data.OSDisplay | Should -Match '23H2'
            $data.OSDisplay | Should -Match '22631\.3296'
        }

        It 'Get-ToolkitTelemetryData preserves Windows 10 for builds below 22000' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
            $regMockWin10 = {
                return [PSCustomObject]@{
                    ProductName        = 'Windows 10 Enterprise'
                    DisplayVersion     = '22H2'
                    CurrentBuildNumber = '19045'
                    UBR                = 4170
                }
            }
            Mock Get-ItemProperty $regMockWin10 -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Get-ItemProperty $regMockWin10 -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }

            $data = Get-ToolkitTelemetryData
            $data.OSDisplay | Should -Match 'Windows 10 Enterprise'
            $data.OSDisplay | Should -Match '22H2'
            $data.OSDisplay | Should -Match '19045\.4170'
        }

        It 'Get-ToolkitTelemetryData queries hardware manufacturer and model from BIOS registry' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
            $biosMock = {
                return [PSCustomObject]@{
                    SystemManufacturer = 'Dell Inc.'
                    SystemProductName  = 'Latitude 7420'
                }
            }
            Mock Get-ItemProperty $biosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Get-ItemProperty $biosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }

            $data = Get-ToolkitTelemetryData
            $data.HardwareDisplay | Should -Be 'Dell Inc. Latitude 7420'
        }

        It 'Get-ToolkitTelemetryData filters virtual adapters and resolves active IPv4' -Skip:(-not $isTUIAvailable) {
            $data = Get-ToolkitTelemetryData
            $data.ActiveIPv4 | Should -Not -BeNullOrEmpty
            $data.ActiveIPv4 | Should -Not -Match '^127\.'
        }

        It 'Get-ToolkitTelemetryData dynamically detects storage based on SystemDrive' -Skip:(-not $isTUIAvailable) {
            $data = Get-ToolkitTelemetryData
            $data.StorageDisplay | Should -Match 'System Drive'
            $data.StorageDisplay | Should -Match 'GB Free'
        }

        It 'Read-ToolkitMenuChoice renders concise "Select" prompt without trailing colon to avoid Read-Host duplicate colon' -Skip:(-not $isTUIAvailable) {
            $script:capturedPrompt = $null
            Mock Read-Host {
                param($Prompt)
                $script:capturedPrompt = $Prompt
                return '1'
            }
            $null = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3')
            $script:capturedPrompt | Should -Be '  Select'
            $script:capturedPrompt | Should -Not -Match '\[1,2,3\]'
        }

        It 'Show-ToolkitHeader preserves width and does not throw on oversized lines' -Skip:(-not $isTUIAvailable) {
            $longLine = "VeryLongKey    : " + ('A' * 200)
            { Show-ToolkitHeader -Title 'Test' -Width 78 -InfoLines @($longLine) } | Should -Not -Throw
        }

        It 'Get-ToolkitTelemetryData preserves Windows Server edition names for builds >= 22000' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
            $regMockServer = {
                return [PSCustomObject]@{
                    ProductName        = 'Windows Server 2025 Standard'
                    DisplayVersion     = '24H2'
                    CurrentBuildNumber = '26100'
                    UBR                = 1742
                }
            }
            Mock Get-ItemProperty $regMockServer -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Get-ItemProperty $regMockServer -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }

            $data = Get-ToolkitTelemetryData
            $data.OSDisplay | Should -Match 'Windows Server 2025 Standard'
            $data.OSDisplay | Should -Not -Match '^Windows 11 Windows Server'
            $data.OSDisplay | Should -Match '26100\.1742'
        }

        It 'Get-ToolkitTelemetryData sanitizes OEM dummy BIOS strings and falls back gracefully' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
            $dummyBiosMock = {
                return [PSCustomObject]@{
                    SystemManufacturer = 'To Be Filled By O.E.M.'
                    SystemProductName  = 'To Be Filled By O.E.M.'
                }
            }
            Mock Get-ItemProperty $dummyBiosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Get-ItemProperty $dummyBiosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }

            $data = Get-ToolkitTelemetryData
            $data.HardwareDisplay | Should -Not -Match 'To Be Filled By O\.E\.M\.'
        }

        It 'Read-ToolkitMenuChoice normalizes legacy verbose prompts with bracketed options to concise Select prompt' -Skip:(-not $isTUIAvailable) {
            $script:capturedPrompt = $null
            Mock Read-Host {
                param($Prompt)
                $script:capturedPrompt = $Prompt
                return '1'
            }
            $null = Read-ToolkitMenuChoice -Prompt 'Select Category [1,2,3,4,5,6,R,Q,X]' -ValidKeys @('1', '2', '3')
            $script:capturedPrompt | Should -Be '  Select'
            $script:capturedPrompt | Should -Not -Match '\[1,2,3,4,5,6,R,Q,X\]'
        }

        It 'IToolkit root manifest and TUI module export telemetry and layout width cmdlets' -Skip:(-not $isTUIAvailable) {
            $tuiPsd1 = Import-PowerShellDataFile -Path $script:TUIManifest
            $tuiPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitTelemetryData'
            $tuiPsd1.FunctionsToExport | Should -Contain 'Get-MainSystemInfoLines'
            $tuiPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitLayoutWidth'
            $tuiPsd1.FunctionsToExport | Should -Contain 'Write-ToolkitMenuDivider'

            $itoolkitPsd1 = Import-PowerShellDataFile -Path (Join-Path $script:ProjectRoot 'IToolkit.psd1')
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitTelemetryData'
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Get-MainSystemInfoLines'
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitLayoutWidth'
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Write-ToolkitMenuDivider'
        }

        It 'Get-ToolkitTelemetryData sanitizes OEM dummy BIOS strings without trailing dot and falls back to BaseBoard' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
            $dummyBiosMock = {
                return [PSCustomObject]@{
                    SystemManufacturer = 'To Be Filled By O.E.M'
                    SystemProductName  = 'To Be Filled By OEM'
                }
            }
            Mock Get-ItemProperty $dummyBiosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Get-ItemProperty $dummyBiosMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }

            $bbMock = {
                return [PSCustomObject]@{
                    Manufacturer = 'ASUSTeK COMPUTER INC.'
                    Product      = 'ROG STRIX B550-F GAMING'
                }
            }
            Mock Get-CimInstance $bbMock -ParameterFilter { $ClassName -eq 'Win32_BaseBoard' } -ModuleName TUI
            Mock Get-CimInstance $bbMock -ParameterFilter { $ClassName -eq 'Win32_BaseBoard' }

            $data = Get-ToolkitTelemetryData
            $data.HardwareDisplay | Should -Not -Match 'To Be Filled By'
            $data.HardwareDisplay | Should -Match 'ASUSTeK COMPUTER INC\. ROG STRIX B550-F GAMING'
        }

        It 'Get-ToolkitTelemetryData handles multi-instance collection from Win32_ComputerSystem for RAM calculation' -Skip:(-not $isTUIAvailable) {
            $multiCsMock = {
                return @(
                    [PSCustomObject]@{ TotalPhysicalMemory = 34359738368 },
                    [PSCustomObject]@{ TotalPhysicalMemory = 34359738368 }
                )
            }
            Mock Get-CimInstance $multiCsMock -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -ModuleName TUI
            Mock Get-CimInstance $multiCsMock -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

            $data = Get-ToolkitTelemetryData
            $data.RAMDisplay | Should -Match '32 GB'
        }

        It 'Get-ToolkitTelemetryData handles zero TotalSize drive gracefully without division by zero' -Skip:(-not $isTUIAvailable) {
            $data = Get-ToolkitTelemetryData
            $data.StorageDisplay | Should -Not -BeNullOrEmpty
            { Show-ToolkitHeader -Title 'Test' -InfoLines @($data.StorageDisplay) } | Should -Not -Throw
        }

        It 'Get-ToolkitTelemetryData handles multi-instance collection from Win32_OperatingSystem for OS and build detection' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $false } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } -ModuleName TUI
            Mock Test-Path { return $false } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
            $multiOsMock = {
                return @(
                    [PSCustomObject]@{ Caption = 'Microsoft Windows 10 Pro'; BuildNumber = '22631'; Version = '10.0.22631.3296' },
                    [PSCustomObject]@{ Caption = 'Microsoft Windows 10 Pro'; BuildNumber = '22631'; Version = '10.0.22631.3296' }
                )
            }
            Mock Get-CimInstance $multiOsMock -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } -ModuleName TUI
            Mock Get-CimInstance $multiOsMock -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }

            $data = Get-ToolkitTelemetryData
            $data.OSDisplay | Should -Match 'Windows 11 Pro'
            $data.OSDisplay | Should -Match '22631\.3296'
        }

        It 'Get-ToolkitTelemetryData deduplicates manufacturer brand prefix when model starts with brand name' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
            $brandMock = {
                return [PSCustomObject]@{
                    SystemManufacturer = 'Dell Inc.'
                    SystemProductName  = 'Dell XPS 15 9520'
                }
            }
            Mock Get-ItemProperty $brandMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Get-ItemProperty $brandMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }

            $data = Get-ToolkitTelemetryData
            $data.HardwareDisplay | Should -Be 'Dell XPS 15 9520'
            $data.HardwareDisplay | Should -Not -Match '^Dell Inc\. Dell'
        }

        It 'Get-ToolkitTelemetryData reads BaseBoard from BIOS registry when SystemManufacturer is dummy' -Skip:(-not $isTUIAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
            $bbRegMock = {
                return [PSCustomObject]@{
                    SystemManufacturer    = 'To Be Filled By O.E.M.'
                    SystemProductName     = 'Default string'
                    BaseBoardManufacturer = 'Micro-Star International Co., Ltd.'
                    BaseBoardProduct      = 'MAG B650 TOMAHAWK WIFI'
                }
            }
            Mock Get-ItemProperty $bbRegMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' } -ModuleName TUI
            Mock Get-ItemProperty $bbRegMock -ParameterFilter { $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }

            $data = Get-ToolkitTelemetryData
            $data.HardwareDisplay | Should -Match 'Micro-Star International Co\., Ltd\. MAG B650 TOMAHAWK WIFI'
        }

        It 'Read-ToolkitMenuChoice normalizes multi-word selection prompt variants to concise Select prompt' -Skip:(-not $isTUIAvailable) {
            $script:capturedPrompt = $null
            Mock Read-Host {
                param($Prompt)
                $script:capturedPrompt = $Prompt
                return '1'
            }
            $null = Read-ToolkitMenuChoice -Prompt 'Select Category or Submenu [1..10]' -ValidKeys @('1', '2')
            $script:capturedPrompt | Should -Be '  Select'
        }

        It 'Read-ToolkitMenuChoice formats Default selection in prompt without duplicate colon' -Skip:(-not $isTUIAvailable) {
            $script:capturedPrompt = $null
            Mock Read-Host {
                param($Prompt)
                $script:capturedPrompt = $Prompt
                return '1'
            }
            $null = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2') -Default '1'
            $script:capturedPrompt | Should -Be '  Select (Default: 1)'
        }

        It 'Show-ToolkitHeader wraps multi-part lines without trimming real data' -Skip:(-not $isTUIAvailable) {
            $longInfo = @("Processor & RAM: AMD Ryzen 7 7800X3D 8-Core Processor (16 Cores) | RAM: 31.1 GB (18.4 GB Free)")
            { Show-ToolkitHeader -Title 'Test' -Width 78 -InfoLines $longInfo } | Should -Not -Throw
        }

        It 'Get-ToolkitLayoutWidth returns safe width bounded by Min and Max' -Skip:(-not $isTUIAvailable) {
            $w = Get-ToolkitLayoutWidth -Default 100 -Min 60 -Max 120
            $w | Should -BeGreaterOrEqual 60
            $w | Should -BeLessOrEqual 120
        }

        It 'Write-ToolkitMenuDivider renders without error' -Skip:(-not $isTUIAvailable) {
            { Write-ToolkitMenuDivider -Width 80 } | Should -Not -Throw
            { Write-ToolkitMenuDivider } | Should -Not -Throw
        }

        It 'Show-ToolkitHeader and Show-ToolkitMenuOption auto-fit window width when Width is not specified' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitHeader -Title 'Auto Fit Test' } | Should -Not -Throw
            { Show-ToolkitMenuOption -Key '1' -Label 'Option with status' -Status 'OK' } | Should -Not -Throw
        }
    }

    Context 'Show-ToolkitItemTable Tabular Display Engine' {
        It 'Renders clean [No items found] box when $Items is empty collection' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitItemTable -Items @() -Columns @('Name', 'Status') } | Should -Not -Throw
            { Show-ToolkitItemTable -Items @() -Columns @('Name', 'Status') -Title 'EMPTY LIST' -Width 60 } | Should -Not -Throw
        }

        It 'Renders clean [No items found] box when $Items is $null' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitItemTable -Items $null -Columns @('Name', 'Status') } | Should -Not -Throw
        }

        It 'Renders table with auto-calculated width when Width is omitted' -Skip:(-not $isTUIAvailable) {
            $testItems = @(
                [PSCustomObject]@{ Name = 'Administrator'; Status = '[ENABLED]'; Role = 'Domain Admin' },
                [PSCustomObject]@{ Name = 'Guest'; Status = '[DISABLED]'; Role = 'Guest User' }
            )
            { Show-ToolkitItemTable -Items $testItems -Columns @('Name', 'Status', 'Role') -Title 'LOCAL ACCOUNTS' } | Should -Not -Throw
        }

        It 'Respects explicit Width parameter and clamps minimum layout width' -Skip:(-not $isTUIAvailable) {
            $testItems = @(
                [PSCustomObject]@{ Item = 'Primary Printer'; Port = '192.168.1.50'; Status = '[READY]' },
                [PSCustomObject]@{ Item = 'Secondary Spooler'; Port = 'USB001'; Status = '[STOPPED]' }
            )
            { Show-ToolkitItemTable -Items $testItems -Columns @('Item', 'Port', 'Status') -Width 80 } | Should -Not -Throw
            { Show-ToolkitItemTable -Items $testItems -Columns @('Item', 'Port', 'Status') -Width 40 } | Should -Not -Throw
            { Show-ToolkitItemTable -Items $testItems -Columns @('Item', 'Port', 'Status') -Width 120 } | Should -Not -Throw
        }

        It 'Formats row indices [1], [2], ... and supports custom Headers mapping' -Skip:(-not $isTUIAvailable) {
            $items = @(
                [PSCustomObject]@{ Name = 'App1'; State = 'Running' },
                [PSCustomObject]@{ Name = 'App2'; State = 'Stopped' },
                [PSCustomObject]@{ Name = 'App3'; State = 'Ready' }
            )
            { Show-ToolkitItemTable -Items $items -Columns @('Name', 'State') -Headers @('APPLICATION', 'CURRENT STATE') } | Should -Not -Throw
        }

        It 'Handles all standardized status badges ([ENABLED], [DISABLED], [LOCKED], [RUNNING], [STOPPED], [READY], [OK], [WARN], [FAIL])' -Skip:(-not $isTUIAvailable) {
            $badgeItems = @(
                [PSCustomObject]@{ Id = '1'; Badge = '[ENABLED]' },
                [PSCustomObject]@{ Id = '2'; Badge = '[DISABLED]' },
                [PSCustomObject]@{ Id = '3'; Badge = '[LOCKED]' },
                [PSCustomObject]@{ Id = '4'; Badge = '[RUNNING]' },
                [PSCustomObject]@{ Id = '5'; Badge = '[STOPPED]' },
                [PSCustomObject]@{ Id = '6'; Badge = '[READY]' },
                [PSCustomObject]@{ Id = '7'; Badge = '[OK]' },
                [PSCustomObject]@{ Id = '8'; Badge = '[WARN]' },
                [PSCustomObject]@{ Id = '9'; Badge = '[FAIL]' },
                [PSCustomObject]@{ Id = '10'; Badge = '[ACTIVE]' },
                [PSCustomObject]@{ Id = '11'; Badge = '[ERROR]' }
            )
            { Show-ToolkitItemTable -Items $badgeItems -Columns @('Id', 'Badge') -Title 'STATUS BADGE MATRIX' } | Should -Not -Throw
        }

        It 'Uses pure ASCII borders (+, -, |) with zero Unicode box characters' -Skip:(-not $isTUIAvailable) {
            $sampleItems = @(
                [PSCustomObject]@{ Component = 'Spooler'; Status = '[READY]' },
                [PSCustomObject]@{ Component = 'RPC'; Status = '[RUNNING]' }
            )
            $tableLines = @(Show-ToolkitItemTable -Items $sampleItems -Columns @('Component', 'Status') -Title 'ASCII TEST' -Width 78 6>&1)

            $tableLines.Count | Should -BeGreaterThan 0
            foreach ($entry in $tableLines) {
                $line = [string]$entry
                $charCodes = [int[]][char[]]$line
                foreach ($c in $charCodes) {
                    $c | Should -BeLessOrEqual 127
                }
                $line | Should -Not -Match '[\u2500-\u257F]'
            }
        }

        It 'Renders items provided as Hashtables as well as PSCustomObjects' -Skip:(-not $isTUIAvailable) {
            $hashItems = @(
                @{ Name = 'Profile1'; DataFile = 'C:\Users\test\mail.ost'; Status = '[READY]' },
                @{ Name = 'Profile2'; DataFile = 'C:\Users\test\archive.pst'; Status = '[DISABLED]' }
            )
            { Show-ToolkitItemTable -Items $hashItems -Columns @('Name', 'DataFile', 'Status') -Title 'HASH ITEMS' } | Should -Not -Throw
        }
    }

    Context 'Read-ToolkitItemSelection Input Parsing & Safeguards' {
        It 'Correctly parses valid numeric integer indices (1..MaxIndex) returning Type Index' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '1' }
            $res1 = Read-ToolkitItemSelection -MaxIndex 5
            $res1.Type | Should -Be 'Index'
            $res1.Value | Should -Be 1

            Mock Read-Host { return '5' }
            $res5 = Read-ToolkitItemSelection -MaxIndex 5
            $res5.Type | Should -Be 'Index'
            $res5.Value | Should -Be 5
        }

        It 'Correctly parses bracketed numeric selection (e.g. [2]) returning Type Index' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '[2]' }
            $res = Read-ToolkitItemSelection -MaxIndex 10
            $res.Type | Should -Be 'Index'
            $res.Value | Should -Be 2
        }

        It 'Correctly parses valid action hotkeys (case-insensitive) returning Type Hotkey' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'b' }
            $resB = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('B', 'R', 'A')
            $resB.Type | Should -Be 'Hotkey'
            $resB.Value | Should -Be 'B'

            Mock Read-Host { return 'R' }
            $resR = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('B', 'R', 'A')
            $resR.Type | Should -Be 'Hotkey'
            $resR.Value | Should -Be 'R'

            Mock Read-Host { return 'a' }
            $resA = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('B', 'R', 'A')
            $resA.Type | Should -Be 'Hotkey'
            $resA.Value | Should -Be 'A'
        }

        It 'Correctly parses standard exit commands (Q, QUIT, EXIT) returning Type Exit' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'q' }
            $resQ = Read-ToolkitItemSelection -MaxIndex 5
            $resQ.Type | Should -Be 'Exit'
            $resQ.Value | Should -Be 'Q'

            Mock Read-Host { return 'quit' }
            $resQuit = Read-ToolkitItemSelection -MaxIndex 5
            $resQuit.Type | Should -Be 'Exit'
            $resQuit.Value | Should -Be 'Q'

            Mock Read-Host { return 'EXIT' }
            $resExit = Read-ToolkitItemSelection -MaxIndex 5
            $resExit.Type | Should -Be 'Exit'
            $resExit.Value | Should -Be 'Q'
        }

        It 'Re-prompts on invalid input and returns subsequent valid choice' -Skip:(-not $isTUIAvailable) {
            $script:attemptNum = 0
            Mock Read-Host {
                $script:attemptNum++
                if ($script:attemptNum -eq 1) { return 'invalid_option' }
                if ($script:attemptNum -eq 2) { return '99' }
                return '3'
            }
            $res = Read-ToolkitItemSelection -MaxIndex 5
            $res.Type | Should -Be 'Index'
            $res.Value | Should -Be 3
            $script:attemptNum | Should -Be 3
        }

        It 'Applies 5-attempt headless safeguard on repeated invalid input and exits safely' -Skip:(-not $isTUIAvailable) {
            $script:loopCount = 0
            Mock Read-Host {
                $script:loopCount++
                return 'invalid_headless_input'
            }
            $res = Read-ToolkitItemSelection -MaxIndex 5
            $res.Type | Should -Be 'Exit'
            $res.Value | Should -Be 'Q'
            $script:loopCount | Should -Be 5
        }

        It 'Clean exit on $null / closed stdin (EOF) immediately without hanging' -Skip:(-not $isTUIAvailable) {
            $script:eofCalls = 0
            Mock Read-Host {
                $script:eofCalls++
                return $null
            }
            $res = Read-ToolkitItemSelection -MaxIndex 10 -ValidHotkeys @('B', 'Q')
            $res.Type | Should -Be 'Exit'
            $res.Value | Should -Be 'Q'
            $script:eofCalls | Should -Be 1
        }
    }

    Context 'Item-Centric Submenu Matrix Non-Interactive & Immediate Exit Verification' {
        $submenus = @(
            @{ Name = 'Accounts'; Command = 'Invoke-ToolkitSubmenuAccounts' },
            @{ Name = 'Printers'; Command = 'Invoke-ToolkitSubmenuPrinters' },
            @{ Name = 'Outlook';  Command = 'Invoke-ToolkitSubmenuOutlook' },
            @{ Name = 'Office';   Command = 'Invoke-ToolkitSubmenuOffice' },
            @{ Name = 'Backup';   Command = 'Invoke-ToolkitSubmenuBackup' }
        )

        It '<Name>: Terminates immediately without processing when -ExitImmediately is passed' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            { & $Command -ExitImmediately } | Should -Not -Throw
        }

        It '<Name>: Renders non-interactively and NEVER calls Read-Host' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            Mock Read-Host { throw "CRITICAL: Read-Host must not be called in non-interactive mode for $Name!" }
            Mock Read-ToolkitMenuChoice { throw "CRITICAL: Read-ToolkitMenuChoice must not be called in non-interactive mode for $Name!" }
            Mock Read-ToolkitItemSelection { throw "CRITICAL: Read-ToolkitItemSelection must not be called in non-interactive mode for $Name!" }

            { & $Command -NonInteractive } | Should -Not -Throw
        }
    }

    Context 'Milestone M3: Submenus Item-Centric Workflow & Routing' {
        It 'Invoke-ToolkitSubmenuPrinters auto-enumerates printers and routes index to contextual menu' -Skip:(-not $isTUIAvailable) {
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{
                        Name         = 'HP-LaserJet-Finance'
                        WorkOffline  = $false
                        PrinterState = 0
                        Status       = 'OK'
                        DriverName   = 'HP Universal Printing PCL 6'
                        PortName     = '192.168.1.100'
                    }
                )
            } -ParameterFilter { $ClassName -eq 'Win32_Printer' }

            $script:selectionCalled = $false
            $script:choiceCalled = $false
            $script:pSelCount = 0

            Mock Read-ToolkitItemSelection {
                $script:pSelCount++
                if ($script:pSelCount -eq 1) {
                    $script:selectionCalled = $true
                    return [PSCustomObject]@{ Type = 'Index'; Value = 1 }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Read-ToolkitMenuChoice {
                $script:choiceCalled = $true
                return 'B'
            }

            { Invoke-ToolkitSubmenuPrinters } | Should -Not -Throw
            $script:selectionCalled | Should -BeTrue
            $script:choiceCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuPrinters handles top-level action hotkey S (Spooler Restart)' -Skip:(-not $isTUIAvailable) {
            $script:spoolerResetCalled = $false
            Mock Reset-PrintSpoolerQueue {
                $script:spoolerResetCalled = $true
            }
            $script:itemSelCount = 0
            Mock Read-ToolkitItemSelection {
                $script:itemSelCount++
                if ($script:itemSelCount -eq 1) {
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = 'S' }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Wait-UserAcknowledge { }

            { Invoke-ToolkitSubmenuPrinters } | Should -Not -Throw
            $script:spoolerResetCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuOutlook auto-enumerates items and routes index to contextual menu' -Skip:(-not $isTUIAvailable) {
            Mock Get-OutlookSystemContext {
                return [PSCustomObject]@{
                    IsRunning      = $false
                    ProcessId      = $null
                    OfficeVersion  = '16.0'
                    DefaultProfile = 'ContosoProfile'
                    Profiles       = @('ContosoProfile')
                    DataFiles      = @()
                }
            }
            Mock Find-OutlookDataFiles {
                return @(
                    [PSCustomObject]@{
                        Path    = 'C:\Mail\archive.pst'
                        Type    = 'PST'
                        Profile = 'ContosoProfile'
                    }
                )
            }

            $script:outlookCtxCalled = $false
            $script:outlookMenuCalled = $false
            $script:oSelCount = 0

            Mock Read-ToolkitItemSelection {
                $script:oSelCount++
                if ($script:oSelCount -eq 1) {
                    $script:outlookCtxCalled = $true
                    return [PSCustomObject]@{ Type = 'Index'; Value = 1 }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Read-ToolkitMenuChoice {
                $script:outlookMenuCalled = $true
                return 'B'
            }

            { Invoke-ToolkitSubmenuOutlook } | Should -Not -Throw
            $script:outlookCtxCalled | Should -BeTrue
            $script:outlookMenuCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuOutlook handles top-level action hotkey E (Expand PST limit)' -Skip:(-not $isTUIAvailable) {
            $script:threshCalled = $false
            Mock Set-OutlookPstThreshold {
                $script:threshCalled = $true
            }
            $script:outSelCount = 0
            Mock Read-ToolkitItemSelection {
                $script:outSelCount++
                if ($script:outSelCount -eq 1) {
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = 'E' }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Wait-UserAcknowledge { }

            { Invoke-ToolkitSubmenuOutlook } | Should -Not -Throw
            $script:threshCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuOffice auto-enumerates installed apps and routes index to contextual menu' -Skip:(-not $isTUIAvailable) {
            Mock Get-Process {
                return @(
                    [PSCustomObject]@{
                        Id   = 4004
                        Name = 'EXCEL'
                    }
                )
            } -ParameterFilter { $Name -eq 'EXCEL' }

            $script:officeSelCalled = $false
            $script:officeCtxCalled = $false
            $script:ofSelCount = 0

            Mock Read-ToolkitItemSelection {
                $script:ofSelCount++
                if ($script:ofSelCount -eq 1) {
                    $script:officeSelCalled = $true
                    return [PSCustomObject]@{ Type = 'Index'; Value = 1 }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Read-ToolkitMenuChoice {
                $script:officeCtxCalled = $true
                return 'B'
            }

            { Invoke-ToolkitSubmenuOffice } | Should -Not -Throw
            $script:officeSelCalled | Should -BeTrue
            $script:officeCtxCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuOffice handles top-level action hotkey C (Clear Temp Cache)' -Skip:(-not $isTUIAvailable) {
            $script:cacheClearCalled = $false
            Mock Clear-OfficeTempCache {
                $script:cacheClearCalled = $true
            }
            $script:offSelCount = 0
            Mock Read-ToolkitItemSelection {
                $script:offSelCount++
                if ($script:offSelCount -eq 1) {
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = 'C' }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Wait-UserAcknowledge { }

            { Invoke-ToolkitSubmenuOffice } | Should -Not -Throw
            $script:cacheClearCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuBackup auto-enumerates backup items and routes index to contextual menu' -Skip:(-not $isTUIAvailable) {
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{
                        ID           = 'VSS-TEST-GUID-001'
                        DeviceObject = '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1'
                    }
                )
            } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }

            $script:backupSelCalled = $false
            $script:backupCtxCalled = $false
            $script:bSelCount = 0

            Mock Read-ToolkitItemSelection {
                $script:bSelCount++
                if ($script:bSelCount -eq 1) {
                    $script:backupSelCalled = $true
                    return [PSCustomObject]@{ Type = 'Index'; Value = 1 }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Read-ToolkitMenuChoice {
                $script:backupCtxCalled = $true
                return 'B'
            }

            { Invoke-ToolkitSubmenuBackup } | Should -Not -Throw
            $script:backupSelCalled | Should -BeTrue
            $script:backupCtxCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuBackup handles top-level action hotkey M (Map Folders)' -Skip:(-not $isTUIAvailable) {
            $script:mapFoldersCalled = $false
            Mock Get-UserProfileDirectoryMap {
                $script:mapFoldersCalled = $true
                return [PSCustomObject]@{ Documents = 'C:\Users\test\Documents' }
            }
            $script:bakSelCount = 0
            Mock Read-ToolkitItemSelection {
                $script:bakSelCount++
                if ($script:bakSelCount -eq 1) {
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = 'M' }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = 'Q' }
            }
            Mock Wait-UserAcknowledge { }

            { Invoke-ToolkitSubmenuBackup } | Should -Not -Throw
            $script:mapFoldersCalled | Should -BeTrue
        }
    }
}
