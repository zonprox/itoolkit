namespace IToolkit.Tests.TestDoubles;

using IToolkit.Core.Abstractions;

/// <summary>
/// In-memory test double for IDialogService and ISafetyConfirmationService.
/// Provides non-blocking execution, configurable return values, and call tracking for unit tests.
/// </summary>
public class MockDialogService : IDialogService, ISafetyConfirmationService
{
    /// <summary>
    /// Default boolean result returned by Confirm and ConfirmAsync. Defaults to true.
    /// </summary>
    public bool ConfirmationResult { get; set; } = true;

    /// <summary>
    /// Optional custom handler for confirmation logic.
    /// </summary>
    public Func<string, string, string, bool>? ConfirmationFunc { get; set; }

    /// <summary>
    /// Path returned by ShowOpenFileDialog.
    /// </summary>
    public string? SelectedOpenFilePath { get; set; }

    /// <summary>
    /// Path returned by ShowSaveFileDialog.
    /// </summary>
    public string? SelectedSaveFilePath { get; set; }

    /// <summary>
    /// Path returned by ShowOpenFolderDialog.
    /// </summary>
    public string? SelectedFolderPath { get; set; }

    /// <summary>
    /// Boolean result returned by OpenFolderInExplorer. Defaults to true.
    /// </summary>
    public bool OpenFolderInExplorerResult { get; set; } = true;

    // Call Counters
    public int ShowOpenFileDialogCallCount { get; private set; }
    public int ShowSaveFileDialogCallCount { get; private set; }
    public int ShowOpenFolderDialogCallCount { get; private set; }
    public int OpenFolderInExplorerCallCount { get; private set; }
    public int ConfirmCallCount { get; private set; }
    public int ConfirmAsyncCallCount { get; private set; }

    // Call Records
    public List<string> OpenedInExplorerPaths { get; } = new();
    public List<(string Title, string Message, string WarningDetails)> ConfirmationRequests { get; } = new();

    /// <inheritdoc />
    public string? ShowOpenFileDialog(string title, string filter, string? defaultPath = null)
    {
        ShowOpenFileDialogCallCount++;
        return SelectedOpenFilePath;
    }

    /// <inheritdoc />
    public string? ShowSaveFileDialog(string title, string filter, string? defaultFileName = null, string? defaultPath = null)
    {
        ShowSaveFileDialogCallCount++;
        return SelectedSaveFilePath;
    }

    /// <inheritdoc />
    public string? ShowOpenFolderDialog(string title, string? defaultPath = null)
    {
        ShowOpenFolderDialogCallCount++;
        return SelectedFolderPath;
    }

    /// <inheritdoc />
    public bool OpenFolderInExplorer(string folderPath)
    {
        OpenFolderInExplorerCallCount++;
        OpenedInExplorerPaths.Add(folderPath);
        return OpenFolderInExplorerResult;
    }

    /// <inheritdoc />
    public bool Confirm(string title, string message, string warningDetails)
    {
        ConfirmCallCount++;
        ConfirmationRequests.Add((title, message, warningDetails));

        if (ConfirmationFunc != null)
        {
            return ConfirmationFunc(title, message, warningDetails);
        }

        return ConfirmationResult;
    }

    /// <inheritdoc />
    public Task<bool> ConfirmAsync(string title, string message, string warningDetails)
    {
        ConfirmAsyncCallCount++;
        return Task.FromResult(Confirm(title, message, warningDetails));
    }

    /// <summary>
    /// Resets all counters and recorded call lists.
    /// </summary>
    public void Reset()
    {
        ShowOpenFileDialogCallCount = 0;
        ShowSaveFileDialogCallCount = 0;
        ShowOpenFolderDialogCallCount = 0;
        OpenFolderInExplorerCallCount = 0;
        ConfirmCallCount = 0;
        ConfirmAsyncCallCount = 0;
        OpenedInExplorerPaths.Clear();
        ConfirmationRequests.Clear();
    }
}
