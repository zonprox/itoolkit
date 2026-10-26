namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using IToolkit.App.Native;
using IToolkit.Core.Utilities;
using Xunit;

/// <summary>
/// Static analysis and architectural compliance tests for logging standardization:
/// 100% 7-bit ASCII compliance, zero BOM, .NET 10 project settings, TreatWarningsAsErrors=true,
/// and strict iToolKit_ casing for log files.
/// </summary>
[Collection("ActivityLoggerDiskFile")]
public class LoggingStandardizationTests
{
    private const string ExpectedBranding = "iToolKit";

    private static readonly string[] TouchedFiles =
    {
        "src/IToolkit.Core/Utilities/ExceptionFormatter.cs",
        "src/IToolkit.Core/Abstractions/IActivityLogger.cs",
        "src/IToolkit.App/Native/ActivityLogger.cs",
        "src/IToolkit.App/App.xaml.cs",
        "src/IToolkit.App/Services/WpfDialogService.cs",
        "src/IToolkit.App/ViewModels/MainViewModel.cs",
        "src/IToolkit.App/ViewModels/ActivityConsoleViewModel.cs",
        "src/IToolkit.App/ViewModels/ViewModelBase.cs",
        "tests/IToolkit.Tests/TestDoubles/MockDialogService.cs",
        "tests/IToolkit.Tests/UI/StartupAndExceptionLoggingTests.cs",
        "tests/IToolkit.Tests/Services/DialogLoggingTests.cs",
        "tests/IToolkit.Tests/UI/ViewModelLifecycleAndEventLoggingTests.cs",
        "tests/IToolkit.Tests/StaticAnalysis/LoggingStandardizationTests.cs"
    };

    // =========================================================================
    // 1. 100% 7-BIT ASCII AND ZERO UTF-8 BOM COMPLIANCE
    // =========================================================================

    [Fact]
    public void All_Touched_Source_And_Test_Files_Are_100Percent_Ascii_Compliant()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var violations = new List<AsciiViolation>();

        foreach (string relativePath in TouchedFiles)
        {
            string fullPath = Path.Combine(repoRoot, relativePath);
            Assert.True(File.Exists(fullPath), $"Touched file does not exist: {fullPath}");

            violations.AddRange(StaticAnalysisHelper.ScanNonAsciiBytes(fullPath));
        }

