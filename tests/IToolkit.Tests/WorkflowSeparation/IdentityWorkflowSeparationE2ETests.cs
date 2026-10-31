namespace IToolkit.Tests.WorkflowSeparation;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Identity;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Comprehensive E2E test suite validating architectural and workflow separation
/// between global system-wide fixes and per-entity operations in Module 1 (Identity & User Profiles).
/// Tiers:
///  - Tier 1: Feature Coverage (Isolated Happy Path)
///  - Tier 2: Boundary & Corner Cases (Invalid inputs, injection prevention, guardrails)
///  - Tier 3: Non-Interference (Entity A vs Entity B, Global fixes vs Entity state)
///  - Tier 4: Real-World Scenarios (End-to-End Administrator Lifecycles)
/// </summary>
public class IdentityWorkflowSeparationE2ETests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly ResourceGuard _resourceGuard;
    private readonly TestActivityLogger _logger;
    private readonly IdentityService _identityService;
    private readonly BackupService _backupService;

    public IdentityWorkflowSeparationE2ETests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService();
        _wmi = new MockWmiService();
        _resourceGuard = new ResourceGuard(_fileSystem);
        _logger = new TestActivityLogger();

        _identityService = new IdentityService(_processRunner, _fileSystem, _registry, _network, _wmi, _logger);
        _backupService = new BackupService(_processRunner, _fileSystem, _registry, _resourceGuard, logger: _logger);
    }

    #region Tier 1: Feature Coverage (Isolated Happy Path)

    [Fact]
    public void Tier1_Global_EnableBuiltInAdministrator_TargetsOnlySid500Account()
    {
        // Arrange
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", [
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", true }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "Worker1" }, { "SID", "S-1-5-21-999-1001" }, { "Disabled", true }, { "Lockout", true } }
        ]);

        // Act
        bool result = _identityService.EnableBuiltInAdministrator();

        // Assert
        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Equals("net.exe user \"Administrator\" /active:yes", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains("Worker1", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Tier1_Global_TestDomainReachability_ChecksCriticalDomainPorts()
    {
        // Arrange
        string domain = "corp.enterprise.local";
        _network.SetHostReachable(domain, true);
        _network.SetPortOpen(domain, 88, true);
        _network.SetPortOpen(domain, 389, true);
        _network.SetPortOpen(domain, 445, true);

        // Act
        var result = _identityService.TestDomainReachability(domain);

        // Assert
        Assert.True(result.IsReachable);
        Assert.True(result.KerberosPortOpen);
        Assert.True(result.LdapPortOpen);
        Assert.True(result.SmbPortOpen);
        Assert.Equal(domain, result.Domain);
    }

    [Fact]
    public void Tier1_PerEntity_UnlockLocalAccount_ExecutesExclusivelyForDesignatedUser()
    {
        // Act
        bool result = _identityService.UnlockLocalAccount("Alice");

        // Assert
        Assert.True(result);
        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Equal("net.exe user \"Alice\" /active:yes", _processRunner.ExecutedCommands[0]);
    }

    [Fact]
    public void Tier1_PerEntity_SetAccountEnabled_TogglesSpecificAccountState()
    {
        // Act: disable Bob
        bool result = _identityService.SetAccountEnabled("Bob", false);

        // Assert
        Assert.True(result);
        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Equal("net.exe user \"Bob\" /active:no", _processRunner.ExecutedCommands[0]);
    }

    [Fact]
    public void Tier1_PerEntity_GetUserProfileMap_ResolvesSpecificUserProfile()
    {
        // Arrange
        string username = "Alice";
        string profileDir = $@"C:\Users\{username}";
        _fileSystem.CreateDirectory(profileDir);
        _fileSystem.CreateDirectory(Path.Combine(profileDir, "Desktop"));
        _fileSystem.CreateDirectory(Path.Combine(profileDir, "Documents"));

        // Act
        var map = _backupService.GetUserProfileMap(username);

        // Assert
        Assert.Equal(username, map.Username);
        Assert.Equal(profileDir, map.ProfilePath);
        Assert.Equal(Path.Combine(profileDir, "Desktop"), map.DesktopPath);
        Assert.Equal(Path.Combine(profileDir, "Documents"), map.DocumentsPath);
    }

    [Fact]
    public async Task Tier1_ViewModel_RefreshAccounts_PopulatesGlobalInventoryWithoutSideEffects()
    {
        // Arrange
        var accounts = new List<LocalAccountItem>
        {
            new("Administrator", "S-1-5-21-999-500", true, false, true, true),
            new("Alice", "S-1-5-21-999-1001", true, false, false, false),
            new("Bob", "S-1-5-21-999-1002", false, true, false, false)
        };

        var identityMock = new Mock<IIdentityService>();
        identityMock.Setup(s => s.GetLocalAccounts()).Returns(accounts);
        var backupMock = new Mock<IBackupService>();

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _logger);

        // Act
        await vm.RefreshAccountsCommand.ExecuteAsync(null);

        // Assert
        Assert.Equal(3, vm.Accounts.Count);
        Assert.NotNull(vm.SelectedAccount);
        Assert.Contains("Loaded 3 local user accounts", vm.LastIdentityStatus);
        identityMock.Verify(s => s.GetLocalAccounts(), Times.Once);
        identityMock.Verify(s => s.UnlockLocalAccount(It.IsAny<string>()), Times.Never);
        identityMock.Verify(s => s.SetAccountEnabled(It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
    }

    #endregion

    #region Tier 2: Boundary & Corner Cases

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("\t")]
    public void Tier2_Boundary_InvalidOrWhitespaceUsernames_ThrowsOrFailsGracefully(string invalidUsername)
    {
        // Assert: unlock, enable, and create reject invalid usernames cleanly
        Assert.Throws<ArgumentException>(() => _identityService.UnlockLocalAccount(invalidUsername));
        Assert.Throws<ArgumentException>(() => _identityService.SetAccountEnabled(invalidUsername, true));
        Assert.Throws<ArgumentException>(() => _identityService.CreateLocalAccount(invalidUsername, "P@ssword123"));
        Assert.Empty(_processRunner.ExecutedCommands);
    }

    [Fact]
    public void Tier2_Boundary_SpecialCharactersAndSpacesInUsername_SafelyEscapedInProcessRunner()
    {
        // Arrange
        string usernameWithSpaces = "Domain Admin User";

        // Act
        bool result = _identityService.UnlockLocalAccount(usernameWithSpaces);

        // Assert
        Assert.True(result);
        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Equal("net.exe user \"Domain Admin User\" /active:yes", _processRunner.ExecutedCommands[0]);
    }

    [Fact]
    public void Tier2_Boundary_DeleteBuiltInAdministratorSid500_BlockedByGuardrail()
    {
        // Arrange
        string adminSid = "S-1-5-21-123456789-123456789-123456789-500";

        // Act & Assert: Guardrail must throw InvalidOperationException protecting SID-500
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount("Administrator", adminSid));

        Assert.Contains("SID -500", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(_processRunner.ExecutedCommands);
    }

    [Fact]
    public void Tier2_Boundary_DeleteActiveUser_BlockedByGuardrail()
    {
        // Arrange: current user cannot be deleted
        string activeUser = Environment.UserName;

        // Act & Assert: Guardrail must throw InvalidOperationException protecting active user
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _identityService.RemoveLocalAccount(activeUser, "S-1-5-21-999-1005"));

        Assert.Contains("active", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(_processRunner.ExecutedCommands);
    }

    [Fact]
    public void Tier2_Boundary_NonExistentUserUnlock_FailsGracefully()
    {
        // Arrange: simulate net.exe reporting user not found (exit code 2)
        _processRunner.SetCommandResult(
            "net.exe user \"GhostUser\" /active:yes",
            new ProcessExecutionResult(2, string.Empty, "The user name could not be found.", false));

        // Act
        bool result = _identityService.UnlockLocalAccount("GhostUser");

        // Assert
        Assert.False(result);
        Assert.Single(_processRunner.ExecutedCommands);
    }

    [Fact]
    public void Tier2_Boundary_ProfileRestore_CorruptManifest_AbortsWithoutMutatingFileSystem()
    {
        // Arrange: Malformed JSON manifest
        string backupDir = @"D:\Backups\CorruptBackup";
        string manifestFile = Path.Combine(backupDir, "IToolkit_Backup_Manifest.json");
        _fileSystem.CreateDirectory(backupDir);
        _fileSystem.WriteAllText(manifestFile, "{ \"invalid_json\": true ");

        // Act & Assert: Throws JsonException on malformed JSON without writing any files
        Assert.Throws<JsonException>(() =>
            _backupService.RestoreProfileData(backupDir, manifestFile, "Alice"));

        // Arrange 2: Valid JSON but corrupt/missing file in manifest
        string relativeFile = "Documents\\Report.docx";
        var manifestData = new BackupManifestData(
            DateTime.UtcNow,
            backupDir,
            100,
            [new BackupManifestItem(relativeFile, "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", 100)]);
        _fileSystem.WriteAllText(manifestFile, JsonSerializer.Serialize(manifestData));

        var result = _backupService.RestoreProfileData(backupDir, manifestFile, "Alice");
        Assert.False(result.Success);
        Assert.False(result.Validated);
    }

    #endregion

    #region Tier 3: Cross-Feature Combinations & Non-Interference

    [Fact]
    public void Tier3_NonInterference_UnlockingEntityA_DoesNotMutateEntityB_OrGlobalAdmin()
    {
        // Act: Unlock Alice only
        bool result = _identityService.UnlockLocalAccount("Alice");

        // Assert
        Assert.True(result);
        Assert.Single(_processRunner.ExecutedCommands);
        Assert.Equal("net.exe user \"Alice\" /active:yes", _processRunner.ExecutedCommands[0]);

        // Verifying Bob and Administrator are not touched
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains("Bob", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains("Administrator", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Tier3_NonInterference_GlobalBuiltInAdminRecovery_DoesNotMutateStandardLocalAccounts()
    {
        // Arrange
        _wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", [
            new Dictionary<string, object?> { { "Name", "Administrator" }, { "SID", "S-1-5-21-999-500" }, { "Disabled", true }, { "Lockout", false } },
            new Dictionary<string, object?> { { "Name", "Alice" }, { "SID", "S-1-5-21-999-1001" }, { "Disabled", true }, { "Lockout", true } },
            new Dictionary<string, object?> { { "Name", "Bob" }, { "SID", "S-1-5-21-999-1002" }, { "Disabled", true }, { "Lockout", true } }
        ]);

        // Act: Global recovery of built-in admin
        bool enableOk = _identityService.EnableBuiltInAdministrator();
        bool pwOk = _identityService.ResetBuiltInAdministratorPassword("NewP@ssword2026!");

        // Assert
        Assert.True(enableOk);
        Assert.True(pwOk);

        // Verifies net.exe was ONLY run for Administrator, never for Alice or Bob
        foreach (string cmd in _processRunner.ExecutedCommands)
        {
            Assert.Contains("Administrator", cmd, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Alice", cmd, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Bob", cmd, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void Tier3_NonInterference_RemovingEntityA_LeavesEntityBIntact()
    {
        // Arrange
        string userA = "TempContractorA";
        string userB = "PermanentEmployeeB";

        // Act: Remove user A
        bool removed = _identityService.RemoveLocalAccount(userA, "S-1-5-21-999-1010");

        // Assert
        Assert.True(removed);
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Equals($"net.exe user \"{userA}\" /delete", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(_processRunner.ExecutedCommands, cmd => cmd.Contains(userB, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Tier3_NonInterference_ProfileRestoreTargetedAtUserA_DoesNotTouchUserBDirectory()
    {
        // Arrange
        string backupDir = @"D:\Backups\AliceProfile";
        string manifestPath = Path.Combine(backupDir, "IToolkit_Backup_Manifest.json");
        string relativeFile = "Documents\\Report.docx";
        string payload = "Classified Report Content";

        _fileSystem.CreateDirectory(backupDir);
        string sourceFile = Path.Combine(backupDir, relativeFile);
        _fileSystem.WriteAllText(sourceFile, payload);
        string hash = _fileSystem.ComputeSha256(sourceFile);

        var manifestData = new BackupManifestData(
            DateTime.UtcNow,
            backupDir,
            payload.Length,
            [new BackupManifestItem(relativeFile, hash, payload.Length)]);

        _fileSystem.WriteAllText(manifestPath, JsonSerializer.Serialize(manifestData));

        string targetUser = "AliceTarget";
        string aliceTargetDir = $@"C:\Users\{targetUser}";
        string bobDir = @"C:\Users\BobUntouched";

        _fileSystem.CreateDirectory(aliceTargetDir);
        _fileSystem.CreateDirectory(bobDir);

        // Act
        var restoreResult = _backupService.RestoreProfileData(backupDir, manifestPath, targetUser);

        // Assert
        Assert.True(restoreResult.Success);
        Assert.True(restoreResult.Validated);
        Assert.True(_fileSystem.FileExists(Path.Combine(aliceTargetDir, relativeFile)));
        Assert.False(_fileSystem.FileExists(Path.Combine(bobDir, relativeFile)));
    }

    #endregion

    #region Tier 4: Real-World Scenarios (End-to-End Admin Lifecycles)

    [Fact]
    public async Task Tier4_RealWorld_FullAdminLifecycle_Onboard_Troubleshoot_GlobalCheck_Offboard()
    {
        // Phase 1: Onboarding Contractor
        string contractor = "ContractorAlpha";
        bool created = _identityService.CreateLocalAccount(contractor, "InitialP@ss2026!", "External Consultant", addToAdminGroup: false);
        Assert.True(created);
        Assert.Contains(_processRunner.ExecutedCommands, cmd => cmd.Equals($"net.exe user \"{contractor}\" \"InitialP@ss2026!\" /add /comment:\"External Consultant\"", StringComparison.OrdinalIgnoreCase));

        // Phase 2: Troubleshooting - Contractor gets locked out
        // Admin uses ViewModel to manage accounts
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var confirmMock = new Mock<ISafetyConfirmationService>();
        confirmMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        var accountsList = new List<LocalAccountItem>
        {
            new("Administrator", "S-1-5-21-999-500", true, false, true, true),
            new(contractor, "S-1-5-21-999-1020", true, true, false, false),
            new("StaffMember", "S-1-5-21-999-1001", true, false, false, false)
        };

        identityMock.Setup(s => s.GetLocalAccounts()).Returns(accountsList);
        identityMock.Setup(s => s.UnlockLocalAccount(contractor)).Returns(true);
        identityMock.Setup(s => s.RemoveLocalAccount(contractor, "S-1-5-21-999-1020")).Returns(true);

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _logger, confirmationService: confirmMock.Object);
        await vm.RefreshAccountsCommand.ExecuteAsync(null);

        // Select contractor and unlock
        vm.SelectedAccount = vm.Accounts.First(a => a.Username == contractor);
        Assert.True(vm.UnlockAccountCommand.CanExecute(null));
        await vm.UnlockAccountCommand.ExecuteAsync(null);

        identityMock.Verify(s => s.UnlockLocalAccount(contractor), Times.Once);
        identityMock.Verify(s => s.UnlockLocalAccount("StaffMember"), Times.Never);

        // Phase 3: Global System Maintenance - Run domain test
        identityMock.Setup(s => s.TestDomainReachability("corp.local"))
            .Returns(new DomainReachabilityResult("corp.local", true, true, true, true, true, "OK"));

        vm.DomainTestName = "corp.local";
        await vm.TestDomainReachabilityCommand.ExecuteAsync(null);
        Assert.Contains("corp.local", vm.LastIdentityStatus);

        // Phase 4: Offboarding - Delete contractor
        vm.SelectedAccount = vm.Accounts.First(a => a.Username == contractor);
        Assert.True(vm.RemoveAccountCommand.CanExecute(null));
        await vm.RemoveAccountCommand.ExecuteAsync(null);

        identityMock.Verify(s => s.RemoveLocalAccount(contractor, "S-1-5-21-999-1020"), Times.Once);
        identityMock.Verify(s => s.RemoveLocalAccount("StaffMember", It.IsAny<string>()), Times.Never);
        identityMock.Verify(s => s.RemoveLocalAccount("Administrator", It.IsAny<string>()), Times.Never);
    }

    #endregion
}
