namespace IToolkit.Tests.Services;

using System;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge tests verifying edge cases for MockDialogService and WpfDialogService.
/// Tests null paths, empty filters, cancellation/rejection, resetting state, call tracking,
/// and safe explorer opening with non-existent or invalid paths.
/// </summary>
public class MockDialogServiceEmpiricalChallengeTests
{
    [Fact]
    public void MockDialogService_NullPaths_ReturnsNullAndIncrementsCounters()
    {
        // Arrange
        var mock = new MockDialogService
        {
            SelectedOpenFilePath = null,
            SelectedSaveFilePath = null,
            SelectedFolderPath = null
        };

        // Act
        string? openResult = mock.ShowOpenFileDialog(null!, null!, null);
        string? saveResult = mock.ShowSaveFileDialog(null!, null!, null, null);
        string? folderResult = mock.ShowOpenFolderDialog(null!, null);

        // Assert
        Assert.Null(openResult);
        Assert.Null(saveResult);
        Assert.Null(folderResult);
        Assert.Equal(1, mock.ShowOpenFileDialogCallCount);
        Assert.Equal(1, mock.ShowSaveFileDialogCallCount);
        Assert.Equal(1, mock.ShowOpenFolderDialogCallCount);
    }

    [Fact]
    public void MockDialogService_EmptyFiltersAndTitles_ExecutesWithoutExceptions()
    {
        // Arrange
        var mock = new MockDialogService
        {
            SelectedOpenFilePath = "C:\\test\\file.wim",
            SelectedSaveFilePath = "C:\\test\\out.pst",
            SelectedFolderPath = "C:\\test\\dir"
        };

        // Act
        string? openResult = mock.ShowOpenFileDialog(string.Empty, string.Empty);
        string? saveResult = mock.ShowSaveFileDialog(string.Empty, string.Empty, string.Empty, string.Empty);
        string? folderResult = mock.ShowOpenFolderDialog(string.Empty);
        bool explorerResult = mock.OpenFolderInExplorer(string.Empty);

        // Assert
        Assert.Equal("C:\\test\\file.wim", openResult);
        Assert.Equal("C:\\test\\out.pst", saveResult);
        Assert.Equal("C:\\test\\dir", folderResult);
        Assert.True(explorerResult);
        Assert.Equal(1, mock.ShowOpenFileDialogCallCount);
        Assert.Equal(1, mock.ShowSaveFileDialogCallCount);
        Assert.Equal(1, mock.ShowOpenFolderDialogCallCount);
        Assert.Equal(1, mock.OpenFolderInExplorerCallCount);
        Assert.Single(mock.OpenedInExplorerPaths);
        Assert.Equal(string.Empty, mock.OpenedInExplorerPaths[0]);
    }

    [Fact]
    public async Task MockDialogService_CancellationAndRejection_ReturnsFalseAcrossSyncAndAsync()
    {
        // Arrange
        var mock = new MockDialogService
        {
            ConfirmationResult = false
        };

        // Act
        bool syncResult = mock.Confirm("Destructive Action", "Format drive?", "Data will be lost.");
        bool asyncResult = await mock.ConfirmAsync("Destructive Action", "Format drive?", "Data will be lost.");

        // Assert
        Assert.False(syncResult);
        Assert.False(asyncResult);
        Assert.Equal(2, mock.ConfirmCallCount);
        Assert.Equal(1, mock.ConfirmAsyncCallCount);
        Assert.Equal(2, mock.ConfirmationRequests.Count);
    }

    [Fact]
    public async Task MockDialogService_ConfirmationFunc_RejectionTakesPrecedenceOverDefaultResult()
    {
        // Arrange
        var mock = new MockDialogService
        {
            ConfirmationResult = true, // Default true, but func will reject
            ConfirmationFunc = (title, message, warning) => false
        };

        // Act
        bool syncResult = mock.Confirm("Scrub Office", "Remove all Office installations?", "High impact.");
        bool asyncResult = await mock.ConfirmAsync("Scrub Office", "Remove all Office installations?", "High impact.");

        // Assert
        Assert.False(syncResult);
        Assert.False(asyncResult);
        Assert.Equal(2, mock.ConfirmCallCount);
        Assert.Equal(1, mock.ConfirmAsyncCallCount);
    }

    [Fact]
    public void MockDialogService_Reset_ComprehensivelyClearsCountersAndRecordedCollections()
    {
        // Arrange
        var mock = new MockDialogService();
        mock.ShowOpenFileDialog("Title1", "Filter1");
        mock.ShowSaveFileDialog("Title2", "Filter2");
        mock.ShowOpenFolderDialog("Title3");
        mock.OpenFolderInExplorer("C:\\Logs");
        mock.Confirm("Confirm1", "Msg1", "Warn1");

        Assert.Equal(1, mock.ShowOpenFileDialogCallCount);
        Assert.Equal(1, mock.ShowSaveFileDialogCallCount);
        Assert.Equal(1, mock.ShowOpenFolderDialogCallCount);
        Assert.Equal(1, mock.OpenFolderInExplorerCallCount);
        Assert.Equal(1, mock.ConfirmCallCount);
        Assert.Single(mock.OpenedInExplorerPaths);
        Assert.Single(mock.ConfirmationRequests);

        // Act
        mock.Reset();

        // Assert
        Assert.Equal(0, mock.ShowOpenFileDialogCallCount);
        Assert.Equal(0, mock.ShowSaveFileDialogCallCount);
        Assert.Equal(0, mock.ShowOpenFolderDialogCallCount);
        Assert.Equal(0, mock.OpenFolderInExplorerCallCount);
        Assert.Equal(0, mock.ConfirmCallCount);
        Assert.Equal(0, mock.ConfirmAsyncCallCount);
        Assert.Empty(mock.OpenedInExplorerPaths);
        Assert.Empty(mock.ConfirmationRequests);

        // Verify subsequent calls re-record accurately from clean state
        mock.OpenFolderInExplorer("C:\\NewLogs");
        Assert.Equal(1, mock.OpenFolderInExplorerCallCount);
        Assert.Single(mock.OpenedInExplorerPaths);
        Assert.Equal("C:\\NewLogs", mock.OpenedInExplorerPaths[0]);
    }

