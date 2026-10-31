namespace IToolkit.Core.Services.Software;

using System.Globalization;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;

/// <summary>
/// Pillar 5: Managed Enterprise 8-Application Catalog implementation in pure C# .NET 10.0 LTS (win-x64).
/// </summary>
public class AppInstallerService : IAppInstallerService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IRegistryService _registry;
    private readonly ProcessLockGuard _processLockGuard;
    private readonly INetworkService _network;
    private readonly IActivityLogger? _logger;

    private static readonly Dictionary<string, AppCatalogItem> CatalogItems = new(StringComparer.OrdinalIgnoreCase)
    {
        ["VCRedistAIO"] = new(
            "VCRedistAIO",
            "Visual C++ Redistributable AIO",
            null,
            AppInstallMode.DirectOnly,
            "https://github.com/abbodi1406/vcredist/releases/latest/download/VisualCppRedist_AIO_x86_x64.exe",
            "/ai /y",
            null,
            null,
            Array.Empty<string>()),

        ["UniKey"] = new(
            "UniKey",
            "UniKey",
            null,
            AppInstallMode.ArchiveExtract,
            "https://www.unikey.org/assets/release/unikey43RC5-200929-win64.zip",
            "/VERYSILENT /NORESTART",
            "UniKey.lnk",
            null,
            new[] { "UniKeyNT", "UniKey" }),

        ["UltraVNC"] = new(
            "UltraVNC",
            "UltraVNC",
            null,
            AppInstallMode.DirectOnly,
            "https://uvnc.eu/download/1436/UltraVNC_1_4_36_X64_Setup.exe",
            "/VERYSILENT /NORESTART",
            "UltraVNC.lnk",
            null,
            new[] { "vncviewer", "winvnc" }),

        ["KLiteCodec"] = new(
            "KLiteCodec",
            "K-Lite Codec Pack",
            "CodecGuide.K-LiteCodecPack.Standard",
            AppInstallMode.WingetWithFallback,
            "https://files3.codecguide.com/K-Lite_Codec_Pack_1860_Standard.exe",
            "/verysilent /norestart",
            "Media Player Classic.lnk",
            null,
            new[] { "mpc-hc64", "mpc-hc", "mpc-be64" }),

        ["Chrome"] = new(
            "Chrome",
            "Google Chrome",
            "Google.Chrome",
            AppInstallMode.WingetWithFallback,
            "https://dl.google.com/chrome/install/latest/chrome_installer.exe",
            "/silent /install",
            "Google Chrome.lnk",
            "Browser",
            new[] { "chrome" }),

        ["FoxitReader"] = new(
            "FoxitReader",
            "Foxit PDF Reader",
            "Foxit.FoxitReader",
            AppInstallMode.WingetWithFallback,
            "https://cdn01.foxitsoftware.com/product/reader/desktop/win/FoxitPDFReader_Setup.exe",
            "/quiet /norestart",
            "Foxit PDF Reader.lnk",
            "PDF",
            new[] { "FoxitPDFReader", "FoxitReader" }),

        ["Zalo"] = new(
            "Zalo",
            "Zalo",
            null,
            AppInstallMode.DirectOnly,
            "https://res-zalo.zadn.vn/download/ZaloSetup.exe",
            "/VERYSILENT /NORESTART /S",
            "Zalo.lnk",
            null,
            new[] { "Zalo" }),

        ["WinRAR"] = new(
            "WinRAR",
            "WinRAR",
            "RARLab.WinRAR",
            AppInstallMode.WingetWithFallback,
            "https://www.rarlab.com/rar/winrar-x64-701.exe",
            "/s",
            "WinRAR.lnk",
            null,
            new[] { "WinRAR" })
    };

    public AppInstallerService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        ProcessLockGuard processLockGuard,
        INetworkService network,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _processLockGuard = processLockGuard ?? throw new ArgumentNullException(nameof(processLockGuard));
        _network = network ?? throw new ArgumentNullException(nameof(network));
        _logger = logger;
    }

    public IReadOnlyList<AppCatalogItem> GetCatalog() => CatalogItems.Values.ToList();

    public AppCatalogItem? GetApp(string appId) =>
        CatalogItems.TryGetValue(appId, out var item) ? item : null;

    private string GetDesktopDirectory()
    {
        string? userProfile = Environment.GetEnvironmentVariable("USERPROFILE");
        return !string.IsNullOrEmpty(userProfile) ? Path.Combine(userProfile, "Desktop") : @"C:\Users\Default\Desktop";
    }

    public AppInstallResult InstallApplication(string appId)
    {
        var app = GetApp(appId);
        if (app == null)
        {
            return new AppInstallResult(appId, appId, "None", false, $"Application '{appId}' not found in enterprise catalog.", false);
        }

        _logger?.LogInfo(nameof(AppInstallerService), $"Starting installation of '{app.DisplayName}' (Mode: {app.InstallMode}, Winget: {app.WingetId ?? "Bypassed"})...");

        // 1. Terminate conflicting processes
        if (app.ConflictingProcesses.Count > 0)
        {
            _processLockGuard.EnsureProcessesClosed(app.ConflictingProcesses, TimeSpan.FromSeconds(3));
        }

        // 2. Winget-first execution if WingetId is configured
        if (!string.IsNullOrEmpty(app.WingetId))
        {
            _logger?.LogInfo(nameof(AppInstallerService), $"Attempting Winget installation for '{app.DisplayName}' (ID: {app.WingetId})...");
            string wingetArgs = $"install --id {app.WingetId} --silent --accept-package-agreements --accept-source-agreements";
            var wingetRes = _processRunner.Run("winget.exe", wingetArgs);

            if (wingetRes.ExitCode == 0)
            {
                ApplyPostInstall(app);
                _processLockGuard.RestartClosedProcesses();
                _logger?.LogSuccess(nameof(AppInstallerService), $"Successfully installed '{app.DisplayName}' via Winget.");
                return new AppInstallResult(app.AppId, app.DisplayName, "Winget", true, "Installed via Winget successfully.", true);
            }

            _logger?.LogWarning(nameof(AppInstallerService), $"Winget failed (exit {wingetRes.ExitCode}). Falling back to direct download for '{app.DisplayName}'...");
        }

        // 3. Direct Download / Extraction execution
        string tempDir = Path.GetTempPath();
        string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture);
        if (app.InstallMode == AppInstallMode.ArchiveExtract)
        {
            // ZIP archive extraction (UniKey)
            string tempZip = Path.Combine(tempDir, $"{app.AppId}_{timestamp}.zip");
            string targetDir = $@"C:\Program Files\{app.AppId}";

            try
            {
                _logger?.LogInfo(nameof(AppInstallerService), $"Downloading archive from '{app.DirectDownloadUrl}'...");
                bool downloaded = !string.IsNullOrEmpty(app.DirectDownloadUrl) && _network.DownloadFile(app.DirectDownloadUrl, tempZip);
                if (!downloaded || !_fileSystem.FileExists(tempZip))
                {
                    return new AppInstallResult(app.AppId, app.DisplayName, "ArchiveExtract", false, "Failed to download archive.", true);
                }

                _fileSystem.CreateDirectory(targetDir);

                try
                {
                    _fileSystem.ExtractZipArchive(tempZip, targetDir, overwrite: true);
                }
                catch (Exception ex)
                {
                    _logger?.LogError(nameof(AppInstallerService), $"Failed to extract archive for '{app.DisplayName}': {ex.Message}");
                    return new AppInstallResult(app.AppId, app.DisplayName, "ArchiveExtract", false, $"Failed to extract archive: {ex.Message}", true);
                }

                string exePath = Path.Combine(targetDir, "UniKeyNT.exe");
                ApplyPostInstall(app, exePath);
            }
            finally
            {
                if (_fileSystem.FileExists(tempZip))
                {
                    _fileSystem.DeleteFile(tempZip);
                }
            }
            _processLockGuard.RestartClosedProcesses();
            return new AppInstallResult(app.AppId, app.DisplayName, "ArchiveExtract", true, "Extracted and configured successfully.", !_fileSystem.FileExists(tempZip));
        }
        else
        {
            // Direct setup executable
            string tempExe = Path.Combine(tempDir, $"{app.AppId}_Setup_{timestamp}.exe");
            int exitCode = -1;

            try
            {
                _logger?.LogInfo(nameof(AppInstallerService), $"Downloading installer from '{app.DirectDownloadUrl}'...");
                bool downloaded = !string.IsNullOrEmpty(app.DirectDownloadUrl) && _network.DownloadFile(app.DirectDownloadUrl, tempExe);
                if (!downloaded || !_fileSystem.FileExists(tempExe))
                {
                    return new AppInstallResult(app.AppId, app.DisplayName, "DirectDownload", false, "Failed to download installer binary.", true);
                }

                // Run installer silently
                var runRes = _processRunner.Run(tempExe, app.SilentArguments);
                exitCode = runRes.ExitCode;

                if (exitCode == 0)
                {
                    ApplyPostInstall(app);
                }
            }
            finally
            {
                if (_fileSystem.FileExists(tempExe))
                {
                    _fileSystem.DeleteFile(tempExe);
                }
            }

            bool success = exitCode == 0;
            if (success)
            {
                _processLockGuard.RestartClosedProcesses();
            }
            return new AppInstallResult(app.AppId, app.DisplayName, "DirectDownload", success, $"Installer executed with exit code {exitCode}.", !_fileSystem.FileExists(tempExe));
        }
    }

    private void ApplyPostInstall(AppCatalogItem app, string? explicitExePath = null)
    {
        // 1. Create desktop shortcut if defined
        if (!string.IsNullOrEmpty(app.ShortcutName))
        {
            string target = explicitExePath ?? $@"C:\Program Files\{app.AppId}\{app.AppId}.exe";
            CreateDesktopShortcut(app.ShortcutName, target);
        }

        // 2. Configure default app handler if defined
        if (app.DefaultAppType == "Browser")
        {
            SetDefaultBrowserCore();
            ConfigureUblockOriginLitePolicyCore();
        }
        else if (app.DefaultAppType == "PDF")
        {
            SetDefaultPdfViewerCore();
        }
    }

    public IReadOnlyList<AppInstallResult> InstallBatch(IEnumerable<string> appIds)
    {
        ArgumentNullException.ThrowIfNull(appIds);
        var inputList = appIds.ToList();

        // RUNTIME SEQUENCING: VCRedistAIO is ALWAYS ordered first!
        var orderedList = new List<string>();
        if (inputList.Any(id => id.Equals("VCRedistAIO", StringComparison.OrdinalIgnoreCase)))
        {
            orderedList.Add("VCRedistAIO");
        }
        foreach (var id in inputList)
        {
            if (!id.Equals("VCRedistAIO", StringComparison.OrdinalIgnoreCase))
            {
                orderedList.Add(id);
            }
        }

        _logger?.LogInfo(nameof(AppInstallerService), $"Executing batch install of {orderedList.Count} application(s). Sequence: {string.Join(" -> ", orderedList)}");

        var results = new List<AppInstallResult>();
        foreach (var id in orderedList)
        {
            var res = InstallApplication(id);
            results.Add(res);
        }

        return results;
    }

    public bool CreateDesktopShortcut(string shortcutName, string targetPath, string? arguments = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(shortcutName);
        _logger?.LogInfo(nameof(AppInstallerService), $"Creating desktop shortcut '{shortcutName}' -> '{targetPath}'...");

        string desktop = GetDesktopDirectory();
        _fileSystem.CreateDirectory(desktop);

        string shortcutFile = Path.Combine(desktop, shortcutName);
        _fileSystem.WriteAllText(shortcutFile, $"[Shortcut: Target={targetPath}; Args={arguments ?? ""}]");
        return true;
    }

    public bool SetDefaultBrowser(string browserExecutable = "chrome.exe")
    {
        _logger?.LogInfo(nameof(AppInstallerService), "Assigning Google Chrome as default web browser...");
        _processLockGuard.EnsureProcessesClosed(new[] { "chrome" }, TimeSpan.FromSeconds(3));
        try
        {
            return SetDefaultBrowserCore(browserExecutable);
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses(new[] { "chrome" });
        }
    }

    private bool SetDefaultBrowserCore(string browserExecutable = "chrome.exe")
    {
        _processRunner.Run(browserExecutable, "--make-default-browser");

        _registry.CreateKey(@"HKCU\Software\Classes\.htm");
        _registry.SetValue(@"HKCU\Software\Classes\.htm", "", "ChromeHTML", RegistryValueKind.String);

        _registry.CreateKey(@"HKCU\Software\Classes\.html");
        _registry.SetValue(@"HKCU\Software\Classes\.html", "", "ChromeHTML", RegistryValueKind.String);
        return true;
    }

    public bool SetDefaultPdfViewer(string pdfExecutable = "FoxitPDFReader.exe")
    {
        _logger?.LogInfo(nameof(AppInstallerService), "Assigning Foxit PDF Reader as default PDF viewer...");
        _processLockGuard.EnsureProcessesClosed(new[] { "FoxitPDFReader", "FoxitReader" }, TimeSpan.FromSeconds(3));
        try
        {
            return SetDefaultPdfViewerCore(pdfExecutable);
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses(new[] { "FoxitPDFReader" });
        }
    }

    private bool SetDefaultPdfViewerCore(string pdfExecutable = "FoxitPDFReader.exe")
    {
        _processRunner.Run(pdfExecutable, "/register");

        _registry.CreateKey(@"HKCU\Software\Classes\.pdf");
        _registry.SetValue(@"HKCU\Software\Classes\.pdf", "", "FoxitPDFReader.Document", RegistryValueKind.String);
        return true;
    }

    public bool ConfigureUblockOriginLitePolicy()
    {
        _logger?.LogInfo(nameof(AppInstallerService), "Deploying uBlock Origin Lite enterprise extension policy for Chrome...");
        _processLockGuard.EnsureProcessesClosed(new[] { "chrome" }, TimeSpan.FromSeconds(3));
        try
        {
            return ConfigureUblockOriginLitePolicyCore();
        }
        finally
        {
            _processLockGuard.RestartClosedProcesses(new[] { "chrome" });
        }
    }

    private bool ConfigureUblockOriginLitePolicyCore()
    {
        string extensionEntry = "ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx";

        var targets = new[]
        {
            @"HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist",
            @"HKCU\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"
        };

        foreach (var key in targets)
        {
            _registry.CreateKey(key);
            _registry.SetValue(key, "1", extensionEntry, RegistryValueKind.String);
        }

        return true;
    }
}
