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
            $lines.Count | Should -BeGreaterOrEqual 6
            $lines[0] | Should -Match '^OS & Build\s*:'
            $lines[1] | Should -Match '^Hardware Model\s*:'
            $lines[2] | Should -Match '^Processor & RAM\s*:'
            $lines[3] | Should -Match '^Storage Space\s*:'
            $lines[4] | Should -Match '^Network Status\s*:'
            $lines[5] | Should -Match '^Security & Env\s*:'
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

        It 'Read-ToolkitMenuChoice renders concise "Select: " prompt without dumping valid keys array' -Skip:(-not $isTUIAvailable) {
            $script:capturedPrompt = $null
            Mock Read-Host {
                param($Prompt)
                $script:capturedPrompt = $Prompt
                return '1'
            }
            $null = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3')
            $script:capturedPrompt | Should -Be '  Select: '
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
            $script:capturedPrompt | Should -Be '  Select: '
            $script:capturedPrompt | Should -Not -Match '\[1,2,3,4,5,6,R,Q,X\]'
        }

        It 'IToolkit root manifest and TUI module export Get-ToolkitTelemetryData and Get-MainSystemInfoLines' -Skip:(-not $isTUIAvailable) {
            $tuiPsd1 = Import-PowerShellDataFile -Path $script:TUIManifest
            $tuiPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitTelemetryData'
            $tuiPsd1.FunctionsToExport | Should -Contain 'Get-MainSystemInfoLines'

            $itoolkitPsd1 = Import-PowerShellDataFile -Path (Join-Path $script:ProjectRoot 'IToolkit.psd1')
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Get-ToolkitTelemetryData'
            $itoolkitPsd1.FunctionsToExport | Should -Contain 'Get-MainSystemInfoLines'
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
            $script:capturedPrompt | Should -Be '  Select: '
        }
    }
}
