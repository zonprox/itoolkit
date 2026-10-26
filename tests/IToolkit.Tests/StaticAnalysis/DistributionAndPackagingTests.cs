namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Xml.Linq;
using Xunit;

public class DistributionAndPackagingTests
{
    private static readonly string[] ProhibitedSatelliteLanguages =
    {
        "cs", "de", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"
    };

    [Fact]
    public void RepositoryRoot_ContainsOnlyEssentialFiles()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();

        var allowedRootFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "IToolkit.sln",
            "README.md",
            "AGENTS.md",
            ".gitignore",
            ".gitattributes",
            "iToolKit.zip"
        };

        var actualRootFiles = Directory.GetFiles(repoRoot)
            .Select(Path.GetFileName)
            .Where(f => !string.IsNullOrEmpty(f))
            .ToList();

        var unexpectedFiles = actualRootFiles
            .Where(f => !allowedRootFiles.Contains(f!))
            .ToList();

        Assert.True(
            unexpectedFiles.Count == 0,
            $"Found unexpected files at repository root: {string.Join(", ", unexpectedFiles)}. Auxiliary documents should be under docs/.");
    }

    [Fact]
    public void AuxiliaryDocumentation_IsOrganizedUnderDocsDirectory()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string docsDir = Path.Combine(repoRoot, "docs");

        Assert.True(Directory.Exists(docsDir), "The 'docs/' directory must exist.");

        string[] requiredDocFiles = { "PROJECT.md", "TEST_INFRA.md", "TEST_READY.md" };
        foreach (var docFile in requiredDocFiles)
        {
            string filePath = Path.Combine(docsDir, docFile);
            Assert.True(File.Exists(filePath), $"Expected '{docFile}' to exist in 'docs/' directory.");
            Assert.True(new FileInfo(filePath).Length > 0, $"Documentation file '{docFile}' must not be empty.");

            string rootPath = Path.Combine(repoRoot, docFile);
            Assert.False(File.Exists(rootPath), $"Legacy document '{docFile}' must not remain at repository root.");
        }
    }

    [Fact]
    public void BuildOutputs_InSrcAndTests_ContainZeroNonEnglishSatelliteDirectories()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var searchRoots = new[]
        {
            Path.Combine(repoRoot, "src"),
            Path.Combine(repoRoot, "tests")
        };

        var langSet = new HashSet<string>(ProhibitedSatelliteLanguages, StringComparer.OrdinalIgnoreCase);
        var violations = new List<string>();

        foreach (var root in searchRoots)
        {
            if (!Directory.Exists(root))
            {
                continue;
            }

            foreach (var dir in Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories))
            {
                string dirName = Path.GetFileName(dir);
                if (langSet.Contains(dirName))
                {
                    violations.Add(Path.GetRelativePath(repoRoot, dir));
                }
            }
        }

        Assert.True(
            violations.Count == 0,
            $"Build outputs contain prohibited non-English satellite language directories:\n" +
            string.Join("\n", violations.Select(v => " - " + v)));
    }

    [Fact]
    public void ProjectFiles_ConfigureEnglishSatelliteResourcesAndSuppressXmlDocs()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string[] projectRelativePaths =
        {
            Path.Combine("src", "IToolkit.App", "IToolkit.App.csproj"),
            Path.Combine("src", "IToolkit.Core", "IToolkit.Core.csproj"),
            Path.Combine("tests", "IToolkit.Tests", "IToolkit.Tests.csproj")
        };

        foreach (var relativePath in projectRelativePaths)
        {
            string fullPath = Path.Combine(repoRoot, relativePath);
            Assert.True(File.Exists(fullPath), $"Project file not found: {fullPath}");

            var doc = XDocument.Load(fullPath);
            var satelliteElement = doc.Descendants("SatelliteResourceLanguages").FirstOrDefault();
            Assert.NotNull(satelliteElement);
            Assert.Equal("en", satelliteElement.Value.Trim());

            var genDocElement = doc.Descendants("GenerateDocumentationFile").FirstOrDefault();
            Assert.NotNull(genDocElement);
            Assert.Equal("false", genDocElement.Value.Trim(), ignoreCase: true);
        }
    }

    [Fact]
    public void ReleaseArchive_HasCleanLayout_ZeroNonEnglishResources_AndZeroBloat()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string zipPath = Path.Combine(repoRoot, "iToolKit.zip");

        if (!File.Exists(zipPath))
        {
            return;
        }

        using var zip = ZipFile.OpenRead(zipPath);
        var entries = zip.Entries.Select(e => e.FullName.Replace('\\', '/')).ToList();

        Assert.Contains(entries, e => e.Equals("iToolKit.exe", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(entries, e => e.Equals("README.md", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(entries, e => e.StartsWith("Logs/", StringComparison.OrdinalIgnoreCase));

        // Ensure zero .pdb files
        var pdbEntries = entries.Where(e => e.EndsWith(".pdb", StringComparison.OrdinalIgnoreCase)).ToList();
        Assert.True(
            pdbEntries.Count == 0,
            $"Release archive contains prohibited debug symbols (.pdb):\n" +
            string.Join("\n", pdbEntries.Select(p => " - " + p)));

        // Ensure zero .xml files
        var xmlEntries = entries.Where(e => e.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)).ToList();
        Assert.True(
            xmlEntries.Count == 0,
            $"Release archive contains prohibited XML documentation files:\n" +
            string.Join("\n", xmlEntries.Select(x => " - " + x)));

        // Ensure zero non-English language folders
        foreach (var lang in ProhibitedSatelliteLanguages)
        {
            string prefix = lang + "/";
            var langEntries = entries.Where(e => e.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList();
            Assert.True(
                langEntries.Count == 0,
                $"Release archive contains non-English satellite resources for '{lang}':\n" +
                string.Join("\n", langEntries.Select(l => " - " + l)));
        }

        // Ensure no loose dll files dumped into root
        var looseDlls = entries
            .Where(e => !e.Contains('/') && e.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
            .ToList();
        Assert.True(
            looseDlls.Count == 0,
            $"Release archive must not dump loose DLLs into the root folder. Found {looseDlls.Count} loose DLLs:\n" +
            string.Join("\n", looseDlls.Take(20).Select(d => " - " + d)));
    }

    [Fact]
    public void PackagingScript_EnforcesSingleFileAndSanitization()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string scriptPath = Path.Combine(repoRoot, "scripts", "package-and-upload.sh");
        Assert.True(File.Exists(scriptPath), $"Script not found: {scriptPath}");

        string content = File.ReadAllText(scriptPath);
        Assert.Contains("PublishSingleFile=true", content);
        Assert.Contains("IncludeNativeLibrariesForSelfExtract=true", content);
        Assert.Contains("IncludeAllContentForSelfExtract=true", content);
        Assert.Contains("*.pdb", content);
        Assert.Contains("*.xml", content);
        Assert.Contains("placeholder.log", content);
        Assert.Contains(".NET 10", content);
    }

    [Fact]
    public void AllProjects_Target_Net10_And_Never_Net8()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var csprojFiles = StaticAnalysisHelper.EnumerateSourceFiles(repoRoot, new[] { ".csproj" }).ToList();
        Assert.NotEmpty(csprojFiles);

        foreach (var csprojFile in csprojFiles)
        {
            string content = File.ReadAllText(csprojFile);
            var doc = XDocument.Parse(content);
            var tfElement = doc.Descendants("TargetFramework").FirstOrDefault();

            Assert.NotNull(tfElement);
            string tf = tfElement.Value.Trim();

            Assert.StartsWith("net10.0", tf, StringComparison.Ordinal);
            Assert.DoesNotContain("net8.0", content, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void AgentsMarkdown_RetainsNet10MandateAndProhibitsDowngrade()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string agentsPath = Path.Combine(repoRoot, "AGENTS.md");
        Assert.True(File.Exists(agentsPath), $"AGENTS.md not found at: {agentsPath}");

        string content = File.ReadAllText(agentsPath);
        Assert.Contains("## 8. Target Framework & Runtime Standard (.NET 10 Latest Stable)", content);
        Assert.Contains("NEVER downgrade", content);
        Assert.Contains("net10.0", content);
    }
}
