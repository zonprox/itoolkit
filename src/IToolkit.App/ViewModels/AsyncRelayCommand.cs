namespace IToolkit.App.ViewModels;

using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Input;

public interface IAsyncRelayCommand : ICommand
{
    bool IsExecuting { get; }
    Task ExecuteAsync(object? parameter);
    void RaiseCanExecuteChanged();
}

/// <summary>
/// Asynchronous ICommand implementation supporting Task-based execution with concurrency guards.
/// </summary>
public class AsyncRelayCommand : IAsyncRelayCommand
{
    private readonly Func<object?, Task> _execute;
    private readonly Predicate<object?>? _canExecute;
    private int _isExecutingState;

    public AsyncRelayCommand(Func<object?, Task> execute, Predicate<object?>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
        : this(execute != null ? _ => execute() : throw new ArgumentNullException(nameof(execute)), canExecute == null ? null : _ => canExecute())
    {
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsExecuting => Volatile.Read(ref _isExecutingState) == 1;

    public bool CanExecute(object? parameter)
    {
        return !IsExecuting && (_canExecute == null || _canExecute(parameter));
    }

    public async void Execute(object? parameter)
    {
        await ExecuteAsync(parameter).ConfigureAwait(false);
    }

    public async Task ExecuteAsync(object? parameter)
    {
        if (!CanExecute(parameter))
        {
            return;
        }

        if (Interlocked.CompareExchange(ref _isExecutingState, 1, 0) != 0)
        {
            return;
        }

        try
        {
            RaiseCanExecuteChanged();
            await _execute(parameter).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Exchange(ref _isExecutingState, 0);
            RaiseCanExecuteChanged();
        }
    }

    public void RaiseCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}

/// <summary>
/// Generic asynchronous ICommand implementation for strongly-typed command parameters.
/// </summary>
public class AsyncRelayCommand<T> : IAsyncRelayCommand
{
    private readonly Func<T?, Task> _execute;
    private readonly Predicate<T?>? _canExecute;
    private int _isExecutingState;

    public AsyncRelayCommand(Func<T?, Task> execute, Predicate<T?>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsExecuting => Volatile.Read(ref _isExecutingState) == 1;

    public bool CanExecute(object? parameter)
    {
        if (IsExecuting)
        {
            return false;
        }

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

    public async void Execute(object? parameter)
    {
        await ExecuteAsync(parameter).ConfigureAwait(false);
    }

    public async Task ExecuteAsync(object? parameter)
    {
        if (!CanExecute(parameter))
        {
            return;
        }

        if (Interlocked.CompareExchange(ref _isExecutingState, 1, 0) != 0)
        {
            return;
        }

        try
        {
            RaiseCanExecuteChanged();
            if (parameter == null && typeof(T).IsValueType && Nullable.GetUnderlyingType(typeof(T)) == null)
            {
                await _execute(default).ConfigureAwait(false);
            }
            else
            {
                await _execute((T?)parameter).ConfigureAwait(false);
            }
        }
        finally
        {
            Interlocked.Exchange(ref _isExecutingState, 0);
            RaiseCanExecuteChanged();
        }
    }

    public void RaiseCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
