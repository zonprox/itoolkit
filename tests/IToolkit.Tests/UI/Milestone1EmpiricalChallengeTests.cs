namespace IToolkit.Tests.UI;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.Native;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Utilities;
using Xunit;

[Collection("ActivityLoggerDiskFile")]
public class Milestone1EmpiricalChallengeTests
{
    private class TestActivityLoggerSink : IActivityLogger
    {
        public List<ActivityLogEntry> Entries { get; } = new();
        public event Action<ActivityLogEntry>? EntryLogged;

        public void Log(LogLevel level, string component, string message)
        {
            var entry = new ActivityLogEntry(DateTime.Now, level, component, message);
            Entries.Add(entry);
            EntryLogged?.Invoke(entry);
        }
    }

    // =========================================================================
    // 1. EXCEPTION FORMATTER EMPIRICAL VERIFICATION & ADVERSARIAL STRESS TESTS
    // =========================================================================

    [Fact]
    public void ExceptionFormatter_NullException_ReturnsEmptyString()
    {
        string result = ExceptionFormatter.FormatException(null);
        Assert.Equal(string.Empty, result);
    }

    [Fact]
    public void ExceptionFormatter_NullException_WithContextMessage_ReturnsContextMessage()
    {
        string result = ExceptionFormatter.FormatException("Pre-startup initialization", null);
        Assert.Equal("Pre-startup initialization", result);

        string emptyResult = ExceptionFormatter.FormatException(string.Empty, null);
        Assert.Equal(string.Empty, emptyResult);

        string whitespaceResult = ExceptionFormatter.FormatException("   ", null);
        Assert.Equal("   ", whitespaceResult);
    }

    [Fact]
    public void ExceptionFormatter_SingleLevelException_FormatsTypeAndMessageAndStack()
    {
        Exception ex;
        try
        {
            throw new InvalidOperationException("Failed to access configuration hive");
        }
        catch (Exception caught)
        {
            ex = caught;
        }

        string result = ExceptionFormatter.FormatException("ConfigLoader", ex);

        Assert.Contains("ConfigLoader | ", result);
        Assert.Contains("[System.InvalidOperationException] Failed to access configuration hive", result);
        Assert.Contains("Stack Trace:", result);
        Assert.Contains("Milestone1EmpiricalChallengeTests", result);
    }

    [Fact]
    public void ExceptionFormatter_DeepRecursiveInnerExceptions_TraversesAllLevels()
    {
        // 4 levels of nested exceptions: Root -> Inner1 -> Inner2 -> Inner3
        var inner3 = new UnauthorizedAccessException("Access denied to registry key");
        var inner2 = new IOException("Disk read error while accessing hive", inner3);
        var inner1 = new InvalidOperationException("Subsystem initialization failed", inner2);
        var root = new ApplicationException("Application startup crashed", inner1);

        string result = ExceptionFormatter.FormatException(root);

        Assert.Contains("[System.ApplicationException] Application startup crashed", result);
        Assert.Contains("---> (Inner Exception #1) [System.InvalidOperationException] Subsystem initialization failed", result);
        Assert.Contains("---> (Inner Exception #2) [System.IO.IOException] Disk read error while accessing hive", result);
        Assert.Contains("---> (Inner Exception #3) [System.UnauthorizedAccessException] Access denied to registry key", result);
    }

    [Fact]
    public void ExceptionFormatter_ExtremeDepth_CappedAt20Levels_PreventsUnboundedLoop()
    {
        // Construct a chain 30 levels deep
        Exception current = new InvalidOperationException("Leaf exception at depth 30");
        for (int i = 29; i >= 1; i--)
        {
            current = new ApplicationException($"Exception wrapper at depth {i}", current);
        }

        string result = ExceptionFormatter.FormatException(current);

        // Assert cap at depth 20
        Assert.Contains("(Inner Exception #20)", result);
        Assert.DoesNotContain("(Inner Exception #21)", result);
    }

    [Fact]
    public void ExceptionFormatter_AggregateException_MultipleNestedExceptions_FormatsAllChildren()
    {
        var child1 = new TimeoutException("Database connection timeout");
        var child2 = new InvalidOperationException("Service bus endpoint offline");
        var child3 = new ArgumentException("Parameter format invalid");
        var agg = new AggregateException("Parallel task cluster failed", child1, child2, child3);

        string result = ExceptionFormatter.FormatException("TaskRunner", agg);

        Assert.Contains("TaskRunner | [System.AggregateException]", result);
        // Child 1 is inner exception of AggregateException
        Assert.Contains("(Inner Exception #1) [System.TimeoutException] Database connection timeout", result);
        // Children 2 and 3 are additional aggregate inner exceptions
        Assert.Contains("(Aggregate Inner #1) [System.InvalidOperationException] Service bus endpoint offline", result);
        Assert.Contains("(Aggregate Inner #2) [System.ArgumentException] Parameter format invalid", result);
    }

