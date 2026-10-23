namespace IToolkit.App.Mvvm;

// Type forwarders to support both IToolkit.App.Mvvm and IToolkit.App.ViewModels namespaces
public abstract class ViewModelBase : IToolkit.App.ViewModels.ViewModelBase
{
    protected ViewModelBase(IToolkit.Core.Abstractions.IActivityLogger? logger = null) : base(logger) { }
}

public abstract class ObservableObject : IToolkit.App.ViewModels.ObservableObject
{
    protected ObservableObject(IToolkit.Core.Abstractions.IActivityLogger? logger = null) : base(logger) { }
}

public interface IRelayCommand : IToolkit.App.ViewModels.IRelayCommand { }

public class RelayCommand : IToolkit.App.ViewModels.RelayCommand
{
    public RelayCommand(System.Action<object?> execute, System.Predicate<object?>? canExecute = null) : base(execute, canExecute) { }
    public RelayCommand(System.Action execute, System.Func<bool>? canExecute = null) : base(execute, canExecute) { }
}

public class RelayCommand<T> : IToolkit.App.ViewModels.RelayCommand<T>
{
    public RelayCommand(System.Action<T?> execute, System.Predicate<T?>? canExecute = null) : base(execute, canExecute) { }
}

public interface IAsyncRelayCommand : IToolkit.App.ViewModels.IAsyncRelayCommand { }

public class AsyncRelayCommand : IToolkit.App.ViewModels.AsyncRelayCommand
{
    public AsyncRelayCommand(System.Func<object?, System.Threading.Tasks.Task> execute, System.Predicate<object?>? canExecute = null) : base(execute, canExecute) { }
    public AsyncRelayCommand(System.Func<System.Threading.Tasks.Task> execute, System.Func<bool>? canExecute = null) : base(execute, canExecute) { }
}

public class AsyncRelayCommand<T> : IToolkit.App.ViewModels.AsyncRelayCommand<T>
{
    public AsyncRelayCommand(System.Func<T?, System.Threading.Tasks.Task> execute, System.Predicate<T?>? canExecute = null) : base(execute, canExecute) { }
}
