namespace IToolkit.App.Services;

using System.Diagnostics;
using System.IO;
using System.Windows;
using IToolkit.Core.Abstractions;
using Microsoft.Win32;

/// <summary>
/// Production WPF implementation of dialog and user safety confirmation services.
/// Uses native Windows OpenFolderDialog, OpenFileDialog, SaveFileDialog, MessageBox, and Windows Explorer.
/// </summary>
public class WpfDialogService : IDialogService, ISafetyConfirmationService
{
    private readonly IActivityLogger? _logger;

    /// <summary>
    /// Parameterless constructor preserved for reflection-based instantiation in tests.
    /// </summary>
    public WpfDialogService() : this(null)
    {
    }

    /// <summary>
    /// Primary constructor supporting optional dependency-injected activity logger.
    /// </summary>
    public WpfDialogService(IActivityLogger? logger = null)
    {
        _logger = logger;
    }

    /// <inheritdoc />
    public string? ShowOpenFileDialog(string title, string filter, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowOpenFileDialog(title, filter, defaultPath));
        }

        _logger?.LogInfo("DialogService", $"Showing OpenFileDialog: Title='{title}', Filter='{filter}', DefaultPath='{defaultPath}'.");

        var dialog = new OpenFileDialog
        {
            Title = title,
            Filter = filter
        };

        if (!string.IsNullOrWhiteSpace(defaultPath))
        {
            if (Directory.Exists(defaultPath))
            {
                dialog.InitialDirectory = defaultPath;
            }
            else if (File.Exists(defaultPath))
            {
                dialog.InitialDirectory = Path.GetDirectoryName(defaultPath);
                dialog.FileName = Path.GetFileName(defaultPath);
            }
            else
            {
                dialog.InitialDirectory = defaultPath;
            }
        }

        try
        {
            bool? result = dialog.ShowDialog();
            if (result == true)
            {
                _logger?.LogInfo("DialogService", $"OpenFileDialog selected: '{dialog.FileName}' (Title='{title}').");
                return dialog.FileName;
            }

            _logger?.LogInfo("DialogService", $"OpenFileDialog cancelled by user (Title='{title}').");
            return null;
        }
        catch (Exception ex)
        {
            _logger?.LogError("DialogService", $"OpenFileDialog failed (Title='{title}')", ex);
            throw;
        }
    }

    /// <inheritdoc />
    public string? ShowSaveFileDialog(string title, string filter, string? defaultFileName = null, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowSaveFileDialog(title, filter, defaultFileName, defaultPath));
        }

        _logger?.LogInfo("DialogService", $"Showing SaveFileDialog: Title='{title}', Filter='{filter}', DefaultFileName='{defaultFileName}', DefaultPath='{defaultPath}'.");

        var dialog = new SaveFileDialog
        {
            Title = title,
            Filter = filter
        };

        if (!string.IsNullOrWhiteSpace(defaultFileName))
        {
            dialog.FileName = defaultFileName;
        }

        if (!string.IsNullOrWhiteSpace(defaultPath))
        {
            if (Directory.Exists(defaultPath))
            {
                dialog.InitialDirectory = defaultPath;
            }
            else
            {
                dialog.InitialDirectory = defaultPath;
            }
        }

        try
        {
            bool? result = dialog.ShowDialog();
            if (result == true)
            {
                _logger?.LogInfo("DialogService", $"SaveFileDialog selected: '{dialog.FileName}' (Title='{title}').");
                return dialog.FileName;
            }

            _logger?.LogInfo("DialogService", $"SaveFileDialog cancelled by user (Title='{title}').");
            return null;
        }
        catch (Exception ex)
        {
            _logger?.LogError("DialogService", $"SaveFileDialog failed (Title='{title}')", ex);
            throw;
        }
    }

    /// <inheritdoc />
    public string? ShowOpenFolderDialog(string title, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowOpenFolderDialog(title, defaultPath));
        }

        _logger?.LogInfo("DialogService", $"Showing OpenFolderDialog: Title='{title}', DefaultPath='{defaultPath}'.");

        var dialog = new OpenFolderDialog
        {
            Title = title
        };

        if (!string.IsNullOrWhiteSpace(defaultPath) && Directory.Exists(defaultPath))
        {
            dialog.InitialDirectory = defaultPath;
        }

        try
        {
            bool? result = dialog.ShowDialog();
            if (result == true)
            {
                _logger?.LogInfo("DialogService", $"OpenFolderDialog selected: '{dialog.FolderName}' (Title='{title}').");
                return dialog.FolderName;
            }

            _logger?.LogInfo("DialogService", $"OpenFolderDialog cancelled by user (Title='{title}').");
            return null;
        }
        catch (Exception ex)
        {
            _logger?.LogError("DialogService", $"OpenFolderDialog failed (Title='{title}')", ex);
            throw;
        }
    }

    /// <inheritdoc />
    public bool OpenFolderInExplorer(string folderPath)
    {
        if (string.IsNullOrWhiteSpace(folderPath))
        {
            _logger?.LogWarning("DialogService", "OpenFolderInExplorer called with null or empty path.");
            return false;
        }

        try
        {
            string arguments;
            if (Directory.Exists(folderPath))
            {
                arguments = $"\"{folderPath}\"";
            }
            else if (File.Exists(folderPath))
            {
                arguments = $"/select,\"{folderPath}\"";
            }
            else
            {
                _logger?.LogWarning("DialogService", $"Directory does not exist for Explorer launch: '{folderPath}'.");
                return false;
            }

            _logger?.LogInfo("DialogService", $"Launching Windows Explorer for folder: '{folderPath}'.");

            var startInfo = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = arguments,
                UseShellExecute = true
            };

            using var process = Process.Start(startInfo);
            return true;
        }
        catch (Exception ex)
        {
            _logger?.LogError("DialogService", $"Failed to launch Windows Explorer for folder '{folderPath}'", ex);
            return false;
        }
    }

    /// <inheritdoc />
    public bool Confirm(string title, string message, string warningDetails)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => Confirm(title, message, warningDetails));
        }

        string fullMessage = string.IsNullOrWhiteSpace(warningDetails)
            ? message
            : $"{message}\n\nWARNING:\n{warningDetails}";

        _logger?.LogWarning("SafetyConfirmation", $"Safety confirmation prompt displayed: '{title}' - '{fullMessage}'.");

        try
        {
            MessageBoxResult result = MessageBox.Show(fullMessage, title, MessageBoxButton.YesNo, MessageBoxImage.Warning);
            bool confirmed = result == MessageBoxResult.Yes;
            if (confirmed)
            {
                _logger?.LogInfo("SafetyConfirmation", $"Safety confirmation '{title}' result: Confirmed (Yes).");
            }
            else
            {
                _logger?.LogWarning("SafetyConfirmation", $"Safety confirmation '{title}' result: Dismissed (No).");
            }

            return confirmed;
        }
        catch (Exception ex)
        {
            _logger?.LogError("SafetyConfirmation", $"Safety confirmation dialog '{title}' failed", ex);
            throw;
        }
    }

    /// <inheritdoc />
    public Task<bool> ConfirmAsync(string title, string message, string warningDetails)
    {
        return Task.FromResult(Confirm(title, message, warningDetails));
    }
}