    [Fact]
    public void ExceptionFormatter_AggregateException_SingleChild_DoesNotDuplicate()
    {
        var singleChild = new InvalidOperationException("Single child error");
        var agg = new AggregateException("Aggregate with single child", singleChild);

        string result = ExceptionFormatter.FormatException(agg);

        Assert.Contains("(Inner Exception #1) [System.InvalidOperationException] Single child error", result);
        Assert.DoesNotContain("Aggregate Inner #", result);
    }

    [Fact]
    public void ExceptionFormatter_NonAsciiCharacters_SanitizesToStrictAscii()
    {
        // Use Unicode escape sequences (\uXXXX) to maintain 100% 7-bit ASCII in C# source file
        // French: "\u00E9chec d'\u00E9l\u00E9vation"
        // Japanese: "\u30A8\u30E9\u30FC\u767A\u751F"
        // Vietnamese: "L\u1ED7i kh\u1EDFi \u0111\u1ED9ng"
        // Cyrillic: "\u041E\u0448\u0438\u0431\u043A\u0430"
        // Emoji: "\uD83D\uDCA5 Crash"
        string nonAsciiMessage = "Crash: \u00E9chec \u30A8\u30E9\u30FC L\u1ED7i \u041E\u0448\u0438\u0431\u043A\u0430 \uD83D\uDCA5!";
        var inner = new InvalidOperationException("Inner: \u00E0\u00E8\u00EC\u00F2\u00F9");
        var ex = new Exception(nonAsciiMessage, inner);

        string result = ExceptionFormatter.FormatException("Context: \u00FCber-test", ex);

        // Verify that EVERY character in the result is strictly <= 127
        foreach (char c in result)
        {
            Assert.True((int)c <= 127, $"Expected ASCII <= 127, found char '{(int)c}' (0x{(int)c:X4})");
        }

        // Verify non-ASCII characters were replaced with '?'
        Assert.Contains("Context: ?ber-test", result);
        Assert.Contains("[System.Exception] Crash: ?chec ??? L?i ?????? ??!", result);
        Assert.Contains("Inner: ?????", result);
    }

    // =========================================================================
    // 2. IACTIVITYLOGGER DEFAULT METHOD VERIFICATION
    // =========================================================================

    [Fact]
    public void IActivityLogger_LogErrorWithException_FormatsMessageAndAppendsException()
    {
        var sink = new TestActivityLoggerSink();
        IActivityLogger logger = sink;

        var ex = new InvalidOperationException("Connection refused");
        logger.LogError("NetworkService", "Failed to ping gateway", ex);

        Assert.Single(sink.Entries);
        var entry = sink.Entries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.Equal("NetworkService", entry.Component);
        Assert.Contains("Failed to ping gateway | Exception: [System.InvalidOperationException] Connection refused", entry.Message);
    }

    [Fact]
    public void IActivityLogger_LogErrorWithNullException_LogsPlainMessageWithoutExceptionSuffix()
    {
        var sink = new TestActivityLoggerSink();
        IActivityLogger logger = sink;

        logger.LogError("AuthService", "User cancelled elevation prompt", (Exception?)null);

        Assert.Single(sink.Entries);
        var entry = sink.Entries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.Equal("AuthService", entry.Component);
        Assert.Equal("User cancelled elevation prompt", entry.Message);
        Assert.DoesNotContain("| Exception:", entry.Message);
    }

    // =========================================================================
    // 3. ACTIVITYLOGGER DIRECTORY RESOLUTION & CONSTRUCTION
    // =========================================================================