        Assert.True(
            violations.Count == 0,
            $"Found {violations.Count} non-ASCII byte(s) across touched files:\n" +
            string.Join("\n", violations.Select(v => $" - {Path.GetRelativePath(repoRoot, v.FilePath)}:{v.LineNumber}:{v.ColumnNumber} (byte 0x{v.ByteValue:X2}) near \"{v.ContextSnippet}\"")));
    }

    [Fact]
    public void All_Touched_Files_Have_Zero_Utf8_Byte_Order_Marks()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var bomViolations = new List<string>();

        foreach (string relativePath in TouchedFiles)
        {
            string fullPath = Path.Combine(repoRoot, relativePath);
            using var stream = File.OpenRead(fullPath);
            if (stream.Length >= 3)
            {
                byte[] header = new byte[3];
                stream.ReadExactly(header, 0, 3);
                if (header[0] == 0xEF && header[1] == 0xBB && header[2] == 0xBF)
                {
                    bomViolations.Add(relativePath);
                }
            }
        }

        Assert.True(
            bomViolations.Count == 0,
            $"Found {bomViolations.Count} file(s) with UTF-8 BOM:\n" +
            string.Join("\n", bomViolations.Select(f => " - " + f)));
    }

    // =========================================================================
    // 2. .NET 10 TARGET FRAMEWORK & COMPILATION SETTINGS
    // =========================================================================

    [Fact]
    public void All_Projects_Target_Net10_And_Enforce_TreatWarningsAsErrors()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string[] projectRelativePaths =
        {
            "src/IToolkit.Core/IToolkit.Core.csproj",
            "src/IToolkit.App/IToolkit.App.csproj",
            "tests/IToolkit.Tests/IToolkit.Tests.csproj"
        };

        foreach (string projPath in projectRelativePaths)
        {
            string fullPath = Path.Combine(repoRoot, projPath);
            Assert.True(File.Exists(fullPath), $"Project file not found: {fullPath}");

            var doc = XDocument.Load(fullPath);

            // TargetFramework validation
            var tfElement = doc.Descendants("TargetFramework").FirstOrDefault();
            Assert.NotNull(tfElement);
            string tf = tfElement.Value.Trim();

            Assert.True(
                tf == "net10.0" || tf == "net10.0-windows",
                $"Project '{projPath}' has TargetFramework '{tf}'. Must be 'net10.0' or 'net10.0-windows'.");

            Assert.DoesNotContain("net8.0", tf);
            Assert.DoesNotContain("net9.0", tf);

            // TreatWarningsAsErrors validation
            var warnAsError = doc.Descendants("TreatWarningsAsErrors").FirstOrDefault();
            Assert.NotNull(warnAsError);
            Assert.Equal("true", warnAsError.Value.Trim(), ignoreCase: true);

            // Nullable enable validation
            var nullable = doc.Descendants("Nullable").FirstOrDefault();
            Assert.NotNull(nullable);
            Assert.Equal("enable", nullable.Value.Trim(), ignoreCase: true);
        }
    }

    // =========================================================================
    // 3. STRICT iToolKit_ CASING FOR LOGGING PATTERNS
    // =========================================================================

    [Fact]
    public void ActivityLogger_LogFilePattern_Maintains_Strict_iToolKit_Casing()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string loggerSrcPath = Path.Combine(repoRoot, "src", "IToolkit.App", "Native", "ActivityLogger.cs");
        Assert.True(File.Exists(loggerSrcPath), $"ActivityLogger.cs not found at: {loggerSrcPath}");

        string sourceContent = File.ReadAllText(loggerSrcPath);

        // Verify correct casing pattern in source code
        Assert.Contains($"$\"{ExpectedBranding}_", sourceContent);

        // Ensure no deviant casings
        Assert.DoesNotContain("\"IToolkit_", sourceContent);
        Assert.DoesNotContain("\"itoolkit_", sourceContent);
        Assert.DoesNotContain("\"IToolKit_", sourceContent);

        // Runtime check: verify instantiated log file naming
        var logger = new ActivityLogger();
        string logPath = logger.LogFilePath;
        string fileName = Path.GetFileName(logPath);

        Assert.StartsWith($"{ExpectedBranding}_", fileName, StringComparison.Ordinal);
        Assert.EndsWith(".log", fileName, StringComparison.Ordinal);
    }

    [Fact]
    public void ActivityLogger_ResolveBaseDirectory_Uses_Strict_iToolKit_Prefix_Check()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string loggerSrcPath = Path.Combine(repoRoot, "src", "IToolkit.App", "Native", "ActivityLogger.cs");
        string sourceContent = File.ReadAllText(loggerSrcPath);

        // Verify that ProcessPath check checks for "iToolKit"
        Assert.Contains("fileName.StartsWith(\"iToolKit\", StringComparison.OrdinalIgnoreCase)", sourceContent);
        Assert.Contains("fileNameWithoutExt.StartsWith(\"iToolKit\", StringComparison.OrdinalIgnoreCase)", sourceContent);
    }

    [Fact]
    public void ExceptionFormatter_SanitizeToAscii_ReplacesNonAsciiWithQuestionMark()
    {
        var ex = new InvalidOperationException("Test with non-ASCII: \u00C4\u00D6\u00DC \u26A0\uFE0F");
        string formatted = ExceptionFormatter.FormatException("Context", ex);

        // Assert strictly 100% 7-bit ASCII
        foreach (char c in formatted)
        {
            Assert.True((int)c <= 127, $"Expected char <= 127, got {(int)c}");
        }

        Assert.Contains("Test with non-ASCII: ??? ??", formatted);
    }
}
