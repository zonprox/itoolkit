namespace IToolkit.Tests.Services;

using Microsoft.Extensions.DependencyInjection;
using IToolkit.Core.Abstractions;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Unit tests for IDialogService and ISafetyConfirmationService test double abstractions and DI resolution.
/// </summary>
public class DialogServiceTests
{
    [Fact]
    public void MockDialogService_DefaultConfirmationResult_ReturnsTrueAndRecordsCall()
    {
        // Arrange
        var dialog = new MockDialogService();

        // Act
        bool result = dialog.Confirm("Confirm Action", "Proceed with disk cleanup?", "Free space will be reclaimed.");

        // Assert
        Assert.True(result);
        Assert.Equal(1, dialog.ConfirmCallCount);
        Assert.Single(dialog.ConfirmationRequests);
        Assert.Equal("Confirm Action", dialog.ConfirmationRequests[0].Title);
        Assert.Equal("Proceed with disk cleanup?", dialog.ConfirmationRequests[0].Message);
        Assert.Equal("Free space will be reclaimed.", dialog.ConfirmationRequests[0].WarningDetails);
    }

    [Fact]
    public async Task MockDialogService_DefaultConfirmationAsync_ReturnsTrueAndRecordsCall()
    {
        // Arrange
        var dialog = new MockDialogService();

        // Act
        bool result = await dialog.ConfirmAsync("Reset Winsock", "Reset network catalog?", "Active connections will drop.");

        // Assert
        Assert.True(result);
        Assert.Equal(1, dialog.ConfirmAsyncCallCount);
        Assert.Equal(1, dialog.ConfirmCallCount);
        Assert.Single(dialog.ConfirmationRequests);
        Assert.Equal("Reset Winsock", dialog.ConfirmationRequests[0].Title);
        Assert.Equal("Reset network catalog?", dialog.ConfirmationRequests[0].Message);
        Assert.Equal("Active connections will drop.", dialog.ConfirmationRequests[0].WarningDetails);
    }

