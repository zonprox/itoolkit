namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Input;
using IToolkit.App.Native;
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

[Collection("ActivityLoggerDiskFile")]
public class Milestone5EmpiricalChallengeTests
{
    // =========================================================================
    // SECTION 1: Concurrency and Race Condition Stress Tests
    // =========================================================================

    [Fact]
    public async Task AsyncRelayCommand_ConcurrencyStress_100ParallelDispatches_AllowsOnlySingleExecutionAndResets()
    {
        // Arrange
        int concurrentCount = 0;
        int maxConcurrentObserved = 0;
        int totalExecutions = 0;
        var tcs = new TaskCompletionSource<bool>();

        var startedTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        var cmd = new AsyncRelayCommand(async () =>
        {
            int current = Interlocked.Increment(ref concurrentCount);
            // Track peak concurrent executions
            int initialMax;
            do
            {
                initialMax = Volatile.Read(ref maxConcurrentObserved);
                if (current <= initialMax) break;
            }
            while (Interlocked.CompareExchange(ref maxConcurrentObserved, current, initialMax) != initialMax);

            Interlocked.Increment(ref totalExecutions);
            startedTcs.TrySetResult(true);
            await tcs.Task;
            Interlocked.Decrement(ref concurrentCount);
        });

        // Act - Launch 100 parallel tasks trying to execute the exact same command at the same instant
        int rejectedCount = 0;
        var allRejectedTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        var tasks = new Task[100];
        for (int i = 0; i < 100; i++)
        {
            tasks[i] = Task.Run(async () =>
            {
                await cmd.ExecuteAsync(null);
                if (Interlocked.Increment(ref rejectedCount) == 99)
                {
                    allRejectedTcs.TrySetResult(true);
                }
            });
        }

        // Wait until at least one task has entered the command delegate
        await startedTcs.Task;

        Assert.True(cmd.IsExecuting, "Command must report IsExecuting == true while operation is in-flight.");
        Assert.False(cmd.CanExecute(null), "Command must report CanExecute == false while executing.");

        // Wait until all 99 concurrent tasks have attempted and were rejected by the in-flight guard
        await allRejectedTcs.Task;

        // Release the in-flight operation
        tcs.SetResult(true);
        await Task.WhenAll(tasks);

        // Assert
        Assert.False(cmd.IsExecuting, "Command must report IsExecuting == false after completion.");
        Assert.True(cmd.CanExecute(null), "Command must report CanExecute == true after completion.");
        Assert.Equal(1, maxConcurrentObserved);
        Assert.Equal(1, totalExecutions);

        // Verify command can be executed again cleanly after completion
        int sequentialRunCount = 0;
        var sequentialCmd = new AsyncRelayCommand(async () =>
        {
            await Task.Yield();
            Interlocked.Increment(ref sequentialRunCount);
        });
        await sequentialCmd.ExecuteAsync(null);
        Assert.Equal(1, sequentialRunCount);
    }

    [Fact]
    public async Task AsyncRelayCommand_SynchronousExecute_100ParallelCalls_DoesNotThrowOrCorruptState()
    {
        // Arrange
        int totalExecutions = 0;
        var cmd = new AsyncRelayCommand(async () =>
        {
            await Task.Delay(10);
            Interlocked.Increment(ref totalExecutions);
        });

        var commandInterface = (ICommand)cmd;

        // Act - Fire 100 parallel threads through the synchronous ICommand.Execute interface
        var tasks = Enumerable.Range(0, 100)
            .Select(_ => Task.Run(() => commandInterface.Execute(null)))
            .ToArray();

        await Task.WhenAll(tasks);
        for (int i = 0; i < 50 && cmd.IsExecuting; i++)
        {
            await Task.Delay(20);
        }

        // Assert - zero crashes, state cleanly reset
        Assert.False(cmd.IsExecuting);
        Assert.True(cmd.CanExecute(null));
        Assert.True(totalExecutions >= 1);
    }

