namespace IToolkit.Core.Services.Software;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using IToolkit.Core.Models;

/// <summary>
/// High-performance parser for Windows Package Manager (winget.exe) columnar CLI output and exit codes.
/// Slices variable fixed-width tables dynamically and decodes HRESULT and Win32 process return codes.
/// </summary>
public static class WingetCliParser
{
    // ================= Well-Known Winget & Windows Exit Codes =================
    public const int ExitCodeSuccess = 0;
    public const int ExitCodeRebootRequired = 3010; // ERROR_SUCCESS_REBOOT_REQUIRED (0x00000BC2)
    public const int ExitCodeCancelled = 1223; // ERROR_CANCELLED (0x800704C7)
    public const int ExitCodeInvalidArguments = unchecked((int)0x8A150002); // -1978335230
    public const int ExitCodeCommandFailed = unchecked((int)0x8A150003); // -1978335229
    public const int ExitCodeNoApplicationsFound = unchecked((int)0x8A150014); // -1978335212
    public const int ExitCodeMultipleApplicationsFound = unchecked((int)0x8A150016); // -1978335210
    public const int ExitCodeCommandRequiresAdmin = unchecked((int)0x8A150019); // -1978335207
    public const int ExitCodeCommandRequiresAdminAlt = -1978335068; // 0x8A1500A4
    public const int ExitCodeUpdateNotApplicable = unchecked((int)0x8A15002B); // -1978335189
    public const int ExitCodeUpdateAllHasFailure = unchecked((int)0x8A15002C); // -1978335188
    public const int ExitCodePackageAgreementsNotAccepted = unchecked((int)0x8A150041); // -1978335167
    public const int ExitCodeSourceAgreementsNotAccepted = unchecked((int)0x8A150046); // -1978335162
    public const int ExitCodePackageAlreadyInstalled = unchecked((int)0x8A150061); // -1978335135

    private static readonly Regex ColumnHeaderRegex = new(
        @"\b(Name|Id|Version|Available|Source|Match)\b",
        RegexOptions.Compiled);

    private static readonly Regex UpgradesSummaryRegex = new(
        @"^\s*\d+\s+upgrades?\s+available\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private record ColumnDefinition(string Name, int StartIndex);

    /// <summary>
    /// Parses the stdout of 'winget search &lt;query&gt;' into a list of packages.
    /// </summary>
    public static IReadOnlyList<WingetPackage> ParsePackages(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
            return Array.Empty<WingetPackage>();

        var rows = ParseTableRows(output);
        var packages = new List<WingetPackage>(rows.Count);

        foreach (var row in rows)
        {
            string name = row.GetValueOrDefault("Name", string.Empty);
            string id = row.GetValueOrDefault("Id", string.Empty);

            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(id))
                continue;

            string version = row.GetValueOrDefault("Version", string.Empty);
            string? match = row.TryGetValue("Match", out var m) && !string.IsNullOrWhiteSpace(m) ? m : null;
            string source = row.TryGetValue("Source", out var s) && !string.IsNullOrWhiteSpace(s) ? s : "winget";

            packages.Add(new WingetPackage(name, id, version, match, source));
        }

        return packages;
    }

    /// <summary>
    /// Alias for ParsePackages.
    /// </summary>
    public static IReadOnlyList<WingetPackage> ParseSearchResults(string? output) => ParsePackages(output);

    /// <summary>
    /// Alias for ParsePackages.
    /// </summary>
    public static IReadOnlyList<WingetPackage> ParseSearchOutput(string? output) => ParsePackages(output);

    /// <summary>
    /// Parses the stdout of 'winget list' into a list of installed applications.
    /// </summary>
    public static IReadOnlyList<WingetInstalledApp> ParseInstalledApps(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
            return Array.Empty<WingetInstalledApp>();

        var rows = ParseTableRows(output);
        var installedApps = new List<WingetInstalledApp>(rows.Count);

        foreach (var row in rows)
        {
            string name = row.GetValueOrDefault("Name", string.Empty);
            string id = row.GetValueOrDefault("Id", string.Empty);

            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(id))
                continue;

            string version = row.GetValueOrDefault("Version", string.Empty);
            string? available = row.TryGetValue("Available", out var a) && !string.IsNullOrWhiteSpace(a) ? a : null;
            string source = row.GetValueOrDefault("Source", string.Empty);

            installedApps.Add(new WingetInstalledApp(name, id, version, available, source));
        }

