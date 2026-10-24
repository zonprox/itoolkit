namespace IToolkit.App.ViewModels;

using System;
using System.Threading;
using System.Windows.Input;

public interface IRelayCommand : ICommand
{
    void RaiseCanExecuteChanged();
}

/// <summary>
/// Synchronous ICommand implementation wrapping Action delegates.
/// </summary>
public class RelayCommand : IRelayCommand
{
    private readonly Action<object?> _execute;
    private readonly Predicate<object?>? _canExecute;
    private readonly SynchronizationContext? _uiContext = SynchronizationContext.Current;

    public RelayCommand(Action<object?> execute, Predicate<object?>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
        : this(execute != null ? _ => execute() : throw new ArgumentNullException(nameof(execute)), canExecute == null ? null : _ => canExecute())
    {
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute == null || _canExecute(parameter);

    public void Execute(object? parameter) => _execute(parameter);

    public void RaiseCanExecuteChanged()
    {
        if (_uiContext != null && SynchronizationContext.Current != _uiContext)
        {
            _uiContext.Post(_ => CanExecuteChanged?.Invoke(this, EventArgs.Empty), null);
            return;
        }

        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}

/// <summary>
/// Generic synchronous ICommand implementation for strongly-typed command parameters.
/// </summary>
public class RelayCommand<T> : IRelayCommand
{
    private readonly Action<T?> _execute;
    private readonly Predicate<T?>? _canExecute;
    private readonly SynchronizationContext? _uiContext = SynchronizationContext.Current;

    public RelayCommand(Action<T?> execute, Predicate<T?>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter)
    {
        if (_canExecute == null)
        {
            return true;
        }

        if (parameter == null && typeof(T).IsValueType && Nullable.GetUnderlyingType(typeof(T)) == null)
        {
            return _canExecute(default);
        }

        return _canExecute((T?)parameter);
    }

    public void Execute(object? parameter)
    {
        if (parameter == null && typeof(T).IsValueType && Nullable.GetUnderlyingType(typeof(T)) == null)
        {
            _execute(default);
            return;
        }

        _execute((T?)parameter);
    }

    public void RaiseCanExecuteChanged()
    {
        if (_uiContext != null && SynchronizationContext.Current != _uiContext)
        {
            _uiContext.Post(_ => CanExecuteChanged?.Invoke(this, EventArgs.Empty), null);
            return;
        }

        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
