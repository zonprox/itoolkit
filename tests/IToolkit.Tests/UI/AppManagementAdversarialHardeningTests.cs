namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Moq;
using Xunit;

/// <summary>
/// Adversarial white-box stress testing and coverage hardening suite for AppManagementViewModel,
/// AsyncRelayCommand, and Presentation Layer state transitions.
/// </summary>
public class AppManagementAdversarialHardeningTests : IDisposable
{
    private readonly Mock<IAppInstallerService> _appInstallerMock = new();
    private readonly Mock<ISafetyConfirmationService> _confirmationMock = new();
    private readonly Mock<IActivityLogger> _loggerMock = new();

    public AppManagementAdversarialHardeningTests()
    {
        ViewModelBase.ResetOperationEvents();
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private AppManagementViewModel CreateViewModel(bool includeConfirmationService = true)
    {
        return new AppManagementViewModel(
            _appInstallerMock.Object,
            includeConfirmationService ? _confirmationMock.Object : null,
            _loggerMock.Object);
    }

    // =========================================================================
    // SECTION 1: BRANCH COVERAGE & EDGE CASE PROBING
    // =========================================================================

    [Theory]
    [InlineData("   7zip   ", "7zip")]
    [InlineData("notepad++", "notepad++")]
    [InlineData("app; drop table;", "app; drop table;")]
    public async Task SearchAppsAsync_QueryTrimmingAndSpecialCharacters_SearchesExactTrimmedQuery(string inputQuery, string expectedTrimmed)
    {
        var vm = CreateViewModel();
        vm.SearchQuery = inputQuery;

        _appInstallerMock.Setup(s => s.SearchPackagesAsync(expectedTrimmed, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetPackage>
            {
                new("TargetApp", "target.app.id", "1.0.0", null, "winget")
            });

        await vm.SearchAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.SearchPackagesAsync(expectedTrimmed, It.IsAny<CancellationToken>()), Times.Once);
        Assert.Single(vm.SearchResults);
        Assert.Contains($"Found 1 package(s) matching '{expectedTrimmed}'.", vm.SearchStatusText);
        Assert.False(vm.IsSearching);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task SearchAppsAsync_WhenZeroResultsReturned_SetsAccurateZeroCountStatus()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "nonexistent_app_404";

        _appInstallerMock.Setup(s => s.SearchPackagesAsync("nonexistent_app_404", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetPackage>());

        await vm.SearchAppsCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.SearchPackagesAsync("nonexistent_app_404", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.SearchResults);
        Assert.Contains("No packages found matching 'nonexistent_app_404'.", vm.SearchStatusText);
        Assert.False(vm.IsSearching);
    }

    [Fact]
    public async Task SearchAppsAsync_WhenMultiplePackagesReturned_WiresSubItemInstallCommandsDirectly()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "editor";

        var packages = new List<WingetPackage>
        {
            new("VS Code", "Microsoft.VisualStudioCode", "1.95.0", null, "winget"),
            new("Notepad++", "Notepad++.Notepad++", "8.7.1", null, "winget")
        };

        _appInstallerMock.Setup(s => s.SearchPackagesAsync("editor", It.IsAny<CancellationToken>()))
            .ReturnsAsync(packages);

        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Notepad++.Notepad++", "Notepad++", "winget", true, "Success", true));

        await vm.SearchAppsCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.SearchResults.Count);

        var notepadVm = vm.SearchResults[1];
        Assert.Equal("Notepad++.Notepad++", notepadVm.Id);

        // Execute sub-item command directly
        await notepadVm.InstallCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.InstallWingetPackageAsync("Notepad++.Notepad++", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Equal("Installed", notepadVm.Status);
        Assert.False(notepadVm.IsInstalling);
    }

    [Fact]
    public void ClearSearch_WhenExecuted_ResetsQueryResultsAndStatusCleanly()
    {
        var vm = CreateViewModel();
        vm.SearchQuery = "terminal";
        vm.SearchResults.Add(new WingetPackageViewModel(new WingetPackage("Terminal", "Microsoft.WindowsTerminal", "1.21", null, "winget")));
        vm.SearchStatusText = "Found 1 package(s) matching 'terminal'.";

        vm.ClearSearchCommand.Execute(null);

        Assert.Equal(string.Empty, vm.SearchQuery);
        Assert.Empty(vm.SearchResults);
        Assert.Equal("Search cleared. Enter a keyword to search.", vm.SearchStatusText);

        // Repeated invocation on already cleared state must not throw
        vm.ClearSearchCommand.Execute(null);
        Assert.Equal(string.Empty, vm.SearchQuery);
        Assert.Empty(vm.SearchResults);
    }

    [Fact]
    public async Task RefreshInstalledAsync_WhenInventoryEmpty_SetsAccurateZeroLoadedStatus()
    {
        var vm = CreateViewModel();

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetInstalledApp>());

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.InstalledApps);
        Assert.Equal("Loaded 0 installed application(s).", vm.InstalledStatusText);
        Assert.False(vm.IsLoadingInstalled);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RefreshInstalledAsync_WhenPopulated_WiresSubItemUninstallCommandsDirectly()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Git", "Git.Git", "2.47.1", null, "winget"),
            new("7-Zip", "7zip.7zip", "24.08", null, "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "winget", true, "Success", true));

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.InstalledApps.Count);

