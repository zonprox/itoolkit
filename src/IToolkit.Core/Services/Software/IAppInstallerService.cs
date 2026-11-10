namespace IToolkit.Core.Services.Software;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for enterprise 8-application catalog, Winget-first vs. direct download pipelines,
/// desktop shortcuts, default app associations, and Chrome enterprise extension policy.
/// </summary>
public interface IAppInstallerService
{
    IReadOnlyList<AppCatalogItem> GetCatalog();
    AppCatalogItem? GetApp(string appId);
    AppInstallResult InstallApplication(string appId);
    IReadOnlyList<AppInstallResult> InstallBatch(IEnumerable<string> appIds);
    bool CreateDesktopShortcut(string shortcutName, string targetPath, string? arguments = null);
    bool SetDefaultBrowser(string browserExecutable = "chrome.exe");
    bool SetDefaultPdfViewer(string pdfExecutable = "FoxitPDFReader.exe");
    bool ConfigureUblockOriginLitePolicy();

    // New Winget Subsystem Capabilities
    Task<IReadOnlyList<WingetPackage>> SearchPackagesAsync(string query, CancellationToken ct = default);
    Task<IReadOnlyList<WingetInstalledApp>> GetInstalledApplicationsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<WingetUpdateItem>> GetAvailableUpdatesAsync(CancellationToken ct = default);
    Task<AppInstallResult> InstallWingetPackageAsync(string packageId, CancellationToken ct = default);
    Task<AppInstallResult> UpgradeWingetPackageAsync(string packageId, CancellationToken ct = default);
    Task<AppInstallResult> UninstallWingetPackageAsync(string packageId, CancellationToken ct = default);
}

