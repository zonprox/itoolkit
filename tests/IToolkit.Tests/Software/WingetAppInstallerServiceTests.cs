namespace IToolkit.Tests.Software;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Software;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class WingetAppInstallerServiceTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly ProcessLockGuard _lockGuard;
    private readonly AppInstallerService _service;

    public WingetAppInstallerServiceTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _service = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, _network);
    }

    [Fact]
    public async Task SearchPackagesAsync_ValidQuery_ExecutesWingetWithStandardFlags_AndReturnsParsedPackages()
    {
        string expectedArgs = "search \"7zip\" --source winget --accept-source-agreements --disable-interactivity";
        string fullCmd = $"winget.exe {expectedArgs}";

        string mockOutput =
            "Name   Id        Version Match Source\r\n" +
            "-------------------------------------\r\n" +
            "7-Zip  7zip.7zip 24.09         winget\r\n";

        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(0, mockOutput, string.Empty, false));

        var results = await _service.SearchPackagesAsync("7zip");

        Assert.Single(results);
        Assert.Equal("7-Zip", results[0].Name);
        Assert.Equal("7zip.7zip", results[0].Id);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(fullCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task SearchPackagesAsync_EmptyOrWhitespaceQuery_ReturnsEmptyListWithoutExecutingWinget(string? query)
    {
        var results = await _service.SearchPackagesAsync(query!);

        Assert.NotNull(results);
        Assert.Empty(results);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.StartsWith("winget.exe search", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task SearchPackagesAsync_NoPackagesFoundExitCode_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe search \"NonExistentApp12345\" --source winget --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(-1978335212, "No package found matching input criteria.", string.Empty, false));

        var results = await _service.SearchPackagesAsync("NonExistentApp12345");

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task SearchPackagesAsync_ProcessTimesOut_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe search \"HangingQuery\" --source winget --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(1, string.Empty, "Timed out", true));

        var results = await _service.SearchPackagesAsync("HangingQuery");

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task SearchPackagesAsync_ProcessError_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe search \"ErrorApp\" --source winget --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(1, string.Empty, "Fatal error", false));

        var results = await _service.SearchPackagesAsync("ErrorApp");

        Assert.NotNull(results);
        Assert.Empty(results);
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_ExecutesWingetList_ReturnsInventory()
    {
        string fullCmd = "winget.exe list --disable-interactivity --nowarn";

        string mockOutput =
            "Name     Id                Version Source\r\n" +
            "------------------------------------------\r\n" +
            "Git      Git.Git           2.55.0  winget\r\n" +
            "UltraVNC uvncbvba.UltraVNC 1.8.3.2 winget\r\n";

        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(0, mockOutput, string.Empty, false));

        var apps = await _service.GetInstalledApplicationsAsync();

        Assert.Equal(2, apps.Count);
        Assert.Equal("Git", apps[0].Name);
        Assert.Equal("UltraVNC", apps[1].Name);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(fullCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_ProcessFails_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe list --disable-interactivity --nowarn";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(1, string.Empty, "Error accessing winget database", false));

        var apps = await _service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    [Fact]
    public async Task GetInstalledApplicationsAsync_NoAppsExitCode_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe list --disable-interactivity --nowarn";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(-1978335212, string.Empty, "No packages found", false));

        var apps = await _service.GetInstalledApplicationsAsync();

        Assert.NotNull(apps);
        Assert.Empty(apps);
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_ExecutesWingetListUpgradeAvailable_ReturnsUpdates()
    {
        string fullCmd = "winget.exe list --upgrade-available --disable-interactivity --nowarn";

        string mockOutput =
            "Name Id      Version  Available Source\r\n" +
            "--------------------------------------\r\n" +
            "Git  Git.Git 2.55.0.5 2.56.0.4  winget\r\n" +
            "1 upgrade available.\r\n";

        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(0, mockOutput, string.Empty, false));

        var updates = await _service.GetAvailableUpdatesAsync();

        Assert.Single(updates);
        Assert.Equal("Git", updates[0].Name);
        Assert.Equal("Git.Git", updates[0].Id);
        Assert.Equal("2.55.0.5", updates[0].InstalledVersion);
        Assert.Equal("2.56.0.4", updates[0].AvailableVersion);
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_NoUpdatesExitCode0x8A150014_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe list --upgrade-available --disable-interactivity --nowarn";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(-1978335212, "No available upgrade found.", string.Empty, false));

        var updates = await _service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task GetAvailableUpdatesAsync_ProcessFails_ReturnsEmptyList()
    {
        string fullCmd = "winget.exe list --upgrade-available --disable-interactivity --nowarn";
        _processRunner.SetCommandResult(fullCmd, new ProcessExecutionResult(1, string.Empty, "Update service unavailable", false));

        var updates = await _service.GetAvailableUpdatesAsync();

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_SuccessExitCode0_ReturnsSuccessResult()
    {
        string expectedCmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(expectedCmd, new ProcessExecutionResult(0, "Successfully installed", string.Empty, false));

        var result = await _service.InstallWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Equal("7zip.7zip", result.AppId);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(expectedCmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_RebootRequiredExitCode3010_ReturnsSuccessWithRebootNotice()
    {
        string cmd = "winget.exe install --id Some.Driver --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(3010, "Reboot required", string.Empty, false));

        var result = await _service.InstallWingetPackageAsync("Some.Driver");

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_UserCancelledElevationExitCode1223_ReturnsFailureWithCancelledMessage()
    {
        string cmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(1223, string.Empty, "Operation cancelled by user.", false));

        var result = await _service.InstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("cancelled", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_AdminRequiredExitCode0x8A150019_ReturnsFailureWithAdminMessage()
    {
        string cmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(-1978335068, string.Empty, "Administrator privileges required.", false));

        var result = await _service.InstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("Administrator", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InstallWingetPackageAsync_GeneralFailure_ReturnsFailureResult()
    {
        string cmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(1, string.Empty, "Download hash mismatch", false));

        var result = await _service.InstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("Download hash mismatch", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null!)]
    public async Task InstallWingetPackageAsync_EmptyPackageId_ReturnsFailureWithoutCallingWinget(string? packageId)
    {
        var result = await _service.InstallWingetPackageAsync(packageId!);

        Assert.False(result.Success);
        Assert.Contains("empty", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.StartsWith("winget.exe install", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallWingetPackageAsync_Timeout_ReturnsFailureResult()
    {
        string cmd = "winget.exe install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(1, string.Empty, "Timed out", true));

        var result = await _service.InstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("timed out", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UpgradeWingetPackageAsync_SuccessExitCode0_ReturnsSuccessResult()
    {
        string cmd = "winget.exe upgrade --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(0, "Successfully upgraded", string.Empty, false));

        var result = await _service.UpgradeWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(cmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task UpgradeWingetPackageAsync_AlreadyUpToDateExitCode0x8A15002B_ReturnsSuccessWithAlreadyUpdatedMessage()
    {
        string cmd = "winget.exe upgrade --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(-1978335189, "No available upgrade found.", string.Empty, false));

        var result = await _service.UpgradeWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success, "Already up-to-date should be treated as successful completion");
        Assert.Contains("Already up-to-date", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UpgradeWingetPackageAsync_RebootRequiredExitCode3010_ReturnsSuccessWithRebootNotice()
    {
        string cmd = "winget.exe upgrade --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(3010, "Reboot pending", string.Empty, false));

        var result = await _service.UpgradeWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Contains("Reboot required", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_SuccessExitCode0_ReturnsSuccessResult()
    {
        string cmd = "winget.exe uninstall --id 7zip.7zip --exact --silent --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(0, "Successfully uninstalled", string.Empty, false));

        var result = await _service.UninstallWingetPackageAsync("7zip.7zip");

        Assert.True(result.Success);
        Assert.Equal("7zip.7zip", result.AppId);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(cmd, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_PackageNotFoundExitCode0x8A150014_ReturnsFailureResult()
    {
        string cmd = "winget.exe uninstall --id 7zip.7zip --exact --silent --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(-1978335212, "No installed package found matching input criteria.", string.Empty, false));

        var result = await _service.UninstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("No package found", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UninstallWingetPackageAsync_AdminRequiredExitCode0x8A150019_ReturnsFailureResult()
    {
        string cmd = "winget.exe uninstall --id 7zip.7zip --exact --silent --disable-interactivity";
        _processRunner.SetCommandResult(cmd, new ProcessExecutionResult(-1978335068, string.Empty, "Administrator elevation required.", false));

        var result = await _service.UninstallWingetPackageAsync("7zip.7zip");

        Assert.False(result.Success);
        Assert.Contains("Administrator", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LegacyCatalog_All8Apps_RemainAccessibleAndPassThroughExistingPipelines()
    {
        var catalog = _service.GetCatalog();
        Assert.Equal(8, catalog.Count);

        var chrome = _service.GetApp("Chrome");
        Assert.NotNull(chrome);
        Assert.Equal("Google Chrome", chrome.DisplayName);
        Assert.Equal("Google.Chrome", chrome.WingetId);

        // Verify synchronous legacy InstallApplication command signature is untouched
        string legacyChromeCmd = "winget.exe install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements";
        _processRunner.SetCommandResult(legacyChromeCmd, new ProcessExecutionResult(0, "Success", string.Empty, false));

        var installResult = _service.InstallApplication("Chrome");
        Assert.True(installResult.Success);
        Assert.Equal("Winget", installResult.MethodUsed);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals(legacyChromeCmd, StringComparison.OrdinalIgnoreCase));
    }
}
