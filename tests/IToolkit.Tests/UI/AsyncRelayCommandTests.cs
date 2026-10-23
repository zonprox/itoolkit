namespace IToolkit.Tests.UI;

using System;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using Xunit;

public class AsyncRelayCommandTests
{
    [Fact]
    public async Task Parameterless_ExecuteAsync_InvokesTask()
    {
        bool executed = false;
        var cmd = new AsyncRelayCommand(async () =>
        {
            await Task.Yield();
            executed = true;
        });

        Assert.True(cmd.CanExecute(null));
        await cmd.ExecuteAsync(null);

        Assert.True(executed);
    }

    [Fact]
    public async Task ConcurrencyGuard_PreventsReentrancyWhileExecuting()
    {
        var tcs = new TaskCompletionSource<bool>();
        var cmd = new AsyncRelayCommand(async () =>
        {
            await tcs.Task;
        });

        Assert.True(cmd.CanExecute(null));

        var execTask = cmd.ExecuteAsync(null);

        Assert.True(cmd.IsExecuting);
        Assert.False(cmd.CanExecute(null));

        tcs.SetResult(true);
        await execTask;

        Assert.False(cmd.IsExecuting);
        Assert.True(cmd.CanExecute(null));
    }

    [Fact]
    public async Task Parameterized_ExecuteAsync_PassesArgument()
    {
        string? received = null;
        var cmd = new AsyncRelayCommand<string>(async s =>
        {
            await Task.Yield();
            received = s;
        });

        await cmd.ExecuteAsync("Payload");
        Assert.Equal("Payload", received);
    }

    [Fact]
    public async Task Execution_RestoresIsExecuting_EvenOnFailure()
    {
        var cmd = new AsyncRelayCommand(async () =>
        {
            await Task.Yield();
            throw new InvalidOperationException("Simulated fault");
        });

        await Assert.ThrowsAsync<InvalidOperationException>(() => cmd.ExecuteAsync(null));
        Assert.False(cmd.IsExecuting);
        Assert.True(cmd.CanExecute(null));
    }

    [Fact]
    public void Constructor_NullAction_ThrowsArgumentNullException()
    {
        Assert.Throws<ArgumentNullException>(() => new AsyncRelayCommand((Func<Task>)null!));
        Assert.Throws<ArgumentNullException>(() => new AsyncRelayCommand<string>((Func<string?, Task>)null!));
    }
}
