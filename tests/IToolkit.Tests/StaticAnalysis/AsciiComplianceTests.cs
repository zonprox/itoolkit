namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

public class AsciiComplianceTests
{
    private static readonly string[] TargetExtensions = { ".cs", ".xaml", ".manifest", ".csproj", ".md" };

    [Fact]
    public void SourceFiles_In_Src_Are_100Percent_Ascii_Compliant()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string srcDir = Path.Combine(repoRoot, "src");

        var files = StaticAnalysisHelper.EnumerateSourceFiles(srcDir, TargetExtensions).ToList();
        Assert.NotEmpty(files);

        var violations = new List<AsciiViolation>();

        // Act
        foreach (var file in files)
        {
            violations.AddRange(StaticAnalysisHelper.ScanNonAsciiBytes(file));
        }

        // Assert
        Assert.True(
            violations.Count == 0,
            FormatFailureMessage(repoRoot, "src/", violations));
    }

    [Fact]
    public void TestFiles_In_Tests_Are_100Percent_Ascii_Compliant()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string testsDir = Path.Combine(repoRoot, "tests");

        var files = StaticAnalysisHelper.EnumerateSourceFiles(testsDir, TargetExtensions).ToList();
        Assert.NotEmpty(files);

        var violations = new List<AsciiViolation>();

        // Act
        foreach (var file in files)
        {
            violations.AddRange(StaticAnalysisHelper.ScanNonAsciiBytes(file));
        }

        // Assert
        Assert.True(
            violations.Count == 0,
            FormatFailureMessage(repoRoot, "tests/", violations));
    }

    [Fact]
    public void Source_And_Test_Files_Have_Zero_Utf8_Byte_Order_Marks()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var allFiles = StaticAnalysisHelper.EnumerateSourceFiles(Path.Combine(repoRoot, "src"), TargetExtensions)
            .Concat(StaticAnalysisHelper.EnumerateSourceFiles(Path.Combine(repoRoot, "tests"), TargetExtensions))
            .ToList();

        var bomViolations = new List<string>();

        // Act
        foreach (var file in allFiles)
        {
            using var stream = File.OpenRead(file);
            if (stream.Length >= 3)
            {
                byte[] header = new byte[3];
                stream.ReadExactly(header, 0, 3);
                if (header[0] == 0xEF && header[1] == 0xBB && header[2] == 0xBF)
                {
                    bomViolations.Add(Path.GetRelativePath(repoRoot, file));
                }
            }
        }

        // Assert
        Assert.True(
            bomViolations.Count == 0,
            $"Found {bomViolations.Count} file(s) with UTF-8 Byte Order Marks (BOM). Files must be pure 7-bit ASCII without BOM:\n" +
            string.Join("\n", bomViolations.Select(v => " - " + v)));
    }

    [Fact]
    public void AsciiScanner_Accurately_Detects_Violations_And_Calculates_Coordinates()
    {
        // Arrange
        string tempFile = Path.Combine(Path.GetTempPath(), $"AsciiTest_{Guid.NewGuid():N}.cs");
        try
        {
            // Line 1: ASCII
            // Line 2: non-ASCII byte 0xE6 at column 5
            byte[] testBytes =
            {
                (byte)'a', (byte)'b', (byte)'c', 0x0A,
                (byte)'1', (byte)'2', (byte)'3', (byte)'4', 0xE6, (byte)'5', 0x0A
            };
            File.WriteAllBytes(tempFile, testBytes);

            // Act
            var violations = StaticAnalysisHelper.ScanNonAsciiBytes(tempFile);

            // Assert
            Assert.Single(violations);
            var v = violations[0];
            Assert.Equal(2, v.LineNumber);
            Assert.Equal(5, v.ColumnNumber);
            Assert.Equal(8, v.ByteOffset);
            Assert.Equal(0xE6, v.ByteValue);
        }
        finally
        {
            if (File.Exists(tempFile))
            {
                File.Delete(tempFile);
            }
        }
    }

    private static string FormatFailureMessage(string repoRoot, string scope, List<AsciiViolation> violations)
    {
        return $"Found {violations.Count} non-ASCII byte(s) in {scope}. All files must be 100% 7-bit ASCII (byte <= 127):\n" +
               string.Join("\n", violations.Take(30).Select(v =>
                   $" - {Path.GetRelativePath(repoRoot, v.FilePath)}:{v.LineNumber}:{v.ColumnNumber} (offset {v.ByteOffset}, byte 0x{v.ByteValue:X2}) near \"{v.ContextSnippet}\"")) +
               (violations.Count > 30 ? $"\n ... and {violations.Count - 30} more violations." : string.Empty);
    }
}
