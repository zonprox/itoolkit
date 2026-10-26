namespace IToolkit.App.ViewModels;

using System;
using System.Collections.ObjectModel;
using System.Text;
using System.Threading;
using System.Windows.Input;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Clipboard abstraction to decouple ViewModel logic from Windows Presentation STA clipboard calls in unit tests.
/// </summary>
public interface IClipboardService
{
    void SetText(string text);
}

public class DefaultClipboardService : IClipboardService
{
    public void SetText(string text)
    {
        try
        {
            var clipboardType = Type.GetType("System.Windows.Clipboard, PresentationCore");
            clipboardType?.GetMethod("SetText", new[] { typeof(string) })?.Invoke(null, new object[] { text });
        }
        catch
        {
            // Ignore transient COM clipboard errors
        }
    }
}

public class ActivityConsoleViewModel : ViewModelBase, IDisposable
{
    private readonly IActivityLogger _logger;
    private readonly IClipboardService _clipboardService;
    private readonly SynchronizationContext? _uiContext;

    private readonly ObservableCollection<ActivityLogEntry> _allEntries = new();
    private readonly ObservableCollection<ActivityLogEntry> _filteredEntries = new();

    private string _searchFilter = string.Empty;
    private string _selectedLevelFilter = "All";
    private bool _autoScroll = true;
    private bool _isExpanded = true;
    private double _consoleHeight = double.NaN;
    private bool _disposed;
    private bool _isOpen;

    private int _totalCount;
    private int _errorCount;
    private int _warningCount;

    private string _executionStatus = "Ready";
    private string _executionStatusBrush = "#94A3B8";

    private bool _showCompletionBanner;
    private string _completionMessage = string.Empty;
    private string _completionBannerBrush = "#22C55E";

    public ActivityConsoleViewModel(
        IActivityLogger logger,
        IClipboardService? clipboardService = null)
        : base(logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _clipboardService = clipboardService ?? new DefaultClipboardService();
        _uiContext = SynchronizationContext.Current;

        ClearLogCommand = new RelayCommand(() =>
        {
            Logger?.LogInfo(nameof(ActivityConsoleViewModel), "Activity Log cleared by user.");
            ClearLog();
        });
        CopyLogCommand = new RelayCommand(() =>
        {
            CopyLog();
            Logger?.LogInfo(nameof(ActivityConsoleViewModel), "Activity Log copied to clipboard.");
        });
        ToggleAutoScrollCommand = new RelayCommand(() => AutoScroll = !AutoScroll);
        ToggleExpandedCommand = new RelayCommand(ToggleExpanded);
        DismissCompletionCommand = new RelayCommand(() => ShowCompletionBanner = false);
        SetFilterCommand = new RelayCommand<string>(level => SelectedLevelFilter = level ?? "All");
        CloseCommand = new RelayCommand(() =>
        {
            IsOpen = false;
            Logger?.LogInfo(nameof(ActivityConsoleViewModel), "Activity Log window closed.");
            RequestClose?.Invoke();
        });
        OpenCommand = new RelayCommand(() =>
        {
            IsOpen = true;
            Logger?.LogInfo(nameof(ActivityConsoleViewModel), "Activity Log window opened.");
            RequestOpen?.Invoke();
        });

        // Wire into Core Activity Logger event stream
        _logger.EntryLogged += OnEntryLogged;

        // Wire into ViewModelBase operation events
        ViewModelBase.OperationStarted += OnOperationStarted;
        ViewModelBase.OperationFinished += OnOperationFinished;
    }

    public ObservableCollection<ActivityLogEntry> FilteredEntries => _filteredEntries;

    public string SearchFilter
    {
        get => _searchFilter;
        set
        {
            if (SetProperty(ref _searchFilter, value))
            {
                ApplyFilter();
            }
        }
    }

    public string SelectedLevelFilter
    {
        get => _selectedLevelFilter;
        set
        {
            if (SetProperty(ref _selectedLevelFilter, value))
            {
                ApplyFilter();
            }
        }
    }

    public bool AutoScroll { get => _autoScroll; set => SetProperty(ref _autoScroll, value); }
    public bool IsExpanded { get => _isExpanded; set => SetProperty(ref _isExpanded, value); }
    public double ConsoleHeight { get => _consoleHeight; set => SetProperty(ref _consoleHeight, value); }
    public bool IsOpen { get => _isOpen; set => SetProperty(ref _isOpen, value); }

    public int TotalCount { get => _totalCount; private set => SetProperty(ref _totalCount, value); }
    public int ErrorCount { get => _errorCount; private set => SetProperty(ref _errorCount, value); }
    public int WarningCount { get => _warningCount; private set => SetProperty(ref _warningCount, value); }

    public string ExecutionStatus { get => _executionStatus; set => SetProperty(ref _executionStatus, value); }
    public string ExecutionStatusBrush { get => _executionStatusBrush; set => SetProperty(ref _executionStatusBrush, value); }

