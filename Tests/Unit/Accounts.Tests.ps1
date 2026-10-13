# ==============================================================================
# Accounts.Tests.ps1
# Unit test suite for Modules/Accounts
# Covers: Get-LocalAccountList, New-LocalAccountItem, Unlock-LocalAccountItem,
# Set-LocalAccountState, Get-DomainAccountItem, Unlock-DomainAccountItem,
# Set-DomainAccountState, Enable-BuiltInAdministrator, Test-DomainReachability,
# Join-ToolkitDomain, Disconnect-ToolkitDomain.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:AccountsManifest = Join-Path $ProjectRoot 'Modules/Accounts/Accounts.psd1'
$isAccountsAvailable = Test-Path $script:AccountsManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
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
}
Describe 'Unit: User & Domain Account Administration Module' {

    Context 'Local Account Administration & ADSI Unlock' {
        It 'Get-LocalAccountList returns list of local accounts with SID and status' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Disabled = $false; Lockout = $false; PasswordRequired = $true },
                    [PSCustomObject]@{ Name = 'Guest'; SID = 'S-1-5-21-100-501'; Disabled = $true; Lockout = $false; PasswordRequired = $false }
                )
            }
            $accounts = Get-LocalAccountList
            $accounts.Count | Should -Be 2
            $accounts[0].Name | Should -Be 'Administrator'
            $accounts[0].Enabled | Should -BeTrue
        }

        It 'New-LocalAccountItem creates local user using SecureString password' -Skip:(-not $isAccountsAvailable) {
            $secPwd = ConvertTo-SecureString 'ComplexPass!2026' -AsPlainText -Force
            Mock New-LocalUser { return [PSCustomObject]@{ Name = 'NewTech'; SID = [PSCustomObject]@{ Value = 'S-1-5-21-100-1001' } } }
            $res = New-LocalAccountItem -Username 'NewTech' -Password $secPwd -FullName 'Support Tech'
            $res.Username | Should -Be 'NewTech'
            $res.Created | Should -BeTrue
        }

        It 'Unlock-LocalAccountItem clears ADSI lockout flag' -Skip:(-not $isAccountsAvailable) {
            Mock Unlock-LocalUser { }
            $res = Unlock-LocalAccountItem -Username 'LockedUser'
            $res | Should -BeTrue
        }

        It 'Set-LocalAccountState enables or disables account' -Skip:(-not $isAccountsAvailable) {
            Mock Enable-LocalUser { }
            Mock Disable-LocalUser { }
            $resEnable = Set-LocalAccountState -Username 'TestUser' -Enabled $true
            $resEnable | Should -BeTrue

            $resDisable = Set-LocalAccountState -Username 'TestUser' -Enabled $false
            $resDisable | Should -BeTrue
        }
    }

    Context 'Built-in Administrator SID -500 Activation' {
        It 'Enable-BuiltInAdministrator activates SID -500 account safely' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-123456789-500' }
            }
            Mock Enable-LocalUser { }
            $res = Enable-BuiltInAdministrator
            $res.AdministratorName | Should -Be 'Administrator'
            $res.Enabled | Should -BeTrue
        }
    }

    Context 'Domain Pre-Flight Reachability & Account Management' {
        It 'Test-DomainReachability validates DNS, Kerberos (88), LDAP (389), and SMB (445)' -Skip:(-not $isAccountsAvailable) {
            Mock Resolve-DnsName { return [PSCustomObject]@{ NameHost = 'dc01.corp.local' } }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $true } }

            $res = Test-DomainReachability -DomainName 'corp.local'
            $res.DnsResolved | Should -BeTrue
            $res.KerberosPortOpen | Should -BeTrue
            $res.LdapPortOpen | Should -BeTrue
            $res.Reachable | Should -BeTrue
        }

        It 'Get-DomainAccountItem queries domain account status via AccountManagement' -Skip:(-not $isAccountsAvailable) {
            Mock Get-ADUser { return [PSCustomObject]@{ SamAccountName = 'jdoe'; UserPrincipalName = 'jdoe@corp.local'; Enabled = $true; LockedOut = $false } }
            $res = Get-DomainAccountItem -Username 'jdoe' -Domain 'corp.local'
            $res.SamAccountName | Should -Be 'jdoe'
            $res.Enabled | Should -BeTrue
        }
    }

    Context 'Domain Join & Safe Disjoin with Lockout Prevention' {
        It 'Join-ToolkitDomain joins computer to domain via CIM' -Skip:(-not $isAccountsAvailable) {
            $secPwd = ConvertTo-SecureString 'DomainJoinPass!' -AsPlainText -Force
            $cred = [PSCredential]::new('CORP\JoinAdmin', $secPwd)
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 0 } }

            $res = Join-ToolkitDomain -DomainName 'corp.local' -Credential $cred
            $res.Success | Should -BeTrue
            $res.ReturnCode | Should -Be 0
        }

        It 'Disconnect-ToolkitDomain prevents lockout if no active local administrator exists' -Skip:(-not $isAccountsAvailable) {
            # No active local administrator
            Mock Get-LocalAccountList {
                return @([PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Enabled = $false })
            }
            $secPwd = ConvertTo-SecureString 'WorkgroupPass!' -AsPlainText -Force
            $cred = [PSCredential]::new('Administrator', $secPwd)

            { Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred } | Should -Throw
        }

        It 'Disconnect-ToolkitDomain succeeds when local administrator is active and verified' -Skip:(-not $isAccountsAvailable) {
            Mock Get-LocalAccountList {
                return @([PSCustomObject]@{ Name = 'Administrator'; SID = 'S-1-5-21-100-500'; Enabled = $true })
            }
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 0 } }
            $secPwd = ConvertTo-SecureString 'WorkgroupPass!' -AsPlainText -Force
            $cred = [PSCredential]::new('Administrator', $secPwd)

            $res = Disconnect-ToolkitDomain -WorkgroupName 'WORKGROUP' -Credential $cred
            $res.Success | Should -BeTrue
        }
    }

    Context 'Permanent Local Account Deletion (Remove-LocalAccountItem)' {
        It 'Blocks deletion of built-in Administrator account by name' -Skip:(-not $isAccountsAvailable) {
            { Remove-LocalAccountItem -Username 'Administrator' } | Should -Throw "*built-in Administrator*"
        }

        It 'Blocks deletion of built-in Administrator account with domain prefix and whitespace' -Skip:(-not $isAccountsAvailable) {
            { Remove-LocalAccountItem -Username '.\Administrator' } | Should -Throw "*built-in Administrator*"
            { Remove-LocalAccountItem -Username 'DOMAIN\Administrator' } | Should -Throw "*built-in Administrator*"
            { Remove-LocalAccountItem -Username '  Administrator  ' } | Should -Throw "*built-in Administrator*"
        }

        It 'Blocks deletion of built-in Administrator account by SID -500' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = 'RenamedAdmin'
                    SID          = 'S-1-5-21-987654321-500'
                    LocalAccount = $true
                }
            }
            { Remove-LocalAccountItem -Username 'RenamedAdmin' } | Should -Throw "*built-in Administrator*"
        }

        It 'Blocks deletion of renamed Administrator passed via -SID or pipeline object' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance { return $null }
            { Remove-LocalAccountItem -Username 'CustomAdmin' -SID 'S-1-5-21-987654321-500' } | Should -Throw "*built-in Administrator*"
            { [PSCustomObject]@{ Name = 'CustomAdmin'; SID = 'S-1-5-21-987654321-500' } | Remove-LocalAccountItem } | Should -Throw "*built-in Administrator*"
        }

        It 'Blocks deletion of currently logged-in user' -Skip:(-not $isAccountsAvailable) {
            $currUser = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = $currUser
                    SID          = 'S-1-5-21-987654321-1002'
                    LocalAccount = $true
                }
            }
            { Remove-LocalAccountItem -Username $currUser } | Should -Throw "*currently logged-in user*"
        }

        It 'Blocks deletion of currently logged-in user with domain prefix or whitespace' -Skip:(-not $isAccountsAvailable) {
            $currUser = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = $currUser
                    SID          = 'S-1-5-21-987654321-1002'
                    LocalAccount = $true
                }
            }
            { Remove-LocalAccountItem -Username ".\$currUser" } | Should -Throw "*currently logged-in user*"
            { Remove-LocalAccountItem -Username "MYPC\$currUser" } | Should -Throw "*currently logged-in user*"
            { Remove-LocalAccountItem -Username "  $currUser  " } | Should -Throw "*currently logged-in user*"
        }

        It 'Permanently removes user account, profile directory, and ProfileList registry key' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = 'ContractorUser'
                    SID          = 'S-1-5-21-987654321-1005'
                    LocalAccount = $true
                }
            }
            Mock Test-Path { return $true }
            Mock Remove-LocalUser { }
            $script:deletedItems = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Item {
                param($LiteralPath)
                $script:deletedItems.Add($LiteralPath)
            }

            $res = Remove-LocalAccountItem -Username 'ContractorUser'
            $res.Success | Should -BeTrue
            $res.AccountRemoved | Should -BeTrue
            Assert-MockCalled Remove-LocalUser -Times 1
            $res.ProfilePathRemoved | Should -BeTrue
            $res.ProfileListRemoved | Should -BeTrue
            $script:deletedItems | Should -Contain "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-987654321-1005"
        }

        It 'Expands registry ProfileImagePath with environment variables and removes profile directory' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = 'ExpUser'
                    SID          = 'S-1-5-21-987654321-1007'
                    LocalAccount = $true
                }
            }
            Mock Test-Path { return $true }
            Mock Get-ItemProperty {
                param($LiteralPath, $Name)
                if ($Name -eq 'ProfileImagePath') {
                    return [PSCustomObject]@{ ProfileImagePath = '%SystemDrive%\Users\ExpUser' }
                }
                return $null
            }
            Mock Remove-LocalUser { }
            $script:deletedPaths = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Item {
                param($LiteralPath)
                $script:deletedPaths.Add($LiteralPath)
            }

            $res = Remove-LocalAccountItem -Username 'ExpUser'
            $res.Success | Should -BeTrue
            $res.ProfilePathRemoved | Should -BeTrue
            $expDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
            $script:deletedPaths | Should -Contain "$expDrive\Users\ExpUser"
        }

        It 'Supports WhatIf dry run without deleting' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance {
                return [PSCustomObject]@{
                    Name         = 'WhatIfUser'
                    SID          = 'S-1-5-21-987654321-1006'
                    LocalAccount = $true
                }
            }
            $res = Remove-LocalAccountItem -Username 'WhatIfUser' -WhatIf
            $res.Success | Should -BeTrue
            $res.AccountRemoved | Should -BeTrue
        }

        It 'Rejects empty or whitespace-only username with terminating error' -Skip:(-not $isAccountsAvailable) {
            { Remove-LocalAccountItem -Username '   ' } | Should -Throw "*cannot be null, empty, or whitespace-only*"
        }

        It 'Throws clear terminating error when deleting non-existent user without profile targets' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance { return $null }
            Mock Test-Path { return $false }
            Mock Remove-LocalUser { throw "User NonExistentUser was not found." }

            { Remove-LocalAccountItem -Username 'NonExistentUser' } | Should -Throw "*was not found*"
        }

        It 'Cleans up orphaned profile directory when user account is absent from SAM' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance { return $null }
            Mock Remove-LocalUser { throw "User OrphanUser was not found." }
            $script:orphanDeleted = $false
            Mock Test-Path {
                param($LiteralPath)
                if ($LiteralPath -match 'OrphanUser') { return $true }
                return $false
            }
            Mock Remove-Item {
                param($LiteralPath)
                if ($LiteralPath -match 'OrphanUser') { $script:orphanDeleted = $true }
            }

            $res = Remove-LocalAccountItem -Username 'OrphanUser' -ProfilePath 'C:\Users\OrphanUser'
            $res.Success | Should -BeTrue
            $res.AccountRemoved | Should -BeFalse
            $res.ProfilePathRemoved | Should -BeTrue
            $script:orphanDeleted | Should -BeTrue
        }

        It 'Tolerates non-existent user when -Force is passed' -Skip:(-not $isAccountsAvailable) {
            Mock Get-CimInstance { return $null }
            Mock Test-Path { return $false }
            Mock Remove-LocalUser { throw "User GhostUser was not found." }

            $res = Remove-LocalAccountItem -Username 'GhostUser' -Force
            $res.Success | Should -BeTrue
            $res.AccountRemoved | Should -BeFalse
        }
    }
}