    [Fact]
    public void ActivityLogger_CustomBaseDirectory_ResolvesToSpecifiedDirectory()
    {
        string customDir = Path.Combine(Path.GetTempPath(), $"iToolKit_CustomDirTest_{Guid.NewGuid():N}");
        try
        {
            var concreteLogger = new ActivityLogger(customDir);
            IActivityLogger logger = concreteLogger;

            string expectedLogsDir = Path.Combine(customDir, "Logs");
            string expectedLogFile = Path.Combine(expectedLogsDir, $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

            Assert.Equal(expectedLogFile, concreteLogger.LogFilePath);
            Assert.True(Directory.Exists(expectedLogsDir), "Constructor should create custom Logs directory");

            logger.LogInfo("TestModule", "Testing custom directory resolution");

            Assert.True(File.Exists(expectedLogFile));
            string content = File.ReadAllText(expectedLogFile);
            Assert.Contains("Testing custom directory resolution", content);
        }
        finally
        {
            if (Directory.Exists(customDir))
            {
                try { Directory.Delete(customDir, recursive: true); } catch { }
            }
        }
    }

    [Fact]
    public void ActivityLogger_DefaultConstructor_ResolvesUnderAppContextBaseDirectoryInTests()
    {
        var logger = new ActivityLogger();

        string expectedDirectory = Path.Combine(AppContext.BaseDirectory, "Logs");
        string expectedFile = Path.Combine(expectedDirectory, $"iToolKit_{DateTime.Now:yyyyMMdd}.log");

        Assert.Equal(expectedFile, logger.LogFilePath);
        Assert.StartsWith(expectedDirectory, logger.LogFilePath, StringComparison.Ordinal);
    }

    [Fact]
    public void ActivityLogger_ResolveBaseDirectory_SimulatedProcessPath_ReflectionTest()
    {
        // ResolveBaseDirectory is a private static method. Invoke via reflection to test edge cases.
        var method = typeof(ActivityLogger).GetMethod("ResolveBaseDirectory", BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        // 1. Explicit customBaseDirectory must always be respected
        string customPath = "/opt/itoolkit/custom";
        var res1 = method.Invoke(null, new object?[] { customPath }) as string;
        Assert.Equal(customPath, res1);

        // 2. Null or whitespace customBaseDirectory falls back to ProcessPath or AppContext.BaseDirectory
        var res2 = method.Invoke(null, new object?[] { null }) as string;
        Assert.NotNull(res2);
        Assert.NotEmpty(res2);

        var res3 = method.Invoke(null, new object?[] { "   " }) as string;
        Assert.NotNull(res3);
        Assert.NotEmpty(res3);
    }

    // =========================================================================
    // 4. ACTIVITYLOGGER CONCURRENT WRITES AND STRESS TESTS
    // =========================================================================

    [Fact]
    public async Task ActivityLogger_HighConcurrency_ConcurrentWrites_ZeroDropsOrCorruption()
    {
        string customDir = Path.Combine(Path.GetTempPath(), $"iToolKit_ConcurrentTest_{Guid.NewGuid():N}");
        try
        {
            var logger = new ActivityLogger(customDir);
            var receivedEntries = new ConcurrentBag<ActivityLogEntry>();

            logger.EntryLogged += entry =>
            {
                receivedEntries.Add(entry);
            };

            const int workerCount = 10;
            const int logsPerWorker = 50;
            const int expectedTotal = workerCount * logsPerWorker;

            var tasks = new Task[workerCount];
            var barrier = new Barrier(workerCount);

            for (int w = 0; w < workerCount; w++)
            {
                int workerId = w;
                tasks[w] = Task.Run(() =>
                {
                    barrier.SignalAndWait();
                    for (int i = 0; i < logsPerWorker; i++)
                    {
                        var level = (i % 5) switch
                        {
                            0 => LogLevel.Info,
                            1 => LogLevel.Warning,
                            2 => LogLevel.Error,
                            3 => LogLevel.Success,
                            _ => LogLevel.Debug
                        };
                        logger.Log(level, $"Worker_{workerId}", $"Concurrent execution log payload index {i}");
                    }
                });
            }

            await Task.WhenAll(tasks);

            // Verify in-memory events
            Assert.Equal(expectedTotal, receivedEntries.Count);

            // Verify disk output
            Assert.True(File.Exists(logger.LogFilePath));
            string[] lines = File.ReadAllLines(logger.LogFilePath);
            Assert.Equal(expectedTotal, lines.Length);

            // Verify integrity of each written line
            foreach (string line in lines)
            {
                Assert.StartsWith("[", line);
                Assert.Contains("] [", line);
                Assert.Contains("Concurrent execution log payload index", line);
            }
        }
        finally
        {
            if (Directory.Exists(customDir))
            {
                try { Directory.Delete(customDir, recursive: true); } catch { }
            }
        }
    }

    [Fact]
    public async Task ActivityLogger_ConcurrentLogging_WhileLogsDirectoryDeleted_RecreatesGracefully()
    {
        string customDir = Path.Combine(Path.GetTempPath(), $"iToolKit_RecreationTest_{Guid.NewGuid():N}");
        try
        {
            var concreteLogger = new ActivityLogger(customDir);
            IActivityLogger logger = concreteLogger;
            string logsDir = Path.Combine(customDir, "Logs");

            logger.LogInfo("Initial", "Initial message to create log file");
            Assert.True(File.Exists(concreteLogger.LogFilePath));

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            int logCount = 0;

            // Worker task writing continuously
            var writeTask = Task.Run(async () =>
            {
                int idx = 0;
                while (!cts.Token.IsCancellationRequested)
                {
                    logger.LogInfo("StressWriter", $"Stress message index {idx++}");
                    Interlocked.Increment(ref logCount);
                    await Task.Delay(5);
                }
            });

            // Chaos task deleting the Logs directory repeatedly
            var chaosTask = Task.Run(async () =>
            {
                while (!cts.Token.IsCancellationRequested)
                {
                    await Task.Delay(40);
                    try
                    {
                        if (Directory.Exists(logsDir))
                        {
                            Directory.Delete(logsDir, recursive: true);
                        }
                    }
                    catch
                    {
                        // Directory may be temporarily locked by write
                    }
                }
            });

            await Task.WhenAll(writeTask, chaosTask);

            // Write one final log entry to verify system is operational
            logger.LogSuccess("Recovery", "Final post-chaos recovery entry");

            Assert.True(Directory.Exists(logsDir), "Logs directory must exist after logging recovery");
            Assert.True(File.Exists(concreteLogger.LogFilePath), "Log file must exist after recovery");
            string content = File.ReadAllText(concreteLogger.LogFilePath);
            Assert.Contains("Final post-chaos recovery entry", content);
        }
        finally
        {
            if (Directory.Exists(customDir))
            {
                try { Directory.Delete(customDir, recursive: true); } catch { }
            }
        }
    }
}
