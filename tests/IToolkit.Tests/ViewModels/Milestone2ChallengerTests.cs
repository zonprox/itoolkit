namespace IToolkit.Tests.ViewModels;

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

public class Milestone2ChallengerTests
{
    private readonly MockDialogService _dialogService;
    private readonly Mock<IActivityLogger> _loggerMock;

    public Milestone2ChallengerTests()
    {
        _dialogService = new MockDialogService();
        _loggerMock = new Mock<IActivityLogger>();
    }

    #region 1. ConnectivityViewModel Stress Tests: Empty, Null, Multiple Adapters

    [Fact]
    public async Task ConnectivityViewModel_NullNetworkService_RefreshAdaptersAsync_SafeNoOp()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            networkService: null,
            _dialogService,
            _dialogService);

        // When network service is null, refresh should be a safe no-op
        await vm.RefreshAdaptersAsync();

        Assert.Empty(vm.AvailableAdapters);
        Assert.Null(vm.SelectedAdapter);
        Assert.Equal("Ethernet", vm.NetworkAdapterName);
        Assert.Equal("Ready", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task ConnectivityViewModel_EmptyAdapterList_HandledGracefully()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var netServiceMock = new Mock<INetworkService>();

        netServiceMock.Setup(n => n.GetAdapters()).Returns(new List<NetworkAdapterInfo>());

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            netServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Empty(vm.AvailableAdapters);
        Assert.Null(vm.SelectedAdapter);
        Assert.Equal("Ethernet", vm.NetworkAdapterName);
        Assert.Contains("Discovered 0 network adapter(s)", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task ConnectivityViewModel_NullAdapterList_HandledGracefully()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var netServiceMock = new Mock<INetworkService>();

        netServiceMock.Setup(n => n.GetAdapters()).Returns((IReadOnlyList<NetworkAdapterInfo>?)null!);

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            netServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Empty(vm.AvailableAdapters);
        Assert.Null(vm.SelectedAdapter);
        Assert.Equal("Ethernet", vm.NetworkAdapterName);
        Assert.Contains("Discovered 0 network adapter(s)", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task ConnectivityViewModel_NetworkServiceThrowsException_HandledGracefully()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var netServiceMock = new Mock<INetworkService>();

        netServiceMock.Setup(n => n.GetAdapters()).Throws(new InvalidOperationException("WMI query failed"));

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            netServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Empty(vm.AvailableAdapters);
        Assert.Null(vm.SelectedAdapter);
        Assert.Contains("Adapter discovery failed: WMI query failed", vm.LastNetworkStatus);
        _loggerMock.Verify(l => l.LogError(nameof(ConnectivityViewModel), It.Is<string>(s => s.Contains("Adapter discovery failed"))), Times.Once);
    }

    [Fact]
    public async Task ConnectivityViewModel_MultipleAdaptersAllDown_SelectsFirstAdapterAsFallback()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var netServiceMock = new Mock<INetworkService>();

        var adapters = new List<NetworkAdapterInfo>
        {
            new NetworkAdapterInfo("1", "Ethernet 1", "Realtek NIC", "AA-BB-CC-00-11-22", "Down", Array.Empty<string>()),
            new NetworkAdapterInfo("2", "Wi-Fi", "Intel NIC", "AA-BB-CC-00-11-33", "Down", Array.Empty<string>()),
            new NetworkAdapterInfo("3", "Bluetooth", "Generic BT", "AA-BB-CC-00-11-44", "Down", Array.Empty<string>())
        };

        netServiceMock.Setup(n => n.GetAdapters()).Returns(adapters);

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            netServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Equal(3, vm.AvailableAdapters.Count);
        Assert.NotNull(vm.SelectedAdapter);
        Assert.Equal("Ethernet 1", vm.SelectedAdapter.Name);
        Assert.Equal("Ethernet 1", vm.NetworkAdapterName);
        Assert.Contains("Discovered 3 network adapter(s). Active: Ethernet 1", vm.LastNetworkStatus);
    }

    [Fact]
    public async Task ConnectivityViewModel_MultipleAdaptersWithUpStatus_SelectsFirstActiveAdapter()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var netServiceMock = new Mock<INetworkService>();

        var adapters = new List<NetworkAdapterInfo>
        {
            new NetworkAdapterInfo("1", "vEthernet (Default Switch)", "Hyper-V", "AA-BB-CC-00-11-01", "Down", Array.Empty<string>()),
            new NetworkAdapterInfo("2", "Bluetooth", "BT Device", "AA-BB-CC-00-11-02", "Down", Array.Empty<string>()),
            new NetworkAdapterInfo("3", "Wi-Fi 6", "Intel AX200", "AA-BB-CC-00-11-03", "Up", new[] { "192.168.1.50" }),
            new NetworkAdapterInfo("4", "Ethernet 2", "Realtek GbE", "AA-BB-CC-00-11-04", "Up", new[] { "10.0.0.2" })
        };

        netServiceMock.Setup(n => n.GetAdapters()).Returns(adapters);

        var vm = new ConnectivityViewModel(
            connMock.Object,
            printerMock.Object,
            _loggerMock.Object,
            netServiceMock.Object,
            _dialogService,
            _dialogService);

        await vm.RefreshAdaptersAsync();

        Assert.Equal(4, vm.AvailableAdapters.Count);
        Assert.NotNull(vm.SelectedAdapter);
        Assert.Equal("Wi-Fi 6", vm.SelectedAdapter.Name);
        Assert.Equal("Wi-Fi 6", vm.NetworkAdapterName);
    }

    [Fact]
    public void ConnectivityViewModel_SettingSelectedAdapterToNull_PreservesNetworkAdapterName()
    {
        var connMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();

        var vm = new ConnectivityViewModel(connMock.Object, printerMock.Object, _loggerMock.Object);

        var adapter = new NetworkAdapterInfo("1", "CustomNic", "Intel", "00-11-22-33-44-55", "Up", Array.Empty<string>());
        vm.SelectedAdapter = adapter;
        Assert.Equal("CustomNic", vm.NetworkAdapterName);

        // Setting to null should not wipe out NetworkAdapterName
        vm.SelectedAdapter = null;
        Assert.Equal("CustomNic", vm.NetworkAdapterName);
    }

    #endregion

    #region 2. IdentityBackupViewModel Domain Discovery Fallbacks

    [Fact]
    public void IdentityBackupViewModel_DetectDomain_ReturnsNonEmptyAndNonWhitespace()
    {
        string detected = IdentityBackupViewModel.DetectDomain();

        Assert.NotNull(detected);
        Assert.False(string.IsNullOrWhiteSpace(detected));
    }

    [Fact]
    public void IdentityBackupViewModel_AutoDetectDomain_PopulatesDomainTestName()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        vm.DomainTestName = string.Empty;
        vm.AutoDetectDomain();

        Assert.False(string.IsNullOrWhiteSpace(vm.DomainTestName));
    }

    [Fact]
    public async Task IdentityBackupViewModel_ScanIdentityAsync_InvokesAutoDetectDomain()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();

        identityMock.Setup(i => i.GetLocalAccounts()).Returns(Array.Empty<LocalAccountItem>());
        identityMock.Setup(i => i.GetBuiltInAdministrator()).Returns((LocalAccountItem?)null);

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        vm.DomainTestName = string.Empty;
        await vm.ScanIdentityAsync();

        Assert.False(string.IsNullOrWhiteSpace(vm.DomainTestName));
    }

    [Fact]
    public void IdentityBackupViewModel_DomainTestName_EmptyOrNull_DisablesTestDomainReachability()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        vm.DomainTestName = string.Empty;
        Assert.False(vm.TestDomainReachabilityCommand.CanExecute(null));

        vm.DomainTestName = "contoso.com";
        Assert.True(vm.TestDomainReachabilityCommand.CanExecute(null));
    }

    [Fact]
    public void IdentityBackupViewModel_DomainUserSamName_EmptyOrNull_DisablesUnlockDomainUser()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();

        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object);

        vm.DomainTestName = "contoso.com";
        vm.DomainUserSamName = string.Empty;
        Assert.False(vm.UnlockDomainUserCommand.CanExecute(null));

        vm.DomainUserSamName = "jdoe";
        Assert.True(vm.UnlockDomainUserCommand.CanExecute(null));
    }

    #endregion

    #region 3. Smart Path Handling: Browse and Open Commands with Null, Empty, and Invalid Paths

    [Fact]
    public void WpfDialogService_OpenFolderInExplorer_HandlesNullEmptyAndInvalidPathsSafely()
    {
        // Locate iToolKit.dll which contains WpfDialogService
        string appAssemblyPath = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "IToolkit.App", "bin", "Release", "net8.0-windows", "win-x64", "iToolKit.dll"));

        if (!File.Exists(appAssemblyPath))
        {
            appAssemblyPath = Path.GetFullPath(
                Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "IToolkit.App", "bin", "Debug", "net8.0-windows", "win-x64", "iToolKit.dll"));
        }

        if (!File.Exists(appAssemblyPath))
        {
            return;
        }

        var appAssembly = Assembly.LoadFrom(appAssemblyPath);
        var wpfDialogServiceType = appAssembly.GetType("IToolkit.App.Services.WpfDialogService");
        Assert.NotNull(wpfDialogServiceType);

        var instance = Activator.CreateInstance(wpfDialogServiceType);
        Assert.NotNull(instance);

        var openFolderMethod = wpfDialogServiceType.GetMethod("OpenFolderInExplorer", new[] { typeof(string) });
        Assert.NotNull(openFolderMethod);

        // Null string
        Assert.Equal(false, openFolderMethod.Invoke(instance, new object?[] { null }));

        // Empty string
        Assert.Equal(false, openFolderMethod.Invoke(instance, new object?[] { string.Empty }));

        // Whitespace string
        Assert.Equal(false, openFolderMethod.Invoke(instance, new object?[] { "   " }));

        // Non-existent path
        string nonExistent = Path.Combine(Path.GetTempPath(), "IToolkit_NonExistent_" + Guid.NewGuid().ToString("N"));
        Assert.Equal(false, openFolderMethod.Invoke(instance, new object?[] { nonExistent }));

        // Invalid path with illegal characters
        Assert.Equal(false, openFolderMethod.Invoke(instance, new object?[] { @"Invalid|Path*?<>Chars" }));
    }

    [Fact]
    public void SystemHealthViewModel_BrowseWimSource_NullDialogService_DoesNotThrow()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, dialogService: null);

        // Should not throw NullReferenceException
        vm.BrowseWimSourceCommand.Execute(null);
        Assert.Null(vm.CustomWimSource);
    }

    [Fact]
    public void SystemHealthViewModel_BrowseWimSource_DialogCancelled_PreservesExistingValue()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService);

        vm.CustomWimSource = @"C:\Existing\install.wim";

        // Dialog returns null (user cancelled)
        _dialogService.SelectedOpenFilePath = null;
        vm.BrowseWimSourceCommand.Execute(null);
        Assert.Equal(@"C:\Existing\install.wim", vm.CustomWimSource);

        // Dialog returns whitespace
        _dialogService.SelectedOpenFilePath = "   ";
        vm.BrowseWimSourceCommand.Execute(null);
        Assert.Equal(@"C:\Existing\install.wim", vm.CustomWimSource);
    }

    [Fact]
    public void SystemHealthViewModel_OpenWimFolder_NullEmptyWhitespace_DisablesCommandAndDoesNotCallService()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, _dialogService);

        vm.CustomWimSource = null;
        Assert.False(vm.OpenWimFolderCommand.CanExecute(null));
        vm.OpenWimFolderCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.CustomWimSource = string.Empty;
        Assert.False(vm.OpenWimFolderCommand.CanExecute(null));
        vm.OpenWimFolderCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.CustomWimSource = "   ";
        Assert.False(vm.OpenWimFolderCommand.CanExecute(null));
        vm.OpenWimFolderCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);
    }

    [Fact]
    public void SystemHealthViewModel_OpenWimFolder_NullDialogService_DoesNotThrow()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var vm = new SystemHealthViewModel(healthMock.Object, _loggerMock.Object, dialogService: null);

        vm.CustomWimSource = @"C:\Valid\Path.wim";
        Assert.True(vm.OpenWimFolderCommand.CanExecute(null));

        // When dialogService is null, executing should not throw
        vm.OpenWimFolderCommand.Execute(null);
    }

    [Fact]
    public void OfficeOutlookViewModel_BrowseCommands_NullDialogService_DoesNotThrow()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, dialogService: null);

        vm.BrowseTargetPstCommand.Execute(null);
        vm.BrowseSourcePstCommand.Execute(null);
        vm.BrowseRelocationDirCommand.Execute(null);
        vm.BrowseBackupDirCommand.Execute(null);

        Assert.Equal(@"C:\OutlookFiles\NewDefaultStore.pst", vm.TargetPstPath);
        Assert.Null(vm.SourcePstPath);
        Assert.Equal(@"D:\OutlookFiles", vm.RelocationDestinationDir);
        Assert.Equal(@"D:\OutlookBackups", vm.BackupDirectory);
    }

    [Fact]
    public void OfficeOutlookViewModel_BrowseCommands_Cancelled_PreservesExistingValues()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService);

        vm.TargetPstPath = @"C:\Original\Target.pst";
        vm.SourcePstPath = @"C:\Original\Source.pst";
        vm.RelocationDestinationDir = @"C:\Original\Reloc";
        vm.BackupDirectory = @"C:\Original\Backup";

        _dialogService.SelectedSaveFilePath = null;
        _dialogService.SelectedOpenFilePath = "   ";
        _dialogService.SelectedFolderPath = string.Empty;

        vm.BrowseTargetPstCommand.Execute(null);
        vm.BrowseSourcePstCommand.Execute(null);
        vm.BrowseRelocationDirCommand.Execute(null);
        vm.BrowseBackupDirCommand.Execute(null);

        Assert.Equal(@"C:\Original\Target.pst", vm.TargetPstPath);
        Assert.Equal(@"C:\Original\Source.pst", vm.SourcePstPath);
        Assert.Equal(@"C:\Original\Reloc", vm.RelocationDestinationDir);
        Assert.Equal(@"C:\Original\Backup", vm.BackupDirectory);
    }

    [Fact]
    public void OfficeOutlookViewModel_OpenCommands_NullEmptyWhitespace_DisablesCommandAndDoesNotCallService()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, _dialogService);

        // RelocationDestinationDir
        vm.RelocationDestinationDir = string.Empty;
        Assert.False(vm.OpenRelocationDirCommand.CanExecute(null));
        vm.OpenRelocationDirCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.RelocationDestinationDir = "   ";
        Assert.False(vm.OpenRelocationDirCommand.CanExecute(null));
        vm.OpenRelocationDirCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        // BackupDirectory
        vm.BackupDirectory = string.Empty;
        Assert.False(vm.OpenBackupDirCommand.CanExecute(null));
        vm.OpenBackupDirCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.BackupDirectory = "   ";
        Assert.False(vm.OpenBackupDirCommand.CanExecute(null));
        vm.OpenBackupDirCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);
    }

    [Fact]
    public void OfficeOutlookViewModel_OpenCommands_NullDialogService_DoesNotThrow()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _loggerMock.Object, dialogService: null);

        vm.RelocationDestinationDir = @"C:\TestReloc";
        vm.BackupDirectory = @"C:\TestBackup";

        Assert.True(vm.OpenRelocationDirCommand.CanExecute(null));
        Assert.True(vm.OpenBackupDirCommand.CanExecute(null));

        vm.OpenRelocationDirCommand.Execute(null);
        vm.OpenBackupDirCommand.Execute(null);
    }

    [Fact]
    public void IdentityBackupViewModel_BrowseCommands_NullDialogService_DoesNotThrow()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, dialogService: null);

        vm.BrowseBackupDestinationCommand.Execute(null);
        vm.BrowseRestoreBackupCommand.Execute(null);

        Assert.Equal(@"D:\UserBackups", vm.BackupDestinationDirectory);
        Assert.Equal(@"D:\UserBackups", vm.RestoreBackupDirectory);
    }

    [Fact]
    public void IdentityBackupViewModel_BrowseCommands_Cancelled_PreservesExistingValues()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService);

        vm.BackupDestinationDirectory = @"E:\CustomBackup";
        vm.RestoreBackupDirectory = @"E:\CustomRestore";

        _dialogService.SelectedFolderPath = null;
        vm.BrowseBackupDestinationCommand.Execute(null);
        Assert.Equal(@"E:\CustomBackup", vm.BackupDestinationDirectory);

        _dialogService.SelectedFolderPath = "   ";
        vm.BrowseRestoreBackupCommand.Execute(null);
        Assert.Equal(@"E:\CustomRestore", vm.RestoreBackupDirectory);
    }

    [Fact]
    public void IdentityBackupViewModel_OpenCommands_NullEmptyWhitespace_DisablesCommandAndDoesNotCallService()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, _dialogService);

        // BackupDestinationDirectory
        vm.BackupDestinationDirectory = string.Empty;
        Assert.False(vm.OpenBackupDestinationCommand.CanExecute(null));
        vm.OpenBackupDestinationCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.BackupDestinationDirectory = "   ";
        Assert.False(vm.OpenBackupDestinationCommand.CanExecute(null));
        vm.OpenBackupDestinationCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        // RestoreBackupDirectory
        vm.RestoreBackupDirectory = string.Empty;
        Assert.False(vm.OpenRestoreBackupCommand.CanExecute(null));
        vm.OpenRestoreBackupCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);

        vm.RestoreBackupDirectory = "   ";
        Assert.False(vm.OpenRestoreBackupCommand.CanExecute(null));
        vm.OpenRestoreBackupCommand.Execute(null);
        Assert.Equal(0, _dialogService.OpenFolderInExplorerCallCount);
    }

    [Fact]
    public void IdentityBackupViewModel_OpenCommands_NullDialogService_DoesNotThrow()
    {
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var vm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _loggerMock.Object, dialogService: null);

        vm.BackupDestinationDirectory = @"D:\ValidBackup";
        vm.RestoreBackupDirectory = @"D:\ValidRestore";

        Assert.True(vm.OpenBackupDestinationCommand.CanExecute(null));
        Assert.True(vm.OpenRestoreBackupCommand.CanExecute(null));

        vm.OpenBackupDestinationCommand.Execute(null);
        vm.OpenRestoreBackupCommand.Execute(null);
    }

    #endregion
}
