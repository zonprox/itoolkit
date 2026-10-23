namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using Moq;
using Xunit;

public class DashboardAndNavigationTests
{
    [Fact]
    public async Task DashboardViewModel_QuickSystemRepairCommand_InvokesBothDismAndSfc()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();
        var loggerMock = new Mock<IActivityLogger>();

        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Returns((DismScanResult.Successful("DISM OK"), SfcScanResult.Clean("SFC OK")));

        var vm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            loggerMock.Object);

        await vm.QuickSystemRepairCommand.ExecuteAsync(null);

        healthMock.Verify(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()), Times.Once);
        Assert.Contains("healthy", vm.SystemHealthStatus);
    }

    [Fact]
    public async Task DashboardViewModel_QuickMailRepairCommand_InvokesQuickMailAndCacheRepair()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();
        var loggerMock = new Mock<IActivityLogger>();

        outlookMock.Setup(o => o.QuickMailAndCacheRepair(It.IsAny<string?>()))
            .Returns(new QuickMailRepairResult(true, true, true, true, true, true, "Mail repair OK"));

        var vm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            loggerMock.Object);

        await vm.QuickMailRepairCommand.ExecuteAsync(null);

        outlookMock.Verify(o => o.QuickMailAndCacheRepair(It.IsAny<string?>()), Times.Once);
        Assert.Contains("clean", vm.OfficeStatus);
    }

    [Fact]
    public async Task DashboardViewModel_QuickNetworkResetCommand_ResetsStack()
    {
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();
        var loggerMock = new Mock<IActivityLogger>();

        netMock.Setup(n => n.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "Reset OK"));

        var vm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            loggerMock.Object);

        await vm.QuickNetworkResetCommand.ExecuteAsync(null);

        netMock.Verify(n => n.RemediateNetworkStack(), Times.Once);
        Assert.Contains("ready", vm.NetworkStatus);
    }

    [Fact]
    public void MainViewModel_NavigateCommand_SwitchesCurrentView()
    {
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var elevationMock = new Mock<IElevationService>();
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var appInstallerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();
        var loggerMock = new Mock<IActivityLogger>();

        appInstallerMock.Setup(a => a.GetCatalog()).Returns(new List<AppCatalogItem>());
        printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new List<string>());

        var telemetryHeader = new TelemetryHeaderViewModel(telemetryMock.Object, elevationMock.Object);
        telemetryHeader.StopPolling();

        var activityConsole = new ActivityConsoleViewModel(loggerMock.Object);
        var dashboardVm = new DashboardViewModel(healthMock.Object, officeMock.Object, outlookMock.Object, netMock.Object, backupMock.Object, optMock.Object, loggerMock.Object);
        var healthVm = new SystemHealthViewModel(healthMock.Object, loggerMock.Object);
        var officeVm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, loggerMock.Object);
        var connectivityVm = new ConnectivityViewModel(netMock.Object, printerMock.Object, loggerMock.Object);
        var identityVm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, loggerMock.Object);
        var softwareVm = new SoftwareOptimizationViewModel(appInstallerMock.Object, optMock.Object, loggerMock.Object);

        var mainVm = new MainViewModel(
            telemetryHeader,
            activityConsole,
            dashboardVm,
            healthVm,
            officeVm,
            connectivityVm,
            identityVm,
            softwareVm);

        Assert.Equal("iToolKit", mainVm.AppTitle);
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);

        mainVm.NavigateCommand.Execute("SystemHealth");
        Assert.Equal("SystemHealth", mainVm.CurrentPillarName);
        Assert.Same(healthVm, mainVm.CurrentPageViewModel);

        mainVm.NavigateCommand.Execute("Connectivity");
        Assert.Equal("Connectivity", mainVm.CurrentPillarName);
        Assert.Same(connectivityVm, mainVm.CurrentPageViewModel);

        mainVm.NavigateCommand.Execute("SoftwareOptimization");
        Assert.Equal("SoftwareOptimization", mainVm.CurrentPillarName);
        Assert.Same(softwareVm, mainVm.CurrentPageViewModel);

        mainVm.NavigateCommand.Execute("Dashboard");
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);
        Assert.Same(dashboardVm, mainVm.CurrentPageViewModel);
    }

    [Fact]
    public async Task TelemetryHeaderViewModel_RefreshTelemetryAsync_PullsSnapshot()
    {
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var elevationMock = new Mock<IElevationService>();

        var snapshot = new TelemetrySnapshot(
            OsDescription: "Windows 11 Pro 64-bit",
            OsBuild: "22631.3007",
            IsElevated: true,
            CpuUsagePercentage: 15.5,
            MemoryUsedBytes: 8_589_934_592, // 8 GB
            MemoryTotalBytes: 17_179_869_184, // 16 GB
            SystemDriveFreeBytes: 214_748_364_800, // 200 GB
            SystemDriveTotalBytes: 536_870_912_000, // 500 GB
            NetworkConnected: true,
            ActiveTaskDescription: "Idle"
        );

        telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>())).ReturnsAsync(snapshot);

        var vm = new TelemetryHeaderViewModel(telemetryMock.Object, elevationMock.Object);
        vm.StopPolling();

        await vm.RefreshTelemetryAsync();

        Assert.Equal("Windows 11 Pro 64-bit", vm.OsDescription);
        Assert.Equal("22631.3007", vm.OsBuild);
        Assert.True(vm.IsElevated);
        Assert.Equal("Administrator", vm.ElevationBadgeText);
        Assert.Equal("16%", vm.CpuUsageText);
        Assert.Contains("8.0 / 16.0 GB", vm.MemoryUsageText);
        Assert.Contains("200.0 GB Free", vm.DiskFreeSpaceText);
        Assert.Equal("Connected", vm.NetworkStatusText);
    }
}
