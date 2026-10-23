namespace IToolkit.Tests.UI;

using System;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using Xunit;

public class ActivityConsoleViewModelTests
{
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
        var vm = new ActivityConsoleViewModel(logger);

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
        var vm = new ActivityConsoleViewModel(logger);

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
        var vm = new ActivityConsoleViewModel(logger);

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
        var vm = new ActivityConsoleViewModel(logger);

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
        var vm = new ActivityConsoleViewModel(logger, clipboard);

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
        var vm = new ActivityConsoleViewModel(logger);

        bool initial = vm.IsExpanded;
        vm.ToggleExpandedCommand.Execute(null);
        Assert.Equal(!initial, vm.IsExpanded);

        vm.ToggleExpandedCommand.Execute(null);
        Assert.Equal(initial, vm.IsExpanded);
    }
}
