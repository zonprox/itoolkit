namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Unit tests for ViewModel navigation, rail toggles, activity console commands,
/// and ViewModelBase asynchronous execution lifecycle and diagnostic exception logging.
/// </summary>
public class ViewModelLifecycleAndEventLoggingTests : IDisposable
{
    private readonly TestActivityLogger _logger = new();

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private class FakeClipboardService : IClipboardService
    {
        public string? CopiedText { get; private set; }
        public void SetText(string text) => CopiedText = text;
    }

    private class TestOperationViewModel : ViewModelBase
    {
        public TestOperationViewModel(IActivityLogger? logger = null) : base(logger)
        {
        }

        public Task RunSuccessAsync(string operationName) => ExecuteAsync(operationName, () => Task.CompletedTask);

        public Task RunFailureAsync(string operationName, Exception ex) => ExecuteAsync(operationName, () => Task.FromException(ex));

        public Task RunLongRunningAsync(string operationName, TaskCompletionSource<bool> tcs) => ExecuteAsync(operationName, async () => await tcs.Task);
    }

    private MainViewModel CreateMainViewModel()
    {
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var appInstallerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();

        appInstallerMock.Setup(a => a.GetCatalog()).Returns(new List<AppCatalogItem>());
        printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new List<string>());

        var telemetryHeader = new TelemetryHeaderViewModel(telemetryMock.Object);
        telemetryHeader.StopPolling();

