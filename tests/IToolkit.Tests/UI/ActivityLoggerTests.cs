namespace IToolkit.Tests.UI;

using System;
using System.IO;
using IToolkit.App.Native;
using IToolkit.Core.Models;
using Xunit;

[Collection("ActivityLoggerDiskFile")]
public class ActivityLoggerTests
{
    [Fact]
    public void ActivityLogger_CreatesLogFileInPortableLogsDirectory_WithCorrectNamingConvention()
    {
        var logger = new ActivityLogger();
        logger.Log(LogLevel.Info, "TestModule", "Path compliance verification test");

        string expectedDirectory = Path.Combine(AppContext.BaseDirectory, "Logs");
        string expectedFile = Path.Combine(expectedDirectory, $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

        Assert.True(Directory.Exists(expectedDirectory), $"Expected directory '{expectedDirectory}' to exist.");
        Assert.True(File.Exists(expectedFile), $"Expected log file '{expectedFile}' to exist.");
        Assert.Equal(expectedFile, logger.LogFilePath);

        string content = File.ReadAllText(expectedFile);
        Assert.Contains("TestModule", content);
        Assert.Contains("Path compliance verification test", content);
    }

    [Fact]
    public void ActivityLogger_RecreatesDirectoryAndWritesLog_WhenLogsDirectoryDeletedAtRuntime()
    {
        var logger = new ActivityLogger();
        string logPath = logger.LogFilePath;
        string logsDir = Path.GetDirectoryName(logPath)!;

        // Log initial message
        logger.Log(LogLevel.Info, "TestModule", "Initial message before deletion");
        Assert.True(File.Exists(logPath));

        // Simulate external deletion of the Logs directory
        if (Directory.Exists(logsDir))
        {
            Directory.Delete(logsDir, recursive: true);
        }
        Assert.False(Directory.Exists(logsDir));

        // Log subsequent message after directory removal
        logger.Log(LogLevel.Warning, "TestModule", "Message after directory deletion");

        // Assert directory and log file are cleanly recreated
        Assert.True(Directory.Exists(logsDir), $"Expected directory '{logsDir}' to be recreated.");
        Assert.True(File.Exists(logPath), $"Expected log file '{logPath}' to be recreated.");

        string content = File.ReadAllText(logPath);
        Assert.Contains("Message after directory deletion", content);
    }

    [Fact]
    public void ActivityLogger_LogFilePath_DynamicallyMatchesCurrentDate()
    {
        var logger = new ActivityLogger();
        string expectedDateStamp = DateTime.Now.ToString("yyyyMMdd");
        string expectedFileName = $"iToolKit_{expectedDateStamp}.log";

        string actualFileName = Path.GetFileName(logger.LogFilePath);
        Assert.Equal(expectedFileName, actualFileName);
    }
}