        var zipVm = vm.InstalledApps.First(a => a.Id == "7zip.7zip");

        // Execute sub-item uninstall command directly
        await zipVm.UninstallCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Single(vm.InstalledApps);
        Assert.DoesNotContain(vm.InstalledApps, a => a.Id == "7zip.7zip");
    }

    [Theory]
    [InlineData(".*", 0)]
    [InlineData("[a-z]+", 0)]
    [InlineData("(?i)chrome", 0)]
    [InlineData("Chrome", 1)]
    [InlineData("google", 1)]
    [InlineData("WINGET", 2)]
    public async Task ApplyInstalledFilter_WithSpecialAndRegexCharacters_FiltersSafelyWithoutThrowing(string filter, int expectedCount)
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Google Chrome", "Google.Chrome", "131.0", null, "winget"),
            new("Mozilla Firefox", "Mozilla.Firefox", "133.0", null, "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);

        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.InstalledApps.Count);

        vm.InstalledFilterQuery = filter;
        Assert.Equal(expectedCount, vm.InstalledApps.Count);
    }

    [Fact]
    public async Task CheckUpdatesAsync_WhenZeroUpdates_SetsUpToDateStatusAndDisablesUpgradeAll()
    {
        var vm = CreateViewModel();

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem>());

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));
        Assert.False(vm.IsCheckingUpdates);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task CheckUpdatesAsync_WhenUpdatesExist_WiresSubItemUpdateCommandsDirectly()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("VLC", "VideoLAN.VLC", "3.0.20", "3.0.21", "winget")
        };

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("VideoLAN.VLC", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("VideoLAN.VLC", "VLC", "winget", true, "Success", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Single(vm.AvailableUpdates);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));

        var vlcVm = vm.AvailableUpdates[0];

        // Trigger update directly on sub-item
        await vlcVm.UpdateCommand.ExecuteAsync(null);

        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("VideoLAN.VLC", It.IsAny<CancellationToken>()), Times.Once);
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    // =========================================================================
    // SECTION 2: SAFETY CONFIRMATION REJECTION BRANCHES & STATE INTEGRITY
    // =========================================================================

    [Fact]
    public async Task UninstallAppAsync_WhenConfirmationRejectedMultipleTimes_MaintainsCollectionAndState()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Docker Desktop", "Docker.DockerDesktop", "4.35.0", null, "winget"),
            new("Slack", "SlackTechnologies.Slack", "4.40.0", null, "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);

        await vm.RefreshInstalledAsync();
        Assert.Equal(2, vm.InstalledApps.Count);

        var dockerVm = vm.InstalledApps.First(a => a.Id == "Docker.DockerDesktop");

        // Reject 5 consecutive times
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(false);

        for (int i = 0; i < 5; i++)
        {
            await vm.UninstallAppCommand.ExecuteAsync(dockerVm);
        }

        // Never invoked
        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Exactly(5));

        Assert.Equal(2, vm.InstalledApps.Count);
        Assert.Equal("Installed", dockerVm.Status);
        Assert.False(dockerVm.IsUninstalling);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UninstallAppAsync_WhenConfirmationThrowsOperationCanceledException_RecoversCleanly()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Postman", "Postman.Postman", "11.16.0", null, "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);

        await vm.RefreshInstalledAsync();
        var postmanVm = vm.InstalledApps[0];

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ThrowsAsync(new OperationCanceledException("User dismissed the confirmation prompt abruptly."));

        await Assert.ThrowsAsync<OperationCanceledException>(() => vm.UninstallAppCommand.ExecuteAsync(postmanVm));

        _appInstallerMock.Verify(s => s.UninstallWingetPackageAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
        Assert.Single(vm.InstalledApps);
        Assert.False(postmanVm.IsUninstalling);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task UninstallAppAsync_WhenTargetAppAlsoInAvailableUpdates_RemovesFromBothCollections()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Git", "Git.Git", "2.46.0", "2.47.1", "winget")
        };
        var updates = new List<WingetUpdateItem>
        {
            new("Git", "Git.Git", "2.46.0", "2.47.1", "winget"),
            new("VLC", "VideoLAN.VLC", "3.0.20", "3.0.21", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("Git.Git", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("Git.Git", "Git", "winget", true, "Uninstalled", true));

        await vm.UninstallAppCommand.ExecuteAsync(vm.InstalledApps[0]);

        // Assert removed from InstalledApps AND AvailableUpdates
        Assert.Empty(vm.InstalledApps);
        Assert.Single(vm.AvailableUpdates);
        Assert.Equal("VideoLAN.VLC", vm.AvailableUpdates[0].Id);
        Assert.Contains("Found 1 available package update(s).", vm.UpdatesStatusText);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
        Assert.Equal(100, vm.OperationProgress);
    }

    [Fact]
    public async Task UninstallAppAsync_WhenTargetAppIsLastUpdateInAvailableUpdates_UpdatesStatusToAllUpToDate()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget")
        };
        var updates = new List<WingetUpdateItem>
        {
            new("7-Zip", "7zip.7zip", "24.07", "24.08", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Single(vm.InstalledApps);
        Assert.Single(vm.AvailableUpdates);

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("7zip.7zip", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("7zip.7zip", "7-Zip", "winget", true, "Uninstalled", true));

        await vm.UninstallAppCommand.ExecuteAsync(vm.InstalledApps[0]);

        Assert.Empty(vm.InstalledApps);
        Assert.Empty(vm.AvailableUpdates);
        Assert.Equal("All installed applications are up to date.", vm.UpdatesStatusText);
        Assert.False(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    [Fact]
    public async Task UninstallAppAsync_WhenUninstallationFails_PreservesAvailableUpdatesAndInstalledCollection()
    {
        var vm = CreateViewModel();

        var apps = new List<WingetInstalledApp>
        {
            new("Node.js", "OpenJS.NodeJS", "20.18.0", "22.11.0", "winget")
        };
        var updates = new List<WingetUpdateItem>
        {
            new("Node.js", "OpenJS.NodeJS", "20.18.0", "22.11.0", "winget")
        };

        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(apps);
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.RefreshInstalledAsync();
        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        // Fail uninstall with in-use error (1603)
        _appInstallerMock.Setup(s => s.UninstallWingetPackageAsync("OpenJS.NodeJS", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("OpenJS.NodeJS", "Node.js", "winget", false, "Exit code 1603: Fatal error during uninstallation", true));

        await vm.UninstallAppCommand.ExecuteAsync(vm.InstalledApps[0]);

        // Ensure item was NOT removed
        Assert.Single(vm.InstalledApps);
        Assert.Single(vm.AvailableUpdates);
        Assert.Contains("Failed: Exit code 1603", vm.InstalledApps[0].Status);
        Assert.False(vm.InstalledApps[0].IsUninstalling);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Contains("Uninstallation failed.", vm.OperationProgressText);
    }

    // =========================================================================
    // SECTION 3: CONCURRENCY REENTRANCY & RAPID TAB SWITCHING SIMULATION
    // =========================================================================

    [Fact]
    public async Task RapidTabSwitchingSimulation_WhileInstallInProgress_BlocksAllOtherCommands()
    {
        var vm = CreateViewModel();

        var pkg = new WingetPackage("PowerToys", "Microsoft.PowerToys", "0.85.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        var installTcs = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("Microsoft.PowerToys", It.IsAny<CancellationToken>()))
            .Returns(installTcs.Task);

        // 1. User starts download/install on Tab 1
        var installTask = vm.InstallAppCommand.ExecuteAsync(pkgVm);

        // Verify busy state
        Assert.True(vm.IsBusy);
        Assert.False(vm.IsNotBusy);
        Assert.True(pkgVm.IsInstalling);

        // 2. User rapidly switches to Tab 2 and clicks Refresh Installed
        var refreshTask = vm.RefreshInstalledCommand.ExecuteAsync(null);

        // 3. User rapidly switches to Tab 3 and clicks Check Updates
        var checkUpdatesTask = vm.CheckUpdatesCommand.ExecuteAsync(null);

        // 4. User rapidly switches back to Tab 1 and clicks Search Winget
        vm.SearchQuery = "rust";
        var searchTask = vm.SearchAppsCommand.ExecuteAsync(null);

        // Complete the long-running install
        installTcs.SetResult(new AppInstallResult("Microsoft.PowerToys", "PowerToys", "winget", true, "Installed", true));
        await installTask;
        await Task.WhenAll(refreshTask, checkUpdatesTask, searchTask);

        // Assert the concurrent commands were rejected by CanExecute/ExecuteAsync guard
        _appInstallerMock.Verify(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()), Times.Never);
        _appInstallerMock.Verify(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()), Times.Never);
        _appInstallerMock.Verify(s => s.SearchPackagesAsync("rust", It.IsAny<CancellationToken>()), Times.Never);

        // State is completely recovered
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.False(pkgVm.IsInstalling);
        Assert.Equal("Installed", pkgVm.Status);
    }

    [Fact]
    public async Task RapidTabSwitchingSimulation_WhileBatchUpgradeInProgress_BlocksAllOtherCommands()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1", "App1.Id", "1.0", "2.0", "winget"),
            new("App2", "App2.Id", "1.0", "2.0", "winget")
        };
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.AvailableUpdates.Count);

        var upgradeTcs = new TaskCompletionSource<AppInstallResult>();
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App1.Id", It.IsAny<CancellationToken>()))
            .Returns(upgradeTcs.Task);
        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App2.Id", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("App2.Id", "App2", "winget", true, "Upgraded", true));

        // Start batch upgrade on Tab 3
        var batchTask = vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        Assert.True(vm.IsBusy);

        // Try executing actions on Tab 1 & Tab 2
        var searchTask = vm.SearchAppsCommand.ExecuteAsync(null);
        var refreshTask = vm.RefreshInstalledCommand.ExecuteAsync(null);

        // Finish App1 upgrade
        upgradeTcs.SetResult(new AppInstallResult("App1.Id", "App1", "winget", true, "Upgraded", true));
        await batchTask;
        await Task.WhenAll(searchTask, refreshTask);

        Assert.Empty(vm.AvailableUpdates);
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
    }

    [Fact]
    public async Task AsyncRelayCommand_HighConcurrencyStress_50Threads_GuaranteesSingleExecution()
    {
        int executionCounter = 0;
        int activeConcurrency = 0;
        int maxObservedConcurrency = 0;
        var tcs = new TaskCompletionSource();

        var command = new AsyncRelayCommand(async () =>
        {
            int current = Interlocked.Increment(ref activeConcurrency);
            lock (tcs)
            {
                if (current > maxObservedConcurrency)
                {
                    maxObservedConcurrency = current;
                }
            }
            Interlocked.Increment(ref executionCounter);
            await tcs.Task;
            Interlocked.Decrement(ref activeConcurrency);
        });

        // Dispatch 50 concurrent executions simultaneously
        var tasks = Enumerable.Range(0, 50)
            .Select(_ => Task.Run(() => command.ExecuteAsync(null)))
            .ToArray();

        // Allow some time for all threads to hit the guard
        await Task.Delay(50);

        Assert.True(command.IsExecuting);
        Assert.False(command.CanExecute(null));

        // Release the execution
        tcs.SetResult();
        await Task.WhenAll(tasks);

        // Strictly 1 execution occurred
        Assert.Equal(1, executionCounter);
        Assert.Equal(1, maxObservedConcurrency);
        Assert.False(command.IsExecuting);
        Assert.True(command.CanExecute(null));
    }

    [Fact]
    public async Task AsyncRelayCommandGeneric_NullParameterHandling_ForReferenceAndValueTypes()
    {
        // 1. Reference type command
        string? receivedRef = null;
        var refCommand = new AsyncRelayCommand<string>(s =>
        {
            receivedRef = s;
            return Task.CompletedTask;
        });

        Assert.True(refCommand.CanExecute(null));
        await refCommand.ExecuteAsync(null);
        Assert.Null(receivedRef);

        await refCommand.ExecuteAsync("hello");
        Assert.Equal("hello", receivedRef);

        // 2. Non-nullable value type command (int)
        int receivedVal = -1;
        var valCommand = new AsyncRelayCommand<int>(i =>
        {
            receivedVal = i;
            return Task.CompletedTask;
        });

        Assert.True(valCommand.CanExecute(null));
        await valCommand.ExecuteAsync(null);
        Assert.Equal(0, receivedVal); // default(int) is 0

        await valCommand.ExecuteAsync(42);
        Assert.Equal(42, receivedVal);
    }

    // =========================================================================
    // SECTION 4: MULTIPLE SIMULTANEOUS CANCELLATIONS & EXCEPTION RESILIENCE
    // =========================================================================

    [Fact]
    public async Task InstallAppAsync_WhenCanceledByService_ResetsBusyAndInstallingFlags()
    {
        var vm = CreateViewModel();
        var pkg = new WingetPackage("PostgreSQL", "PostgreSQL.PostgreSQL", "16.4", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        vm.SearchResults.Add(pkgVm);

        _appInstallerMock.Setup(s => s.InstallWingetPackageAsync("PostgreSQL.PostgreSQL", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Installation canceled by cancellation token."));

        await vm.InstallAppCommand.ExecuteAsync(pkgVm);

        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.False(pkgVm.IsInstalling);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Failed: Installation canceled", pkgVm.Status);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Equal("Installation failed.", vm.OperationProgressText);
    }

    [Fact]
    public async Task UpdateAppAsync_WhenCanceledByService_ResetsBusyAndUpdatingFlags()
    {
        var vm = CreateViewModel();
        var update = new WingetUpdateItem("Zoom", "Zoom.Zoom", "5.16.0", "6.2.0", "winget");
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem> { update });

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        var updateVm = vm.AvailableUpdates[0];

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("Zoom.Zoom", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Package upgrade timed out and was aborted."));

        await vm.UpdateAppCommand.ExecuteAsync(updateVm);

        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.False(updateVm.IsUpdating);
        Assert.Contains("failed", vm.StatusMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Failed: Package upgrade timed out", updateVm.Status);
        Assert.Equal(0, vm.OperationProgress);
        Assert.Equal("Update failed.", vm.OperationProgressText);
    }

    [Fact]
    public async Task SimultaneousCancellations_MultipleConsecutiveOperations_AllRecoverToNotBusy()
    {
        var vm = CreateViewModel();

        // Cancel Search
        _appInstallerMock.Setup(s => s.SearchPackagesAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Search canceled"));
        vm.SearchQuery = "test";
        await vm.SearchAppsCommand.ExecuteAsync(null);
        Assert.False(vm.IsBusy);
        Assert.False(vm.IsSearching);

        // Cancel Refresh
        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Refresh canceled"));
        await vm.RefreshInstalledCommand.ExecuteAsync(null);
        Assert.False(vm.IsBusy);
        Assert.False(vm.IsLoadingInstalled);

        // Cancel CheckUpdates
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new OperationCanceledException("Updates canceled"));
        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.False(vm.IsBusy);
        Assert.False(vm.IsCheckingUpdates);

        // Clean operational state
        Assert.True(vm.IsNotBusy);
    }

    // =========================================================================
    // SECTION 5: BATCH WORKFLOW ERROR PROPAGATION & PARTIAL FAILURE RESILIENCE
    // =========================================================================

    [Fact]
    public async Task UpgradeAllAppsAsync_ComplexMixedFailureAndExceptionSequence_ProcessesAllItemsAndThrowsFirstException()
    {
        var vm = CreateViewModel();

        var updates = new List<WingetUpdateItem>
        {
            new("App1", "App1.Id", "1.0", "1.1", "winget"), // Succeeds
            new("App2", "App2.Id", "1.0", "1.1", "winget"), // Throws TimeoutException
            new("App3", "App3.Id", "1.0", "1.1", "winget"), // Returns Failure result
            new("App4", "App4.Id", "1.0", "1.1", "winget"), // Throws HttpRequestException
            new("App5", "App5.Id", "1.0", "1.1", "winget")  // Succeeds
        };

        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(updates);

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App1.Id", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("App1.Id", "App1", "winget", true, "Success", true));

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App2.Id", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new TimeoutException("App2 timed out"));

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App3.Id", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("App3.Id", "App3", "winget", false, "App3 hash error", true));

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App4.Id", It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("App4 connection drop"));

        _appInstallerMock.Setup(s => s.UpgradeWingetPackageAsync("App5.Id", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AppInstallResult("App5.Id", "App5", "winget", true, "Success", true));

        await vm.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal(5, vm.AvailableUpdates.Count);

        // Execute batch update
        await vm.UpgradeAllAppsCommand.ExecuteAsync(null);

        // 1. Verify ALL 5 items were attempted
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("App1.Id", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("App2.Id", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("App3.Id", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("App4.Id", It.IsAny<CancellationToken>()), Times.Once);
        _appInstallerMock.Verify(s => s.UpgradeWingetPackageAsync("App5.Id", It.IsAny<CancellationToken>()), Times.Once);

        // 2. Successful items (1 and 5) removed; Failed items (2, 3, 4) remain
        Assert.Equal(3, vm.AvailableUpdates.Count);
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "App2.Id" && u.Status == "Failed: App2 timed out");
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "App3.Id" && u.Status == "Failed: App3 hash error");
        Assert.Contains(vm.AvailableUpdates, u => u.Id == "App4.Id" && u.Status == "Failed: App4 connection drop");

        // 3. Progress and status text accurately report 2 of 5
        Assert.Equal(100, vm.OperationProgress);
        Assert.Equal("Batch update completed.", vm.OperationProgressText);
        Assert.Equal("Batch upgrade finished: 2 of 5 package(s) updated.", vm.UpdatesStatusText);

        // 4. Status message captures the first encountered exception
        Assert.Contains("Upgrade All Applications failed: App2 timed out", vm.StatusMessage);

        // 5. ViewModel is unblocked and ready for retry
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.True(vm.UpgradeAllAppsCommand.CanExecute(null));
    }

    // =========================================================================
    // SECTION 6: PRESENTATION MODELS EDGE CASES & INVARIANTS
    // =========================================================================

    [Fact]
    public void PresentationViewModels_NullModelInConstructor_ThrowsArgumentNullException()
    {
        Assert.Throws<ArgumentNullException>("package", () => new WingetPackageViewModel(null!));
        Assert.Throws<ArgumentNullException>("app", () => new InstalledAppViewModel(null!));
        Assert.Throws<ArgumentNullException>("updateItem", () => new AppUpdateViewModel(null!));
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("   ", false)]
    [InlineData("2.0.0", true)]
    [InlineData("unknown", true)]
    public void InstalledAppViewModel_HasUpdate_StrictPrecisionTesting(string? availableVersion, bool expectedHasUpdate)
    {
        var app = new WingetInstalledApp("App", "app.id", "1.0.0", availableVersion, "winget");
        var vm = new InstalledAppViewModel(app);

        Assert.Equal(expectedHasUpdate, vm.HasUpdate);
    }

    [Fact]
    public void PresentationViewModels_IsWorkingPropertyChanges_RaiseCanExecuteChanged()
    {
        // 1. WingetPackageViewModel
        var pkg = new WingetPackage("App", "app.id", "1.0", null, "winget");
        var pkgVm = new WingetPackageViewModel(pkg);
        int pkgCanExecuteChangeCount = 0;
        pkgVm.InstallCommand.CanExecuteChanged += (_, _) => pkgCanExecuteChangeCount++;

        Assert.True(pkgVm.InstallCommand.CanExecute(null));
        pkgVm.IsInstalling = true;
        Assert.False(pkgVm.InstallCommand.CanExecute(null));
        pkgVm.IsInstalling = false;
        Assert.True(pkgVm.InstallCommand.CanExecute(null));
        Assert.True(pkgCanExecuteChangeCount >= 2);

        // 2. InstalledAppViewModel
        var app = new WingetInstalledApp("App", "app.id", "1.0", null, "winget");
        var appVm = new InstalledAppViewModel(app);
        int appCanExecuteChangeCount = 0;
        appVm.UninstallCommand.CanExecuteChanged += (_, _) => appCanExecuteChangeCount++;

        Assert.True(appVm.UninstallCommand.CanExecute(null));
        appVm.IsUninstalling = true;
        Assert.False(appVm.UninstallCommand.CanExecute(null));
        appVm.IsUninstalling = false;
        Assert.True(appVm.UninstallCommand.CanExecute(null));
        Assert.True(appCanExecuteChangeCount >= 2);

        // 3. AppUpdateViewModel
        var upd = new WingetUpdateItem("App", "app.id", "1.0", "2.0", "winget");
        var updVm = new AppUpdateViewModel(upd);
        int updCanExecuteChangeCount = 0;
        updVm.UpdateCommand.CanExecuteChanged += (_, _) => updCanExecuteChangeCount++;

        Assert.True(updVm.UpdateCommand.CanExecute(null));
        updVm.IsUpdating = true;
        Assert.False(updVm.UpdateCommand.CanExecute(null));
        updVm.IsUpdating = false;
        Assert.True(updVm.UpdateCommand.CanExecute(null));
        Assert.True(updCanExecuteChangeCount >= 2);
    }

    [Fact]
    public async Task ViewModelBase_OperationEvents_AreRaisedCorrectlyWithExitCodes()
    {
        var vm = CreateViewModel();

        string? startedOp = null;
        string? finishedOp = null;
        bool? finishedSuccess = null;
        int? finishedExitCode = null;

        ViewModelBase.OperationStarted += op => startedOp = op;
        ViewModelBase.OperationFinished += (op, success, code) =>
        {
            finishedOp = op;
            finishedSuccess = success;
            finishedExitCode = code;
        };

        // 1. Successful operation
        _appInstallerMock.Setup(s => s.GetAvailableUpdatesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<WingetUpdateItem>());

        await vm.CheckUpdatesCommand.ExecuteAsync(null);

        Assert.Equal("Check Available Updates", startedOp);
        Assert.Equal("Check Available Updates", finishedOp);
        Assert.True(finishedSuccess);
        Assert.Equal(0, finishedExitCode);

        // 2. Failed operation
        _appInstallerMock.Setup(s => s.GetInstalledApplicationsAsync(It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("Registry error"));

        await vm.RefreshInstalledCommand.ExecuteAsync(null);

        Assert.Equal("Refresh Installed Applications", startedOp);
        Assert.Equal("Refresh Installed Applications", finishedOp);
        Assert.False(finishedSuccess);
        Assert.Equal(1, finishedExitCode);
    }
}
