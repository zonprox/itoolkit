namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Xunit;

public class LegacyResidueTests
{
    private static readonly string[] LegacyScriptExtensions = { ".ps1", ".psm1", ".psd1", ".bat" };
    private static readonly string[] ProhibitedLegacyDirectories = { "Modules", "Build", "TestLogs", "Tests" };

    [Fact]
    public void Repository_Contains_Zero_Legacy_Scripts()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var files = StaticAnalysisHelper.EnumerateSourceFiles(
            repoRoot,
            LegacyScriptExtensions);

        // Act
        var violations = files
            .Select(f => Path.GetRelativePath(repoRoot, f))
            .OrderBy(f => f)
            .ToList();

        // Assert
        Assert.True(
            violations.Count == 0,
            $"Found {violations.Count} prohibited legacy script file(s) in repository. All *.ps1, *.psm1, *.psd1, and *.bat files must be eliminated:\n" +
            string.Join("\n", violations.Take(25).Select(v => " - " + v)) +
            (violations.Count > 25 ? $"\n ... and {violations.Count - 25} more." : string.Empty));
    }

    [Fact]
    public void Repository_Contains_Zero_Legacy_Directories()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var actualDirNames = Directory.GetDirectories(repoRoot)
            .Select(Path.GetFileName)
            .Where(name => !string.IsNullOrEmpty(name))
            .ToHashSet(StringComparer.Ordinal);

        // Act
        // Use exact case-sensitive ordinal comparison so that on Windows NTFS
        // the presence of lowercase 'tests' does not falsely match legacy uppercase 'Tests'.
        var existingProhibitedDirs = ProhibitedLegacyDirectories
            .Where(dir => actualDirNames.Contains(dir))
            .ToList();

        // Assert
        Assert.True(
            existingProhibitedDirs.Count == 0,
            $"Repository contains legacy directory residue that must be purged: {string.Join(", ", existingProhibitedDirs)}");
    }

    [Fact]
    public void Source_Contains_Zero_Legacy_PowerShell_Commandlets_Or_Shims()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string srcDir = Path.Combine(repoRoot, "src");

        var sourceFiles = StaticAnalysisHelper.EnumerateSourceFiles(
            srcDir,
            new[] { ".cs", ".xaml" });

        // Prohibited tokens: legacy cmdlets and execution shims
        var prohibitedTokens = new[]
        {
            "Import-Module",
            "System.Management.Automation",
            "powershell.exe -File",
            "pwsh.exe -File",
            "powershell -File",
            "pwsh -File",
            "Invoke-ToolkitSubmenu",
            "Start-IToolkitMenu",
            "Show-ToolkitHeader",
            "Invoke-ToolkitConsoleAction",
            "Start-ToolkitSelfElevation",
            "IToolkit.psd1",
            "IToolkit.psm1",
            "Start-IToolkit.ps1",
            "Build-IToolkitPackage.ps1",
            "Run-IToolkit.bat"
        };

        var violations = new List<string>();

        // Act
        foreach (var file in sourceFiles)
        {
            string relativePath = Path.GetRelativePath(repoRoot, file);
            string[] lines = File.ReadAllLines(file);

            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].Trim();

                // Check prohibited tokens
                foreach (var token in prohibitedTokens)
                {
                    if (line.Contains(token, StringComparison.OrdinalIgnoreCase))
                    {
                        violations.Add($"{relativePath}:{i + 1} contains prohibited token '{token}': \"{line}\"");
                    }
                }

                // Check Invoke-Expression outside comments
                if (!line.StartsWith("//") && !line.StartsWith("*") && !line.StartsWith("/*"))
                {
                    if (Regex.IsMatch(line, @"\bInvoke-Expression\b|\biex\s+", RegexOptions.IgnoreCase))
                    {
                        violations.Add($"{relativePath}:{i + 1} contains prohibited execution shim 'Invoke-Expression': \"{line}\"");
                    }
                }
            }
        }

        // Assert
        Assert.True(
            violations.Count == 0,
            $"Found {violations.Count} legacy PowerShell commandlet/shim occurrence(s) in src/:\n" +
            string.Join("\n", violations));
    }

    [Fact]
    public void Core_Services_Do_Not_Use_PowerShell_For_Toolkit_Operations()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string servicesDir = Path.Combine(repoRoot, "src", "IToolkit.Core", "Services");

        var serviceFiles = StaticAnalysisHelper.EnumerateSourceFiles(
            servicesDir,
            new[] { ".cs" });

        var violations = new List<string>();

        // Act
        foreach (var file in serviceFiles)
        {
            // OptimizationService is permitted to execute external third-party debloat scripts (e.g. Win11Debloat)
            // in an isolated sandbox, but MUST NOT use PowerShell for native toolkit features.
            string fileName = Path.GetFileName(file);
            if (fileName.Equals("OptimizationService.cs", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string relativePath = Path.GetRelativePath(repoRoot, file);
            string[] lines = File.ReadAllLines(file);

            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i];
                if (line.Contains("powershell", StringComparison.OrdinalIgnoreCase) ||
                    line.Contains("pwsh", StringComparison.OrdinalIgnoreCase))
                {
                    // Ignore XML doc comments
                    if (line.TrimStart().StartsWith("///"))
                    {
                        continue;
                    }

                    violations.Add($"{relativePath}:{i + 1} shells out to PowerShell: \"{line.Trim()}\"");
                }
            }
        }

        // Assert
        Assert.True(
            violations.Count == 0,
            $"Core pillar services must use native C# / Win32 APIs, not PowerShell. Found violations:\n" +
            string.Join("\n", violations));
    }
}
