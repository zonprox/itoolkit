namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Moq;
using Xunit;

public class SoftwareOptimizationViewModelTests
{
    private readonly Mock<IAppInstallerService> _appInstallerMock;
    private readonly Mock<IOptimizationService> _optimizationMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    private readonly List<AppCatalogItem> _catalog = new()
    {
        new AppCatalogItem("chrome", "Google Chrome", "Google.Chrome", AppInstallMode.WingetWithFallback, "https://dl.google.com/chrome.exe", "/silent /install", "Google Chrome", "browser", Array.Empty<string>()),
        new AppCatalogItem("firefox", "Mozilla Firefox", "Mozilla.Firefox", AppInstallMode.WingetWithFallback, "https://download.mozilla.org/firefox.exe", "-ms", "Mozilla Firefox", "browser", Array.Empty<string>()),
        new AppCatalogItem("unikey", "UniKey", null, AppInstallMode.ArchiveExtract, "https://www.unikey.org/unikey.zip", "", "UniKey", null, Array.Empty<string>())
    };

    public SoftwareOptimizationViewModelTests()
    {
        _appInstallerMock = new Mock<IAppInstallerService>();
        _optimizationMock = new Mock<IOptimizationService>();
        _loggerMock = new Mock<IActivityLogger>();

        _appInstallerMock
            .Setup(s => s.GetCatalog())
            .Returns(_catalog);
    }

    [Fact]
    public void Constructor_LoadsCatalogAndInitializesList()
    {
        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);

        Assert.Equal(3, vm.CatalogApps.Count);
        Assert.Equal("chrome", vm.CatalogApps[0].Item.AppId);
    }

    [Fact]
    public void SelectAllAndDeselectAll_TogglesSelectionState()
    {
        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);

        vm.SelectAllCommand.Execute(null);
        Assert.All(vm.CatalogApps, a => Assert.True(a.IsSelected));

        vm.DeselectAllCommand.Execute(null);
        Assert.All(vm.CatalogApps, a => Assert.False(a.IsSelected));
    }

    [Fact]
    public async Task BatchInstallCommand_InstallsSelectedApps()
    {
        _appInstallerMock
            .Setup(s => s.InstallApplication("chrome"))
            .Returns(new AppInstallResult("chrome", "Google Chrome", "Winget", true, "Installed via Winget", true));
        _appInstallerMock
            .Setup(s => s.InstallApplication("firefox"))
            .Returns(new AppInstallResult("firefox", "Mozilla Firefox", "Winget", true, "Installed via Winget", true));

        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);

        vm.CatalogApps[0].IsSelected = true;
        vm.CatalogApps[1].IsSelected = true;

        await vm.BatchInstallCommand.ExecuteAsync(null);

        Assert.Equal("Installed", vm.CatalogApps[0].Status);
        Assert.Equal("Installed", vm.CatalogApps[1].Status);
        Assert.Contains("Batch installation finished for 2 applications", vm.LastSoftwareStatus);
        _appInstallerMock.Verify(s => s.InstallApplication("chrome"), Times.Once);
        _appInstallerMock.Verify(s => s.InstallApplication("firefox"), Times.Once);
    }

    [Fact]
    public async Task CheckWingetStatusCommand_UpdatesVersionAndHealthText()
    {
        _optimizationMock
            .Setup(s => s.GetWingetStatus())
            .Returns(new WingetStatus(true, "1.7.10861", true, true, "Winget healthy"));

        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);

        await vm.CheckWingetStatusCommand.ExecuteAsync(null);

        Assert.Equal("v1.7.10861 (Healthy)", vm.WingetVersionText);
        Assert.Equal("Winget healthy", vm.LastSoftwareStatus);
    }

    [Fact]
    public async Task LaunchWin11DebloatCommand_ExecutesAndReportsStatus()
    {
        _optimizationMock
            .Setup(s => s.LaunchWin11Debloat(null))
            .Returns(new DebloatExecutionResult("Win11Debloat", "https://example.com/script.ps1", true, true, 0, true, "Output", "Win11Debloat executed successfully."));

        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);

        await vm.LaunchWin11DebloatCommand.ExecuteAsync(null);

        Assert.Contains("Win11Debloat executed successfully", vm.LastSoftwareStatus);
    }

    [Fact]
    public async Task BatchInstallCommand_ExceptionInFirstApp_ContinuesRemainingApps()
    {
        _appInstallerMock
            .Setup(s => s.InstallApplication("chrome"))
            .Throws(new InvalidOperationException("Download hash mismatch"));
        _appInstallerMock
            .Setup(s => s.InstallApplication("firefox"))
            .Returns(new AppInstallResult("firefox", "Mozilla Firefox", "Winget", true, "Installed", true));

        var vm = new SoftwareOptimizationViewModel(_appInstallerMock.Object, _optimizationMock.Object, _loggerMock.Object);
        vm.CatalogApps[0].IsSelected = true;
        vm.CatalogApps[1].IsSelected = true;

        await vm.BatchInstallCommand.ExecuteAsync(null);

        Assert.Equal("Failed", vm.CatalogApps[0].Status);
        Assert.Equal("Installed", vm.CatalogApps[1].Status);
        Assert.Contains("Batch installation finished with 1 failure(s)", vm.LastSoftwareStatus);
        _appInstallerMock.Verify(s => s.InstallApplication("chrome"), Times.Once);
        _appInstallerMock.Verify(s => s.InstallApplication("firefox"), Times.Once);
    }
}
