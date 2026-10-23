namespace IToolkit.Tests.PillarTests;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Software;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class SoftwareAndOptimizationServiceTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly ProcessLockGuard _lockGuard;
    private readonly AppInstallerService _appInstaller;
    private readonly OptimizationService _optimizationService;

    public SoftwareAndOptimizationServiceTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _appInstaller = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, _network);
        _optimizationService = new OptimizationService(_processRunner, _fileSystem, _network);
    }

    [Fact]
    public void AppCatalog_ContainsExactly8CanonicalApps_WithStrictWingetRules()
    {
        var catalog = _appInstaller.GetCatalog();

        Assert.Equal(8, catalog.Count);

        // Verify concise canonical names
        var expectedApps = new Dictionary<string, (string DisplayName, string? WingetId)>
        {
            ["VCRedistAIO"] = ("Visual C++ Redistributable AIO", null),
            ["UniKey"] = ("UniKey", null),
            ["UltraVNC"] = ("UltraVNC", null),
            ["KLiteCodec"] = ("K-Lite Codec Pack", "CodecGuide.K-LiteCodecPack.Standard"),
            ["Chrome"] = ("Google Chrome", "Google.Chrome"),
            ["FoxitReader"] = ("Foxit PDF Reader", "Foxit.FoxitReader"),
            ["Zalo"] = ("Zalo", null),
            ["WinRAR"] = ("WinRAR", "RARLab.WinRAR")
        };

        foreach (var (appId, (displayName, wingetId)) in expectedApps)
        {
            var app = catalog.FirstOrDefault(a => a.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase));
            Assert.NotNull(app);
            Assert.Equal(displayName, app.DisplayName);
            Assert.Equal(wingetId, app.WingetId);
        }
    }

    [Fact]
    public void InstallBatch_SequencesVCRedistAIOFirst()
    {
        var appsToInstall = new[] { "Chrome", "UniKey", "VCRedistAIO", "WinRAR" };

        var results = _appInstaller.InstallBatch(appsToInstall);

        Assert.Equal(4, results.Count);
        // VCRedistAIO MUST be first!
        Assert.Equal("VCRedistAIO", results[0].AppId);
    }

    [Fact]
    public void InstallApplication_WingetSupported_UsesWinget_AndAppliesPostInstall()
    {
        string chromeWingetCmd = "winget.exe install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements";
        _processRunner.SetCommandResult(chromeWingetCmd, new ProcessExecutionResult(0, "Installed", string.Empty, false));

        var result = _appInstaller.InstallApplication("Chrome");

        Assert.True(result.Success);
        Assert.Equal("Winget", result.MethodUsed);

        // Post-install: verify Chrome was set as default browser and uBlock policy configured
        Assert.Equal("ChromeHTML", _registry.GetValue<string>(@"HKCU\Software\Classes\.htm", ""));
        Assert.Equal("ChromeHTML", _registry.GetValue<string>(@"HKCU\Software\Classes\.html", ""));
        Assert.Contains("ddkjiahejlhfcafbddmgiahcphecmpfh", _registry.GetValue<string>(@"HKCU\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist", "1"));
    }

    [Fact]
    public void InstallApplication_NonWinget_BypassesWinget_CleansUpTempInstaller()
    {
        _processRunner.AddProcess(201, "UniKeyNT");

        var result = _appInstaller.InstallApplication("UniKey");

        Assert.True(result.Success);
        Assert.Equal("ArchiveExtract", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Process lock termination check
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("winget.exe"));
        Assert.False(_processRunner.IsProcessRunning("UniKeyNT"), "Conflicting process should have been terminated");

        // Verify UniKeyNT.exe was deployed and shortcut created
        Assert.True(_fileSystem.FileExists(@"C:\Program Files\UniKey\UniKeyNT.exe"));
    }

    [Fact]
    public void InstallApplication_DirectDownload_CleansUpTempFileInFinally()
    {
        var result = _appInstaller.InstallApplication("UltraVNC");

        Assert.True(result.Success);
        Assert.Equal("DirectDownload", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Verify no leftover installer files in temp directory
        var tempFiles = _fileSystem.EnumerateFiles(Path.GetTempPath(), "*UltraVNC*");
        Assert.Empty(tempFiles);
    }

    [Fact]
    public void SetDefaultPdfViewer_SetsRegistryClasses()
    {
        bool result = _appInstaller.SetDefaultPdfViewer();

        Assert.True(result);
        Assert.Equal("FoxitPDFReader.Document", _registry.GetValue<string>(@"HKCU\Software\Classes\.pdf", ""));
    }

    [Fact]
    public void GetWingetStatus_ReturnsHealthy_WhenVersionAndSourceListSucceed()
    {
        _processRunner.SetCommandResult("winget.exe --version", new ProcessExecutionResult(0, "v1.9.25200\r\n", string.Empty, false));
        _processRunner.SetCommandResult("winget.exe source list", new ProcessExecutionResult(0, "Name   Argument\r\n----   --------\r\nwinget https://cdn.winget.microsoft.com/cache\r\n", string.Empty, false));

        var status = _optimizationService.GetWingetStatus();

        Assert.True(status.IsInstalled);
        Assert.True(status.Healthy);
        Assert.Equal("v1.9.25200", status.Version);
    }

    [Fact]
    public void ExecuteDebloatScript_Fails_WhenInternetIsUnavailable()
    {
        _network.SetHostReachable("1.1.1.1", false);
        _network.SetHostReachable("github.com", false);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.Contains("No active internet connection", result.Message);
    }

    [Theory]
    [InlineData("http://debloat.raphi.re/")] // Insecure HTTP
    [InlineData("ftp://debloat.raphi.re/")]  // Insecure FTP
    public void ExecuteDebloatScript_ThrowsSecurityException_WhenNotHttps(string url)
    {
        _network.SetHostReachable("1.1.1.1", true);

        Assert.Throws<SecurityException>(() =>
            _optimizationService.ExecuteDebloatScript("Tool", url));
    }

    [Theory]
    [InlineData("https://malicious-site.com/script.ps1")]
    [InlineData("https://evil-server.org/debloat.ps1")]
    public void ExecuteDebloatScript_ThrowsSecurityException_WhenDomainNotWhitelisted(string url)
    {
        _network.SetHostReachable("1.1.1.1", true);

        Assert.Throws<SecurityException>(() =>
            _optimizationService.ExecuteDebloatScript("Tool", url));
    }

    [Fact]
    public void ExecuteDebloatScript_RejectsHtmlPayload_WhenRemoteServerReturnsLandingPageOr404()
    {
        _network.SetHostReachable("1.1.1.1", true);
        string html404 = "<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>Error 404</body></html>";
        _network.SetSimulatedDownload("https://debloat.raphi.re/", html404);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.False(result.SyntaxValid);
        Assert.Contains("HTML tags", result.Message);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));
    }

    [Fact]
    public void ExecuteDebloatScript_SucceedsForWhitelistedDomain_AndCleansTempFile()
    {
        _network.SetHostReachable("1.1.1.1", true);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.True(result.ExecutionSuccess);
        Assert.True(result.SyntaxValid);
        Assert.True(result.TempCleanedUp);

        // Verify isolated execution arguments (no IEX)
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File"));

        // Verify temporary script was cleaned up
        var tempScripts = _fileSystem.EnumerateFiles(Path.GetTempPath(), "iToolKit_Win11Debloat_*.ps1");
        Assert.Empty(tempScripts);
    }
}
