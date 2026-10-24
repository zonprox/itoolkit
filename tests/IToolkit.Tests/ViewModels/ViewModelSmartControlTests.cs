namespace IToolkit.Tests.ViewModels;

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using Xunit;

public class ViewModelSmartControlTests
{
    private readonly MockDialogService _dialogService;
    private readonly Mock<IActivityLogger> _loggerMock;

    public ViewModelSmartControlTests()
    {
        _dialogService = new MockDialogService();
        _loggerMock = new Mock<IActivityLogger>();
    }

    #region 1. Smart Path Browse and Open Commands

    [Fact]
    public void SystemHealthViewModel_BrowseWimSourceCommand_UpdatesCustomWimSource()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        _dialogService.SelectedOpenFilePath = @"D:\Images\install.wim";
        vm.BrowseWimSourceCommand.Execute(null);

        Assert.Equal(@"D:\Images\install.wim", vm.CustomWimSource);
        Assert.Equal(1, _dialogService.ShowOpenFileDialogCallCount);
    }

    [Fact]
    public void SystemHealthViewModel_OpenWimFolderCommand_OpensDirectoryInExplorer()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        Assert.False(vm.OpenWimFolderCommand.CanExecute(null));

        vm.CustomWimSource = @"D:\Images\install.wim";
        Assert.True(vm.OpenWimFolderCommand.CanExecute(null));

        vm.OpenWimFolderCommand.Execute(null);

        Assert.Equal(1, _dialogService.OpenFolderInExplorerCallCount);
        Assert.Contains(@"D:\Images\install.wim", _dialogService.OpenedInExplorerPaths);
    }

    [Fact]
    public void OfficeOutlookViewModel_SmartPathCommands_BrowseAndOpenCorrectly()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        // BrowseTargetPstCommand
        _dialogService.SelectedSaveFilePath = @"D:\OutlookFiles\Archived.pst";
        vm.BrowseTargetPstCommand.Execute(null);
        Assert.Equal(@"D:\OutlookFiles\Archived.pst", vm.TargetPstPath);

        // BrowseSourcePstCommand
        _dialogService.SelectedOpenFilePath = @"C:\Mail\Source.pst";
        vm.BrowseSourcePstCommand.Execute(null);
        Assert.Equal(@"C:\Mail\Source.pst", vm.SourcePstPath);

        // BrowseRelocationDirCommand & OpenRelocationDirCommand
        _dialogService.SelectedFolderPath = @"E:\TargetRelocation";
        vm.BrowseRelocationDirCommand.Execute(null);
        Assert.Equal(@"E:\TargetRelocation", vm.RelocationDestinationDir);

        vm.OpenRelocationDirCommand.Execute(null);
        Assert.Contains(@"E:\TargetRelocation", _dialogService.OpenedInExplorerPaths);

        // BrowseBackupDirCommand & OpenBackupDirCommand
        _dialogService.SelectedFolderPath = @"F:\OutlookBackups";
        vm.BrowseBackupDirCommand.Execute(null);
        Assert.Equal(@"F:\OutlookBackups", vm.BackupDirectory);

        vm.OpenBackupDirCommand.Execute(null);
        Assert.Contains(@"F:\OutlookBackups", _dialogService.OpenedInExplorerPaths);
    }

    [Fact]
    public void IdentityBackupViewModel_SmartPathCommands_BrowseAndOpenCorrectly()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        // BrowseBackupDestinationCommand & OpenBackupDestinationCommand
        _dialogService.SelectedFolderPath = @"E:\Profiles\Backup";
        vm.BrowseBackupDestinationCommand.Execute(null);
        Assert.Equal(@"E:\Profiles\Backup", vm.BackupDestinationDirectory);

        vm.OpenBackupDestinationCommand.Execute(null);
        Assert.Contains(@"E:\Profiles\Backup", _dialogService.OpenedInExplorerPaths);

        // BrowseRestoreBackupCommand & OpenRestoreBackupCommand
        _dialogService.SelectedFolderPath = @"E:\Profiles\RestoreSource";
        vm.BrowseRestoreBackupCommand.Execute(null);
        Assert.Equal(@"E:\Profiles\RestoreSource", vm.RestoreBackupDirectory);

        vm.OpenRestoreBackupCommand.Execute(null);
        Assert.Contains(@"E:\Profiles\RestoreSource", _dialogService.OpenedInExplorerPaths);
    }

    #endregion

    #region 2. Adapter Auto-Discovery & Context Binding

    [Fact]
    public async Task ConnectivityViewModel_RefreshAdaptersAsync_PopulatesAdaptersAndSelectsActive()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var networkServiceMock = new Mock<INetworkService>();

        var adapters = new List<NetworkAdapterInfo>
        {
            new NetworkAdapterInfo("1", "vEthernet", "Hyper-V Virtual", "00-15-5D-01-02-03", "Down", new[] { "192.168.100.1" }),
            new NetworkAdapterInfo("2", "Wi-Fi", "Intel Wi-Fi 6E", "00-1A-2B-3C-4D-5E", "Up", new[] { "192.168.1.150" }),
            new NetworkAdapterInfo("3", "Ethernet 2", "Realtek PCIe GbE", "00-1A-2B-3C-4D-5F", "Up", new[] { "192.168.2.150" })
        };

        networkServiceMock.Setup(n => n.GetAdapters()).Returns(adapters);

        var vm = new ConnectivityViewModel(
            netMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            networkServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Equal(3, vm.AvailableAdapters.Count);
        Assert.NotNull(vm.SelectedAdapter);
        Assert.Equal("Wi-Fi", vm.SelectedAdapter.Name);
        Assert.Equal("Wi-Fi", vm.NetworkAdapterName);
        Assert.Contains("Discovered 3 network adapter(s)", vm.LastNetworkStatus);
    }

    [Fact]
    public void ConnectivityViewModel_SelectedAdapter_UpdatesNetworkAdapterName()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object);

        var adapter = new NetworkAdapterInfo("4", "CustomAdapter0", "Virtual NIC", "00-00-00-00-00-00", "Up", Array.Empty<string>());
        vm.SelectedAdapter = adapter;

        Assert.Equal("CustomAdapter0", vm.NetworkAdapterName);
    }

    [Fact]
    public async Task MainViewModel_RunSystemScanAsync_TriggersAdapterDiscovery()
    {
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var installerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();
        var networkServiceMock = new Mock<INetworkService>();

        telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new TelemetrySnapshot(
                OsDescription: "Windows 11 Pro",
                OsBuild: "Build 26100",
                IsElevated: true,
                CpuUsagePercentage: 5,
                MemoryUsedBytes: 4000,
                MemoryTotalBytes: 8000,
                SystemDriveFreeBytes: 50000,
                SystemDriveTotalBytes: 100000,
                NetworkConnected: true,
                ActiveTaskDescription: "Ready"));

        var adapters = new List<NetworkAdapterInfo>
        {
            new NetworkAdapterInfo("1", "Ethernet", "Intel GbE", "AA-BB-CC-DD-EE-FF", "Up", new[] { "10.0.0.5" })
        };
        networkServiceMock.Setup(n => n.GetAdapters()).Returns(adapters);
        installerMock.Setup(a => a.GetCatalog()).Returns(new List<AppCatalogItem>());
        optMock.Setup(o => o.GetWingetStatus()).Returns(new WingetStatus(true, "1.9", true, true, "OK"));
        printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new List<string> { "0x0000011b" });

        var telemetryHeader = new TelemetryHeaderViewModel(telemetryMock.Object);
        telemetryHeader.StopPolling();
        var activityConsole = new ActivityConsoleViewModel(_loggerMock.Object);
        var dashboardVm = new DashboardViewModel(healthMock.Object, officeMock.Object, outlookMock.Object, connMock.Object, backupMock.Object, optMock.Object, _loggerMock.Object);
        var healthVm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object);
        var officeVm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object);
        var connectivityVm = new ConnectivityViewModel(connMock.Object, printerMock.Object, _loggerMock.Object, networkServiceMock.Object);
        var identityVm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);
        var softwareVm = new SoftwareOptimizationViewModel(installerMock.Object, optMock.Object, _loggerMock.Object);

        var mainVm = new MainViewModel(
            telemetryHeader,
            activityConsole,
            dashboardVm,
            healthVm,
            officeVm,
            connectivityVm,
            identityVm,
            softwareVm,
            _loggerMock.Object);

        await mainVm.RunSystemScanAsync();

        networkServiceMock.Verify(n => n.GetAdapters(), Times.Once);
        Assert.Single(connectivityVm.AvailableAdapters);
        Assert.Equal("Ethernet", connectivityVm.NetworkAdapterName);
    }

    #endregion

    #region 3. Office & Outlook Auto-Binding

    [Fact]
    public void OfficeOutlookViewModel_SelectedDataFile_AutoPopulatesSourcePstPath()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object);

        var fileInfo = new MapiDataFileInfo(
            FilePath: @"C:\Users\John\AppData\Local\Microsoft\Outlook\john@corp.pst",
            DisplayName: "john@corp.pst",
            ProviderName: "Outlook Personal Store",
            IsOst: false,
            IsPst: true,
            FileSizeBytes: 52428800,
            RegistryPath: @"Software\Microsoft\Office\Outlook",
            ExistsOnDisk: true);

        vm.SelectedDataFile = fileInfo;

        Assert.Equal(@"C:\Users\John\AppData\Local\Microsoft\Outlook\john@corp.pst", vm.SourcePstPath);
    }

    #endregion

    #region 4. Identity & Backup Validation and Domain Auto-Detection

    [Fact]
    public void IdentityBackupViewModel_InputValidation_EnforcesNonEmptyAndNonWhitespace()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        // CreateAccountCommand validation
        vm.NewAccountUsername = "";
        vm.NewAccountPassword = "";
        Assert.False(vm.CreateAccountCommand.CanExecute(null));

        vm.NewAccountUsername = "   ";
        vm.NewAccountPassword = "validPassword123";
        Assert.False(vm.CreateAccountCommand.CanExecute(null));

        vm.NewAccountUsername = "admin_user";
        vm.NewAccountPassword = "   ";
        Assert.False(vm.CreateAccountCommand.CanExecute(null));

        vm.NewAccountUsername = "admin_user";
        vm.NewAccountPassword = "validPassword123";
        Assert.True(vm.CreateAccountCommand.CanExecute(null));

        // ResetAdminPasswordCommand validation
        vm.NewAdminPassword = "";
        Assert.False(vm.ResetAdminPasswordCommand.CanExecute(null));

        vm.NewAdminPassword = "   ";
        Assert.False(vm.ResetAdminPasswordCommand.CanExecute(null));

        vm.NewAdminPassword = "NewSecretPassword!";
        Assert.True(vm.ResetAdminPasswordCommand.CanExecute(null));
    }

    [Fact]
    public void IdentityBackupViewModel_DomainAutoDetection_ReturnsFallbackOrSystemDomain()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        vm.AutoDetectDomain();

        Assert.False(string.IsNullOrWhiteSpace(vm.DomainTestName));
    }

    #endregion

    #region 5. Destructive Operations Confirmation Gating

    [Fact]
    public async Task SystemHealthViewModel_CleanWinSxS_WithResetBase_RespectsConfirmationGating()
    {
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.CleanWinSxS(true))
            .Returns(new ComponentCleanupResult(Success: true, ExitCode: 0, Output: "Cleaned"));

        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            WinSxSResetBase = true
        };

        // Rejection branch
        _dialogService.ConfirmationResult = false;
        await vm.CleanWinSxSCommand.ExecuteAsync(null);

        healthMock.Verify(h => h.CleanWinSxS(It.IsAny<bool>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastCleanupSummary);

        // Acceptance branch
        _dialogService.ConfirmationResult = true;
        await vm.CleanWinSxSCommand.ExecuteAsync(null);

        healthMock.Verify(h => h.CleanWinSxS(true), Times.Once);
        Assert.Contains("Cleaned Successfully", vm.LastCleanupSummary);
    }

    [Fact]
    public async Task OfficeOutlookViewModel_ScrubOfficeSuite_RespectsConfirmationGating()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();

        officeMock.Setup(o => o.ScrubOfficeSuiteCleanly())
            .Returns(new OfficeScrubResult(1, 1, 1, true, 10, true, "Cleaned"));

        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService, _dialogService);

        // Rejection branch
        _dialogService.ConfirmationResult = false;
        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        officeMock.Verify(o => o.ScrubOfficeSuiteCleanly(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastOfficeSummary);

        // Acceptance branch
        _dialogService.ConfirmationResult = true;
        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        officeMock.Verify(o => o.ScrubOfficeSuiteCleanly(), Times.Once);
        Assert.Contains("completed successfully", vm.LastOfficeSummary);
    }

    [Fact]
    public async Task ConnectivityViewModel_DestructiveOperations_RespectConfirmationGating()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();

        netMock.Setup(n => n.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, true, "OK"));
        netMock.Setup(n => n.ResetWinsock()).Returns(true);
        netMock.Setup(n => n.ResetTcpIpStack()).Returns(true);
        printerMock.Setup(p => p.PurgeSpoolerQueue())
            .Returns(new SpoolerQueueResult(true, true, true, 4, true, "Purged"));

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _loggerMock.Object, null, _dialogService, _dialogService);

        // Rejections
        _dialogService.ConfirmationResult = false;

        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);
        netMock.Verify(n => n.RemediateNetworkStack(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);

        await vm.ResetWinsockCommand.ExecuteAsync(null);
        netMock.Verify(n => n.ResetWinsock(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);

        await vm.ResetTcpIpCommand.ExecuteAsync(null);
        netMock.Verify(n => n.ResetTcpIpStack(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastNetworkStatus);

        await vm.PurgeSpoolerCommand.ExecuteAsync(null);
        printerMock.Verify(p => p.PurgeSpoolerQueue(), Times.Never);
        Assert.Contains("cancelled by user", vm.LastPrinterStatus);

        // Acceptances
        _dialogService.ConfirmationResult = true;

        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);
        netMock.Verify(n => n.RemediateNetworkStack(), Times.Once);

        await vm.ResetWinsockCommand.ExecuteAsync(null);
        netMock.Verify(n => n.ResetWinsock(), Times.Once);

        await vm.ResetTcpIpCommand.ExecuteAsync(null);
        netMock.Verify(n => n.ResetTcpIpStack(), Times.Once);

        await vm.PurgeSpoolerCommand.ExecuteAsync(null);
        printerMock.Verify(p => p.PurgeSpoolerQueue(), Times.Once);
    }

    [Fact]
    public async Task IdentityBackupViewModel_DestructiveOperations_RespectConfirmationGating()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();

        identityMock.Setup(i => i.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>())).Returns(true);
        backupMock.Setup(b => b.RestoreProfileData(It.IsAny<string>(), It.IsAny<string>()))
            .Returns(new ProfileRestoreResult(true, 10, true, "Restored"));
        backupMock.Setup(b => b.GetUserProfileMap(null))
            .Returns(new UserProfileMap("User", @"C:\Users\User", "", "", "", "", "", false));
        backupMock.Setup(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), true))
            .Returns(new RobocopySyncResult(@"C:\Users\User", @"D:\Backups", 1, true, "Mirrored"));

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService, _dialogService)
        {
            SelectedAccount = new LocalAccountItem("TestUser", "S-1-5-21-1234", true, false, false, false),
            RobocopyMirror = true
        };

        // Rejections
        _dialogService.ConfirmationResult = false;

        await vm.RemoveAccountCommand.ExecuteAsync(null);
        identityMock.Verify(i => i.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastIdentityStatus);

        await vm.RestoreProfileCommand.ExecuteAsync(null);
        backupMock.Verify(b => b.RestoreProfileData(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastBackupStatus);

        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);
        backupMock.Verify(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastBackupStatus);

        // Acceptances
        _dialogService.ConfirmationResult = true;

        await vm.RemoveAccountCommand.ExecuteAsync(null);
        identityMock.Verify(i => i.RemoveLocalAccount("TestUser", "S-1-5-21-1234"), Times.Once);

        await vm.RestoreProfileCommand.ExecuteAsync(null);
        backupMock.Verify(b => b.RestoreProfileData(It.IsAny<string>(), It.IsAny<string>()), Times.Once);

        await vm.ExecuteProfileBackupCommand.ExecuteAsync(null);
        backupMock.Verify(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), true), Times.Once);
    }

    [Fact]
    public async Task SoftwareOptimizationViewModel_ExecuteCustomDebloatCommand_RespectsConfirmationGating()
    {
        var appInstallerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();

        appInstallerMock.Setup(a => a.GetCatalog()).Returns(new List<AppCatalogItem>());

        optMock.Setup(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/script.ps1"))
            .Returns(new DebloatExecutionResult("CustomDebloat", "https://example.com/script.ps1", true, true, 0, true, "Executed successfully", ""));

        var vm = new SoftwareOptimizationViewModel(appInstallerMock.Object, optMock.Object, _loggerMock.Object, _dialogService)
        {
            CustomDebloatScriptUrl = "https://example.com/script.ps1"
        };

        // Rejection
        _dialogService.ConfirmationResult = false;
        await vm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        optMock.Verify(o => o.ExecuteDebloatScript(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.Contains("cancelled by user", vm.LastSoftwareStatus);

        // Acceptance
        _dialogService.ConfirmationResult = true;
        await vm.ExecuteCustomDebloatCommand.ExecuteAsync(null);

        optMock.Verify(o => o.ExecuteDebloatScript("CustomDebloat", "https://example.com/script.ps1"), Times.Once);
        Assert.Contains("executed successfully", vm.LastSoftwareStatus);
    }

    #endregion

    #region 6. Dependency Injection Container Resolution

    [Fact]
    public void ServiceRegistration_ResolvesAllViewModelsWithInjectedDependencies()
    {
        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);

        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        var healthVm = provider.GetRequiredService<SystemHealthViewModel>();
        var officeVm = provider.GetRequiredService<OfficeOutlookViewModel>();
        var connVm = provider.GetRequiredService<ConnectivityViewModel>();
        var identityVm = provider.GetRequiredService<IdentityBackupViewModel>();
        var softwareVm = provider.GetRequiredService<SoftwareOptimizationViewModel>();
        var mainVm = provider.GetRequiredService<MainViewModel>();

        Assert.NotNull(healthVm);
        Assert.NotNull(officeVm);
        Assert.NotNull(connVm);
        Assert.NotNull(identityVm);
        Assert.NotNull(softwareVm);
        Assert.NotNull(mainVm);
    }

    #endregion
}