    [Fact]
    public async Task AsyncRelayCommandGeneric_ConcurrencyStress_PreservesTypeAndPayloadWithoutRaceConditions()
    {
        // Arrange
        var capturedPayloads = new ConcurrentBag<string>();
        int executingCount = 0;
        int maxExecuting = 0;

        var cmd = new AsyncRelayCommand<string>(async payload =>
        {
            int cur = Interlocked.Increment(ref executingCount);
            if (cur > maxExecuting) Volatile.Write(ref maxExecuting, cur);
            await Task.Delay(10);
            if (payload != null)
            {
                capturedPayloads.Add(payload);
            }
            Interlocked.Decrement(ref executingCount);
        });

        // Act - 100 parallel dispatches with unique payloads
        var tasks = Enumerable.Range(0, 100)
            .Select(i => Task.Run(async () => await cmd.ExecuteAsync($"Payload_{i}")))
            .ToArray();

        await Task.WhenAll(tasks);

        // Assert
        Assert.False(cmd.IsExecuting);
        Assert.Equal(1, maxExecuting);
        Assert.NotEmpty(capturedPayloads);
    }

    [Fact]
    public async Task DashboardViewModel_HighFrequencyConcurrentDispatches_PreservesViewModelState()
    {
        // Arrange
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Returns((DismScanResult.Successful("OK"), SfcScanResult.Clean("OK")));

        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        outlookMock.Setup(o => o.QuickMailAndCacheRepair(It.IsAny<string?>()))
            .Returns(new QuickMailRepairResult(true, true, true, true, true, true, "Repaired"));

        var netMock = new Mock<IConnectivityService>();
        netMock.Setup(c => c.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "OK"));