    [Fact]
    public void MockDialogService_CallTracking_PreservesInvocationOrderAndExactArguments()
    {
        // Arrange
        var mock = new MockDialogService();

        // Act
        mock.OpenFolderInExplorer("C:\\First");
        mock.OpenFolderInExplorer("C:\\Second");
        mock.OpenFolderInExplorer("C:\\Third");
        mock.Confirm("TitleA", "MsgA", "WarnA");
        mock.Confirm("TitleB", "MsgB", "WarnB");

        // Assert
        Assert.Equal(3, mock.OpenFolderInExplorerCallCount);
        Assert.Equal(3, mock.OpenedInExplorerPaths.Count);
        Assert.Equal("C:\\First", mock.OpenedInExplorerPaths[0]);
        Assert.Equal("C:\\Second", mock.OpenedInExplorerPaths[1]);
        Assert.Equal("C:\\Third", mock.OpenedInExplorerPaths[2]);

        Assert.Equal(2, mock.ConfirmCallCount);
        Assert.Equal(2, mock.ConfirmationRequests.Count);
        Assert.Equal(("TitleA", "MsgA", "WarnA"), mock.ConfirmationRequests[0]);
        Assert.Equal(("TitleB", "MsgB", "WarnB"), mock.ConfirmationRequests[1]);
    }

    [Fact]
    public void WpfDialogService_OpenFolderInExplorer_HandlesEdgeCasesWithoutThrowingExceptions()
    {
        // Locate iToolKit.dll which contains WpfDialogService
        string appAssemblyPath = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "IToolkit.App", "bin", "Release", "net8.0-windows", "win-x64", "iToolKit.dll"));

        if (!File.Exists(appAssemblyPath))
        {
            // If the Release binary is not at the expected path, attempt debug or current configuration
            appAssemblyPath = Path.GetFullPath(
                Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "IToolkit.App", "bin", "Debug", "net8.0-windows", "win-x64", "iToolKit.dll"));
        }

        // Only run if the WPF assembly has been compiled on this system
        if (!File.Exists(appAssemblyPath))
        {
            return;
        }

        var appAssembly = Assembly.LoadFrom(appAssemblyPath);
        var wpfDialogServiceType = appAssembly.GetType("IToolkit.App.Services.WpfDialogService");
        Assert.NotNull(wpfDialogServiceType);

        var instance = Activator.CreateInstance(wpfDialogServiceType);
        Assert.NotNull(instance);

        var openFolderMethod = wpfDialogServiceType.GetMethod("OpenFolderInExplorer", new[] { typeof(string) });
        Assert.NotNull(openFolderMethod);

        // Edge case 1: Null string
        object? nullResult = openFolderMethod.Invoke(instance, new object?[] { null });
        Assert.Equal(false, nullResult);

        // Edge case 2: Empty string
        object? emptyResult = openFolderMethod.Invoke(instance, new object?[] { string.Empty });
        Assert.Equal(false, emptyResult);

        // Edge case 3: Whitespace string
        object? whitespaceResult = openFolderMethod.Invoke(instance, new object?[] { "     " });
        Assert.Equal(false, whitespaceResult);

        // Edge case 4: Non-existent directory path
        object? nonExistentResult = openFolderMethod.Invoke(instance, new object?[] { @"C:\IToolkit_NonExistent_Directory_12345" });
        Assert.Equal(false, nonExistentResult);

        // Edge case 5: Non-existent file path
        object? nonExistentFileResult = openFolderMethod.Invoke(instance, new object?[] { @"C:\IToolkit_NonExistent_Directory_12345\file.txt" });
        Assert.Equal(false, nonExistentFileResult);

        // Edge case 6: Invalid path characters (e.g. wildcards, pipes)
        object? invalidCharsResult = openFolderMethod.Invoke(instance, new object?[] { @"C:\Invalid|Path*?<>Chars" });
        Assert.Equal(false, invalidCharsResult);

        // Edge case 7: Embedded null byte
        object? nullByteResult = openFolderMethod.Invoke(instance, new object?[] { "C:\\Invalid\0Path" });
        Assert.Equal(false, nullByteResult);

        // Edge case 8: Extremely long path (> 350 chars)
        string longPath = @"C:\" + new string('a', 350);
        object? longPathResult = openFolderMethod.Invoke(instance, new object?[] { longPath });
        Assert.Equal(false, longPathResult);
    }
}
