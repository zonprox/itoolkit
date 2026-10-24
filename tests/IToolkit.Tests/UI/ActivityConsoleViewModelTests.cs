namespace IToolkit.Tests.UI;

using System;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using Xunit;

public class ActivityConsoleViewModelTests : IDisposable
{
    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }
    private class FakeActivityLogger : IActivityLogger
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

    private class FakeClipboardService : IClipboardService
    {
        public string? CopiedText { get; private set; }
        public void SetText(string text) => CopiedText = text;
    }

    [Fact]
    public void ReceivesLogEntries_AndUpdatesCounters()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("TestCat", "Informational test message");
        logger.LogWarning("TestCat", "Warning test message");
        logger.LogError("TestCat", "Error test message");

        Assert.Equal(3, vm.TotalCount);
        Assert.Equal(1, vm.WarningCount);
        Assert.Equal(1, vm.ErrorCount);
        Assert.Equal(3, vm.FilteredEntries.Count);
    }

    [Fact]
    public void FilterByLevel_FiltersEntriesCorrectly()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("Cat1", "Info msg");
        logger.LogWarning("Cat2", "Warn msg");
        logger.LogError("Cat3", "Err msg");

        vm.SelectedLevelFilter = "Error";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Error, vm.FilteredEntries[0].Level);

        vm.SelectedLevelFilter = "Warning";
        Assert.Single(vm.FilteredEntries);
        Assert.Equal(LogLevel.Warning, vm.FilteredEntries[0].Level);

        vm.SelectedLevelFilter = "All";
        Assert.Equal(3, vm.FilteredEntries.Count);
    }

    [Fact]
    public void FilterBySearchText_FiltersMatchingEntries()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("Network", "DNS flush initiated");
        logger.LogInfo("Storage", "Cleaned 45MB temp files");
        logger.LogInfo("Network", "Adapter reset complete");

        vm.SearchFilter = "DNS";
        Assert.Single(vm.FilteredEntries);
        Assert.Contains("DNS", vm.FilteredEntries[0].Message);

        vm.SearchFilter = "network";
        Assert.Equal(2, vm.FilteredEntries.Count);

        vm.SearchFilter = "";
        Assert.Equal(3, vm.FilteredEntries.Count);
    }

    [Fact]
    public void ClearLogCommand_ClearsAllEntriesAndResetsCounters()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        logger.LogInfo("Cat", "Message 1");
        logger.LogError("Cat", "Message 2");

        Assert.Equal(2, vm.TotalCount);
        Assert.Equal(1, vm.ErrorCount);

        vm.ClearLogCommand.Execute(null);

        Assert.Equal(0, vm.TotalCount);
        Assert.Equal(0, vm.ErrorCount);
        Assert.Equal(0, vm.WarningCount);
        Assert.Empty(vm.FilteredEntries);
    }

    [Fact]
    public void CopyLogCommand_CopiesFormattedLogsToClipboard()
    {
        var logger = new FakeActivityLogger();
        var clipboard = new FakeClipboardService();
        using var vm = new ActivityConsoleViewModel(logger, clipboard);

        logger.LogInfo("TestModule", "Sample log for clipboard");

        vm.CopyLogCommand.Execute(null);

        Assert.NotNull(clipboard.CopiedText);
        Assert.Contains("Sample log for clipboard", clipboard.CopiedText);
        Assert.Contains("[Info", clipboard.CopiedText);
    }

    [Fact]
    public void ToggleExpandedCommand_TogglesExpansionState()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        bool initial = vm.IsExpanded;
        vm.ToggleExpandedCommand.Execute(null);
        Assert.Equal(!initial, vm.IsExpanded);

        vm.ToggleExpandedCommand.Execute(null);
        Assert.Equal(initial, vm.IsExpanded);
    }

    private class TestOperationViewModel : ViewModelBase
    {
        public TestOperationViewModel(IActivityLogger? logger = null) : base(logger) { }

        public Task RunSuccessAsync(string name) => ExecuteAsync(name, () => Task.CompletedTask);
        public Task RunFailureAsync(string name) => ExecuteAsync(name, () => throw new InvalidOperationException("Operation failed"));
    }

    [Fact]
    public void InitialState_IsOpenIsFalse()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        Assert.False(vm.IsOpen);
    }

    [Fact]
    public void OperationStarted_SetsIsOpenTrue_UpdatesExecutionStatus_AndRaisesRequestOpen()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        bool requestOpenRaised = false;
        vm.RequestOpen += () => requestOpenRaised = true;

        Assert.False(vm.IsOpen);

        ViewModelBase.RaiseOperationStarted("Quick System Repair");

        Assert.True(vm.IsOpen);
        Assert.Equal("Executing...", vm.ExecutionStatus);
        Assert.True(requestOpenRaised);
    }

    [Fact]
    public async Task OperationExecution_ViaViewModelBase_SetsIsOpenTrue_AndRaisesRequestOpen()
    {
        var logger = new FakeActivityLogger();
        using var consoleVm = new ActivityConsoleViewModel(logger);
        var operationVm = new TestOperationViewModel(logger);

        bool requestOpenRaised = false;
        consoleVm.RequestOpen += () => requestOpenRaised = true;

        Assert.False(consoleVm.IsOpen);

        await operationVm.RunSuccessAsync("Automated PST Pipeline");

        Assert.True(consoleVm.IsOpen);
        Assert.True(requestOpenRaised);
    }

    [Fact]
    public void CloseCommand_SetsIsOpenFalse_AndRaisesRequestClose()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        // Open first
        vm.OpenCommand.Execute(null);
        Assert.True(vm.IsOpen);

        bool requestCloseRaised = false;
        vm.RequestClose += () => requestCloseRaised = true;

        vm.CloseCommand.Execute(null);

        Assert.False(vm.IsOpen);
        Assert.True(requestCloseRaised);
    }

    [Fact]
    public void OpenCommand_SetsIsOpenTrue_AndRaisesRequestOpen()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        Assert.False(vm.IsOpen);

        bool requestOpenRaised = false;
        vm.RequestOpen += () => requestOpenRaised = true;

        vm.OpenCommand.Execute(null);

        Assert.True(vm.IsOpen);
        Assert.True(requestOpenRaised);
    }

    [Fact]
    public void OperationFinished_ShowsCompletionBanner_AndSetsStatus()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        ViewModelBase.RaiseOperationStarted("Network Adapter Remediation");
        Assert.False(vm.ShowCompletionBanner);

        ViewModelBase.RaiseOperationFinished("Network Adapter Remediation", true, 0);

        Assert.True(vm.ShowCompletionBanner);
        Assert.Equal("Completed", vm.ExecutionStatus);
        Assert.Contains("finished successfully", vm.CompletionMessage);
    }

    [Fact]
    public void OperationFinished_WithFailure_ShowsErrorCompletionBanner()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        ViewModelBase.RaiseOperationStarted("Corrupted Registry Repair");
        Assert.False(vm.ShowCompletionBanner);

        ViewModelBase.RaiseOperationFinished("Corrupted Registry Repair", false, 1);

        Assert.True(vm.ShowCompletionBanner);
        Assert.Equal("Failed", vm.ExecutionStatus);
        Assert.Contains("failed with exit code 1", vm.CompletionMessage);
    }

    [Fact]
    public async Task OperationExecution_Failure_ViaViewModelBase_ShowsErrorCompletionBanner()
    {
        var logger = new FakeActivityLogger();
        using var consoleVm = new ActivityConsoleViewModel(logger);
        var operationVm = new TestOperationViewModel(logger);

        await operationVm.RunFailureAsync("Failing Operation");

        Assert.True(consoleVm.ShowCompletionBanner);
        Assert.Equal("Errors Encountered", consoleVm.ExecutionStatus);
        Assert.Contains("failed", consoleVm.CompletionMessage);
    }

    [Fact]
    public void Dispose_UnsubscribesFromOperationEvents_AndDoesNotReceiveSubsequentEvents()
    {
        var logger = new FakeActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        vm.Dispose();

        ViewModelBase.RaiseOperationStarted("PostDisposeOp");
        Assert.False(vm.IsOpen);
        Assert.Equal("Ready", vm.ExecutionStatus);

        ViewModelBase.RaiseOperationFinished("PostDisposeOp", true, 0);
        Assert.False(vm.ShowCompletionBanner);
    }

    [Fact]
    public void Dispose_UnsubscribesFromLogger_AndDoesNotReceiveSubsequentEntries()
    {
        var logger = new FakeActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        vm.Dispose();

        logger.LogInfo("TestCat", "Post-dispose message");
        Assert.Equal(0, vm.TotalCount);
        Assert.Empty(vm.FilteredEntries);
    }

    [Fact]
    public void Dispose_CanBeCalledMultipleTimesWithoutThrowing()
    {
        var logger = new FakeActivityLogger();
        var vm = new ActivityConsoleViewModel(logger);

        var ex = Record.Exception(() =>
        {
            vm.Dispose();
            vm.Dispose();
        });

        Assert.Null(ex);
    }

    [Fact]
    public void ResetOperationEvents_ClearsAllSubscribedDelegates()
    {
        var logger = new FakeActivityLogger();
        using var vm = new ActivityConsoleViewModel(logger);

        ViewModelBase.ResetOperationEvents();

        ViewModelBase.RaiseOperationStarted("ResetOp");
        Assert.False(vm.IsOpen);
        Assert.Equal("Ready", vm.ExecutionStatus);
    }
}
