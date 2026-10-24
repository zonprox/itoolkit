namespace IToolkit.Tests.StaticAnalysis;

using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using IToolkit.App.Native;
using Xunit;

public class NamingStandardizationTests
{
    private const string ExpectedCasing = "iToolKit";

    [Fact]
    public void AppCsproj_AssemblyName_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string csprojPath = Path.Combine(repoRoot, "src", "IToolkit.App", "IToolkit.App.csproj");
        Assert.True(File.Exists(csprojPath), $"File not found: {csprojPath}");

        // Act
        var doc = XDocument.Load(csprojPath);
        var assemblyNameElement = doc.Descendants("AssemblyName").FirstOrDefault();

        // Assert
        Assert.NotNull(assemblyNameElement);
        string assemblyName = assemblyNameElement.Value.Trim();
        Assert.Equal(ExpectedCasing, assemblyName);

        // Ensure no deviant casing is present anywhere in AssemblyName tags
        string content = File.ReadAllText(csprojPath);
        Assert.Contains($"<AssemblyName>{ExpectedCasing}</AssemblyName>", content);
        Assert.DoesNotContain("<AssemblyName>IToolkit</AssemblyName>", content);
        Assert.DoesNotContain("<AssemblyName>itoolkit</AssemblyName>", content);
        Assert.DoesNotContain("<AssemblyName>IToolKit</AssemblyName>", content);
    }

    [Fact]
    public void MainWindow_Title_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string xamlPath = Path.Combine(repoRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(xamlPath), $"File not found: {xamlPath}");

        // Act
        string content = File.ReadAllText(xamlPath);

        // Assert
        Assert.Contains($"Title=\"{ExpectedCasing}\"", content);
        Assert.DoesNotContain("Title=\"IToolkit\"", content);
        Assert.DoesNotContain("Title=\"itoolkit\"", content);
        Assert.DoesNotContain("Title=\"IToolKit\"", content);

        // Verify branding header text block
        Assert.Contains($"<TextBlock Text=\"{ExpectedCasing}\"", content);
    }

    [Fact]
    public void ActivityLogWindow_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string xamlPath = Path.Combine(repoRoot, "src", "IToolkit.App", "Views", "ActivityLogWindow.xaml");
        Assert.True(File.Exists(xamlPath), $"File not found: {xamlPath}");

        // Act
        string content = File.ReadAllText(xamlPath);

        // Assert
        Assert.Contains($"Title=\"{ExpectedCasing} - Activity Log\"", content);
        Assert.Contains($"Icon=\"pack://application:,,,/{ExpectedCasing};component/Assets/{ExpectedCasing}.ico\"", content);
        Assert.DoesNotContain("Title=\"IToolkit", content);
        Assert.DoesNotContain("Title=\"itoolkit", content);
        Assert.DoesNotContain("Title=\"IToolKit", content);
    }

    [Fact]
    public void AppManifest_AssemblyIdentity_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string manifestPath = Path.Combine(repoRoot, "src", "IToolkit.App", "app.manifest");
        Assert.True(File.Exists(manifestPath), $"File not found: {manifestPath}");

        // Act
        var doc = XDocument.Load(manifestPath);
        XNamespace ns = "urn:schemas-microsoft-com:asm.v1";
        var identityElement = doc.Descendants(ns + "assemblyIdentity").FirstOrDefault();

        // Assert
        Assert.NotNull(identityElement);
        string? nameAttr = identityElement.Attribute("name")?.Value;
        Assert.NotNull(nameAttr);
        Assert.Equal($"{ExpectedCasing}.App", nameAttr);

        string rawContent = File.ReadAllText(manifestPath);
        Assert.Contains($"name=\"{ExpectedCasing}.App\"", rawContent);
        Assert.DoesNotContain("name=\"IToolkit.App\"", rawContent);
        Assert.DoesNotContain("name=\"itoolkit.App\"", rawContent);
    }

    [Fact]
    public void ActivityLogger_LogFile_Pattern_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string loggerSrcPath = Path.Combine(repoRoot, "src", "IToolkit.App", "Native", "ActivityLogger.cs");
        Assert.True(File.Exists(loggerSrcPath), $"File not found: {loggerSrcPath}");

        // Act & Assert Source Code Pattern
        string content = File.ReadAllText(loggerSrcPath);
        Assert.Contains($"\"{ExpectedCasing}\", \"Logs\"", content);
        Assert.Contains($"\"{ExpectedCasing}_", content);

        // Act & Assert Runtime Instantiation
        var logger = new ActivityLogger();
        string logPath = logger.LogFilePath;
        string fileName = Path.GetFileName(logPath);

        Assert.Contains(ExpectedCasing, logPath);
        Assert.StartsWith($"{ExpectedCasing}_", fileName, StringComparison.Ordinal);
        Assert.EndsWith(".log", fileName, StringComparison.Ordinal);
    }

    [Fact]
    public void IdentityBackupViewModel_BackupManifest_Has_Strict_iToolKit_Casing()
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string vmPath = Path.Combine(repoRoot, "src", "IToolkit.App", "ViewModels", "IdentityBackupViewModel.cs");
        Assert.True(File.Exists(vmPath), $"File not found: {vmPath}");

        // Act
        string content = File.ReadAllText(vmPath);
        const string expectedManifestName = $"{ExpectedCasing}_Backup_Manifest.json";

        // Assert
        Assert.Contains($"\"{expectedManifestName}\"", content);
        Assert.DoesNotContain("\"IToolkit_Backup_Manifest.json\"", content);
        Assert.DoesNotContain("\"itoolkit_backup_manifest.json\"", content);
        Assert.DoesNotContain("\"IToolKit_Backup_Manifest.json\"", content);
    }

    [Theory]
    [InlineData("src/IToolkit.App/App.xaml.cs", "iToolKit Error")]
    [InlineData("src/IToolkit.App/App.xaml.cs", "iToolKit initializing")]
    [InlineData("src/IToolkit.Core/Services/Software/OptimizationService.cs", "iToolKit_")]
    public void UserVisibleStrings_Use_Standardized_iToolKit_Prefix(string relativePath, string expectedToken)
    {
        // Arrange
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string fullPath = Path.Combine(repoRoot, relativePath);
        Assert.True(File.Exists(fullPath), $"File not found: {fullPath}");

        // Act
        string content = File.ReadAllText(fullPath);

        // Assert
        Assert.Contains(expectedToken, content);
    }
}
