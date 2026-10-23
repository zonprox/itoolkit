namespace IToolkit.Tests.UI;

using System;
using System.Collections.Concurrent;
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
using Moq;
using Xunit;

public class Milestone4ChallengerTests
{
    private class TestActivityLogger : IActivityLogger
    {
        public event Action<ActivityLogEntry>? EntryLogged;

        public void Log(LogLevel level, string component, string message)
        {
            EntryLogged?.Invoke(new ActivityLogEntry(DateTime.UtcNow, level, component, message));
        }

        public void LogInfo(string component, string message) => Log(LogLevel.Info, component, message);
        public void LogWarning(string component, string message) => Log(LogLevel.Warning, component, message);
        public void LogError(string component, string message) => Log(LogLevel.Error, component, message);
        public void LogSuccess(string component, string message) => Log(LogLevel.Success, component, message);
        public void LogDebug(string component, string message) => Log(LogLevel.Debug, component, message);
    }

    // =========================================================================
    // 1. ASYNC RELAY COMMAND REENTRANCY AND CONCURRENCY STRESS TESTS
    // =========================================================================

    [Fact]
    public async Task AsyncRelayCommand_SequentialDoubleExecution_RejectsSecondExecution()
    {
        int executionCount = 0;
        var tcs = new TaskCompletionSource<bool>();

        var cmd = new AsyncRelayCommand(async () =>
        {
            Interlocked.Increment(ref executionCount);
            await tcs.Task;
        });

        // First call starts execution
        var firstTask = cmd.ExecuteAsync(null);

        Assert.True(cmd.IsExecuting);
        Assert.False(cmd.CanExecute(null));

        // Second call while first is in-flight must be rejected by reentrancy guard
        var secondTask = cmd.ExecuteAsync(null);
        await secondTask;

        // Verify second execution did not increment the counter
        Assert.Equal(1, executionCount);

        // Allow first execution to complete
        tcs.SetResult(true);
        await firstTask;

        Assert.False(cmd.IsExecuting);
        Assert.True(cmd.CanExecute(null));
        Assert.Equal(1, executionCount);

        // Subsequent call after completion should succeed
        var thirdTcs = new TaskCompletionSource<bool>();
        thirdTcs.SetResult(true);
        await cmd.ExecuteAsync(null);
        Assert.Equal(2, executionCount);
    }

    [Fact]
    public async Task AsyncRelayCommand_ConcurrentMultiThreadedTrigger_StressTest()
    {
        int executionCount = 0;
        var startedBarrier = new Barrier(21); // 20 workers + 1 orchestrator
        var holdTcs = new TaskCompletionSource<bool>();

        var cmd = new AsyncRelayCommand(async () =>
        {
            Interlocked.Increment(ref executionCount);
            await holdTcs.Task;
        });

        const int callerCount = 20;
        var tasks = new Task[callerCount];

        for (int i = 0; i < callerCount; i++)
        {
            tasks[i] = Task.Run(async () =>
            {
                startedBarrier.SignalAndWait();
                await cmd.ExecuteAsync(null);
            });
        }

        startedBarrier.SignalAndWait();
        await Task.Delay(50); // Give threads time to hit ExecuteAsync

        holdTcs.SetResult(true);
        await Task.WhenAll(tasks);

        // Under an ideal atomic reentrancy guard, exactly 1 caller enters while running.
        // We record whether executionCount was bounded to 1.
        Assert.True(executionCount >= 1, "Command must execute at least once");
        Assert.Equal(1, executionCount);
    }