        var activityConsole = new ActivityConsoleViewModel(_logger);
        var dashboardVm = new DashboardViewModel(healthMock.Object, officeMock.Object, outlookMock.Object, netMock.Object, backupMock.Object, optMock.Object, _logger);
        var healthVm = new SystemHealthViewModel(healthMock.Object, _logger);
        var officeVm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _logger);
        var connectivityVm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _logger);
        var identityVm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _logger);
        var softwareVm = new SoftwareOptimizationViewModel(appInstallerMock.Object, optMock.Object, _logger);

        return new MainViewModel(
            telemetryHeader,
            activityConsole,
            dashboardVm,
            healthVm,
            officeVm,
            connectivityVm,
            identityVm,
            softwareVm,
            _logger);
    }

    // =========================================================================
    // 1. MAINVIEWMODEL NAVIGATION LOGGING
    // =========================================================================

    [Fact]
    public void MainViewModel_TabNavigation_LogsTransitionBetweenPillars()
    {
        var mainVm = CreateMainViewModel();
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);

        // Transition 1: Dashboard -> SystemHealth
        mainVm.NavigateCommand.Execute("SystemHealth");
        Assert.Equal("SystemHealth", mainVm.CurrentPillarName);
        Assert.Same(mainVm.SystemHealthViewModel, mainVm.CurrentPageViewModel);

        var entries = _logger.CapturedEntries;
        var navEntry1 = entries.LastOrDefault(e => e.Component == nameof(MainViewModel));
        Assert.NotNull(navEntry1);
        Assert.Equal(LogLevel.Info, navEntry1.Level);
        Assert.Equal("Navigated from tab 'Dashboard' to 'SystemHealth'.", navEntry1.Message);

        // Transition 2: SystemHealth -> OfficeOutlook
        mainVm.NavigateCommand.Execute("OfficeOutlook");
        Assert.Equal("OfficeOutlook", mainVm.CurrentPillarName);
        Assert.Same(mainVm.OfficeOutlookViewModel, mainVm.CurrentPageViewModel);

        var navEntry2 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal("Navigated from tab 'SystemHealth' to 'OfficeOutlook'.", navEntry2.Message);

        // Transition 3: OfficeOutlook -> Connectivity
        mainVm.NavigateCommand.Execute("Connectivity");
        Assert.Equal("Connectivity", mainVm.CurrentPillarName);
        Assert.Same(mainVm.ConnectivityViewModel, mainVm.CurrentPageViewModel);

        var navEntry3 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal("Navigated from tab 'OfficeOutlook' to 'Connectivity'.", navEntry3.Message);

        // Transition 4: Connectivity -> IdentityBackup
        mainVm.NavigateCommand.Execute("IdentityBackup");
        Assert.Equal("IdentityBackup", mainVm.CurrentPillarName);
        Assert.Same(mainVm.IdentityBackupViewModel, mainVm.CurrentPageViewModel);

        var navEntry4 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal("Navigated from tab 'Connectivity' to 'IdentityBackup'.", navEntry4.Message);

        // Transition 5: IdentityBackup -> SoftwareOptimization
        mainVm.NavigateCommand.Execute("SoftwareOptimization");
        Assert.Equal("SoftwareOptimization", mainVm.CurrentPillarName);
        Assert.Same(mainVm.SoftwareOptimizationViewModel, mainVm.CurrentPageViewModel);

        var navEntry5 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal("Navigated from tab 'IdentityBackup' to 'SoftwareOptimization'.", navEntry5.Message);

        // Transition 6: SoftwareOptimization -> Dashboard
        mainVm.NavigateCommand.Execute("Dashboard");
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);
        Assert.Same(mainVm.DashboardViewModel, mainVm.CurrentPageViewModel);

        var navEntry6 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal("Navigated from tab 'SoftwareOptimization' to 'Dashboard'.", navEntry6.Message);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MainViewModel_TabNavigation_NullOrWhitespace_DoesNotChangePillarOrLog(string? invalidPillar)
    {
        var mainVm = CreateMainViewModel();
        int initialLogCount = _logger.CapturedEntries.Count;

        mainVm.NavigateCommand.Execute(invalidPillar);

        Assert.Equal("Dashboard", mainVm.CurrentPillarName);
        Assert.Equal(initialLogCount, _logger.CapturedEntries.Count);
    }

    // =========================================================================
    // 2. MAINVIEWMODEL NAVIGATION RAIL TOGGLE LOGGING
    // =========================================================================

    [Fact]
    public void MainViewModel_ToggleNavRailCommand_LogsExpansionStateChanges()
    {
        var mainVm = CreateMainViewModel();
        Assert.True(mainVm.IsNavRailExpanded);

        // Toggle 1: Expanded (true) -> Collapsed (false)
        mainVm.ToggleNavRailCommand.Execute(null);
        Assert.False(mainVm.IsNavRailExpanded);

        var entry1 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal(LogLevel.Info, entry1.Level);
        Assert.Equal("Navigation rail toggled. Expanded=False.", entry1.Message);

        // Toggle 2: Collapsed (false) -> Expanded (true)
        mainVm.ToggleNavRailCommand.Execute(null);
        Assert.True(mainVm.IsNavRailExpanded);

        var entry2 = _logger.CapturedEntries.Last(e => e.Component == nameof(MainViewModel));
        Assert.Equal(LogLevel.Info, entry2.Level);
        Assert.Equal("Navigation rail toggled. Expanded=True.", entry2.Message);
    }

    // =========================================================================
    // 3. ACTIVITYCONSOLEVIEWMODEL COMMAND LOGGING
    // =========================================================================

    [Fact]
    public void ActivityConsoleViewModel_OpenAndCloseCommands_LogWindowLifecycleEvents()
    {
        using var vm = new ActivityConsoleViewModel(_logger);
        Assert.False(vm.IsOpen);

        bool openRequested = false;
        bool closeRequested = false;
        vm.RequestOpen += () => openRequested = true;
        vm.RequestClose += () => closeRequested = true;

        // Open command
        vm.OpenCommand.Execute(null);
        Assert.True(vm.IsOpen);
        Assert.True(openRequested);

        var openEntry = _logger.CapturedEntries.Last();
        Assert.Equal(LogLevel.Info, openEntry.Level);
        Assert.Equal(nameof(ActivityConsoleViewModel), openEntry.Component);
        Assert.Equal("Activity Log window opened.", openEntry.Message);

        // Close command
        vm.CloseCommand.Execute(null);
        Assert.False(vm.IsOpen);
        Assert.True(closeRequested);

        var closeEntry = _logger.CapturedEntries.Last();
        Assert.Equal(LogLevel.Info, closeEntry.Level);
        Assert.Equal(nameof(ActivityConsoleViewModel), closeEntry.Component);
        Assert.Equal("Activity Log window closed.", closeEntry.Message);
    }

    [Fact]
    public void ActivityConsoleViewModel_ClearLogCommand_ClearsEntriesAndLogsEvent()
    {
        using var vm = new ActivityConsoleViewModel(_logger);
        _logger.LogInfo("Test", "Entry before clear");
        Assert.True(vm.TotalCount > 0);

        vm.ClearLogCommand.Execute(null);

        Assert.Equal(0, vm.TotalCount);
        Assert.Equal(0, vm.ErrorCount);
        Assert.Equal(0, vm.WarningCount);
        Assert.Empty(vm.FilteredEntries);

        var clearEntry = _logger.CapturedEntries.Last();
        Assert.Equal(LogLevel.Info, clearEntry.Level);
        Assert.Equal(nameof(ActivityConsoleViewModel), clearEntry.Component);
        Assert.Equal("Activity Log cleared by user.", clearEntry.Message);
    }

    [Fact]
    public void ActivityConsoleViewModel_CopyLogCommand_CopiesToClipboardAndLogsEvent()
    {
        var clipboard = new FakeClipboardService();
        using var vm = new ActivityConsoleViewModel(_logger, clipboard);

        _logger.LogInfo("Connectivity", "NIC reset completed successfully.");

        vm.CopyLogCommand.Execute(null);

        Assert.NotNull(clipboard.CopiedText);
        Assert.Contains("NIC reset completed successfully.", clipboard.CopiedText);

        var copyEntry = _logger.CapturedEntries.Last();
        Assert.Equal(LogLevel.Info, copyEntry.Level);
        Assert.Equal(nameof(ActivityConsoleViewModel), copyEntry.Component);
        Assert.Equal("Activity Log copied to clipboard.", copyEntry.Message);
    }

    // =========================================================================
    // 4. VIEWMODELBASE.EXECUTEASYNC LIFECYCLE & DIAGNOSTIC LOGGING
    // =========================================================================

    [Fact]
    public async Task ViewModelBase_ExecuteAsync_SuccessfulOperation_LogsStartAndSuccess()
    {
        var vm = new TestOperationViewModel(_logger);
        string opName = "Backup User Accounts";

        bool startedFired = false;
        bool finishedFired = false;
        ViewModelBase.OperationStarted += name => { if (name == opName) startedFired = true; };
        ViewModelBase.OperationFinished += (name, success, exitCode) =>
        {
            if (name == opName && success && exitCode == 0) finishedFired = true;
        };

        await vm.RunSuccessAsync(opName);

        Assert.True(startedFired);
        Assert.True(finishedFired);
        Assert.False(vm.IsBusy);
        Assert.Equal($"{opName} completed successfully.", vm.StatusMessage);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        // Entry 1: Start
        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal(nameof(TestOperationViewModel), entries[0].Component);
        Assert.Equal($"Starting operation: {opName}...", entries[0].Message);

        // Entry 2: Success
        Assert.Equal(LogLevel.Success, entries[1].Level);
        Assert.Equal(nameof(TestOperationViewModel), entries[1].Component);
        Assert.Equal($"{opName} completed successfully.", entries[1].Message);
    }

    [Fact]
    public async Task ViewModelBase_ExecuteAsync_FailingOperation_LogsStartAndDiagnosticExceptionError()
    {
        var vm = new TestOperationViewModel(_logger);
        string opName = "Repair MAPI Stores";

        var innerEx = new UnauthorizedAccessException("Access denied to OST container C:\\Users\\Default\\AppData");
        var outerEx = new InvalidOperationException("MAPI engine failed to mount store", innerEx);

        bool startedFired = false;
        bool finishedFired = false;
        ViewModelBase.OperationStarted += name => { if (name == opName) startedFired = true; };
        ViewModelBase.OperationFinished += (name, success, exitCode) =>
        {
            if (name == opName && !success && exitCode == 1) finishedFired = true;
        };

        await vm.RunFailureAsync(opName, outerEx);

        Assert.True(startedFired);
        Assert.True(finishedFired);
        Assert.False(vm.IsBusy);
        Assert.Contains($"{opName} failed: {outerEx.Message}", vm.StatusMessage);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        // Entry 1: Start
        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal(nameof(TestOperationViewModel), entries[0].Component);
        Assert.Equal($"Starting operation: {opName}...", entries[0].Message);

        // Entry 2: Error with full diagnostic exception formatting
        Assert.Equal(LogLevel.Error, entries[1].Level);
        Assert.Equal(nameof(TestOperationViewModel), entries[1].Component);
        Assert.Contains($"Operation '{opName}' failed: {outerEx.Message} | Diagnostics: ", entries[1].Message);
        Assert.Contains("[System.InvalidOperationException] MAPI engine failed to mount store", entries[1].Message);
        Assert.Contains("---> (Inner Exception #1) [System.UnauthorizedAccessException] Access denied to OST container", entries[1].Message);
    }

    [Fact]
    public async Task ViewModelBase_ExecuteAsync_WhenAlreadyBusy_RejectsConcurrentExecution()
    {
        var vm = new TestOperationViewModel(_logger);
        var tcs = new TaskCompletionSource<bool>();

        // Launch first long-running operation
        var task1 = vm.RunLongRunningAsync("Long Operation 1", tcs);
        Assert.True(vm.IsBusy);

        // Attempt second concurrent operation while busy
        var task2 = vm.RunSuccessAsync("Concurrent Operation 2");
        await task2;

        // Verify only Operation 1 was started and logged
        var entries = _logger.CapturedEntries;
        Assert.Single(entries);
        Assert.Equal("Starting operation: Long Operation 1...", entries[0].Message);

        // Complete Operation 1
        tcs.SetResult(true);
        await task1;

        Assert.False(vm.IsBusy);
        Assert.Equal(2, _logger.CapturedEntries.Count);
        Assert.Equal("Long Operation 1 completed successfully.", _logger.CapturedEntries[1].Message);
    }
}