        return installedApps;
    }

    /// <summary>
    /// Alias for ParseInstalledApps.
    /// </summary>
    public static IReadOnlyList<WingetInstalledApp> ParseInstalledAppsOutput(string? output) => ParseInstalledApps(output);

    /// <summary>
    /// Parses the stdout of 'winget list --upgrade-available' into a list of available update items.
    /// </summary>
    public static IReadOnlyList<WingetUpdateItem> ParseUpdates(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
            return Array.Empty<WingetUpdateItem>();

        var rows = ParseTableRows(output);
        var updates = new List<WingetUpdateItem>(rows.Count);

        foreach (var row in rows)
        {
            string name = row.GetValueOrDefault("Name", string.Empty);
            string id = row.GetValueOrDefault("Id", string.Empty);

            if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(id))
                continue;

            string installedVersion = row.GetValueOrDefault("Version", string.Empty);
            string availableVersion = row.GetValueOrDefault("Available", string.Empty);
            string source = row.TryGetValue("Source", out var s) && !string.IsNullOrWhiteSpace(s) ? s : "winget";

            updates.Add(new WingetUpdateItem(name, id, installedVersion, availableVersion, source));
        }

        return updates;
    }

    /// <summary>
    /// Alias for ParseUpdates.
    /// </summary>
    public static IReadOnlyList<WingetUpdateItem> ParseAvailableUpdates(string? output) => ParseUpdates(output);

    /// <summary>
    /// Alias for ParseUpdates.
    /// </summary>
    public static IReadOnlyList<WingetUpdateItem> ParseAvailableUpdatesOutput(string? output) => ParseUpdates(output);

    /// <summary>
    /// Evaluates a process exit code returned by winget.exe into a structured status.
    /// </summary>
    public static WingetExitCodeResult ParseExitCode(
        int exitCode,
        string? operation = null,
        string? packageId = null,
        string? standardError = null)
    {
        string target = string.IsNullOrWhiteSpace(packageId) ? "Package" : $"Package '{packageId}'";
        string op = string.IsNullOrWhiteSpace(operation) ? "Operation" : operation;

        return exitCode switch
        {
            ExitCodeSuccess => new WingetExitCodeResult(
                Success: true,
                Message: $"{target} {op.ToLowerInvariant()} completed successfully."),

            ExitCodeRebootRequired => new WingetExitCodeResult(
                Success: true,
                RebootRequired: true,
                Message: $"{target} {op.ToLowerInvariant()} completed successfully. Reboot required to complete changes."),

            ExitCodeUpdateNotApplicable => new WingetExitCodeResult(
                Success: true,
                AlreadyUpToDate: true,
                Message: $"{target} is already up-to-date at the latest available version."),

            ExitCodePackageAlreadyInstalled => new WingetExitCodeResult(
                Success: true,
                Message: $"{target} is already installed."),

            ExitCodeNoApplicationsFound => new WingetExitCodeResult(
                Success: false,
                Message: $"No package found matching '{packageId ?? "input criteria"}'. (0x8A150014)"),

            ExitCodeCancelled => new WingetExitCodeResult(
                Success: false,
                CancelledByUser: true,
                Message: $"{op} was cancelled by the user (UAC prompt declined)."),

            ExitCodeCommandRequiresAdmin or ExitCodeCommandRequiresAdminAlt => new WingetExitCodeResult(
                Success: false,
                RequiresAdmin: true,
                Message: $"{op} requires administrator privileges. Please run iToolKit as administrator. (0x8A150019)"),

            ExitCodeMultipleApplicationsFound => new WingetExitCodeResult(
                Success: false,
                Message: $"Multiple packages matched '{packageId ?? "criteria"}'. Specify an exact ID. (0x8A150016)"),

            ExitCodePackageAgreementsNotAccepted => new WingetExitCodeResult(
                Success: false,
                Message: "Package license agreements were not accepted. (0x8A150041)"),

            ExitCodeSourceAgreementsNotAccepted => new WingetExitCodeResult(
                Success: false,
                Message: "Source agreements were not accepted. (0x8A150046)"),

            ExitCodeUpdateAllHasFailure => new WingetExitCodeResult(
                Success: false,
                Message: "One or more package updates failed during batch upgrade. (0x8A15002C)"),

            ExitCodeInvalidArguments => new WingetExitCodeResult(
                Success: false,
                Message: "Invalid command-line arguments provided to winget. (0x8A150002)"),

            _ => new WingetExitCodeResult(
                Success: false,
                Message: BuildDefaultErrorMessage(op, target, exitCode, standardError))
        };
    }

    /// <summary>
    /// Evaluates a process exit code returned by winget into a concise tuple.
    /// </summary>
    public static (bool Success, string Message) EvaluateExitCode(int exitCode)
    {
        var result = ParseExitCode(exitCode);
        return (result.Success, result.Message);
    }

    /// <summary>
    /// Translates an install operation exit code directly into an AppInstallResult.
    /// </summary>
    public static AppInstallResult CreateInstallResult(
        string packageId,
        string displayName,
        int exitCode,
        string? standardError = null)
    {
        var outcome = ParseExitCode(exitCode, "Install", packageId, standardError);
        return new AppInstallResult(packageId, displayName, "Winget", outcome.Success, outcome.Message, true);
    }

    /// <summary>
    /// Translates an upgrade operation exit code directly into an AppInstallResult.
    /// </summary>
    public static AppInstallResult CreateUpgradeResult(
        string packageId,
        string displayName,
        int exitCode,
        string? standardError = null)
    {
        var outcome = ParseExitCode(exitCode, "Upgrade", packageId, standardError);
        return new AppInstallResult(packageId, displayName, "Winget", outcome.Success, outcome.Message, true);
    }

    /// <summary>
    /// Translates an uninstall operation exit code directly into an AppInstallResult.
    /// </summary>
    public static AppInstallResult CreateUninstallResult(
        string packageId,
        string displayName,
        int exitCode,
        string? standardError = null)
    {
        var outcome = ParseExitCode(exitCode, "Uninstall", packageId, standardError);
        return new AppInstallResult(packageId, displayName, "Winget", outcome.Success, outcome.Message, true);
    }

    // ================= Exit Code Quick Check Helpers =================
    public static bool IsSuccess(int exitCode) => exitCode == ExitCodeSuccess;
    public static bool IsRebootRequired(int exitCode) => exitCode == ExitCodeRebootRequired;
    public static bool IsNoApplicationsFound(int exitCode) => exitCode == ExitCodeNoApplicationsFound;
    public static bool IsAlreadyInstalled(int exitCode) => exitCode == ExitCodePackageAlreadyInstalled;
    public static bool IsAlreadyUpToDate(int exitCode) => exitCode == ExitCodeUpdateNotApplicable;
    public static bool RequiresAdmin(int exitCode) => exitCode == ExitCodeCommandRequiresAdmin || exitCode == ExitCodeCommandRequiresAdminAlt;
    public static bool IsCancelled(int exitCode) => exitCode == ExitCodeCancelled;
    public static string GetErrorMessage(int exitCode) => ParseExitCode(exitCode).Message;

    // ================= Internal Dynamic Slicing Engine =================

    private static List<Dictionary<string, string>> ParseTableRows(string output)
    {
        var results = new List<Dictionary<string, string>>();
        var lines = output.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);

        int headerIndex = -1;
        for (int i = 0; i < lines.Length - 1; i++)
        {
            if (IsHeaderLine(lines[i]) && IsSeparatorLine(lines[i + 1]))
            {
                headerIndex = i;
                break;
            }
        }

        if (headerIndex == -1)
            return results;

        var columns = ExtractColumns(lines[headerIndex]);
        if (columns.Count == 0)
            return results;

        for (int i = headerIndex + 2; i < lines.Length; i++)
        {
            string line = lines[i];

            if (IsNoiseLine(line))
                continue;

            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int colIdx = 0; colIdx < columns.Count; colIdx++)
            {
                var nextCol = colIdx + 1 < columns.Count ? columns[colIdx + 1] : null;
                row[columns[colIdx].Name] = ExtractColumnValue(line, columns[colIdx], nextCol);
            }

            results.Add(row);
        }

        return results;
    }

    private static bool IsHeaderLine(string line) =>
        line.Contains("Name", StringComparison.Ordinal) &&
        line.Contains("Id", StringComparison.Ordinal) &&
        line.Contains("Version", StringComparison.Ordinal);

    private static bool IsSeparatorLine(string line)
    {
        string trimmed = line.Trim();
        return trimmed.Length >= 3 && trimmed.All(c => c == '-' || c == ' ');
    }

    private static bool IsNoiseLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
            return true;

        string trimmed = line.Trim();
        if (trimmed.StartsWith('<') && trimmed.EndsWith('>'))
            return true;

        if (UpgradesSummaryRegex.IsMatch(trimmed))
            return true;

        if (trimmed.Contains("pins that prevent upgrade", StringComparison.OrdinalIgnoreCase))
            return true;

        if (trimmed.StartsWith("No package found", StringComparison.OrdinalIgnoreCase) ||
            trimmed.StartsWith("No installed package found", StringComparison.OrdinalIgnoreCase) ||
            trimmed.StartsWith("No available upgrade found", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return false;
    }

    private static List<ColumnDefinition> ExtractColumns(string headerLine)
    {
        var matches = ColumnHeaderRegex.Matches(headerLine);
        var columns = new List<ColumnDefinition>(matches.Count);

        foreach (Match match in matches)
        {
            columns.Add(new ColumnDefinition(match.Value, match.Index));
        }

        columns.Sort((a, b) => a.StartIndex.CompareTo(b.StartIndex));
        return columns;
    }

    private static string ExtractColumnValue(string line, ColumnDefinition col, ColumnDefinition? nextCol)
    {
        if (line.Length <= col.StartIndex)
            return string.Empty;

        int start = col.StartIndex;
        if (nextCol == null)
            return line[start..].Trim();

        int length = nextCol.StartIndex - start;
        if (start + length > line.Length)
            length = line.Length - start;

        return line.Substring(start, length).Trim();
    }

    private static string BuildDefaultErrorMessage(string op, string target, int exitCode, string? standardError)
    {
        string hex = $"0x{exitCode:X8}";
        string err = string.IsNullOrWhiteSpace(standardError) ? string.Empty : $" Detail: {standardError.Trim()}";
        return $"{op} for {target} failed with exit code {exitCode} ({hex}).{err}";
    }
}