    [Fact]
    public async Task AsyncRelayCommand_RaceCondition_HighFrequencyConcurrencyStressTest()
    {
        int concurrentOverlapViolations = 0;

        for (int iter = 0; iter < 100; iter++)
        {
            int activeExecutions = 0;
            var cmd = new AsyncRelayCommand(async () =>
            {
                int current = Interlocked.Increment(ref activeExecutions);
                if (current > 1)
                {
                    Interlocked.Increment(ref concurrentOverlapViolations);
                }
                await Task.Yield();
                Interlocked.Decrement(ref activeExecutions);
            });

            var tasks = new Task[10];
            var barrier = new Barrier(10);
            for (int i = 0; i < 10; i++)
            {
                tasks[i] = Task.Run(async () =>
                {
                    barrier.SignalAndWait();
                    await cmd.ExecuteAsync(null);
                });
            }

            await Task.WhenAll(tasks);
        }

        Assert.Equal(0, concurrentOverlapViolations);
    }

    [Fact]
    public async Task AsyncRelayCommandGeneric_TypeParameter_PassesArgumentsAndGuardsReentrancy()
    {
        var received = new List<string>();
        var tcs = new TaskCompletionSource<bool>();

        var cmd = new AsyncRelayCommand<string>(async arg =>
        {
            received.Add(arg ?? string.Empty);
            await tcs.Task;
        });

        var task1 = cmd.ExecuteAsync("First");
        Assert.True(cmd.IsExecuting);

        // Reentrant call
        var task2 = cmd.ExecuteAsync("Second");
        await task2;

        Assert.Single(received);
        Assert.Equal("First", received[0]);

        tcs.SetResult(true);
        await task1;

        Assert.False(cmd.IsExecuting);
    }

    [Fact]
    public async Task AsyncRelayCommand_ExceptionInAction_ResetsExecutingState()
    {
        var cmd = new AsyncRelayCommand(async () =>
        {
            await Task.Yield();
            throw new InvalidOperationException("Simulated domain crash");
        });

        await Assert.ThrowsAsync<InvalidOperationException>(() => cmd.ExecuteAsync(null));

        Assert.False(cmd.IsExecuting);
        Assert.True(cmd.CanExecute(null));
    }

    // =========================================================================
    // 2. ACTIVITY LOGGER THREAD-SAFETY UNDER MULTI-THREADED BURSTS
    // =========================================================================

    private class ThreadSafeDualSinkLogger : IActivityLogger
    {
        private readonly object _lock = new();
        private readonly string _logFilePath;

        public event Action<ActivityLogEntry>? EntryLogged;

        public ThreadSafeDualSinkLogger(string logFilePath)
        {
            _logFilePath = logFilePath;
        }

        public void Log(LogLevel level, string component, string message)
        {
            var entry = new ActivityLogEntry(DateTime.UtcNow, level, component, message);

            lock (_lock)
            {
                try
                {
                    string line = $"[{entry.Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{entry.Level.ToString().ToUpperInvariant(),-7}] [{entry.Component}] {entry.Message}{Environment.NewLine}";
                    File.AppendAllText(_logFilePath, line);
                }
                catch
                {
                    // Never crash on logging failure
                }
            }

            EntryLogged?.Invoke(entry);
        }

        public void LogInfo(string component, string message) => Log(LogLevel.Info, component, message);
        public void LogWarning(string component, string message) => Log(LogLevel.Warning, component, message);
        public void LogError(string component, string message) => Log(LogLevel.Error, component, message);
        public void LogSuccess(string component, string message) => Log(LogLevel.Success, component, message);
        public void LogDebug(string component, string message) => Log(LogLevel.Debug, component, message);
    }

