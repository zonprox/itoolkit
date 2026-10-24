namespace IToolkit.Tests.UI;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Xml.Linq;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using Xunit;

public class Milestone2EmpiricalChallengeTests : IDisposable
{
    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }
    private class EmpiricalTestLogger : IActivityLogger
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

    private class TestHarnessViewModel : ViewModelBase
    {
        public TestHarnessViewModel(IActivityLogger? logger = null) : base(logger) { }

        public Task RunActionAsync(string name, Func<Task> action) => ExecuteAsync(name, action);
    }

    // =========================================================================
    // 1. RAPID CONCURRENT OPERATION TRIGGERING STRESS TESTS
    // =========================================================================

    [Fact]
    public async Task ConcurrentOperations_HighLoadStressTest_DoesNotCorruptStateOrThrow()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        int requestOpenCount = 0;
        int requestCloseCount = 0;
        vm.RequestOpen += () => Interlocked.Increment(ref requestOpenCount);
        vm.RequestClose += () => Interlocked.Increment(ref requestCloseCount);

        const int workerCount = 40;
        const int iterationsPerWorker = 25;
        var exceptions = new ConcurrentBag<Exception>();

        var tasks = Enumerable.Range(0, workerCount).Select(workerId => Task.Run(() =>
        {
            try
            {
                for (int i = 0; i < iterationsPerWorker; i++)
                {
                    string opName = $"WorkerOp_{workerId}_{i}";
                    ViewModelBase.RaiseOperationStarted(opName);

                    if (i % 3 == 0)
                    {
                        logger.LogError("StressComponent", $"Simulated failure in {opName}");
                        ViewModelBase.RaiseOperationFinished(opName, false, 1);
                    }
                    else
                    {
                        logger.LogInfo("StressComponent", $"Simulated success in {opName}");
                        ViewModelBase.RaiseOperationFinished(opName, true, 0);
                    }

                    if (i % 5 == 0)
                    {
                        vm.CloseCommand.Execute(null);
                    }
                    else if (i % 7 == 0)
                    {
                        vm.OpenCommand.Execute(null);
                    }
                }
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        Assert.Empty(exceptions);
        Assert.True(requestOpenCount > 0, "RequestOpen should have fired across concurrent tasks.");
        Assert.NotNull(vm.ExecutionStatus);
        Assert.NotNull(vm.ExecutionStatusBrush);
        Assert.NotNull(vm.CompletionBannerBrush);
        Assert.NotNull(vm.CompletionMessage);
        Assert.True(vm.TotalCount >= 0);
    }

    [Fact]
    public void RapidSequentialOperations_MaintainsStateConsistencyAcrossTransitions()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        // 1. Verify deterministic state transitions on ViewModel instance directly
        const int iterations = 50;
        for (int i = 0; i < iterations; i++)
        {
            string opName = $"SequentialOp_{i}";
            vm.IsOpen = true;

            bool success = (i % 2 == 0);
            vm.NotifyOperationFinished(opName, success, success ? 0 : 42);

            Assert.True(vm.ShowCompletionBanner);
            if (success)
            {
                Assert.Equal("Completed", vm.ExecutionStatus);
                Assert.Contains("[OK]", vm.CompletionMessage);
            }
            else
            {
                Assert.Equal("Failed", vm.ExecutionStatus);
                Assert.Contains("[FAIL]", vm.CompletionMessage);
            }
        }

        // 2. Verify rapid sequential static event firing does not throw or corrupt state
        var exceptions = new List<Exception>();
        for (int i = 0; i < iterations; i++)
        {
            try
            {
                string opName = $"StaticSeqOp_{i}";
                ViewModelBase.RaiseOperationStarted(opName);
                ViewModelBase.RaiseOperationFinished(opName, i % 2 == 0, 0);

                Assert.True(vm.IsOpen);
                Assert.NotNull(vm.ExecutionStatus);
                Assert.NotNull(vm.CompletionMessage);
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        }

        Assert.Empty(exceptions);
    }

    // =========================================================================
    // 2. LIFECYCLE TRANSITIONS & COMMANDS
    // =========================================================================

    [Fact]
    public void LifecycleTransitions_CompleteStateMatrixVerification()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        int openEvents = 0;
        int closeEvents = 0;
        vm.RequestOpen += () => openEvents++;
        vm.RequestClose += () => closeEvents++;

        // Initial state
        Assert.False(vm.IsOpen);
        Assert.Equal(0, openEvents);
        Assert.Equal(0, closeEvents);

        // Transition: OperationStarted -> Opens
        ViewModelBase.RaiseOperationStarted("Op1");
        Assert.True(vm.IsOpen);
        Assert.Equal(1, openEvents);
        Assert.Equal(0, closeEvents);

        // Transition: CloseCommand -> Closes
        vm.CloseCommand.Execute(null);
        Assert.False(vm.IsOpen);
        Assert.Equal(1, openEvents);
        Assert.Equal(1, closeEvents);

        // Idempotent CloseCommand when already closed
        vm.CloseCommand.Execute(null);
        Assert.False(vm.IsOpen);
        Assert.Equal(1, openEvents);
        Assert.Equal(2, closeEvents);

        // Transition: OpenCommand -> Opens
        vm.OpenCommand.Execute(null);
        Assert.True(vm.IsOpen);
        Assert.Equal(2, openEvents);
        Assert.Equal(2, closeEvents);

        // Idempotent OpenCommand when already open
        vm.OpenCommand.Execute(null);
        Assert.True(vm.IsOpen);
        Assert.Equal(3, openEvents);
        Assert.Equal(2, closeEvents);

        // Transition: Subsequent OperationStarted while open
        ViewModelBase.RaiseOperationStarted("Op2");
        Assert.True(vm.IsOpen);
        Assert.Equal(4, openEvents);
        Assert.Equal(2, closeEvents);

        // Transition: OperationFinished preserves IsOpen until user closes
        ViewModelBase.RaiseOperationFinished("Op2", true, 0);
        Assert.True(vm.IsOpen);

        // Close after finish
        vm.CloseCommand.Execute(null);
        Assert.False(vm.IsOpen);
        Assert.Equal(3, closeEvents);
    }

    [Fact]
    public void Commands_HandleNullAndUnexpectedParametersGracefully()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        // Close and Open commands should accept any parameter or null without error
        vm.OpenCommand.Execute("some_string");
        Assert.True(vm.IsOpen);

        vm.CloseCommand.Execute(12345);
        Assert.False(vm.IsOpen);

        vm.ToggleExpandedCommand.Execute(new object());
        Assert.False(vm.IsExpanded);

        vm.ToggleExpandedCommand.Execute(null);
        Assert.True(vm.IsExpanded);

        vm.DismissCompletionCommand.Execute("dismiss");
        Assert.False(vm.ShowCompletionBanner);
    }

    // =========================================================================
    // 3. ERROR COMPLETION STATUS & BANNER LOGIC
    // =========================================================================

    [Fact]
    public void ErrorCompletionStatus_DistinguishesCleanFailureFromLoggedErrors()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        // Scenario 1: Clean failure without error log entries
        ViewModelBase.RaiseOperationStarted("CleanFailOp");
        ViewModelBase.RaiseOperationFinished("CleanFailOp", false, 5);

        Assert.True(vm.ShowCompletionBanner);
        Assert.Equal("Failed", vm.ExecutionStatus);
        Assert.Equal("#EF4444", vm.ExecutionStatusBrush);
        Assert.Equal("#991B1B", vm.CompletionBannerBrush);
        Assert.Contains("[FAIL] 'CleanFailOp' failed with exit code 5", vm.CompletionMessage);

        // Dismiss banner
        vm.DismissCompletionCommand.Execute(null);
        Assert.False(vm.ShowCompletionBanner);

        // Scenario 2: Failure with error entries logged
        ViewModelBase.RaiseOperationStarted("LoggedErrorOp");
        logger.LogError("DiskRepair", "Sector read failure at 0xDEADBEEF");
        Assert.Equal(1, vm.ErrorCount);

        ViewModelBase.RaiseOperationFinished("LoggedErrorOp", false, 1);
        Assert.True(vm.ShowCompletionBanner);
        Assert.Equal("Errors Encountered", vm.ExecutionStatus);
        Assert.Equal("#EF4444", vm.ExecutionStatusBrush);
        Assert.Equal("#991B1B", vm.CompletionBannerBrush);
        Assert.Contains("[FAIL] 'LoggedErrorOp' failed with exit code 1", vm.CompletionMessage);

        // Scenario 3: Success resets to completed banner
        ViewModelBase.RaiseOperationStarted("RecoveryOp");
        ViewModelBase.RaiseOperationFinished("RecoveryOp", true, 0);
        Assert.True(vm.ShowCompletionBanner);
        Assert.Equal("Completed", vm.ExecutionStatus);
        Assert.Equal("#22C55E", vm.ExecutionStatusBrush);
        Assert.Equal("#166534", vm.CompletionBannerBrush);
        Assert.Contains("[OK] 'RecoveryOp' finished successfully with exit code 0", vm.CompletionMessage);
    }

    // =========================================================================
    // 4. VIEWMODELBASE.EXECUTEASYNC INTEGRATION
    // =========================================================================

    [Fact]
    public async Task ExecuteAsync_TriggersCorrectLifecycleAndHandlesExceptions()
    {
        ViewModelBase.ResetOperationEvents();
        var logger = new EmpiricalTestLogger();
        using var consoleVm = new ActivityConsoleViewModel(logger);
        var harnessVm = new TestHarnessViewModel(logger);

        var startedOps = new List<string>();
        var finishedOps = new List<(string Name, bool Success, int ExitCode)>();

        void OnStart(string name) => startedOps.Add(name);
        void OnFinish(string name, bool success, int exitCode) => finishedOps.Add((name, success, exitCode));

        ViewModelBase.OperationStarted += OnStart;
        ViewModelBase.OperationFinished += OnFinish;

        try
        {
            // Successful action
            await harnessVm.RunActionAsync("SuccessfulTask", async () =>
            {
                await Task.Yield();
            });

            Assert.Contains("SuccessfulTask", startedOps);
            Assert.Contains(finishedOps, f => f.Name == "SuccessfulTask" && f.Success && f.ExitCode == 0);
            Assert.Equal("SuccessfulTask completed successfully.", harnessVm.StatusMessage);
            Assert.True(harnessVm.IsNotBusy);

            // Failing action with unhandled exception
            await harnessVm.RunActionAsync("FaultedTask", () =>
            {
                throw new InvalidOperationException("Fatal device IO error");
            });

            Assert.Contains("FaultedTask", startedOps);
            Assert.Contains(finishedOps, f => f.Name == "FaultedTask" && !f.Success && f.ExitCode == 1);
            Assert.Contains("Fatal device IO error", harnessVm.StatusMessage);
            Assert.True(harnessVm.IsNotBusy);
            Assert.Equal("Errors Encountered", consoleVm.ExecutionStatus);
        }
        finally
        {
            ViewModelBase.OperationStarted -= OnStart;
            ViewModelBase.OperationFinished -= OnFinish;
            ViewModelBase.ResetOperationEvents();
        }
    }

    [Fact]
    public async Task ExecuteAsync_WhenAlreadyBusy_SuppressesConcurrentExecution()
    {
        var logger = new EmpiricalTestLogger();
        var harnessVm = new TestHarnessViewModel(logger);

        var tcs = new TaskCompletionSource<bool>();
        int executedCount = 0;

        var task1 = harnessVm.RunActionAsync("BlockingOp", async () =>
        {
            Interlocked.Increment(ref executedCount);
            await tcs.Task;
        });

        // Attempt second concurrent execution on same ViewModel instance while busy
        var task2 = harnessVm.RunActionAsync("SecondOp", async () =>
        {
            Interlocked.Increment(ref executedCount);
            await Task.CompletedTask;
        });

        await task2;
        Assert.Equal(1, executedCount); // Second call suppressed because IsBusy was true

        tcs.SetResult(true);
        await task1;

        Assert.Equal(1, executedCount);
        Assert.True(harnessVm.IsNotBusy);
    }

    // =========================================================================
    // 5. STATIC INVOCATION NULL/EMPTY ARGUMENT RESILIENCE
    // =========================================================================

    [Fact]
    public void StaticEvents_NullOrEmptyArguments_DoNotThrowExceptions()
    {
        var logger = new EmpiricalTestLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        var ex1 = Record.Exception(() => ViewModelBase.RaiseOperationStarted(null!));
        Assert.Null(ex1);

        var ex2 = Record.Exception(() => ViewModelBase.RaiseOperationStarted(string.Empty));
        Assert.Null(ex2);

        var ex3 = Record.Exception(() => ViewModelBase.RaiseOperationFinished(null!, false, -1));
        Assert.Null(ex3);

        var ex4 = Record.Exception(() => ViewModelBase.RaiseOperationFinished(string.Empty, true, 0));
        Assert.Null(ex4);
    }

    // =========================================================================
    // 6. XAML AND CODE-BEHIND CONTRACT CHECKS
    // =========================================================================

    private static string FindSolutionRoot()
    {
        string? current = AppDomain.CurrentDomain.BaseDirectory;
        while (current != null)
        {
            if (File.Exists(Path.Combine(current, "IToolkit.sln")))
            {
                return current;
            }
            current = Directory.GetParent(current)?.FullName;
        }
        throw new InvalidOperationException("Could not locate IToolkit.sln directory.");
    }

    [Fact]
    public void ActivityLogWindowXaml_CompliesWithSpecifications()
    {
        string solutionDir = FindSolutionRoot();
        string xamlPath = Path.Combine(solutionDir, "src", "IToolkit.App", "Views", "ActivityLogWindow.xaml");
        Assert.True(File.Exists(xamlPath), $"ActivityLogWindow.xaml must exist at {xamlPath}");

        string content = File.ReadAllText(xamlPath);
        var doc = XDocument.Parse(content);
        var root = doc.Root;
        Assert.NotNull(root);

        // Validate window attributes
        Assert.Equal("iToolKit - Activity Log", root.Attribute("Title")?.Value);
        Assert.Equal("CenterOwner", root.Attribute("WindowStartupLocation")?.Value);
        Assert.Equal("True", root.Attribute("ShowInTaskbar")?.Value);

        double width = double.Parse(root.Attribute("Width")?.Value ?? "0");
        double height = double.Parse(root.Attribute("Height")?.Value ?? "0");
        double minWidth = double.Parse(root.Attribute("MinWidth")?.Value ?? "0");
        double minHeight = double.Parse(root.Attribute("MinHeight")?.Value ?? "0");

        Assert.True(width >= 700, $"Width ({width}) should be >= 700");
        Assert.True(height >= 400, $"Height ({height}) should be >= 400");
        Assert.True(minWidth >= 600, $"MinWidth ({minWidth}) should be >= 600");
        Assert.True(minHeight >= 320, $"MinHeight ({minHeight}) should be >= 320");

        // Validate embedded ActivityConsoleView
        var consoleElement = root.Descendants().FirstOrDefault(e => e.Name.LocalName == "ActivityConsoleView");
        Assert.NotNull(consoleElement);
        Assert.Equal("Stretch", consoleElement.Attribute("VerticalAlignment")?.Value);
        Assert.Equal("Stretch", consoleElement.Attribute("HorizontalAlignment")?.Value);
    }

    [Fact]
    public void MainWindowCodeBehind_ContainsLifecycleWiring()
    {
        string solutionDir = FindSolutionRoot();
        string csPath = Path.Combine(solutionDir, "src", "IToolkit.App", "MainWindow.xaml.cs");
        Assert.True(File.Exists(csPath), $"MainWindow.xaml.cs must exist at {csPath}");

        string code = File.ReadAllText(csPath);

        // Verify subscriptions and lifecycle methods
        Assert.Contains("RequestOpen += ShowLogWindow", code);
        Assert.Contains("RequestClose += CloseLogWindow", code);
        Assert.Contains("ShowLogWindow()", code);
        Assert.Contains("CloseLogWindow()", code);
        Assert.Contains("Dispatcher.Invoke", code);
        Assert.Contains("Dispatcher.HasShutdownStarted", code);
        Assert.Contains("ActivityLogWindow", code);
        Assert.Contains("Owner = this", code);
        Assert.Contains("DataContext = _viewModel.ActivityConsole", code);
    }
}
