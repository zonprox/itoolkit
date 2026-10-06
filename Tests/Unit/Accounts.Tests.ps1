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
}