    [Fact]
    public async Task ActivityLogger_MultiThreadedLoggingBurst_ReceivesAllEventsWithoutCorruption()
    {
        string tempLogFile = Path.Combine(Path.GetTempPath(), $"challenger_burst_{Guid.NewGuid():N}.log");
        try
        {
            var logger = new ThreadSafeDualSinkLogger(tempLogFile);
            var receivedEntries = new ConcurrentBag<ActivityLogEntry>();

            logger.EntryLogged += entry =>
            {
                receivedEntries.Add(entry);
            };

            const int threadCount = 10;
            const int logsPerThread = 50;
            const int expectedTotal = threadCount * logsPerThread;

            var tasks = Enumerable.Range(0, threadCount).Select(threadId => Task.Run(() =>
            {
                for (int i = 0; i < logsPerThread; i++)
                {
                    var level = (i % 5) switch
                    {
                        0 => LogLevel.Info,
                        1 => LogLevel.Warning,
                        2 => LogLevel.Error,
                        3 => LogLevel.Success,
                        _ => LogLevel.Debug
                    };
                    logger.Log(level, $"Thread_{threadId}", $"Message index {i}");
                }
            })).ToArray();

            await Task.WhenAll(tasks);

            Assert.Equal(expectedTotal, receivedEntries.Count);
            Assert.Equal(expectedTotal / 5, receivedEntries.Count(e => e.Level == LogLevel.Error));
            Assert.Equal(expectedTotal / 5, receivedEntries.Count(e => e.Level == LogLevel.Warning));

            // Verify file output
            Assert.True(File.Exists(tempLogFile));
            var lines = File.ReadAllLines(tempLogFile);
            Assert.Equal(expectedTotal, lines.Length);
        }
        finally
        {
            if (File.Exists(tempLogFile))
            {
                try { File.Delete(tempLogFile); } catch { }
            }
        }
    }

    // =========================================================================
    // 3. ACTIVITY CONSOLE VIEW MODEL FILTERING TESTS
    // =========================================================================

    [Fact]
    public void ActivityConsoleViewModel_FilterByLevel_AllLevelsFilterProperly()
    {
        var logger = new TestActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        logger.Log(LogLevel.Debug, "Comp1", "Debug message");
        logger.Log(LogLevel.Info, "Comp2", "Info message");
        logger.Log(LogLevel.Success, "Comp3", "Success message");
        logger.Log(LogLevel.Warning, "Comp4", "Warning message");
        logger.Log(LogLevel.Error, "Comp5", "Error message");

        Assert.Equal(5, vm.TotalCount);

        // Filter: Info
        vm.SelectedLevelFilter = "Info";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Info, vm.FilteredEntries[0].Level);

