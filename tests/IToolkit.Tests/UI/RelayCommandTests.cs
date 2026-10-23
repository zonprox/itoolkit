namespace IToolkit.Tests.UI;

using System;
using IToolkit.App.ViewModels;
using Xunit;

public class RelayCommandTests
{
    [Fact]
    public void Parameterless_Execute_InvokesAction()
    {
        bool executed = false;
        var cmd = new RelayCommand(() => executed = true);

        Assert.True(cmd.CanExecute(null));
        cmd.Execute(null);

        Assert.True(executed);
    }

    [Fact]
    public void Parameterless_CanExecute_RespectsPredicate()
    {
        bool allowed = false;
        var cmd = new RelayCommand(() => { }, () => allowed);

        Assert.False(cmd.CanExecute(null));

        allowed = true;
        Assert.True(cmd.CanExecute(null));
    }

    [Fact]
    public void RaiseCanExecuteChanged_FiresEvent()
    {
        var cmd = new RelayCommand(() => { });
        bool fired = false;
        cmd.CanExecuteChanged += (s, e) => fired = true;

        cmd.RaiseCanExecuteChanged();

        Assert.True(fired);
    }

    [Fact]
    public void Parameterized_Execute_PassesArgument()
    {
        string? received = null;
        var cmd = new RelayCommand<string>(s => received = s);

        cmd.Execute("Hello");

        Assert.Equal("Hello", received);
    }

    [Fact]
    public void Parameterized_CanExecute_ValidatesArgument()
    {
        var cmd = new RelayCommand<string>(s => { }, s => !string.IsNullOrEmpty(s));

        Assert.False(cmd.CanExecute(null));
        Assert.False(cmd.CanExecute(""));
        Assert.True(cmd.CanExecute("Valid"));
    }

    [Fact]
    public void GenericValueType_HandlesNullGracefully()
    {
        int received = -1;
        var cmd = new RelayCommand<int>(n => received = n, n => n >= 0);

        Assert.True(cmd.CanExecute(0));
        Assert.False(cmd.CanExecute(-5));

        cmd.Execute(42);
        Assert.Equal(42, received);
    }

    [Fact]
    public void Constructor_NullAction_ThrowsArgumentNullException()
    {
        Assert.Throws<ArgumentNullException>(() => new RelayCommand((Action)null!));
        Assert.Throws<ArgumentNullException>(() => new RelayCommand<string>((Action<string?>)null!));
    }
}
