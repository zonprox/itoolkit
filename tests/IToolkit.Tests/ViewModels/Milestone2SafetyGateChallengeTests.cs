namespace IToolkit.Tests.ViewModels;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

public class Milestone2SafetyGateChallengeTests
{
    private readonly MockDialogService _dialogService;
    private readonly Mock<IActivityLogger> _loggerMock;

    public Milestone2SafetyGateChallengeTests()
    {
        _dialogService = new MockDialogService();
        _loggerMock = new Mock<IActivityLogger>();
    }

    #region 1. ScrubOfficeSuite Safety Gate

    [Fact]
    public async Task ScrubOfficeSuite_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = false;
        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        officeMock.Verify(o => o.ScrubOfficeSuiteCleanly(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastOfficeSummary);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(OfficeOutlookViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task ScrubOfficeSuite_WhenConfirmationAccepted_ExecutesService()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        officeMock.Setup(o => o.ScrubOfficeSuiteCleanly())
            .Returns(new OfficeScrubResult(1, 1, 1, true, 10, true, "Scrub complete"));

        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = true;
        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        officeMock.Verify(o => o.ScrubOfficeSuiteCleanly(), Times.Once);
        Assert.Contains("completed successfully", vm.LastOfficeSummary);
    }

    [Fact]
    public async Task ScrubOfficeSuite_WhenConfirmationServiceNull_ExecutesWithoutPrompt()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        officeMock.Setup(o => o.ScrubOfficeSuiteCleanly())
            .Returns(new OfficeScrubResult(1, 1, 1, true, 10, true, "Scrub complete"));

        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService, null);

        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        officeMock.Verify(o => o.ScrubOfficeSuiteCleanly(), Times.Once);
        Assert.Equal(0, _dialogService.ConfirmCallCount);
    }

    #endregion

    #region 2. RemoveAccount Safety Gate

    [Fact]
    public async Task RemoveAccount_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            SelectedAccount = new LocalAccountItem("TargetUser", "S-1-5-21-9999", true, false, false, false)
        };

        _dialogService.ConfirmationResult = false;
        await vm.RemoveAccountCommand.ExecuteAsync(null);

        identityMock.Verify(i => i.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastIdentityStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(IdentityBackupViewModel),
            It.Is<string>(msg => msg.Contains("TargetUser") && msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RemoveAccount_WhenConfirmationAccepted_ExecutesService()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        identityMock.Setup(i => i.RemoveLocalAccount("TargetUser", "S-1-5-21-9999")).Returns(true);
        identityMock.Setup(i => i.GetLocalAccounts()).Returns(Array.Empty<LocalAccountItem>());

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            SelectedAccount = new LocalAccountItem("TargetUser", "S-1-5-21-9999", true, false, false, false)
        };

        _dialogService.ConfirmationResult = true;
        await vm.RemoveAccountCommand.ExecuteAsync(null);

        identityMock.Verify(i => i.RemoveLocalAccount("TargetUser", "S-1-5-21-9999"), Times.Once);
        Assert.Contains("removed", vm.LastIdentityStatus);
    }

    [Fact]
    public async Task RemoveAccount_WhenSelectedAccountNull_DoesNotPromptOrExecute()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            SelectedAccount = null
        };

        await vm.RemoveAccountCommand.ExecuteAsync(null);

        identityMock.Verify(i => i.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Equal(0, _dialogService.ConfirmCallCount);
    }

    #endregion

    #region 3. RemediateNetworkStack Safety Gate

    [Fact]
    public async Task RemediateNetworkStack_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = false;
        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);

        netMock.Verify(n => n.RemediateNetworkStack(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RemediateNetworkStack_WhenConfirmationAccepted_ExecutesService()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        netMock.Setup(n => n.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, true, "OK"));

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = true;
        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);

        netMock.Verify(n => n.RemediateNetworkStack(), Times.Once);
        Assert.Contains("Remediated", vm.LastNetworkStatus);
    }

    #endregion

    #region 4. ResetWinsock Safety Gate

    [Fact]
    public async Task ResetWinsock_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = false;
        await vm.ResetWinsockCommand.ExecuteAsync(null);

        netMock.Verify(n => n.ResetWinsock(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(msg => msg.Contains("Winsock") && msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task ResetWinsock_WhenConfirmationAccepted_ExecutesService()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        netMock.Setup(n => n.ResetWinsock()).Returns(true);

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = true;
        await vm.ResetWinsockCommand.ExecuteAsync(null);

        netMock.Verify(n => n.ResetWinsock(), Times.Once);
        Assert.Contains("Winsock Catalog reset successfully", vm.LastNetworkStatus);
    }

    #endregion

    #region 5. ResetTcpIp Safety Gate

    [Fact]
    public async Task ResetTcpIp_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = false;
        await vm.ResetTcpIpCommand.ExecuteAsync(null);

        netMock.Verify(n => n.ResetTcpIpStack(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(msg => msg.Contains("TCP/IP") && msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task ResetTcpIp_WhenConfirmationAccepted_ExecutesService()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        netMock.Setup(n => n.ResetTcpIpStack()).Returns(true);

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = true;
        await vm.ResetTcpIpCommand.ExecuteAsync(null);

        netMock.Verify(n => n.ResetTcpIpStack(), Times.Once);
        Assert.Contains("TCP/IP stack reset successfully", vm.LastNetworkStatus);
    }

    #endregion

    #region 6. PurgeSpooler Safety Gate

    [Fact]
    public async Task PurgeSpooler_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = false;
        await vm.PurgeSpoolerCommand.ExecuteAsync(null);

        printerMock.Verify(p => p.PurgeSpoolerQueue(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(msg => msg.Contains("Spooler") && msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task PurgeSpooler_WhenConfirmationAccepted_ExecutesService()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        printerMock.Setup(p => p.PurgeSpoolerQueue())
            .Returns(new SpoolerQueueResult(true, true, true, 5, true, "Purged"));

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        _dialogService.ConfirmationResult = true;
        await vm.PurgeSpoolerCommand.ExecuteAsync(null);

        printerMock.Verify(p => p.PurgeSpoolerQueue(), Times.Once);
        Assert.Contains("Spooler purged: 5 spool files deleted", vm.LastPrinterStatus);
    }

    #endregion

    #region 7. RestoreProfile Safety Gate

    [Fact]
    public async Task RestoreProfile_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            RestoreBackupDirectory = @"D:\Backups\ProfileSource"
        };

        _dialogService.ConfirmationResult = false;
        await vm.RestoreProfileCommand.ExecuteAsync(null);

        backupMock.Verify(b => b.RestoreProfileData(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastBackupStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(IdentityBackupViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RestoreProfile_WhenConfirmationAccepted_ExecutesService()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        backupMock.Setup(b => b.RestoreProfileData(@"D:\Backups\ProfileSource", @"D:\Backups\ProfileSource\iToolKit_Backup_Manifest.json"))
            .Returns(new ProfileRestoreResult(true, 42, true, "Restored"));

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            RestoreBackupDirectory = @"D:\Backups\ProfileSource"
        };

        _dialogService.ConfirmationResult = true;
        await vm.RestoreProfileCommand.ExecuteAsync(null);

        backupMock.Verify(b => b.RestoreProfileData(@"D:\Backups\ProfileSource", @"D:\Backups\ProfileSource\iToolKit_Backup_Manifest.json"), Times.Once);
        Assert.Contains("42 files restored", vm.LastBackupStatus);
    }

    #endregion

    #region 8. RobocopyMirror Safety Gate

    [Fact]
    public async Task RobocopyMirror_WhenFlagTrueAndConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            RobocopyMirror = true,
            BackupDestinationDirectory = @"E:\TargetBackup"
        };

        _dialogService.ConfirmationResult = false;
        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);

        backupMock.Verify(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastBackupStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(IdentityBackupViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RobocopyMirror_WhenFlagTrueAndConfirmationAccepted_ExecutesServiceWithMirrorTrue()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        backupMock.Setup(b => b.GetUserProfileMap(null))
            .Returns(new UserProfileMap("Admin", @"C:\Users\Admin", "", "", "", "", "", false));
        backupMock.Setup(b => b.RunRobocopySync(@"C:\Users\Admin", @"E:\TargetBackup", true))
            .Returns(new RobocopySyncResult(@"C:\Users\Admin", @"E:\TargetBackup", 1, true, "Mirrored"));

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            RobocopyMirror = true,
            BackupDestinationDirectory = @"E:\TargetBackup"
        };

        _dialogService.ConfirmationResult = true;
        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);

        backupMock.Verify(b => b.RunRobocopySync(@"C:\Users\Admin", @"E:\TargetBackup", true), Times.Once);
        Assert.Contains("completed successfully", vm.LastBackupStatus);
    }

    [Fact]
    public async Task RobocopyMirror_WhenFlagFalse_BypassesConfirmationAndExecutesService()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        backupMock.Setup(b => b.GetUserProfileMap(null))
            .Returns(new UserProfileMap("Admin", @"C:\Users\Admin", "", "", "", "", "", false));
        backupMock.Setup(b => b.RunRobocopySync(@"C:\Users\Admin", @"E:\TargetBackup", false))
            .Returns(new RobocopySyncResult(@"C:\Users\Admin", @"E:\TargetBackup", 1, true, "Copied"));

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            RobocopyMirror = false,
            BackupDestinationDirectory = @"E:\TargetBackup"
        };

        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);

        Assert.Equal(0, _dialogService.ConfirmCallCount);
        backupMock.Verify(b => b.RunRobocopySync(@"C:\Users\Admin", @"E:\TargetBackup", false), Times.Once);
    }

    #endregion

    #region 9. WinSxS ResetBase Safety Gate

    [Fact]
    public async Task WinSxS_WhenResetBaseTrueAndConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            WinSxSResetBase = true
        };

        _dialogService.ConfirmationResult = false;
        await vm.CleanWinSxSCommand.ExecuteAsync(null);

        healthMock.Verify(h => h.CleanWinSxS(It.IsAny<bool>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastCleanupSummary);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(SystemHealthViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task WinSxS_WhenResetBaseTrueAndConfirmationAccepted_ExecutesServiceWithResetBaseTrue()
    {
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.CleanWinSxS(true))
            .Returns(new ComponentCleanupResult(true, 0, "ResetBase Complete"));

        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            WinSxSResetBase = true
        };

        _dialogService.ConfirmationResult = true;
        await vm.CleanWinSxSCommand.ExecuteAsync(null);

        healthMock.Verify(h => h.CleanWinSxS(true), Times.Once);
        Assert.Contains("Cleaned Successfully", vm.LastCleanupSummary);
    }

    [Fact]
    public async Task WinSxS_WhenResetBaseFalse_BypassesConfirmationAndExecutesService()
    {
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.CleanWinSxS(false))
            .Returns(new ComponentCleanupResult(true, 0, "Standard Cleanup Complete"));

        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            WinSxSResetBase = false
        };

        await vm.CleanWinSxSCommand.ExecuteAsync(null);

        Assert.Equal(0, _dialogService.ConfirmCallCount);
        healthMock.Verify(h => h.CleanWinSxS(false), Times.Once);
        Assert.Contains("Cleaned Successfully", vm.LastCleanupSummary);
    }

    #endregion

    #region 10. CustomDebloat Safety Gate

    [Fact]
    public async Task CustomDebloat_WhenConfirmationDenied_AbortsExecutionAndLogsWarning()
    {
        var installerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();
        var vm = new SoftwareOptimizationViewModel(installerMock.Object, optMock.Object, _loggerMock.Object, _dialogService)
        {
            CustomDebloatScriptUrl = "https://example.com/untrusted.ps1"
        };

        _dialogService.ConfirmationResult = false;
        await vm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        optMock.Verify(o => o.ExecuteDebloatScript(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastSoftwareStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(SoftwareOptimizationViewModel),
            It.Is<string>(msg => msg.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task CustomDebloat_WhenConfirmationAccepted_ExecutesService()
    {
        var installerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();
        optMock.Setup(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/trusted.ps1"))
            .Returns(new DebloatExecutionResult("CustomDebloat", "https://example.com/trusted.ps1", true, true, 0, true, "Success", ""));

        var vm = new SoftwareOptimizationViewModel(installerMock.Object, optMock.Object, _loggerMock.Object, _dialogService)
        {
            CustomDebloatScriptUrl = "https://example.com/trusted.ps1"
        };

        _dialogService.ConfirmationResult = true;
        await vm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        optMock.Verify(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/trusted.ps1"), Times.Once);
        Assert.Contains("executed successfully", vm.LastSoftwareStatus);
    }

    [Fact]
    public async Task CustomDebloat_WhenConfirmationServiceNull_ExecutesWithoutPrompt()
    {
        var installerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();
        optMock.Setup(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/trusted.ps1"))
            .Returns(new DebloatExecutionResult("CustomDebloat", "https://example.com/trusted.ps1", true, true, 0, true, "Success", ""));

        var vm = new SoftwareOptimizationViewModel(installerMock.Object, optMock.Object, _loggerMock.Object, null)
        {
            CustomDebloatScriptUrl = "https://example.com/trusted.ps1"
        };

        await vm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        optMock.Verify(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/trusted.ps1"), Times.Once);
        Assert.Equal(0, _dialogService.ConfirmCallCount);
    }

    #endregion

    #region 11. Confirmation Dialog Content Inspection

    [Fact]
    public async Task ConfirmationDialogs_ProvideNonEmptyTitleMessageAndWarningDetails()
    {
        var recordedTitles = new List<string>();
        var recordedMessages = new List<string>();
        var recordedWarnings = new List<string>();

        var confirmMock = new Mock<ISafetyConfirmationService>();
        confirmMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .Callback<string, string, string>((t, m, w) =>
            {
                recordedTitles.Add(t);
                recordedMessages.Add(m);
                recordedWarnings.Add(w);
            })
            .ReturnsAsync(false);

        var healthVm = new SystemHealthViewModel(Mock.Of<ISystemHealthService>(), _loggerMock.Object, null, confirmMock.Object)
        {
            WinSxSResetBase = true
        };
        await healthVm.CleanWinSxSCommand.ExecuteAsync(null);

        var officeVm = new OfficeOutlookViewModel(Mock.Of<IOfficeSuiteService>(), Mock.Of<IOutlookService>(), _loggerMock.Object, null, confirmMock.Object);
        await officeVm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        var connVm = new ConnectivityViewModel(Mock.Of<IConnectivityService>(), Mock.Of<IPrinterService>(), _loggerMock.Object, null, confirmMock.Object, null);
        await connVm.RemediateNetworkStackCommand.ExecuteAsync(null);
        await connVm.ResetWinsockCommand.ExecuteAsync(null);
        await connVm.ResetTcpIpCommand.ExecuteAsync(null);
        await connVm.PurgeSpoolerCommand.ExecuteAsync(null);

        var identityVm = new IdentityBackupViewModel(Mock.Of<IIdentityService>(), Mock.Of<IBackupService>(), _loggerMock.Object, null, confirmMock.Object)
        {
            SelectedAccount = new LocalAccountItem("UserX", "S-1-5-21-1", true, false, false, false),
            RobocopyMirror = true
        };
        await identityVm.RemoveAccountCommand.ExecuteAsync(null);
        await identityVm.RestoreProfileCommand.ExecuteAsync(null);
        await identityVm.ExecuteProfileBackupCommand.ExecuteAsync(null);

        var softwareVm = new SoftwareOptimizationViewModel(Mock.Of<IAppInstallerService>(), Mock.Of<IOptimizationService>(), _loggerMock.Object, confirmMock.Object)
        {
            CustomDebloatScriptUrl = "https://example.com/test.ps1"
        };
        await softwareVm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        Assert.Equal(10, recordedTitles.Count);
        for (int i = 0; i < 10; i++)
        {
            Assert.False(string.IsNullOrWhiteSpace(recordedTitles[i]), $"Title at index {i} should not be empty.");
            Assert.False(string.IsNullOrWhiteSpace(recordedMessages[i]), $"Message at index {i} should not be empty.");
            Assert.False(string.IsNullOrWhiteSpace(recordedWarnings[i]), $"Warning details at index {i} should not be empty.");
        }
    }

    #endregion
}
