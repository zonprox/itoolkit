namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Identity;
using Moq;
using Xunit;

public class IdentityBackupViewModelTests
{
    private readonly Mock<IIdentityService> _identityMock;
    private readonly Mock<IBackupService> _backupMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    public IdentityBackupViewModelTests()
    {
        _identityMock = new Mock<IIdentityService>();
        _backupMock = new Mock<IBackupService>();
        _loggerMock = new Mock<IActivityLogger>();
    }

    [Fact]
    public async Task RefreshAccountsCommand_PopulatesAccountsList()
    {
        var accounts = new List<LocalAccountItem>
        {
            new LocalAccountItem("Administrator", "S-1-5-21-500", true, false, true, true),
            new LocalAccountItem("TestUser", "S-1-5-21-1001", true, false, false, false)
        };

        _identityMock
            .Setup(s => s.GetLocalAccounts())
            .Returns(accounts);

        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object);

        await vm.RefreshAccountsCommand.ExecuteAsync(null);

        Assert.Equal(2, vm.Accounts.Count);
        Assert.Contains("Loaded 2 local user accounts", vm.LastIdentityStatus);
    }

    [Fact]
    public async Task EnableBuiltInAdminCommand_InvokesServiceAndRefreshes()
    {
        _identityMock
            .Setup(s => s.EnableBuiltInAdministrator())
            .Returns(true);
        _identityMock
            .Setup(s => s.GetLocalAccounts())
            .Returns(new List<LocalAccountItem>());

        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object);

        await vm.EnableBuiltInAdminCommand.ExecuteAsync(null);

        _identityMock.Verify(s => s.EnableBuiltInAdministrator(), Times.Once);
        Assert.Contains("enabled successfully", vm.LastIdentityStatus);
    }

    [Fact]
    public async Task TestDomainReachabilityCommand_ReportsConnectivity()
    {
        var reachability = new DomainReachabilityResult(
            Domain: "corp.local",
            DnsResolved: true,
            KerberosPortOpen: true,
            LdapPortOpen: true,
            SmbPortOpen: true,
            IsReachable: true,
            DiagnosticsSummary: "All domain ports open"
        );

        _identityMock
            .Setup(s => s.TestDomainReachability("corp.local"))
            .Returns(reachability);

        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object)
        {
            DomainTestName = "corp.local"
        };

        await vm.TestDomainReachabilityCommand.ExecuteAsync(null);

        Assert.Contains("reachable", vm.LastIdentityStatus);
        Assert.Contains("Kerberos 88: OK", vm.LastIdentityStatus);
    }

    [Fact]
    public async Task ExecuteProfileBackupCommand_RunsFullBackupPipeline()
    {
        _backupMock
            .Setup(s => s.GetUserProfileMap(null))
            .Returns(new UserProfileMap(
                Username: "TestUser",
                ProfilePath: @"C:\Users\TestUser",
                DesktopPath: @"C:\Users\TestUser\Desktop",
                DocumentsPath: @"C:\Users\TestUser\Documents",
                DownloadsPath: @"C:\Users\TestUser\Downloads",
                FavoritesPath: @"C:\Users\TestUser\Favorites",
                PicturesPath: @"C:\Users\TestUser\Pictures",
                IsOneDriveRedirected: false));

        _backupMock
            .Setup(s => s.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), false))
            .Returns(new RobocopySyncResult(
                Source: @"C:\Users\TestUser",
                Destination: @"D:\UserBackups",
                ExitCode: 1,
                IsSuccess: true,
                Output: "Robocopy done"));

        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object)
        {
            BackupDestinationDirectory = @"D:\UserBackups",
            IncludeBookmarks = false,
            IncludeCertificates = false,
            CreateManifest = false
        };

        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);

        Assert.Contains("Profile backup completed successfully", vm.LastBackupStatus);
        _backupMock.Verify(s => s.RunRobocopySync(@"C:\Users\TestUser", @"D:\UserBackups", false), Times.Once);
    }

    [Fact]
    public void ManageAccountCommand_OpensDialogWithTargetEntityContext()
    {
        var target = new LocalAccountItem("TargetUser", "S-1-5-21-9999", true, false, false, false);
        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object);

        vm.ManageAccountCommand.Execute(target);

        Assert.True(vm.IsManageAccountOpen);
        Assert.NotNull(vm.CurrentManageAccount);
        Assert.Equal("TargetUser", vm.CurrentManageAccount.Username);
        Assert.Equal("S-1-5-21-9999", vm.CurrentManageAccount.Sid);
    }

    [Fact]
    public void CloseManageAccountCommand_ClosesDialog()
    {
        var target = new LocalAccountItem("TargetUser", "S-1-5-21-9999", true, false, false, false);
        var vm = new IdentityBackupViewModel(_identityMock.Object, _backupMock.Object, _loggerMock.Object);

        vm.ManageAccountCommand.Execute(target);
        Assert.True(vm.IsManageAccountOpen);

        vm.CloseManageAccountCommand.Execute(null);

        Assert.False(vm.IsManageAccountOpen);
        Assert.Null(vm.CurrentManageAccount);
    }
}
