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

            var debugTypeElement = doc.Descendants("DebugType")
                .FirstOrDefault(e => e.Attribute("Condition")?.Value.Contains("Release") == true);
            Assert.NotNull(debugTypeElement);
            Assert.Equal("none", debugTypeElement.Value.Trim(), ignoreCase: true);

            var debugSymbolsElement = doc.Descendants("DebugSymbols")
                .FirstOrDefault(e => e.Attribute("Condition")?.Value.Contains("Release") == true);
            Assert.NotNull(debugSymbolsElement);
            Assert.Equal("false", debugSymbolsElement.Value.Trim(), ignoreCase: true);
        }
    }

    [Fact]
    public void AppProject_ConfiguresSingleFilePublishAndSelfExtraction()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appCsprojPath = Path.Combine(repoRoot, "src", "IToolkit.App", "IToolkit.App.csproj");
        Assert.True(File.Exists(appCsprojPath), $"Project file not found: {appCsprojPath}");

        var doc = XDocument.Load(appCsprojPath);
        var singleFileElement = doc.Descendants("PublishSingleFile").FirstOrDefault();
        Assert.NotNull(singleFileElement);
        Assert.Equal("true", singleFileElement.Value.Trim(), ignoreCase: true);

        var nativeLibsElement = doc.Descendants("IncludeNativeLibrariesForSelfExtract").FirstOrDefault();
        Assert.NotNull(nativeLibsElement);
        Assert.Equal("true", nativeLibsElement.Value.Trim(), ignoreCase: true);

        var allContentElement = doc.Descendants("IncludeAllContentForSelfExtract").FirstOrDefault();
        Assert.NotNull(allContentElement);
        Assert.Equal("true", allContentElement.Value.Trim(), ignoreCase: true);
    }

    [Fact]
    public void ReleaseArchive_HasCleanLayout_ZeroNonEnglishResources_AndZeroBloat()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string zipPath = Path.Combine(repoRoot, "iToolKit.zip");

        Assert.True(
            File.Exists(zipPath),
            "Release archive 'iToolKit.zip' was not found at repository root. Run 'scripts/package-and-upload.sh' to generate it.");

        using var zip = ZipFile.OpenRead(zipPath);
        var entries = zip.Entries.Select(e => e.FullName.Replace('\\', '/')).ToList();

        Assert.Contains(entries, e => e.Equals("iToolKit.exe", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(entries, e => e.Equals("README.md", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(entries, e => e.Equals("Logs/placeholder.log", StringComparison.OrdinalIgnoreCase));

        var exeEntry = zip.GetEntry("iToolKit.exe");
        Assert.NotNull(exeEntry);
        Assert.True(exeEntry.Length > 0, "iToolKit.exe in release archive must not be empty.");

        var readmeEntry = zip.GetEntry("README.md");
        Assert.NotNull(readmeEntry);
        Assert.True(readmeEntry.Length > 0, "README.md in release archive must not be empty.");

        var placeholderEntry = zip.GetEntry("Logs/placeholder.log");
        Assert.NotNull(placeholderEntry);
        Assert.True(placeholderEntry.Length > 0, "Logs/placeholder.log in release archive must not be empty.");

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

        // Ensure no loose dll files anywhere in the single-file archive
        var allDllEntries = entries.Where(e => e.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).ToList();
        Assert.True(
            allDllEntries.Count == 0,
            $"Release archive must not contain loose DLLs. Found {allDllEntries.Count} loose DLL(s):\n" +
            string.Join("\n", allDllEntries.Take(20).Select(d => " - " + d)));

        // Ensure root contains only approved entries (iToolKit.exe, README.md, Logs/)
        var unexpectedRootEntries = entries
            .Where(e => !e.Contains('/') && !e.Equals("iToolKit.exe", StringComparison.OrdinalIgnoreCase) && !e.Equals("README.md", StringComparison.OrdinalIgnoreCase))
            .ToList();
        Assert.True(
            unexpectedRootEntries.Count == 0,
            $"Release archive contains unexpected loose files at root:\n" +
            string.Join("\n", unexpectedRootEntries.Select(f => " - " + f)));

        // Ensure all nested paths are strictly under Logs/
        var unexpectedDirectoryEntries = entries
            .Where(e => e.Contains('/') && !e.StartsWith("Logs/", StringComparison.OrdinalIgnoreCase))
            .ToList();
        Assert.True(
            unexpectedDirectoryEntries.Count == 0,
            $"Release archive contains unexpected subdirectories:\n" +
            string.Join("\n", unexpectedDirectoryEntries.Select(d => " - " + d)));
    }

    [Fact]
    public void SourceAndTestDirectoryTrees_AdhereToCleanArchitecturalStructure_WithZeroFlatDumps()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string srcDir = Path.Combine(repoRoot, "src");
        string testsDir = Path.Combine(repoRoot, "tests");

        Assert.True(Directory.Exists(srcDir), "The 'src/' directory must exist.");
        Assert.True(Directory.Exists(testsDir), "The 'tests/' directory must exist.");

        // src/ must contain only designated projects and zero loose files
        var srcLooseFiles = Directory.GetFiles(srcDir);
        Assert.True(
            srcLooseFiles.Length == 0,
            $"Found loose files in 'src/': {string.Join(", ", srcLooseFiles.Select(Path.GetFileName))}");

        var srcProjects = Directory.GetDirectories(srcDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("IToolkit.App", srcProjects);
        Assert.Contains("IToolkit.Core", srcProjects);

        // tests/ must contain only designated test project and zero loose files
        var testsLooseFiles = Directory.GetFiles(testsDir);
        Assert.True(
            testsLooseFiles.Length == 0,
            $"Found loose files in 'tests/': {string.Join(", ", testsLooseFiles.Select(Path.GetFileName))}");

        var testProjects = Directory.GetDirectories(testsDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("IToolkit.Tests", testProjects);

        // src/IToolkit.App must be structured by architectural role
        string appDir = Path.Combine(srcDir, "IToolkit.App");
        var appSubDirs = Directory.GetDirectories(appDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("Views", appSubDirs);
        Assert.Contains("ViewModels", appSubDirs);
        Assert.Contains("Native", appSubDirs);
        Assert.Contains("Services", appSubDirs);
        Assert.Contains("Converters", appSubDirs);
        Assert.Contains("Assets", appSubDirs);

        // src/IToolkit.Core must be structured by architectural role
        string coreDir = Path.Combine(srcDir, "IToolkit.Core");
        var coreSubDirs = Directory.GetDirectories(coreDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("Abstractions", coreSubDirs);
        Assert.Contains("Models", coreSubDirs);
        Assert.Contains("Safety", coreSubDirs);
        Assert.Contains("Services", coreSubDirs);
        Assert.Contains("Utilities", coreSubDirs);

        // src/IToolkit.Core/Services must be organized by domain pillar and contain zero loose files
        string coreServicesDir = Path.Combine(coreDir, "Services");
        var coreServicesLooseFiles = Directory.GetFiles(coreServicesDir);
        Assert.True(
            coreServicesLooseFiles.Length == 0,
            $"Found loose files in 'src/IToolkit.Core/Services/': {string.Join(", ", coreServicesLooseFiles.Select(Path.GetFileName))}");

        var coreServiceSubDirs = Directory.GetDirectories(coreServicesDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("SystemHealth", coreServiceSubDirs);
        Assert.Contains("Identity", coreServiceSubDirs);
        Assert.Contains("Office", coreServiceSubDirs);
        Assert.Contains("Software", coreServiceSubDirs);
        Assert.Contains("Connectivity", coreServiceSubDirs);

        var allowedRootAppFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "IToolkit.App.csproj",
            "App.xaml",
            "App.xaml.cs",
            "MainWindow.xaml",
            "MainWindow.xaml.cs",
            "ServiceRegistration.cs",
            "app.manifest"
        };
        var actualAppFiles = Directory.GetFiles(appDir).Select(Path.GetFileName).ToList();
        var unexpectedAppFiles = actualAppFiles.Where(f => !allowedRootAppFiles.Contains(f!)).ToList();
        Assert.True(
            unexpectedAppFiles.Count == 0,
            $"Found unexpected loose files at root of 'src/IToolkit.App/': {string.Join(", ", unexpectedAppFiles)}");

        var allowedRootCoreFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "IToolkit.Core.csproj"
        };
        var actualCoreFiles = Directory.GetFiles(coreDir).Select(Path.GetFileName).ToList();
        var unexpectedCoreFiles = actualCoreFiles.Where(f => !allowedRootCoreFiles.Contains(f!)).ToList();
        Assert.True(
            unexpectedCoreFiles.Count == 0,
            $"Found unexpected loose files at root of 'src/IToolkit.Core/': {string.Join(", ", unexpectedCoreFiles)}");

        // tests/IToolkit.Tests must be structured into test categories with zero loose test files
        string testProjectDir = Path.Combine(testsDir, "IToolkit.Tests");
        var testSubDirs = Directory.GetDirectories(testProjectDir).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.Contains("PillarTests", testSubDirs);
        Assert.Contains("Services", testSubDirs);
        Assert.Contains("StaticAnalysis", testSubDirs);
        Assert.Contains("UI", testSubDirs);
        Assert.Contains("SafetyTests", testSubDirs);
        Assert.Contains("TestDoubles", testSubDirs);
        Assert.Contains("ViewModels", testSubDirs);
        Assert.Contains("Integration", testSubDirs);

        var allowedRootTestFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "IToolkit.Tests.csproj",
            "AssemblyInfo.cs",
            "xunit.runner.json"
        };
        var actualTestProjectFiles = Directory.GetFiles(testProjectDir).Select(Path.GetFileName).ToList();
        var unexpectedTestFiles = actualTestProjectFiles.Where(f => !allowedRootTestFiles.Contains(f!)).ToList();
        Assert.True(
            unexpectedTestFiles.Count == 0,
            $"Found loose files at root of 'tests/IToolkit.Tests/': {string.Join(", ", unexpectedTestFiles)}");
    }

    [Fact]
    public void BuildOutputs_InSrcAndTests_ContainZeroNet8DirectoriesOrFiles()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        var searchRoots = new[]
        {
            Path.Combine(repoRoot, "src"),
            Path.Combine(repoRoot, "tests")
        };

        var violations = new List<string>();

        foreach (var root in searchRoots)
        {
            if (!Directory.Exists(root))
            {
                continue;
            }

            foreach (var dir in Directory.EnumerateDirectories(root, "*net8.0*", SearchOption.AllDirectories))
            {
                violations.Add(Path.GetRelativePath(repoRoot, dir));
            }
        }

        Assert.True(
            violations.Count == 0,
            $"Found obsolete net8.0 build or cache directories in repository:\n" +
            string.Join("\n", violations.Select(v => " - " + v)));
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
