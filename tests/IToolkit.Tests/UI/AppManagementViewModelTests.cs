namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Moq;
using Xunit;

public class AppManagementViewModelTests
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    private AppManagementViewModel CreateViewModel()
    {
        return new AppManagementViewModel(
            _appInstallerMock.Object,
            _confirmationMock.Object,
            _loggerMock.Object);
    }

    [Fact]
    public void Constructor_InitializesEmptyCollectionsAndReadyState()
    {
        var vm = CreateViewModel();

        Assert.NotNull(vm.SearchResults);
        Assert.Empty(vm.SearchResults);
        Assert.NotNull(vm.InstalledApps);
        Assert.Empty(vm.InstalledApps);
        Assert.NotNull(vm.AvailableUpdates);
        Assert.Empty(vm.AvailableUpdates);

        Assert.False(vm.IsSearching);
        Assert.False(vm.IsLoadingInstalled);
        Assert.False(vm.IsCheckingUpdates);
        Assert.False(vm.IsBusy);

        Assert.Contains("Search", vm.SearchStatusText);
        Assert.Contains("Refresh", vm.InstalledStatusText);
        Assert.Contains("Check for Updates", vm.UpdatesStatusText);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public async Task SearchAppsCommand_WithEmptyOrWhitespaceQuery_DoesNotInvokeSearchService(string? query)
    {
        var vm = CreateViewModel();
        vm.SearchQuery = query ?? string.Empty;

        await vm.SearchAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.SearchPackagesAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Contains("valid application name", vm.SearchStatusText);
        Assert.Empty(vm.SearchResults);
    }

    [Fact]
    public async Task SearchAppsCommand_WithValidQuery_QueriesWingetAndPopulatesResults()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "7zip";

        var packages = new List<WingetPackage>
        {
            new("7-Zip", "7zip.7zip", "24.08", null, "winget"),
            new("7-Zip Command Line", "7zip.commandline", "24.08", null, "winget")
        };

        _appInstallerMock.Setup(a => a.SearchPackagesAsync("7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(packages);

        await vm.SearchAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.SearchPackagesAsync("7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Equal(2, vm.SearchResults.Count);
        Assert.Equal("7-Zip", vm.SearchResults[0].Name);
        Assert.Equal("7zip.7zip", vm.SearchResults[0].Id);
        Assert.Equal("24.08", vm.SearchResults[0].Version);
        Assert.Equal("winget", vm.SearchResults[0].Source);
        Assert.Contains("Found 2 package(s)", vm.SearchStatusText);
    }

    [Fact]
    public void ClearSearchCommand_ClearsSearchQueryAndResults()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "notepad++";
        vm.SearchResults.Add(new WingetPackageViewModel(new WingetPackage("Notepad++", "Notepad++.Notepad++", "8.7.1", null, "winget")));

        Assert.Single(vm.SearchResults);
        Assert.NotEmpty(vm.SearchQuery);

        vm.ClearSearchCommand.Execute(null);

        Assert.Empty(vm.SearchQuery);
        Assert.Empty(vm.SearchResults);
        Assert.Contains("cleared", vm.SearchStatusText);
    }

    [Fact]
    public async Task RefreshInstalledCommand_LoadsApplicationsAndAppliesFilter()
    {
        var vm = CreateViewModel();

        var installed = new List<WingetInstalledApp>
        {
            new("Git", "Git.Git", "2.47.1", null, "winget"),
            new("Google Chrome", "Google.Chrome", "131.0.6778.86", null, "winget"),
            new("Mozilla Firefox", "Mozilla.Firefox", "133.0", "133.0.1", "winget")
        };

        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()), Times.Once);
        Assert.Equal(3, vm.InstalledApps.Count);
        Assert.Contains("Loaded 3 installed", vm.InstalledStatusText);

        var firefox = vm.InstalledApps.FirstOrDefault(a => a.Id == "Mozilla.Firefox");
        Assert.NotNull(firefox);
        Assert.True(firefox.HasUpdate);
        Assert.Equal("133.0.1", firefox.AvailableVersion);
    }

    [Fact]
    public async Task InstalledFilterQuery_FiltersInstalledAppsByNameAndId()
    {
        var vm = CreateViewModel();

        var installed = new List<WingetInstalledApp>
        {
            new("Git", "Git.Git", "2.47.1", null, "winget"),
            new("Google Chrome", "Google.Chrome", "131.0", null, "winget"),
            new("Mozilla Firefox", "Mozilla.Firefox", "133.0", null, "winget")
        };

        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(installed);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(3, vm.InstalledApps.Count);

        // Filter by Name
        vm.InstalledFilterQuery = "Chrome";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Google Chrome", vm.InstalledApps[0].Name);

        // Filter by Package ID (case-insensitive)
        vm.InstalledFilterQuery = "git";
        Assert.Single(vm.InstalledApps);
        Assert.Equal("Git.Git", vm.InstalledApps[0].Id);

        // Clear filter
        vm.InstalledFilterQuery = string.Empty;
        Assert.Equal(3, vm.InstalledApps.Count);
    }

    [Fact]
    public async Task CheckUpdatesCommand_LoadsAvailableUpdates()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.0", "8.7.1", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()), Times.Once);
        Assert.Equal(2, vm.AvailableUpdates.Count);
        Assert.Equal("7-Zip", vm.AvailableUpdates[0].Name);
        Assert.Equal("24.07", vm.AvailableUpdates[0].InstalledVersion);
        Assert.Equal("24.08", vm.AvailableUpdates[0].AvailableVersion);
        Assert.Contains("Found 2 available", vm.UpdatesStatusText);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task InstallAppCommand_CallsInstallWingetPackageAsync_AndUpdatesStatus()
    {
        var vm = CreateViewModel();

        var pkg = new WingetPackage("7-Zip", "7zip.7zip", "24.08", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(a => a.InstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "Winget", true, "Success", true));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        _appInstallerMock.Verify(a => a.InstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Equal("Installed", pkgVm.Status);
        Assert.False(pkgVm.IsInstalling);
        Assert.Equal(100, vm.OperationProgress);
        Assert.Contains("Install 7-Zip completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task InstallAppCommand_OnFailure_SetsFailedStatus()
    {
        var vm = CreateViewModel();

        var pkg = new WingetPackage("7-Zip", "7zip.7zip", "24.08", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(a => a.InstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "Winget", false, "Exit code 0x8A150014: Check hash failed", true));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        _appInstallerMock.Verify(a => a.InstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Contains("Failed", pkgVm.Status);
        Assert.False(pkgVm.IsInstalling);
        Assert.Equal(0, vm.OperationProgress);
    }

    [Fact]
    public async Task UninstallAppCommand_WhenConfirmed_CallsUninstall_AndRemovesApp()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Git", "Git.Git", "2.47.1", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        Assert.Single(vm.InstalledApps);
        var appVm = vm.InstalledApps[0];

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(a => a.UninstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Git.Git", "Git", "Winget", true, "Uninstalled", true));

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Once);
        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.InstalledApps);
        Assert.Contains("Uninstall Git completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task UninstallAppCommand_WhenCancelled_DoesNotCallUninstall()
    {
        var vm = CreateViewModel();

        var app = new WingetInstalledApp("Git", "Git.Git", "2.47.1", null, "winget");
        _appInstallerMock.Setup(a => a.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp> { app });

        await vm.RefreshInstalledAsync();
        Assert.Single(vm.InstalledApps);
        var appVm = vm.InstalledApps[0];

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(false);

        await vm.UninstallAppCommand.ExecuteAsync(appVm);

        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Once);
        _appInstallerMock.Verify(a => a.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Single(vm.InstalledApps);
    }

    [Fact]
    public async Task UpdateAppCommand_CallsUpgrade_AndRemovesFromAvailableUpdates()
    {
        var vm = CreateViewModel();

        var update = new WingetUpdateItem("7-Zip", "7zip.7zip", "24.07", "24.08", "winget");
        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { update });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Single(vm.AvailableUpdates);
        var updateVm = vm.AvailableUpdates[0];

        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "Winget", true, "Upgraded", true));

        await vm.UpdateAppCommand.ExecuteAsync(updateVm);

        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.AvailableUpdates);
        Assert.Contains("Update 7-Zip completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task UpgradeAllAppsCommand_UpgradesAllItemsInSequence()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.0", "8.7.1", "winget")
        };

        _appInstallerMock.Setup(a => a.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        _appInstallerMock.Setup(a => a.UpgradeWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("app", "app", "Winget", true, "Upgraded", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(a => a.UpgradeWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal(100, vm.OperationProgress);
        Assert.Contains("2 of 2 package(s) updated", vm.UpdatesStatusText);
    }

    [Fact]
    public async Task SubViewModels_DirectCommandExecution_InvokesConfiguredDelegates()
    {
        bool installCalled = false;
        var pkg = new WingetPackage("App", "app.id", "1.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg, () => { installCalled = true; return Task.CompletedTask; });
        await pkgVm.InstallCommand.ExecuteAsync(null);
        Assert.True(installCalled);

        bool uninstallCalled = false;
        var app = new WingetInstalledApp("App", "app.id", "1.0", null, "winget");
        var appVm = new InstalledAppViewModel(app, () => { uninstallCalled = true; return Task.CompletedTask; });
        await appVm.UninstallCommand.ExecuteAsync(null);
        Assert.True(uninstallCalled);

        bool updateCalled = false;
        var update = new WingetUpdateItem("App", "app.id", "1.0", "2.0", "winget");
        var updateVm = new AppUpdateViewModel(update, () => { updateCalled = true; return Task.CompletedTask; });
        await updateVm.UpdateCommand.ExecuteAsync(null);
        Assert.True(updateCalled);
    }
}
