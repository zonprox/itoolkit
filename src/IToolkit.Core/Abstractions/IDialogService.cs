namespace IToolkit.Core.Abstractions;

/// <summary>
/// Abstraction for platform-specific file picker, folder picker, and Windows Explorer dialogs.
/// </summary>
public interface IDialogService
{
    /// <summary>
    /// Displays a file picker dialog to open an existing file.
    /// </summary>
    string? ShowOpenFileDialog(string title, string filter, string? defaultPath = null);

    /// <summary>
    /// Displays a save file dialog to select or specify a file destination.
    /// </summary>
    string? ShowSaveFileDialog(string title, string filter, string? defaultFileName = null, string? defaultPath = null);

    /// <summary>
    /// Displays a directory picker dialog to select an existing folder.
    /// </summary>
    string? ShowOpenFolderDialog(string title, string? defaultPath = null);

    /// <summary>
    /// Launches Windows Explorer navigating to or highlighting the specified folder path.
    /// Returns true if Explorer was successfully launched, false otherwise.
    /// </summary>
    bool OpenFolderInExplorer(string folderPath);
}
