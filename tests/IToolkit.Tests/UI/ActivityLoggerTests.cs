namespace IToolkit.Tests.UI;

using System;
using System.IO;
using IToolkit.App.Native;
using IToolkit.Core.Models;
using Xunit;

public class ActivityLoggerTests
{
    [Fact]
    public void ActivityLogger_CreatesLogFileInLocalAppData_WithCorrectNamingConvention()
    {
        var logger = new ActivityLogger();
        logger.Log(LogLevel.Info, "TestModule", "Path compliance verification test");

        string expectedDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "iToolKit",
            "Logs");
        string expectedFile = Path.Combine(expectedDirectory, $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

        Assert.True(Directory.Exists(expectedDirectory), $"Expected directory '{expectedDirectory}' to exist.");
        Assert.True(File.Exists(expectedFile), $"Expected log file '{expectedFile}' to exist.");
        Assert.Equal(expectedFile, logger.LogFilePath);

        string content = File.ReadAllText(expectedFile);
        Assert.Contains("TestModule", content);
        Assert.Contains("Path compliance verification test", content);
    }
}