        // Filter: Success
        vm.SelectedLevelFilter = "Success";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Success, vm.FilteredEntries[0].Level);

        // Filter: Warning
        vm.SelectedLevelFilter = "Warning";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Warning, vm.FilteredEntries[0].Level);

        // Filter: Error
        vm.SelectedLevelFilter = "Error";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Error, vm.FilteredEntries[0].Level);

        // Filter: Debug
        vm.SelectedLevelFilter = "Debug";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Debug, vm.FilteredEntries[0].Level);

        // Filter: All
        vm.SelectedLevelFilter = "All";
        Assert.Equal(5, vm.FilteredEntries.Count);
    }

    [Fact]
    public void ActivityConsoleViewModel_FilterCaseSensitivity_HandlesCaseVariations()
    {
        var logger = new TestActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("Comp", "Info msg");
        logger.LogError("Comp", "Error msg");

        // Test lowercase "all"
        vm.SelectedLevelFilter = "all";
        Assert.Equal(2, vm.FilteredEntries.Count);

        // Test lowercase "error"
        vm.SelectedLevelFilter = "error";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Error, vm.FilteredEntries[0].Level);

        // Test uppercase "ERROR"
        vm.SelectedLevelFilter = "ERROR";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Error, vm.FilteredEntries[0].Level);
    }

    [Fact]
    public void ActivityConsoleViewModel_SearchFilter_MatchesComponentAndMessage_CaseInsensitive()
    {
        var logger = new TestActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("NetworkModule", "Checking IP configuration");
        logger.LogWarning("DiskService", "Low free space on volume C:");
        logger.LogError("IdentityService", "Network timeout contacting domain controller");

        // Search by Component
        vm.SearchFilter = "network";
        // Matches NetworkModule (component) and IdentityService (message has 'network')
        Assert.Equal(2, vm.FilteredEntries.Count);

        // Search by Message content
        vm.SearchFilter = "volume C:";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal("DiskService", vm.FilteredEntries[0].Component);

        // Whitespace only search filter should return all
        vm.SearchFilter = "   ";
        Assert.Equal(3, vm.FilteredEntries.Count);

        // Non-matching search filter
        vm.SearchFilter = "NonExistentTerm";
        Assert.Empty(vm.FilteredEntries);
    }

    [Fact]
    public void ActivityConsoleViewModel_CombinedLevelAndSearchFilter()
    {
        var logger = new TestActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("Service", "Starting disk cleanup");
        logger.LogWarning("Service", "Disk cleanup warning: locked file");
        logger.LogError("Service", "Disk cleanup error: out of memory");
        logger.LogError("Network", "DNS failure");

        // Both level and search
        vm.SelectedLevelFilter = "Error";
        vm.SearchFilter = "disk";

        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Error, vm.FilteredEntries[0].Level);
        Assert.Contains("Disk cleanup error", vm.FilteredEntries[0].Message);
    }

    [Fact]
    public void ActivityConsoleViewModel_DynamicAppend_RespectsActiveFilter()
    {
        var logger = new TestActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        vm.SelectedLevelFilter = "Error";

        // Log Info: should NOT be added to FilteredEntries
        logger.LogInfo("Comp", "Ignored info");
        Assert.Empty(vm.FilteredEntries);
        Assert.Equal(1, vm.TotalCount);
        Assert.Equal(0, vm.ErrorCount);

        // Log Error: SHOULD be added to FilteredEntries
        logger.LogError("Comp", "Captured error");
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(2, vm.TotalCount);
        Assert.Equal(1, vm.ErrorCount);
    }

    // =========================================================================
    // 4. VIEW MODEL EXCEPTION HANDLING UNDER UNEXPECTED DOMAIN SERVICE FAULTS
    // =========================================================================

    [Fact]
    public async Task SystemHealthViewModel_UnderlyingServiceThrowsException_HandledGracefully()
    {
        var mockService = new Mock<ISystemHealthService>();
        var logger = new TestActivityLogger();
        var loggedErrors = new List<string>();

        logger.EntryLogged += entry =>
        {
            if (entry.Level == LogLevel.Error) loggedErrors.Add(entry.Message);
        };

        mockService
            .Setup(s => s.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Throws(new InvalidOperationException("Fatal DISM corruption in CBS hive"));

        var vm = new SystemHealthViewModel(mockService.Object, logger);

        // Command must not throw an unhandled exception to the UI caller
        await vm.RunDismSfcPipelineCommand.ExecuteAsync(null);

        // Verification of graceful recovery
        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage);
        Assert.Contains("Fatal DISM corruption in CBS hive", vm.StatusMessage);
        Assert.Single(loggedErrors);
        Assert.Contains("Fatal DISM corruption in CBS hive", loggedErrors[0]);

        // Command must remain executable after error
        Assert.True(vm.RunDismSfcPipelineCommand.CanExecute(null));
    }

    [Fact]
    public async Task OfficeOutlookViewModel_UnderlyingServiceThrowsException_HandledGracefully()
    {
        var mockOffice = new Mock<IOfficeSuiteService>();
        var mockOutlook = new Mock<IOutlookService>();
        var logger = new TestActivityLogger();

        mockOffice
            .Setup(s => s.ScrubOfficeSuiteCleanly())
            .Throws(new UnauthorizedAccessException("Access denied to Office MSI registry hive"));

        var vm = new OfficeOutlookViewModel(mockOffice.Object, mockOutlook.Object, logger);

        await vm.ScrubOfficeSuiteCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage);
        Assert.Contains("Access denied", vm.StatusMessage);
        Assert.True(vm.ScrubOfficeSuiteCommand.CanExecute(null));
    }

    [Fact]
    public async Task ConnectivityViewModel_UnderlyingServiceThrowsException_HandledGracefully()
    {
        var mockConn = new Mock<IConnectivityService>();
        var mockPrinter = new Mock<IPrinterService>();
        var logger = new TestActivityLogger();

        mockConn
            .Setup(s => s.RemediateNetworkStack())
            .Throws(new TimeoutException("Netsh TCP/IP reset timed out"));

        var vm = new ConnectivityViewModel(mockConn.Object, mockPrinter.Object, logger);

        await vm.RemediateNetworkStackCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage);
        Assert.Contains("timed out", vm.StatusMessage);
        Assert.True(vm.RemediateNetworkStackCommand.CanExecute(null));
    }

    [Fact]
    public async Task IdentityBackupViewModel_UnderlyingServiceThrowsException_HandledGracefully()
    {
        var mockId = new Mock<IIdentityService>();
        var mockBackup = new Mock<IBackupService>();
        var logger = new TestActivityLogger();

        mockId
            .Setup(s => s.GetLocalAccounts())
            .Throws(new InvalidOperationException("WMI query Win32_UserAccount failed"));

        var vm = new IdentityBackupViewModel(mockId.Object, mockBackup.Object, logger);

        await vm.RefreshAccountsCommand.ExecuteAsync(null);

        Assert.False(vm.IsBusy);
        Assert.True(vm.IsNotBusy);
        Assert.Contains("failed", vm.StatusMessage);
        Assert.Contains("Win32_UserAccount failed", vm.StatusMessage);
        Assert.True(vm.RefreshAccountsCommand.CanExecute(null));
    }

    [Fact]
    public async Task IdentityBackupViewModel_EnableBuiltInAdmin_NestedExecuteAsyncBehavior()
    {
        var mockId = new Mock<IIdentityService>();
        var mockBackup = new Mock<IBackupService>();
        var logger = new TestActivityLogger();

        mockId.Setup(s => s.EnableBuiltInAdministrator()).Returns(true);
        mockId.Setup(s => s.GetLocalAccounts()).Returns(new List<LocalAccountItem>
        {
            new LocalAccountItem("Administrator", "S-1-5-21-500", true, false, true, true)
        });

        var vm = new IdentityBackupViewModel(mockId.Object, mockBackup.Object, logger);

        await vm.EnableBuiltInAdminCommand.ExecuteAsync(null);

        // Check whether GetLocalAccounts was called to refresh accounts
        // If nested ExecuteAsync is rejected by IsBusy guard, GetLocalAccounts will be 0 calls.
        mockId.Verify(s => s.GetLocalAccounts(), Times.Once);
        Assert.Single(vm.Accounts);
    }

    [Fact]
    public async Task SoftwareOptimizationViewModel_InstallAppException_StatusStuckInInstalling()
    {
        var mockInstaller = new Mock<IAppInstallerService>();
        var mockOpt = new Mock<IOptimizationService>();
        var logger = new TestActivityLogger();

        var item = new AppCatalogItem("Chrome", "Google Chrome", "Google.Chrome", AppInstallMode.WingetWithFallback, "https://dl.google.com/chrome.exe", "/silent", "Chrome", "browser", Array.Empty<string>());
        mockInstaller.Setup(s => s.GetCatalog()).Returns(new List<AppCatalogItem> { item });
        mockInstaller.Setup(s => s.InstallApplication("Chrome")).Throws(new InvalidOperationException("Installer download hash mismatch"));

        var vm = new SoftwareOptimizationViewModel(mockInstaller.Object, mockOpt.Object, logger);
        var appItem = vm.CatalogApps.First();

        // Trigger installation
        appItem.InstallCommand.Execute(null);

        // Wait a moment for async void to execute
        await Task.Delay(50);

        // Status transitions to "Failed" when exception is handled
        Assert.Equal("Failed", appItem.Status);
        Assert.Contains("Installation failed", vm.LastSoftwareStatus);
    }
}
