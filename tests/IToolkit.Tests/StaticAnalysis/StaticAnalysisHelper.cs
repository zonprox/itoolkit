namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

/// <summary>
/// Diagnostic record detailing an ASCII compliance violation.
/// </summary>
public record AsciiViolation(
    string FilePath,
    int LineNumber,
    int ColumnNumber,
    long ByteOffset,
    byte ByteValue,
    string ContextSnippet);

/// <summary>
/// Shared static analysis utilities for repository navigation, file filtering, and byte scanning.
/// </summary>
public static class StaticAnalysisHelper
{
    private static readonly HashSet<string> StandardExclusions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", "bin", "obj", ".agents", ".planning", ".codebase-memory", ".vs", ".idea"
    };

    /// <summary>
    /// Traverses the directory tree upward from AppContext.BaseDirectory until IToolkit.sln is located.
    /// </summary>
    public static string GetRepoRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            if (File.Exists(Path.Combine(current.FullName, "IToolkit.sln")))
            {
                return current.FullName;
            }
            current = current.Parent;
        }

        // Fallback to Directory.GetCurrentDirectory() if BaseDirectory was redirected
        current = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (current != null)
        {
            if (File.Exists(Path.Combine(current.FullName, "IToolkit.sln")))
            {
                return current.FullName;
            }
            current = current.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate repository root containing 'IToolkit.sln'.");
    }

    /// <summary>
    /// Recursively enumerates source files matching specified extensions while pruning build and tooling folders.
    /// </summary>
    public static IEnumerable<string> EnumerateSourceFiles(
        string rootDirectory,
        IEnumerable<string> extensions,
        IEnumerable<string>? additionalExclusions = null)
    {
        if (!Directory.Exists(rootDirectory))
        {
            return Enumerable.Empty<string>();
        }

        var excluded = new HashSet<string>(StandardExclusions, StringComparer.OrdinalIgnoreCase);
        if (additionalExclusions != null)
        {
            foreach (var item in additionalExclusions)
            {
                excluded.Add(item);
            }
        }

        var extSet = new HashSet<string>(extensions, StringComparer.OrdinalIgnoreCase);
        var matchingFiles = new List<string>();

        void Walk(DirectoryInfo dir)
        {
            if (excluded.Contains(dir.Name))
            {
                return;
            }

            try
            {
                foreach (var file in dir.EnumerateFiles())
                {
                    if (extSet.Contains(file.Extension))
                    {
                        matchingFiles.Add(file.FullName);
                    }
                }

                foreach (var subDir in dir.EnumerateDirectories())
                {
                    Walk(subDir);
                }
            }
            catch (UnauthorizedAccessException)
            {
                // Gracefully ignore inaccessible directories in restricted environments
            }
        }

        Walk(new DirectoryInfo(rootDirectory));
        return matchingFiles;
    }

    /// <summary>
    /// Scans a file byte-by-byte for non-ASCII characters (> 127).
    /// </summary>
    public static List<AsciiViolation> ScanNonAsciiBytes(string filePath)
    {
        var violations = new List<AsciiViolation>();
        if (!File.Exists(filePath))
        {
            return violations;
        }

        byte[] bytes = File.ReadAllBytes(filePath);
        int line = 1;
        int col = 1;
        int lineStartOffset = 0;

        for (int i = 0; i < bytes.Length; i++)
        {
            byte b = bytes[i];

            if (b > 127)
            {
                // Capture snippet surrounding the violation
                int snippetStart = Math.Max(lineStartOffset, i - 15);
                int snippetEnd = Math.Min(bytes.Length, i + 15);
                int snippetLength = snippetEnd - snippetStart;

                char[] snippetChars = new char[snippetLength];
                for (int s = 0; s < snippetLength; s++)
                {
                    byte sb = bytes[snippetStart + s];
                    snippetChars[s] = (sb >= 32 && sb <= 126) ? (char)sb : '?';
                }

                violations.Add(new AsciiViolation(
                    filePath,
                    line,
                    col,
                    i,
                    b,
                    new string(snippetChars)));
            }

            if (b == 0x0A) // Line feed (\n)
            {
                line++;
                col = 1;
                lineStartOffset = i + 1;
            }
            else
            {
                col++;
            }
        }

        return violations;
    }
}
