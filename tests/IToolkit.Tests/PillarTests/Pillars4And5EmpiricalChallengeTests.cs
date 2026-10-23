namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Software;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge test suite for Pillar 4 (Identity &amp; Backup) and Pillar 5 (Software &amp; Optimization).
/// Adversarially stress-tests SID-500 Admin translation, active user protection, zero-RSAT domain checks,
/// domain disjoin lockout defense, AppInstaller catalog and cleanup, and Debloat pre-flight validation.
/// </summary>
public class Pillars4And5EmpiricalChallengeTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly ResourceGuard _resourceGuard;
    private readonly ProcessLockGuard _lockGuard;
    private readonly IdentityService _identityService;
    private readonly BackupService _backupService;
    private readonly AppInstallerService _appInstaller;
    private readonly OptimizationService _optimizationService;

    public Pillars4And5EmpiricalChallengeTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _wmi = new MockWmiService();
        _resourceGuard = new ResourceGuard(_fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _identityService = new IdentityService(_processRunner, _fileSystem, _registry, _network, _wmi);
        _backupService = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard);
        _appInstaller = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, _network);
        _optimizationService = new OptimizationService(_processRunner, _fileSystem, _network);
    }

    #region Pillar 4: SID-500 Admin & Active User Protection

    [Theory]
    [InlineData("Administrateur", "S-1-5-21-111-222-333-500")] // French
    [InlineData("Administrador", "S-1-5-21-444-555-666-500")]  // Spanish / Portuguese
    [InlineData("Administrator", "S-1-5-21-777-888-999-500")]  // English / German
    [InlineData("DomainSuperAdmin", "S-1-5-21-100-200-300-500")] // Renamed Built-in Admin
    public void Sid500Admin_LanguageAgnostic_LocatesExactNameAndIssuesCorrectCommands(string adminName, string adminSid)
    {
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", adminName }, { "SID", adminSid }, { "Disabled", true }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "StandardUser" }, { "SID", "S-1-5-21-100-200-300-1001" }, { "Disabled", false }, { "Lockout", false } }
        });

        var admin = _identityService.GetBuiltInAdministrator();
        Assert.NotNull(admin);
        Assert.Equal(adminName, admin.Username);
        Assert.Equal(adminSid, admin.Sid);
        Assert.True(admin.IsBuiltInAdmin);

        // Test Enable
        bool enableResult = _identityService.EnableBuiltInAdministrator();
        Assert.True(enableResult);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == $"net.exe user \"{adminName}\" /active:yes");

        // Test Reset Password
        string testPassword = "AdversarialP@ssw0rd!2026";
        bool pwResult = _identityService.ResetBuiltInAdministratorPassword(testPassword);
        Assert.True(pwResult);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == $"net.exe user \"{adminName}\" \"{testPassword}\"");
    }

    [Fact]
    public void Sid500Admin_NetUserFallback_ParsesTableWhenWmiUnavailable()
    {
        var identityWithoutWmi = new IdentityService(_processRunner, _fileSystem, _registry, _network, wmi: null);

        string netUserOutput =
            "User accounts for \\\\TEST-PC\r\n" +
            "-------------------------------------------------------------------------------\r\n" +
            "Administrator            Guest                    DefaultAccount\r\n" +
            "WDAGUtilityAccount       TechEngineer             \r\n" +
            "The command completed successfully.\r\n";

        _processRunner.SetCommandResult("net.exe user", new ProcessExecutionResult(0, netUserOutput, string.Empty, false));

        var accounts = identityWithoutWmi.GetLocalAccounts();

        Assert.True(accounts.Count >= 5);
        Assert.Contains(accounts, a => a.Username == "Administrator" && a.IsBuiltInAdmin && a.Sid.EndsWith("-500"));
        Assert.Contains(accounts, a => a.Username == "TechEngineer" && !a.IsBuiltInAdmin);
    }

    [Theory]
    [InlineData("Administrator", null)]
    [InlineData("administrator", null)]
    [InlineData("ADMINISTRATOR", null)]
    [InlineData("CustomAdmin", "S-1-5-21-999-500")]
    [InlineData("RenamedAdmin", "S-1-5-32-500")]
    public void RemoveLocalAccount_Guardrail1_BlocksSid500OrAdminDeletion(string username, string? sid)
    {
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(username, sid));

        Assert.Contains("Safety Guardrail Violation: Cannot delete the built-in Administrator account", ex.Message);
    }

    [Fact]
    public void RemoveLocalAccount_Guardrail2_BlocksActiveUserDeletion_AcrossPrefixAndCaseVariations()
    {
        string currentUser = Environment.UserName;

        // Exact match
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(currentUser));

        // Case variations
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(currentUser.ToUpperInvariant()));
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(currentUser.ToLowerInvariant()));

        // Domain / Machine prefixed
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount($@"WORKGROUP\{currentUser}"));
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount($@".\{currentUser}"));
        Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount($@"CORP\{currentUser}"));
    }

    [Fact]
    public void RemoveLocalAccount_ValidTarget_ExecutesSamDelete_RemovesProfile_AndPurgesRegistryKey()
    {
        string targetUser = "Contractor99";
        string targetSid = "S-1-5-21-999-1099";
        string profileDir = $@"C:\Users\{targetUser}";
        _fileSystem.CreateDirectory(profileDir);
        _fileSystem.WriteAllText(Path.Combine(profileDir, "NTUSER.DAT"), "data");

        string profileListKey = $@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{targetSid}";
        _registry.CreateKey(profileListKey);
        _registry.SetValue(profileListKey, "ProfileImagePath", profileDir, RegistryValueKind.String);

        bool success = _identityService.RemoveLocalAccount(targetUser, targetSid);

        Assert.True(success);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == $"net.exe user \"{targetUser}\" /delete");
        Assert.False(_fileSystem.DirectoryExists(profileDir));
        Assert.False(_registry.KeyExists(profileListKey));
    }

    #endregion

    #region Pillar 4: Zero-RSAT Domain Management

    [Theory]
    [InlineData(true, true, true, true, true)]    // All healthy
    [InlineData(true, true, true, false, true)]   // SMB blocked, but Kerb+LDAP up -> Reachable
    [InlineData(false, true, true, true, false)]  // DNS fails -> Unreachable
    [InlineData(true, false, true, true, false)]  // Kerberos 88 fails -> Unreachable
    [InlineData(true, true, false, true, false)]  // LDAP 389 fails -> Unreachable
    [InlineData(false, false, false, false, false)] // All offline -> Unreachable
    public void TestDomainReachability_MatrixVerification(bool dns, bool kerb, bool ldap, bool smb, bool expectedReachable)
    {
        string domain = "enterprise.local";
        _network.SetHostReachable(domain, dns);
        _network.SetPortOpen(domain, 88, kerb);
        _network.SetPortOpen(domain, 389, ldap);
        _network.SetPortOpen(domain, 445, smb);

        var result = _identityService.TestDomainReachability(domain);

        Assert.Equal(expectedReachable, result.IsReachable);
        Assert.Equal(dns, result.DnsResolved);
        Assert.Equal(kerb, result.KerberosPortOpen);
        Assert.Equal(ldap, result.LdapPortOpen);
        Assert.Equal(smb, result.SmbPortOpen);
        Assert.Contains(domain, result.DiagnosticsSummary);
    }

    [Fact]
    public void GetDomainUser_ZeroRsat_ParsesLockedAndActiveStates()
    {
        string domain = "corp.contoso.com";
        string lockedUser = "LockedEngineer";

        string netUserDomainOutput =
            "User name                    LockedEngineer\r\n" +
            "Full Name                    Locked Engineer\r\n" +
            "Comment                      \r\n" +
            "User's comment               \r\n" +
            "Country/region code          000 (System Default)\r\n" +
            "Account active               Locked\r\n" +
            "Account expires              Never\r\n" +
            "The command completed successfully.\r\n";

        _processRunner.SetCommandResult($"net.exe user \"{lockedUser}\" /domain",
            new ProcessExecutionResult(0, netUserDomainOutput, string.Empty, false));

        var user = _identityService.GetDomainUser(domain, lockedUser);

        Assert.NotNull(user);
        Assert.Equal(lockedUser, user.SamAccountName);
        Assert.True(user.IsLockedOut, "Account active Locked should be identified");
        Assert.True(user.IsEnabled, "Account is enabled but locked");
    }

    [Fact]
    public void UnlockDomainUser_ExecutesNetUserActiveYesDomain()
    {
        string domain = "corp.contoso.com";
        string user = "LockedEngineer";

        bool result = _identityService.UnlockDomainUser(domain, user);

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == $"net.exe user \"{user}\" /active:yes /domain");
    }

    [Fact]
    public void DisjoinDomain_LockoutDefense_ThrowsWhenNoEnabledLocalAdmin()
    {
        // Scenario 1: Only disabled admin
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", true }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "StandardGuest" }, { "SID", "S-1-5-21-999-1002" }, { "Disabled", false }, { "Lockout", false } }
        });

        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.DisjoinDomain("WORKGROUP"));

        Assert.Contains("CRITICAL LOCKOUT DEFENSE TRIGGERED", ex.Message);
    }

    [Fact]
    public void DisjoinDomain_LockoutDefense_SucceedsWhenEnabledLocalAdminExists()
    {
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?> { { "Name", "LocalSuperAdmin" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", false }, { "Lockout", false } }
        });

        bool success = _identityService.DisjoinDomain("LOCALWG");

        Assert.True(success);
        Assert.Contains(_wmi.ExecutedMethods, m => m == "Win32_ComputerSystem::UnjoinDomainOrWorkgroup");
    }

    #endregion

    #region Pillar 5: AppInstaller 8-Application Catalog & Behavior

    [Fact]
    public void AppInstaller_All8Apps_ConformStrictlyToCatalogStandards()
    {
        var catalog = _appInstaller.GetCatalog();
        Assert.Equal(8, catalog.Count);

        // 4 Non-Winget Apps (WingetId = null)
        var nonWingetApps = new[] { "VCRedistAIO", "UniKey", "UltraVNC", "Zalo" };
        foreach (var id in nonWingetApps)
        {
            var app = catalog.FirstOrDefault(a => a.AppId.Equals(id, StringComparison.OrdinalIgnoreCase));
            Assert.NotNull(app);
            Assert.Null(app.WingetId);
            Assert.True(app.InstallMode == AppInstallMode.DirectOnly || app.InstallMode == AppInstallMode.ArchiveExtract);
            Assert.False(string.IsNullOrWhiteSpace(app.DirectDownloadUrl));
        }

        // 4 Winget-Supported Apps
        var wingetApps = new Dictionary<string, string>
        {
            ["KLiteCodec"] = "CodecGuide.K-LiteCodecPack.Standard",
            ["Chrome"] = "Google.Chrome",
            ["FoxitReader"] = "Foxit.FoxitReader",
            ["WinRAR"] = "RARLab.WinRAR"
        };
        foreach (var (id, expectedWingetId) in wingetApps)
        {
            var app = catalog.FirstOrDefault(a => a.AppId.Equals(id, StringComparison.OrdinalIgnoreCase));
            Assert.NotNull(app);
            Assert.Equal(expectedWingetId, app.WingetId);
            Assert.Equal(AppInstallMode.WingetWithFallback, app.InstallMode);
            Assert.False(string.IsNullOrWhiteSpace(app.DirectDownloadUrl));
        }
    }

    [Theory]
    [InlineData("Chrome", "Google.Chrome")]
    [InlineData("WinRAR", "RARLab.WinRAR")]
    [InlineData("KLiteCodec", "CodecGuide.K-LiteCodecPack.Standard")]
    [InlineData("FoxitReader", "Foxit.FoxitReader")]
    public void InstallApplication_WingetSupported_UsesWingetFirst_WhenAvailable(string appId, string expectedWingetId)
    {
        string cmd = $"winget.exe install --id {expectedWingetId} --silent --accept-package-agreements --accept-source-agreements";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(0, "Winget success", string.Empty, false));

        var result = _appInstaller.InstallApplication(appId);

        Assert.True(result.Success);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == cmd);

        // Verify no direct installer was staged in temp directory
        var tempInstallers = _fileSystem.EnumerateFiles(Path.GetTempPath(), $"*{appId}*");
        Assert.Empty(tempInstallers);
    }

    [Theory]
    [InlineData("Chrome", "Google.Chrome")]
    [InlineData("WinRAR", "RARLab.WinRAR")]
    [InlineData("KLiteCodec", "CodecGuide.K-LiteCodecPack.Standard")]
    [InlineData("FoxitReader", "Foxit.FoxitReader")]
    public void InstallApplication_WingetSupported_FallsBackToDirectDownload_AndCleansTempWhenWingetFails(string appId, string wingetId)
    {
        // Force winget failure
        string wingetCmd = $"winget.exe install --id {wingetId} --silent --accept-package-agreements --accept-source-agreements";
        _processRunner.SetCommandResult(wingetCmd, new ProcessExecutionResult(1, "Winget error", "Failed", false));

        var result = _appInstaller.InstallApplication(appId);

        Assert.True(result.Success);
        Assert.Equal("DirectDownload", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Verify temp files were deleted in finally block
        var tempInstallers = _fileSystem.EnumerateFiles(Path.GetTempPath(), $"*{appId}*");
        Assert.Empty(tempInstallers);
    }

    [Theory]
    [InlineData("VCRedistAIO", "/ai /y")]
    [InlineData("UltraVNC", "/VERYSILENT /NORESTART")]
    [InlineData("Zalo", "/VERYSILENT /NORESTART /S")]
    public void InstallApplication_NonWingetDirect_BypassesWinget_AndCleansTemp(string appId, string expectedSilentArgs)
    {
        var result = _appInstaller.InstallApplication(appId);

        Assert.True(result.Success);
        Assert.Equal("DirectDownload", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Ensure winget was NEVER called
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.StartsWith("winget.exe"));

        // Ensure installer was run with expected silent args
        Assert.Contains(_processRunner.ExecutedCommands, c => c.EndsWith(expectedSilentArgs));

        // Ensure temp file was cleaned up
        var tempFiles = _fileSystem.EnumerateFiles(Path.GetTempPath(), $"*{appId}*");
        Assert.Empty(tempFiles);
    }

    [Fact]
    public void InstallApplication_UniKey_ArchiveExtraction_TerminatesProcesses_AndCleansTempZip()
    {
        _processRunner.AddProcess(101, "UniKeyNT");
        _processRunner.AddProcess(102, "UniKey");

        var result = _appInstaller.InstallApplication("UniKey");

        Assert.True(result.Success);
        Assert.Equal("ArchiveExtract", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Conflicting processes terminated
        Assert.False(_processRunner.IsProcessRunning("UniKeyNT"));
        Assert.False(_processRunner.IsProcessRunning("UniKey"));

        // Temp zip cleaned up
        var tempZips = _fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*.zip");
        Assert.Empty(tempZips);

        // Deployed executable exists
        Assert.True(_fileSystem.FileExists(@"C:\Program Files\UniKey\UniKeyNT.exe"));
    }

    [Theory]
    [InlineData("Chrome,Zalo,VCRedistAIO,UniKey")]
    [InlineData("WinRAR,FoxitReader,VCRedistAIO")]
    [InlineData("VCRedistAIO,KLiteCodec,UltraVNC")]
    public void InstallBatch_AlwaysSequencesVCRedistAIOFirst(string commaSeparatedApps)
    {
        string[] requestedApps = commaSeparatedApps.Split(',');
        var results = _appInstaller.InstallBatch(requestedApps);

        Assert.Equal(requestedApps.Length, results.Count);
        Assert.Equal("VCRedistAIO", results[0].AppId);
    }

    #endregion

    #region Pillar 5: Debloat Tool Pre-Flight Validation

    [Fact]
    public void ExecuteDebloatScript_FailsWhenOffline()
    {
        _network.SetHostReachable("1.1.1.1", false);
        _network.SetHostReachable("github.com", false);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.False(result.SyntaxValid);
        Assert.Contains("No active internet connection", result.Message);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));
    }

    [Theory]
    [InlineData("http://debloat.raphi.re/")]
    [InlineData("ftp://debloat.raphi.re/script.ps1")]
    [InlineData("file://C:/malicious/script.ps1")]
    public void ExecuteDebloatScript_RejectsNonHttpsSchemes(string insecureUrl)
    {
        _network.SetHostReachable("1.1.1.1", true);

        Assert.Throws<SecurityException>(() =>
            _optimizationService.ExecuteDebloatScript("CustomTool", insecureUrl));
    }

    [Theory]
    [InlineData("https://unapproved-domain.org/script.ps1")]
    [InlineData("https://evil-hacker.com/debloat.ps1")]
    [InlineData("https://pastebin.com/raw/12345")]
    public void ExecuteDebloatScript_RejectsNonWhitelistedDomains(string unapprovedUrl)
    {
        _network.SetHostReachable("1.1.1.1", true);

        Assert.Throws<SecurityException>(() =>
            _optimizationService.ExecuteDebloatScript("CustomTool", unapprovedUrl));
    }

    [Theory]
    [InlineData("https://debloat.raphi.re/")]
    [InlineData("https://debloat.yashg.dev/install.ps1")]
    [InlineData("https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Win11Debloat.ps1")]
    [InlineData("https://github.com/Raphire/Win11Debloat/releases/download/v1.0/script.ps1")]
    public void ExecuteDebloatScript_AllowsApprovedWhitelistedDomains_AndCleansTempFile(string approvedUrl)
    {
        _network.SetHostReachable("1.1.1.1", true);

        var result = _optimizationService.ExecuteDebloatScript("Win11Debloat", approvedUrl);

        Assert.True(result.ExecutionSuccess);
        Assert.True(result.SyntaxValid);
        Assert.True(result.TempCleanedUp);

        // Verifies execution parameters: -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (no IEX)
        Assert.Contains(_processRunner.ExecutedCommands, c =>
            c.Contains("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File"));

        // Verifies temp script cleanup
        var leftoverScripts = _fileSystem.EnumerateFiles(Path.GetTempPath(), "iToolKit_Win11Debloat_*.ps1");
        Assert.Empty(leftoverScripts);
    }

    [Fact]
    public void ExecuteDebloatScript_CleansUpTempScript_EvenWhenProcessFails()
    {
        _network.SetHostReachable("1.1.1.1", true);

        // Simulate powershell script execution failure (exit code 1)
        _processRunner.SetCommandResult("powershell.exe", new ProcessExecutionResult(1, string.Empty, "Script threw error", false));

        var result = _optimizationService.LaunchBrowserDebloat();

        Assert.False(result.ExecutionSuccess);
        Assert.True(result.TempCleanedUp);

        var leftoverScripts = _fileSystem.EnumerateFiles(Path.GetTempPath(), "iToolKit_BrowserDebloat_*.ps1");
        Assert.Empty(leftoverScripts);
    }

    #endregion
}