    public bool ShowCompletionBanner { get => _showCompletionBanner; set => SetProperty(ref _showCompletionBanner, value); }
    public string CompletionMessage { get => _completionMessage; set => SetProperty(ref _completionMessage, value); }
    public string CompletionBannerBrush { get => _completionBannerBrush; set => SetProperty(ref _completionBannerBrush, value); }

    public ICommand ClearLogCommand { get; }
    public ICommand CopyLogCommand { get; }
    public ICommand ToggleAutoScrollCommand { get; }
    public ICommand ToggleExpandedCommand { get; }
    public ICommand DismissCompletionCommand { get; }
    public ICommand SetFilterCommand { get; }
    public ICommand CloseCommand { get; }
    public ICommand OpenCommand { get; }

    public event Action? LogEntryAppended;
    public event Action? RequestOpen;
    public event Action? RequestClose;

    private void OnEntryLogged(ActivityLogEntry entry)
    {
        void Append()
        {
            _allEntries.Add(entry);
            TotalCount = _allEntries.Count;

            if (entry.Level == LogLevel.Error) ErrorCount++;
            if (entry.Level == LogLevel.Warning) WarningCount++;

            if (MatchesFilter(entry))
            {
                _filteredEntries.Add(entry);
            }

            // Update execution state indicators
            if (entry.Level == LogLevel.Error)
            {
                ExecutionStatus = "Errors Encountered";
                ExecutionStatusBrush = "#EF4444";
            }
            else if (ExecutionStatus == "Ready")
            {
                ExecutionStatus = "Executing...";
                ExecutionStatusBrush = "#38BDF8";
            }

            LogEntryAppended?.Invoke();
        }

        if (_uiContext != null && SynchronizationContext.Current != _uiContext)
        {
            _uiContext.Post(_ => Append(), null);
        }
        else
        {
            Append();
        }
    }

    /// <summary>
    /// Replaces the legacy TUI console pause: records completion status, updates the banner, and retains logs.
    /// </summary>
    public void NotifyOperationFinished(string operationName, bool success, int exitCode = 0)
    {
        ShowCompletionBanner = true;
        if (success)
        {
            ExecutionStatus = "Completed";
            ExecutionStatusBrush = "#22C55E";
            CompletionBannerBrush = "#166534";
            CompletionMessage = $"[OK] '{operationName}' finished successfully with exit code {exitCode}. Logs preserved.";
        }
        else
        {
            ExecutionStatus = ErrorCount > 0 ? "Errors Encountered" : "Failed";
            ExecutionStatusBrush = "#EF4444";
            CompletionBannerBrush = "#991B1B";
            CompletionMessage = $"[FAIL] '{operationName}' failed with exit code {exitCode}. Review error logs above.";
        }
    }

    public void ClearLog()
    {
        _allEntries.Clear();
        _filteredEntries.Clear();
        TotalCount = 0;
        ErrorCount = 0;
        WarningCount = 0;
        ExecutionStatus = "Ready";
        ExecutionStatusBrush = "#94A3B8";
        ShowCompletionBanner = false;
    }

    public void CopyLog()
    {
        var sb = new StringBuilder();
        foreach (var entry in _filteredEntries)
        {
            sb.AppendLine($"[{entry.Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{entry.Level,-7}] [{entry.Component}] {entry.Message}");
        }
        _clipboardService.SetText(sb.ToString());
    }

    private void OnOperationStarted(string opName)
    {
        if (_disposed)
        {
            return;
        }

        ExecutionStatus = "Executing...";
        ExecutionStatusBrush = "#38BDF8";
        ShowCompletionBanner = false;
        IsOpen = true;
        RequestOpen?.Invoke();
    }

    private void OnOperationFinished(string operationName, bool success, int exitCode)
    {
        if (_disposed)
        {
            return;
        }

        NotifyOperationFinished(operationName, success, exitCode);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _logger.EntryLogged -= OnEntryLogged;
        ViewModelBase.OperationStarted -= OnOperationStarted;
        ViewModelBase.OperationFinished -= OnOperationFinished;
        GC.SuppressFinalize(this);
    }

    private void ToggleExpanded()
    {
        IsExpanded = !IsExpanded;
        ConsoleHeight = IsExpanded ? double.NaN : 30;
    }

    private void ApplyFilter()
    {
        _filteredEntries.Clear();
        foreach (var entry in _allEntries)
        {
            if (MatchesFilter(entry))
            {
                _filteredEntries.Add(entry);
            }
        }
    }

    private bool MatchesFilter(ActivityLogEntry entry)
    {
        if (!string.Equals(_selectedLevelFilter, "All", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(entry.Level.ToString(), _selectedLevelFilter, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!string.IsNullOrWhiteSpace(_searchFilter))
        {
            bool matchMsg = entry.Message.Contains(_searchFilter, StringComparison.OrdinalIgnoreCase);
            bool matchComp = entry.Component.Contains(_searchFilter, StringComparison.OrdinalIgnoreCase);
            return matchMsg || matchComp;
        }

        return true;
    }
}
