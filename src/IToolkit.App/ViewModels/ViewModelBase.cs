namespace IToolkit.App.ViewModels;

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;

/// <summary>
/// Lightweight base class for MVVM ViewModels providing property change notification, busy state tracking, and activity logging.
/// </summary>
public abstract class ViewModelBase : INotifyPropertyChanged
{
    private readonly SynchronizationContext? _uiContext = SynchronizationContext.Current;
    private bool _isBusy;
    private string _statusMessage = string.Empty;

    public static event Action<string>? OperationStarted;
    public static event Action<string, bool, int>? OperationFinished;

    public static void RaiseOperationStarted(string operationName) => OperationStarted?.Invoke(operationName);
    public static void RaiseOperationFinished(string operationName, bool success, int exitCode = 0) => OperationFinished?.Invoke(operationName, success, exitCode);

    /// <summary>
    /// Resets all static operation event subscribers. Intended for test isolation and application reset.
    /// </summary>
    public static void ResetOperationEvents()
    {
        OperationStarted = null;
        OperationFinished = null;
    }

    protected IActivityLogger? Logger { get; }

    protected ViewModelBase(IActivityLogger? logger = null)
    {
        Logger = logger;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsBusy
    {
        get => _isBusy;
        set
        {
            if (SetProperty(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(IsNotBusy));
            }
        }
    }

    public bool IsNotBusy => !_isBusy;

    public string StatusMessage
    {
        get => _statusMessage;
        set => SetProperty(ref _statusMessage, value);
    }

    protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        if (_uiContext != null && SynchronizationContext.Current != _uiContext)
        {
            _uiContext.Post(_ => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName)), null);
            return;
        }

        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    protected bool SetProperty<T>(ref T storage, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(storage, value))
        {
            return false;
        }

        storage = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    /// <summary>
    /// Executes an asynchronous operation with automatic busy state toggling, status reporting, and activity logging.
    /// </summary>
    protected async Task ExecuteAsync(string operationName, Func<Task> action)
    {
        if (IsBusy)
        {
            return;
        }

        try
        {
            IsBusy = true;
            RaiseOperationStarted(operationName);
            StatusMessage = $"Running {operationName}...";
            Logger?.LogInfo(GetType().Name, $"Starting operation: {operationName}...");

            await action();

            StatusMessage = $"{operationName} completed successfully.";
            Logger?.LogSuccess(GetType().Name, $"{operationName} completed successfully.");
            RaiseOperationFinished(operationName, true, 0);
        }
        catch (Exception ex)
        {
            StatusMessage = $"{operationName} failed: {ex.Message}";
            Logger?.LogError(GetType().Name, $"Operation '{operationName}' failed: {ex.Message}");
            RaiseOperationFinished(operationName, false, 1);
        }
        finally
        {
            IsBusy = false;
        }
    }
}
