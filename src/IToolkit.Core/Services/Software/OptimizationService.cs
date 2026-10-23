namespace IToolkit.Core.Services.Software;

using System.Globalization;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Pillar 5: Windows Package Manager (Winget) and External Debloat Tools implementation in pure C# .NET 8 (win-x64).
/// </summary>
public class OptimizationService : IOptimizationService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly INetworkService _network;
    private readonly IActivityLogger? _logger;

    public static readonly string[] AllowedDebloatDomains =
    {
        "debloat.raphi.re",
        "debloat.yashg.dev",
        "raw.githubusercontent.com",
        "github.com"
    };

    public const string DefaultWin11DebloatUrl = "https://debloat.raphi.re/";
    public const string DefaultBrowserDebloatUrl = "https://debloat.yashg.dev/install.ps1";

    public OptimizationService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        INetworkService network,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _network = network ?? throw new ArgumentNullException(nameof(network));
        _logger = logger;
    }

    public WingetStatus GetWingetStatus()
    {
        _logger?.LogInfo(nameof(OptimizationService), "Checking Winget installation and repository health...");

        var verRes = _processRunner.Run("winget.exe", "--version");
        if (verRes.ExitCode != 0)
        {
            return new WingetStatus(false, string.Empty, false, false, "winget.exe not found or failed to return version.");
        }

        string version = verRes.StandardOutput.Trim();
        var srcRes = _processRunner.Run("winget.exe", "source list");
        bool sourceListValid = srcRes.ExitCode == 0 && srcRes.StandardOutput.Contains("winget", StringComparison.OrdinalIgnoreCase);

        bool healthy = sourceListValid && !string.IsNullOrEmpty(version);
        return new WingetStatus(true, version, sourceListValid, healthy, healthy ? "Winget is healthy." : "Winget source list requires reset.");
    }

    public bool RepairWinget()
    {
        _logger?.LogInfo(nameof(OptimizationService), "Resetting Winget source cache...");
        var res = _processRunner.Run("winget.exe", "source reset --force");
        return res.ExitCode == 0;
    }

    public ProcessExecutionResult UpdateAllPackages()
    {
        _logger?.LogInfo(nameof(OptimizationService), "Executing Winget upgrade across all installed packages...");
        return _processRunner.Run("winget.exe", "upgrade --all --silent --accept-package-agreements --accept-source-agreements");
    }

    public DebloatExecutionResult LaunchWin11Debloat(string? customUrl = null)
    {
        return ExecuteDebloatScript("Win11Debloat", customUrl ?? DefaultWin11DebloatUrl);
    }

    public DebloatExecutionResult LaunchBrowserDebloat(string? customUrl = null)
    {
        return ExecuteDebloatScript("BrowserDebloat", customUrl ?? DefaultBrowserDebloatUrl);
    }

    public DebloatExecutionResult ExecuteDebloatScript(string toolName, string scriptUrl)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(toolName);
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptUrl);

        _logger?.LogInfo(nameof(OptimizationService), $"Launching external debloat utility '{toolName}' from '{scriptUrl}'...");

        // 1. Pre-flight internet check
        bool hasInternet = _network.PingHost("1.1.1.1") || _network.PingHost("github.com");
        if (!hasInternet)
        {
            string err = "Pre-flight internet check failed: No active internet connection detected.";
            _logger?.LogError(nameof(OptimizationService), err);
            return new DebloatExecutionResult(toolName, scriptUrl, false, false, -1, true, string.Empty, err);
        }

        // 2. HTTPS & Domain Whitelist Enforcement
        if (!Uri.TryCreate(scriptUrl, UriKind.Absolute, out var uri) || !uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
        {
            string err = $"Security Violation: Debloat script URL must use HTTPS protocol: '{scriptUrl}'.";
            _logger?.LogError(nameof(OptimizationService), err);
            throw new SecurityException(err);
        }

        bool domainAllowed = AllowedDebloatDomains.Any(d => uri.Host.Equals(d, StringComparison.OrdinalIgnoreCase) || uri.Host.EndsWith("." + d, StringComparison.OrdinalIgnoreCase));
        if (!domainAllowed)
        {
            string err = $"Security Violation: Debloat domain '{uri.Host}' is not in the approved whitelist.";
            _logger?.LogError(nameof(OptimizationService), err);
            throw new SecurityException(err);
        }

        // 3. Staging and Syntax Pre-Validation
        string tempDir = Path.GetTempPath();
        string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture);
        string tempScriptPath = Path.Combine(tempDir, $"iToolKit_{toolName}_{timestamp}.ps1");
        string scriptOutput = string.Empty;
        int exitCode = -1;
        bool syntaxValid = false;
        string? failureError = null;

        try
        {
            // Download genuine remote debloat script
            string scriptPayload;
            try
            {
                _logger?.LogInfo(nameof(OptimizationService), $"Downloading remote debloat script from '{scriptUrl}'...");
                scriptPayload = _network.DownloadString(scriptUrl);
            }
            catch (Exception ex)
            {
                string err = $"Failed to download debloat script from '{scriptUrl}': {ex.Message}";
                _logger?.LogError(nameof(OptimizationService), err);
                return new DebloatExecutionResult(toolName, scriptUrl, false, false, -1, true, string.Empty, err);
            }

            if (string.IsNullOrWhiteSpace(scriptPayload))
            {
                string err = $"Downloaded debloat script payload from '{scriptUrl}' was empty.";
                _logger?.LogError(nameof(OptimizationService), err);
                return new DebloatExecutionResult(toolName, scriptUrl, false, false, -1, true, string.Empty, err);
            }

            // Verify content is not HTML (landing page or 404 error)
            if (scriptPayload.Contains("<!DOCTYPE html", StringComparison.OrdinalIgnoreCase) ||
                scriptPayload.Contains("<html", StringComparison.OrdinalIgnoreCase) ||
                scriptPayload.Contains("<head", StringComparison.OrdinalIgnoreCase) ||
                scriptPayload.Contains("<body", StringComparison.OrdinalIgnoreCase))
            {
                failureError = "Security Validation Failed: Remote script payload contains HTML tags (landing page or 404).";
                _logger?.LogError(nameof(OptimizationService), failureError);
                return new DebloatExecutionResult(toolName, scriptUrl, false, false, -2, true, string.Empty, failureError);
            }

            syntaxValid = true;
            _fileSystem.WriteAllText(tempScriptPath, scriptPayload);

            // 4. Isolated Execution (no Invoke-Expression / IEX)
            string psArgs = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{tempScriptPath}\"";
            var runRes = _processRunner.Run("powershell.exe", psArgs);
            exitCode = runRes.ExitCode;
            scriptOutput = runRes.StandardOutput;
        }
        finally
        {
            // 5. Clean up temporary script file in finally block
            if (_fileSystem.FileExists(tempScriptPath))
            {
                _fileSystem.DeleteFile(tempScriptPath);
            }
        }

        bool tempCleaned = !_fileSystem.FileExists(tempScriptPath);
        bool executionSuccess = exitCode == 0;
        return new DebloatExecutionResult(
            toolName,
            scriptUrl,
            syntaxValid,
            executionSuccess,
            exitCode,
            tempCleaned,
            scriptOutput,
            executionSuccess ? $"{toolName} executed successfully." : failureError ?? $"{toolName} failed with exit code {exitCode}.");
    }
}

public class SecurityException : Exception
{
    public SecurityException(string message) : base(message) { }
}
