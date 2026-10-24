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
    /// <inheritdoc />
    public string? ShowOpenFileDialog(string title, string filter, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowOpenFileDialog(title, filter, defaultPath));
        }

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

        bool? result = dialog.ShowDialog();
        return result == true ? dialog.FileName : null;
    }

    /// <inheritdoc />
    public string? ShowSaveFileDialog(string title, string filter, string? defaultFileName = null, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowSaveFileDialog(title, filter, defaultFileName, defaultPath));
        }

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

        bool? result = dialog.ShowDialog();
        return result == true ? dialog.FileName : null;
    }

    /// <inheritdoc />
    public string? ShowOpenFolderDialog(string title, string? defaultPath = null)
    {
        if (Application.Current?.Dispatcher != null && !Application.Current.Dispatcher.CheckAccess())
        {
            return Application.Current.Dispatcher.Invoke(() => ShowOpenFolderDialog(title, defaultPath));
        }

        var dialog = new OpenFolderDialog
        {
            Title = title
        };

        if (!string.IsNullOrWhiteSpace(defaultPath) && Directory.Exists(defaultPath))
        {
            dialog.InitialDirectory = defaultPath;
        }

        bool? result = dialog.ShowDialog();
        return result == true ? dialog.FolderName : null;
    }

    /// <inheritdoc />
    public bool OpenFolderInExplorer(string folderPath)
    {
        if (string.IsNullOrWhiteSpace(folderPath))
        {
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
                return false;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = arguments,
                UseShellExecute = true
            };

            using var process = Process.Start(startInfo);
            return true;
        }
        catch
        {
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

        MessageBoxResult result = MessageBox.Show(fullMessage, title, MessageBoxButton.YesNo, MessageBoxImage.Warning);
        return result == MessageBoxResult.Yes;
    }

    /// <inheritdoc />
    public Task<bool> ConfirmAsync(string title, string message, string warningDetails)
    {
        return Task.FromResult(Confirm(title, message, warningDetails));
    }
}
