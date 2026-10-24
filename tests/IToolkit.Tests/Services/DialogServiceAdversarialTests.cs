namespace IToolkit.Tests.Services;

using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using IToolkit.Core.Abstractions;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Adversarial stress tests for IDialogService, ISafetyConfirmationService, DI resolution, and ConfirmAsync.
/// </summary>
public class DialogServiceAdversarialTests
{
    [Fact]
    public void DI_Container_ResolvesDialogAndSafetyServicesAsSameSingleton()
    {
        // Arrange
        var services = new ServiceCollection();
        IToolkit.App.ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        // Act - Multiple resolutions
        var dialog1 = provider.GetRequiredService<IDialogService>();
        var dialog2 = provider.GetRequiredService<IDialogService>();
        var safety1 = provider.GetRequiredService<ISafetyConfirmationService>();
        var safety2 = provider.GetRequiredService<ISafetyConfirmationService>();

        // Assert - Singleton identity across calls and interface types
        Assert.NotNull(dialog1);
        Assert.NotNull(dialog2);
        Assert.NotNull(safety1);
        Assert.NotNull(safety2);
        Assert.Same(dialog1, dialog2);
        Assert.Same(safety1, safety2);
        Assert.Same(dialog1, safety1);
    }

    [Fact]
    public void DI_ScopedContainer_PreservesSingletonInstanceAcrossScopes()
    {
        // Arrange
        var services = new ServiceCollection();
        IToolkit.App.ServiceRegistration.ConfigureServices(services);
        using var rootProvider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        var rootDialog = rootProvider.GetRequiredService<IDialogService>();
        var rootSafety = rootProvider.GetRequiredService<ISafetyConfirmationService>();

        // Act - Resolve within a scoped container
        using (var scope = rootProvider.CreateScope())
        {
            var scopedDialog = scope.ServiceProvider.GetRequiredService<IDialogService>();
            var scopedSafety = scope.ServiceProvider.GetRequiredService<ISafetyConfirmationService>();

            // Assert
            Assert.Same(rootDialog, scopedDialog);
            Assert.Same(rootSafety, scopedSafety);
            Assert.Same(scopedDialog, scopedSafety);
        }
    }

    [Fact]
    public void DI_AllRegisteredServices_ResolveWithoutExceptions()
    {
        // Arrange
        var services = new ServiceCollection();
        IToolkit.App.ServiceRegistration.ConfigureServices(services);
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        // Act & Assert - Ensure all registered service types can be instantiated
        foreach (var descriptor in services)
        {
            var resolved = provider.GetService(descriptor.ServiceType);
            Assert.NotNull(resolved);
        }
    }

    [Fact]
    public async Task ConfirmAsync_CompletesSynchronouslyAsRanToCompletion()
    {
        // Arrange
        var mock = new MockDialogService { ConfirmationResult = true };

        // Act
        var task = mock.ConfirmAsync("Title", "Message", "Warning");

        // Assert - Task should be completed immediately without background worker delay
        Assert.True(task.IsCompleted);
        Assert.True(task.IsCompletedSuccessfully);
        Assert.Equal(TaskStatus.RanToCompletion, task.Status);
        bool result = await task;
        Assert.True(result);
    }

    [Fact]
    public async Task ConfirmAsync_PropagatesCustomExceptionsCorrectly()
    {
        // Arrange
        var mock = new MockDialogService
        {
            ConfirmationFunc = (_, _, _) => throw new InvalidOperationException("Adversarial confirmation error.")
        };

        // Act & Assert
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => mock.ConfirmAsync("Dangerous", "Execute?", "High risk"));

        Assert.Equal("Adversarial confirmation error.", ex.Message);
        Assert.Equal(1, mock.ConfirmAsyncCallCount);
        Assert.Equal(1, mock.ConfirmCallCount);
    }

    [Fact]
    public async Task ConfirmAsync_HandlesNullAndEmptyStringArguments()
    {
        // Arrange
        var mock = new MockDialogService { ConfirmationResult = false };

        // Act
        bool result = await mock.ConfirmAsync(null!, string.Empty, "   ");

        // Assert
        Assert.False(result);
        Assert.Equal(1, mock.ConfirmAsyncCallCount);
        Assert.Equal(1, mock.ConfirmCallCount);
        Assert.Single(mock.ConfirmationRequests);
        Assert.Null(mock.ConfirmationRequests[0].Title);
        Assert.Equal(string.Empty, mock.ConfirmationRequests[0].Message);
        Assert.Equal("   ", mock.ConfirmationRequests[0].WarningDetails);
    }


    [Fact]
    public void DialogService_PathsWithExtremeInputs_HandledCleanly()
    {
        // Arrange
        var mock = new MockDialogService
        {
            SelectedOpenFilePath = "C:\\very\\long\\path\\to\\custom.wim",
            SelectedSaveFilePath = "C:\\backups\\destination\\outlook.pst",
            SelectedFolderPath = "C:\\backups\\userprofiles\\target",
            OpenFolderInExplorerResult = false
        };

        // Act
        var openFile = mock.ShowOpenFileDialog("Select WIM", "*.wim", "C:\\some\\nonexistent\\dir");
        var saveFile = mock.ShowSaveFileDialog("Export PST", "*.pst", "Archive.pst", "D:\\temp");
        var folder = mock.ShowOpenFolderDialog("Select Target", "E:\\backup");
        bool explorerResult = mock.OpenFolderInExplorer("   ");

        // Assert
        Assert.Equal("C:\\very\\long\\path\\to\\custom.wim", openFile);
        Assert.Equal("C:\\backups\\destination\\outlook.pst", saveFile);
        Assert.Equal("C:\\backups\\userprofiles\\target", folder);
        Assert.False(explorerResult);
        Assert.Equal(1, mock.ShowOpenFileDialogCallCount);
        Assert.Equal(1, mock.ShowSaveFileDialogCallCount);
        Assert.Equal(1, mock.ShowOpenFolderDialogCallCount);
        Assert.Equal(1, mock.OpenFolderInExplorerCallCount);
        Assert.Single(mock.OpenedInExplorerPaths);
        Assert.Equal("   ", mock.OpenedInExplorerPaths[0]);
    }

    [Fact]
    public void MockDialogService_Reset_AllowsReusabilityAcrossSubsequentTests()
    {
        // Arrange
        var mock = new MockDialogService();
        mock.Confirm("Title1", "Msg1", "Warn1");
        mock.OpenFolderInExplorer("C:\\test");
        Assert.Equal(1, mock.ConfirmCallCount);
        Assert.Equal(1, mock.OpenFolderInExplorerCallCount);

        // Act
        mock.Reset();

        // Assert
        Assert.Equal(0, mock.ConfirmCallCount);
        Assert.Equal(0, mock.OpenFolderInExplorerCallCount);
        Assert.Empty(mock.ConfirmationRequests);
        Assert.Empty(mock.OpenedInExplorerPaths);

        // Subsequent use
        bool nextConfirm = mock.Confirm("Title2", "Msg2", "Warn2");
        Assert.True(nextConfirm);
        Assert.Equal(1, mock.ConfirmCallCount);
        Assert.Single(mock.ConfirmationRequests);
    }
}