    [Fact]
    public async Task MockDialogService_ConfiguredConfirmationResult_ReturnsFalseWhenConfigured()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            ConfirmationResult = false
        };

        // Act
        bool syncResult = dialog.Confirm("Title", "Message", "Details");
        bool asyncResult = await dialog.ConfirmAsync("TitleAsync", "MessageAsync", "DetailsAsync");

        // Assert
        Assert.False(syncResult);
        Assert.False(asyncResult);
        Assert.Equal(2, dialog.ConfirmCallCount);
        Assert.Equal(1, dialog.ConfirmAsyncCallCount);
        Assert.Equal(2, dialog.ConfirmationRequests.Count);
    }

    [Fact]
    public void MockDialogService_ConfirmationFunc_EvaluatesCustomRule()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            ConfirmationFunc = (title, _, _) => title.StartsWith("Safe", StringComparison.OrdinalIgnoreCase)
        };

        // Act
        bool safeResult = dialog.Confirm("SafeOperation", "Can run?", "No danger.");
        bool unsafeResult = dialog.Confirm("DangerousOperation", "Can run?", "Severe risk.");

        // Assert
        Assert.True(safeResult);
        Assert.False(unsafeResult);
        Assert.Equal(2, dialog.ConfirmCallCount);
    }

    [Fact]
    public void MockDialogService_ShowOpenFileDialog_ReturnsConfiguredPathAndIncrementsCounter()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            SelectedOpenFilePath = @"C:\Images\custom.wim"
        };

        // Act
        string? result = dialog.ShowOpenFileDialog("Select WIM Image", "WIM files (*.wim)|*.wim");

        // Assert
        Assert.Equal(@"C:\Images\custom.wim", result);
        Assert.Equal(1, dialog.ShowOpenFileDialogCallCount);
    }

    [Fact]
    public void MockDialogService_ShowSaveFileDialog_ReturnsConfiguredPathAndIncrementsCounter()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            SelectedSaveFilePath = @"C:\Mail\Outlook.pst"
        };

        // Act
        string? result = dialog.ShowSaveFileDialog("Export PST", "PST files (*.pst)|*.pst", "Archive.pst");

        // Assert
        Assert.Equal(@"C:\Mail\Outlook.pst", result);
        Assert.Equal(1, dialog.ShowSaveFileDialogCallCount);
    }

    [Fact]
    public void MockDialogService_ShowOpenFolderDialog_ReturnsConfiguredFolderAndIncrementsCounter()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            SelectedFolderPath = @"C:\Backups\UserProfiles"
        };

        // Act
        string? result = dialog.ShowOpenFolderDialog("Select Destination Folder");

        // Assert
        Assert.Equal(@"C:\Backups\UserProfiles", result);
        Assert.Equal(1, dialog.ShowOpenFolderDialogCallCount);
    }

    [Fact]
    public void MockDialogService_OpenFolderInExplorer_TracksPathsAndReturnsConfiguredResult()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            OpenFolderInExplorerResult = true
        };

        // Act
        bool firstCall = dialog.OpenFolderInExplorer(@"C:\Logs\iToolKit");
        dialog.OpenFolderInExplorerResult = false;
        bool secondCall = dialog.OpenFolderInExplorer(@"C:\Windows\System32");

        // Assert
        Assert.True(firstCall);
        Assert.False(secondCall);
        Assert.Equal(2, dialog.OpenFolderInExplorerCallCount);
        Assert.Equal(2, dialog.OpenedInExplorerPaths.Count);
        Assert.Equal(@"C:\Logs\iToolKit", dialog.OpenedInExplorerPaths[0]);
        Assert.Equal(@"C:\Windows\System32", dialog.OpenedInExplorerPaths[1]);
    }

    [Fact]
    public void MockDialogService_Reset_ClearsAllCountersAndCollections()
    {
        // Arrange
        var dialog = new MockDialogService
        {
            SelectedOpenFilePath = @"C:\file.txt",
            SelectedSaveFilePath = @"C:\save.txt",
            SelectedFolderPath = @"C:\folder"
        };
        dialog.ShowOpenFileDialog("Title", "Filter");
        dialog.ShowSaveFileDialog("Title", "Filter");
        dialog.ShowOpenFolderDialog("Title");
        dialog.OpenFolderInExplorer(@"C:\folder");
        dialog.Confirm("Title", "Message", "Details");

        // Act
        dialog.Reset();

        // Assert
        Assert.Equal(0, dialog.ShowOpenFileDialogCallCount);
        Assert.Equal(0, dialog.ShowSaveFileDialogCallCount);
        Assert.Equal(0, dialog.ShowOpenFolderDialogCallCount);
        Assert.Equal(0, dialog.OpenFolderInExplorerCallCount);
        Assert.Equal(0, dialog.ConfirmCallCount);
        Assert.Equal(0, dialog.ConfirmAsyncCallCount);
        Assert.Empty(dialog.OpenedInExplorerPaths);
        Assert.Empty(dialog.ConfirmationRequests);
    }

    [Fact]
    public void MockDialogService_ImplementsBothIDialogServiceAndISafetyConfirmationService()
    {
        // Arrange
        var mock = new MockDialogService();

        // Act & Assert
        Assert.IsAssignableFrom<IDialogService>(mock);
        Assert.IsAssignableFrom<ISafetyConfirmationService>(mock);
    }

    [Fact]
    public void ServiceRegistration_ConfiguresDialogAndSafetyConfirmationServices()
    {
        // Arrange
        var services = new ServiceCollection();
        IToolkit.App.ServiceRegistration.ConfigureServices(services);

        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        // Act
        var dialogService = provider.GetRequiredService<IDialogService>();
        var safetyService = provider.GetRequiredService<ISafetyConfirmationService>();

        // Assert
        Assert.NotNull(dialogService);
        Assert.NotNull(safetyService);
        Assert.Same(dialogService, safetyService);
    }
}