        var backupMock = new Mock<IBackupService>();
        backupMock.Setup(b => b.GetUserProfileMap(It.IsAny<string?>()))
            .Returns(new UserProfileMap("TestUser", @"C:\Users\TestUser", @"C:\Users\TestUser\Desktop", @"C:\Users\TestUser\Documents", @"C:\Users\TestUser\Downloads", @"C:\Users\TestUser\Favorites", @"C:\Users\TestUser\Pictures", false));
        backupMock.Setup(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<bool>()))
            .Returns(new RobocopySyncResult(@"C:\Users\TestUser", @"D:\UserBackups\TestUser", 1, true, "OK"));

        var optMock = new Mock<IOptimizationService>();
        optMock.Setup(o => o.UpdateAllPackages())
            .Returns(new ProcessExecutionResult(0, "All updated", string.Empty, false));

        var logger = new TestActivityLogger();
        var dashboardVm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            logger);

        // Act - Fire 60 concurrent tasks across all 6 quick repair commands
        var tasks = new List<Task>();
        for (int i = 0; i < 60; i++)
        {
            int commandIndex = i % 6;
            tasks.Add(Task.Run(async () =>
            {
                switch (commandIndex)
                {
                    case 0: await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null); break;
                    case 1: await dashboardVm.QuickMailRepairCommand.ExecuteAsync(null); break;
                    case 2: await dashboardVm.QuickNetworkResetCommand.ExecuteAsync(null); break;
                    case 3: await dashboardVm.QuickDiskCleanupCommand.ExecuteAsync(null); break;
                    case 4: await dashboardVm.QuickSoftwareUpgradeCommand.ExecuteAsync(null); break;
                    case 5: await dashboardVm.QuickProfileBackupCommand.ExecuteAsync(null); break;
                }
            }));
        }

        await Task.WhenAll(tasks);

        // Assert - After all concurrent operations finish, ViewModel state must be fully recovered
        Assert.False(dashboardVm.IsBusy, "ViewModel must not remain in IsBusy state after all tasks complete.");
        Assert.True(dashboardVm.IsNotBusy);
        Assert.NotEmpty(dashboardVm.StatusMessage);
        Assert.NotEmpty(logger.CapturedEntries);
    }

    [Fact]
    public async Task ActivityLogger_HighVolumeConcurrentLogging_5000Entries_ZeroFileCorruptionOrDrops()
    {
        // Arrange
        var logger = new ActivityLogger();
        int eventCallbackCount = 0;
        logger.EntryLogged += _ => Interlocked.Increment(ref eventCallbackCount);

        const int threadCount = 50;
        const int entriesPerThread = 100;
        const int totalExpected = threadCount * entriesPerThread;

        // Act - 50 concurrent threads logging 100 entries each
        var tasks = Enumerable.Range(0, threadCount).Select(threadId => Task.Run(() =>
        {
            for (int i = 0; i < entriesPerThread; i++)
            {
                var level = (LogLevel)(i % 5);
                logger.Log(level, $"Component_{threadId}", $"Concurrent log trace event {i} from thread {threadId}");
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        // Assert
        Assert.True(File.Exists(logger.LogFilePath), "Log file must exist.");
        Assert.Equal(totalExpected, eventCallbackCount);

        string logFileContent = File.ReadAllText(logger.LogFilePath);
        Assert.Contains("Component_0", logFileContent);
        Assert.Contains($"Component_{threadCount - 1}", logFileContent);
    }

    // =========================================================================
    // SECTION 2: Fault Injection & Exception Resilience in ExecuteAsync
    // =========================================================================

    [Theory]
    [InlineData(typeof(InvalidOperationException), "Fatal hardware I/O device error during SFC scannow.")]
    [InlineData(typeof(UnauthorizedAccessException), "Access to the registry path is denied.")]
    [InlineData(typeof(IOException), "The process cannot access the file because it is being used by another process.")]
    [InlineData(typeof(TimeoutException), "The WMI query timed out after 30 seconds.")]
    [InlineData(typeof(NullReferenceException), "Object reference not set to an instance of an object.")]
    public async Task ViewModelBase_FaultInjection_DiverseExceptionTypes_AreCaughtAndLoggedWithoutCrashingUI(
        Type exceptionType,
        string errorMessage)
    {
        // Arrange
        var exception = (Exception)Activator.CreateInstance(exceptionType, errorMessage)!;
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Throws(exception);

        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();

        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        var dashboardVm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            logger);

        // Act - Invoke command where service throws unexpected exception
        await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null);

        // Assert - ViewModel caught exception, did NOT crash, reset IsBusy, and updated status
        Assert.False(dashboardVm.IsBusy, "IsBusy must be false after caught exception.");
        Assert.True(dashboardVm.IsNotBusy);
        Assert.Contains("failed:", dashboardVm.StatusMessage);
        Assert.Contains(errorMessage, dashboardVm.StatusMessage);

        // Verify Logger and ActivityConsole captured the error
        Assert.Contains(logger.CapturedEntries, e => e.Level == LogLevel.Error && e.Message.Contains(errorMessage));
        Assert.True(consoleVm.ErrorCount >= 1, "ActivityConsole ErrorCount must reflect the failure.");
        Assert.Equal("Errors Encountered", consoleVm.ExecutionStatus);
        Assert.Equal("#EF4444", consoleVm.ExecutionStatusBrush);
    }

    [Fact]
    public async Task DashboardViewModel_FaultInjection_AllSixCommands_CatchExceptionsAndReportFailureCleanly()
    {
        // Arrange
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Throws(new InvalidOperationException("DISM/SFC faulted."));
        healthMock.Setup(h => h.RunUnifiedDiskCleanup(It.IsAny<int>()))
            .Throws(new UnauthorizedAccessException("Disk cleanup access denied."));

        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        outlookMock.Setup(o => o.RepairGlobalMailSettings())
            .Throws(new IOException("Mail options registry locked."));

        var netMock = new Mock<IConnectivityService>();
        netMock.Setup(c => c.RemediateNetworkStack())
            .Throws(new TimeoutException("DHCP renewal timed out."));

        var backupMock = new Mock<IBackupService>();
        backupMock.Setup(b => b.GetUserProfileMap(It.IsAny<string?>()))
            .Throws(new KeyNotFoundException("User profile registry key not found."));

        var optMock = new Mock<IOptimizationService>();
        optMock.Setup(o => o.UpdateAllPackages())
            .Throws(new InvalidOperationException("Winget database corrupted."));

        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        var dashboardVm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            logger);

        // Act & Assert for each of the 6 commands individually
        // 1. QuickSystemRepair
        await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: DISM/SFC faulted", dashboardVm.StatusMessage);

        // 2. QuickMailRepair
        await dashboardVm.QuickMailRepairCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: Mail options registry locked", dashboardVm.StatusMessage);

        // 3. QuickNetworkReset
        await dashboardVm.QuickNetworkResetCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: DHCP renewal timed out", dashboardVm.StatusMessage);

        // 4. QuickDiskCleanup
        await dashboardVm.QuickDiskCleanupCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: Disk cleanup access denied", dashboardVm.StatusMessage);

        // 5. QuickSoftwareUpgrade
        await dashboardVm.QuickSoftwareUpgradeCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: Winget database corrupted", dashboardVm.StatusMessage);

        // 6. QuickProfileBackup
        await dashboardVm.QuickProfileBackupCommand.ExecuteAsync(null);
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: User profile registry key not found", dashboardVm.StatusMessage);

        // Total errors in console must equal 6
        Assert.Equal(6, consoleVm.ErrorCount);
        Assert.Equal("Errors Encountered", consoleVm.ExecutionStatus);
    }

    // =========================================================================
    // SECTION 3: ActivityConsoleViewModel Log Streaming, Filtering & Counters
    // =========================================================================

    [Fact]
    public void ActivityConsoleViewModel_LiveLogStreamingFidelity_AllSeverityLevelsPreservedWithTimestamps()
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        var startTime = DateTime.UtcNow;

        // Act - Stream entries for all 5 LogLevel values
        logger.LogDebug("CoreDiagnostics", "Debug level trace 01");
        logger.LogInfo("SystemHealth", "Info level status 02");
        logger.LogSuccess("OfficeSuite", "Success level confirmation 03");
        logger.LogWarning("NetworkGuard", "Warning level alert 04");
        logger.LogError("SpoolerService", "Error level failure 05");

        // Assert counts
        Assert.Equal(5, consoleVm.TotalCount);
        Assert.Equal(1, consoleVm.WarningCount);
        Assert.Equal(1, consoleVm.ErrorCount);
        Assert.Equal(5, consoleVm.FilteredEntries.Count);

        // Assert fidelity of each entry
        var entries = consoleVm.FilteredEntries.ToList();
        Assert.Equal(LogLevel.Debug, entries[0].Level);
        Assert.Equal("CoreDiagnostics", entries[0].Component);
        Assert.Equal("Debug level trace 01", entries[0].Message);
        Assert.True(entries[0].Timestamp >= startTime);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("SystemHealth", entries[1].Component);

        Assert.Equal(LogLevel.Success, entries[2].Level);
        Assert.Equal("OfficeSuite", entries[2].Component);

        Assert.Equal(LogLevel.Warning, entries[3].Level);
        Assert.Equal("NetworkGuard", entries[3].Component);

        Assert.Equal(LogLevel.Error, entries[4].Level);
        Assert.Equal("SpoolerService", entries[4].Component);
    }

    [Fact]
    public void ActivityConsoleViewModel_FilteringStress_AllCombinationsOfLevelAndQuery()
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        // Stream 500 entries (100 of each LogLevel)
        for (int i = 0; i < 100; i++)
        {
            logger.LogDebug("DiagnosticsEngine", $"Debug trace telemetry {i}");
            logger.LogInfo("SystemHealth", $"Info operational event {i}");
            logger.LogSuccess("OfficeSuite", $"Success workflow finished {i}");
            logger.LogWarning("NetworkGuard", $"Warning packet drop alert {i}");
            logger.LogError("StorageService", $"Error disk sector I/O fault {i}");
        }

        Assert.Equal(500, consoleVm.TotalCount);
        Assert.Equal(100, consoleVm.WarningCount);
        Assert.Equal(100, consoleVm.ErrorCount);

        // 1. Filter by Level: All
        consoleVm.SelectedLevelFilter = "All";
        Assert.Equal(500, consoleVm.FilteredEntries.Count);

        // 2. Filter by Level: Debug
        consoleVm.SelectedLevelFilter = "Debug";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Debug, e.Level));

        // 3. Filter by Level: Info
        consoleVm.SelectedLevelFilter = "Info";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Info, e.Level));

        // 4. Filter by Level: Success
        consoleVm.SelectedLevelFilter = "Success";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Success, e.Level));

        // 5. Filter by Level: Warning
        consoleVm.SelectedLevelFilter = "Warning";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Warning, e.Level));

        // 6. Filter by Level: Error
        consoleVm.SelectedLevelFilter = "Error";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal(LogLevel.Error, e.Level));

        // 7. Search query filter (Component search: case-insensitive)
        consoleVm.SelectedLevelFilter = "All";
        consoleVm.SearchFilter = "networkguard";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Equal("NetworkGuard", e.Component));

        // 8. Search query filter (Message text search)
        consoleVm.SearchFilter = "disk sector";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e => Assert.Contains("disk sector", e.Message));

        // 9. Combined Level + Search Filter
        consoleVm.SelectedLevelFilter = "Warning";
        consoleVm.SearchFilter = "packet drop alert 4"; // matches 4, 40..49 = 11 items
        Assert.Equal(11, consoleVm.FilteredEntries.Count);
        Assert.All(consoleVm.FilteredEntries, e =>
        {
            Assert.Equal(LogLevel.Warning, e.Level);
            Assert.Contains("packet drop alert 4", e.Message);
        });

        // 10. Search with special characters (brackets, slashes) without regex crash
        consoleVm.SelectedLevelFilter = "All";
        consoleVm.SearchFilter = "I/O";
        Assert.Equal(100, consoleVm.FilteredEntries.Count);

        // 11. Clear filters
        consoleVm.SearchFilter = string.Empty;
        consoleVm.SelectedLevelFilter = "All";
        Assert.Equal(500, consoleVm.FilteredEntries.Count);
    }

    [Fact]
    public void ActivityConsoleViewModel_CopyLogAndClearLog_OperateDeterministically()
    {
        // Arrange
        var logger = new TestActivityLogger();
        var clipboardMock = new Mock<IClipboardService>();
        string? copiedText = null;
        clipboardMock.Setup(c => c.SetText(It.IsAny<string>()))
            .Callback<string>(text => copiedText = text);

        var consoleVm = new ActivityConsoleViewModel(logger, clipboardMock.Object);

        logger.LogInfo("SystemHealth", "Log record line 1");
        logger.LogError("OfficeSuite", "Log record line 2");

        // Act - Copy Log
        consoleVm.CopyLogCommand.Execute(null);

        // Assert Copy
        Assert.NotNull(copiedText);
        Assert.Contains("Log record line 1", copiedText);
        Assert.Contains("Log record line 2", copiedText);
        Assert.Contains("[SystemHealth]", copiedText);
        Assert.Contains("[OfficeSuite]", copiedText);

        // Act - Clear Log
        consoleVm.ClearLogCommand.Execute(null);

        // Assert Clear
        Assert.Equal(0, consoleVm.TotalCount);
        Assert.Equal(0, consoleVm.ErrorCount);
        Assert.Equal(0, consoleVm.WarningCount);
        Assert.Empty(consoleVm.FilteredEntries);
        Assert.Equal("Ready", consoleVm.ExecutionStatus);
        Assert.Equal("#94A3B8", consoleVm.ExecutionStatusBrush);
        Assert.False(consoleVm.ShowCompletionBanner);
    }

    // =========================================================================
    // SECTION 4: Completion Banner Transitions and Modal Freedom
    // =========================================================================

    [Fact]
    public void ActivityConsoleViewModel_CompletionBanner_LifecycleTransitionsAndModalFreedom()
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        // Verify initial state
        Assert.False(consoleVm.ShowCompletionBanner);
        Assert.Equal("Ready", consoleVm.ExecutionStatus);

        // 1. Successful operation notification
        consoleVm.NotifyOperationFinished("Quick System Repair", true, 0);

        Assert.True(consoleVm.ShowCompletionBanner);
        Assert.Equal("Completed", consoleVm.ExecutionStatus);
        Assert.Equal("#22C55E", consoleVm.ExecutionStatusBrush);
        Assert.Equal("#166534", consoleVm.CompletionBannerBrush);
        Assert.Contains("[OK]", consoleVm.CompletionMessage);
        Assert.Contains("Quick System Repair", consoleVm.CompletionMessage);
        Assert.Contains("exit code 0", consoleVm.CompletionMessage);

        // 2. Dismiss banner command
        consoleVm.DismissCompletionCommand.Execute(null);
        Assert.False(consoleVm.ShowCompletionBanner);
        Assert.Equal("Completed", consoleVm.ExecutionStatus); // Execution status is preserved

        // 3. Failed operation notification
        consoleVm.NotifyOperationFinished("Quick Mail Repair", false, 1603);

        Assert.True(consoleVm.ShowCompletionBanner);
        Assert.Equal("Failed", consoleVm.ExecutionStatus);
        Assert.Equal("#EF4444", consoleVm.ExecutionStatusBrush);
        Assert.Equal("#991B1B", consoleVm.CompletionBannerBrush);
        Assert.Contains("[FAIL]", consoleVm.CompletionMessage);
        Assert.Contains("Quick Mail Repair", consoleVm.CompletionMessage);
        Assert.Contains("exit code 1603", consoleVm.CompletionMessage);

        // 4. Subsequent log arrivals do not dismiss the banner
        logger.LogInfo("PostOperationLog", "Additional background telemetry");
        Assert.True(consoleVm.ShowCompletionBanner);
    }

    [Fact]
    public async Task ActivityConsoleViewModel_SynchronizationContext_MarshalsToRegisteredContext()
    {
        // Arrange
        var mockSyncContext = new TestSynchronizationContext();
        var previousContext = SynchronizationContext.Current;

        try
        {
            SynchronizationContext.SetSynchronizationContext(mockSyncContext);

            var logger = new TestActivityLogger();
            var consoleVm = new ActivityConsoleViewModel(logger);

            // Act - Log from background thread
            await Task.Run(() =>
            {
                logger.LogInfo("BackgroundWorker", "Async worker message");
            });

            // Assert - The test sync context recorded the posted action
            Assert.True(mockSyncContext.PostedActionCount >= 1, "ActivityConsoleViewModel must post to SynchronizationContext if on background thread.");
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(previousContext);
        }
    }

    [Fact]
    public async Task ActivityConsoleViewModel_ConcurrentLoggingWithRapidFilterSwitches_SerializedUnderUIContext_ZeroExceptions()
    {
        // Arrange - Simulate a WPF UI thread with a serializing synchronization context
        var serializingContext = new SerializingTestSynchronizationContext();
        var prevContext = SynchronizationContext.Current;

        try
        {
            SynchronizationContext.SetSynchronizationContext(serializingContext);

            var logger = new TestActivityLogger();
            var consoleVm = new ActivityConsoleViewModel(logger);

            // Act - Concurrently stream 200 logs from multiple threads while switching filters
            var logTasks = Enumerable.Range(0, 10).Select(threadId => Task.Run(() =>
            {
                for (int i = 0; i < 20; i++)
                {
                    logger.Log((LogLevel)(i % 5), $"Module_{threadId}", $"Trace event {i}");
                }
            })).ToArray();

            // Run UI-thread filter switches sequentially through the serializing context
            for (int i = 0; i < 20; i++)
            {
                serializingContext.ExecuteOnContext(() =>
                {
                    string[] filters = { "All", "Info", "Warning", "Error", "Success", "Debug" };
                    consoleVm.SelectedLevelFilter = filters[i % filters.Length];
                    consoleVm.SearchFilter = i % 2 == 0 ? "Module_1" : "Trace";
                });
                await Task.Yield();
            }

            await Task.WhenAll(logTasks);

            // Run final verification on context
            serializingContext.ExecuteOnContext(() =>
            {
                consoleVm.SelectedLevelFilter = "All";
                consoleVm.SearchFilter = string.Empty;
                Assert.Equal(200, consoleVm.TotalCount);
                Assert.Equal(200, consoleVm.FilteredEntries.Count);
            });
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(prevContext);
        }
    }

    [Theory]
    [InlineData(".*+?^${}()|[]\\")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("\"quoted string with slashes / \\ \"")]
    public void ActivityConsoleViewModel_AdversarialFilterInputs_DoesNotThrow(string? adversarialFilter)
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("TestComponent", "A message with [brackets] and (parentheses) / slashes.");
        logger.LogError("AnotherComponent", "Error: failed to access C:\\Windows\\System32.");

        // Act & Assert - must not throw Regex or parsing exceptions
        consoleVm.SearchFilter = adversarialFilter!;
        Assert.NotNull(consoleVm.FilteredEntries);

        consoleVm.SelectedLevelFilter = "NonExistentLevel";
        Assert.Empty(consoleVm.FilteredEntries);

        consoleVm.SelectedLevelFilter = "All";
        consoleVm.SearchFilter = string.Empty;
        Assert.Equal(2, consoleVm.FilteredEntries.Count);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(-1073741819)] // 0xC0000005 Access Violation as signed int
    [InlineData(int.MinValue)]
    [InlineData(int.MaxValue)]
    public void ActivityConsoleViewModel_CompletionBanner_ExtremeExitCodes_RenderCleanly(int exitCode)
    {
        // Arrange
        var logger = new TestActivityLogger();
        var consoleVm = new ActivityConsoleViewModel(logger);

        // Act
        consoleVm.NotifyOperationFinished("Adversarial Exit Code Test", false, exitCode);

        // Assert
        Assert.True(consoleVm.ShowCompletionBanner);
        Assert.Equal("Failed", consoleVm.ExecutionStatus);
        Assert.Contains(exitCode.ToString(), consoleVm.CompletionMessage);
    }

    [Fact]
    public async Task ViewModelBase_OperationCanceledException_GracefullyRecoversWithoutCrash()
    {
        // Arrange
        var healthMock = new Mock<ISystemHealthService>();
        healthMock.Setup(h => h.RunDismSfcPipeline(It.IsAny<string?>(), It.IsAny<bool>()))
            .Throws(new OperationCanceledException("Operation was aborted by user."));

        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();

        var logger = new TestActivityLogger();
        var dashboardVm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            netMock.Object,
            backupMock.Object,
            optMock.Object,
            logger);

        // Act
        await dashboardVm.QuickSystemRepairCommand.ExecuteAsync(null);

        // Assert
        Assert.False(dashboardVm.IsBusy);
        Assert.Contains("failed: Operation was aborted by user", dashboardVm.StatusMessage);
        Assert.Contains(logger.CapturedEntries, e => e.Level == LogLevel.Error && e.Message.Contains("Operation was aborted"));
    }

    private class SerializingTestSynchronizationContext : SynchronizationContext
    {
        private readonly object _lock = new();

        public override void Post(SendOrPostCallback d, object? state)
        {
            lock (_lock)
            {
                d(state);
            }
        }

        public override void Send(SendOrPostCallback d, object? state)
        {
            lock (_lock)
            {
                d(state);
            }
        }

        public void ExecuteOnContext(Action action)
        {
            lock (_lock)
            {
                action();
            }
        }
    }

    private class TestSynchronizationContext : SynchronizationContext
    {
        private int _postedActionCount;

        public int PostedActionCount => Volatile.Read(ref _postedActionCount);

        public override void Post(SendOrPostCallback d, object? state)
        {
            Interlocked.Increment(ref _postedActionCount);
            d(state); // Execute synchronously for test verification
        }
    }
}
