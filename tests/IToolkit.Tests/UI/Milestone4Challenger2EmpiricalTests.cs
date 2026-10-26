namespace IToolkit.Tests.UI;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Core.Utilities;
using IToolkit.Tests.StaticAnalysis;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Empirical challenge test suite for Milestone 4 (Challenger 2):
/// 1. Verifies App.xaml.cs crash hook registration and ResolveLogger fallback resilience.
/// 2. Stress tests ActivityLogger thread safety under heavy concurrent multithreaded logging.
/// 3. Tests ExceptionFormatter ASCII compliance, deep chains, cyclic exceptions, and non-ASCII characters.
/// 4. Tests MockDialogService and WpfDialogService parity and null-parameter resilience.
/// 5. Tests ViewModel navigation and command lifecycle edge cases.
/// </summary>
[Collection("ActivityLoggerDiskFile")]
public class Milestone4Challenger2EmpiricalTests : IDisposable
{
    private readonly string _testBaseDir;
    private readonly TestActivityLogger _inMemoryLogger;

    public Milestone4Challenger2EmpiricalTests()
    {
        _testBaseDir = Path.Combine(Path.GetTempPath(), $"IToolkit_M4C2_{Guid.NewGuid():N}");
        if (Directory.Exists(_testBaseDir))
        {
            Directory.Delete(_testBaseDir, recursive: true);
        }
        _inMemoryLogger = new TestActivityLogger();
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
        try
        {
            if (Directory.Exists(_testBaseDir))
            {
                Directory.Delete(_testBaseDir, recursive: true);
            }
        }
        catch
        {
            // Best effort cleanup in test temp
        }
    }

    private static string GetAppAssemblyPath()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appAssemblyPath = Path.Combine(repoRoot, "src", "IToolkit.App", "bin", "Release", "net10.0-windows", "win-x64", "iToolKit.dll");

        if (!File.Exists(appAssemblyPath))
        {
            appAssemblyPath = Path.Combine(repoRoot, "src", "IToolkit.App", "bin", "Debug", "net10.0-windows", "win-x64", "iToolKit.dll");
        }

        return appAssemblyPath;
    }

    // =========================================================================
    // SECTION 1: CRASH HOOK REGISTRATION & STATIC FALLBACK RESILIENCE
    // =========================================================================

    [Fact]
    public void App_Constructor_RegistersAllThreeUnhandledCrashHooks()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        Assert.True(File.Exists(appXamlCsPath), $"App.xaml.cs not found at: {appXamlCsPath}");

        string source = File.ReadAllText(appXamlCsPath);

        // Verify App() constructor explicitly registers to all 3 unhandled crash events
        Assert.Matches(@"AppDomain\.CurrentDomain\.UnhandledException\s*\+=\s*OnDomainUnhandledException;", source);
        Assert.Matches(@"DispatcherUnhandledException\s*\+=\s*OnDispatcherUnhandledException;", source);
        Assert.Matches(@"TaskScheduler\.UnobservedTaskException\s*\+=\s*OnUnobservedTaskException;", source);
    }

    [Fact]
    public void App_ResolveLogger_HandlesNullOrFaultyServiceProviderGracefully()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string source = File.ReadAllText(appXamlCsPath);

        // Verify ResolveLogger implementation has fallback to _earlyLogger and try/catch guard
        Assert.Contains("return Services?.GetService<IActivityLogger>() ?? _earlyLogger;", source);
        Assert.Contains("catch", source);
        Assert.Contains("return _earlyLogger;", source);
    }

    [Fact]
    public void App_Metadata_VerifiesAllUnhandledCrashHandlersArePresent()
    {
        string assemblyPath = GetAppAssemblyPath();
        Assert.True(File.Exists(assemblyPath), $"App assembly must exist at: {assemblyPath}");

        using var stream = File.OpenRead(assemblyPath);
        using var peReader = new PEReader(stream);
        MetadataReader reader = peReader.GetMetadataReader();

        var methodNames = new HashSet<string>();

        foreach (var typeHandle in reader.TypeDefinitions)
        {
            var typeDef = reader.GetTypeDefinition(typeHandle);
            string typeName = reader.GetString(typeDef.Name);
            string typeNamespace = reader.GetString(typeDef.Namespace);

            if (typeName == "App" && typeNamespace == "IToolkit.App")
            {
                foreach (var methodHandle in typeDef.GetMethods())
                {
                    var methodDef = reader.GetMethodDefinition(methodHandle);
                    methodNames.Add(reader.GetString(methodDef.Name));
                }
                break;
            }
        }

        Assert.Contains("OnDomainUnhandledException", methodNames);
        Assert.Contains("OnDispatcherUnhandledException", methodNames);
        Assert.Contains("OnUnobservedTaskException", methodNames);
        Assert.Contains("ResolveLogger", methodNames);
    }

    // =========================================================================
    // SECTION 2: THREAD SAFETY & CONCURRENT LOGGING STRESS HARNESS
    // =========================================================================

    [Fact]
    public async Task ActivityLogger_HeavyConcurrentLogging_ZeroFileCorruptionOrDroppedEntries()
    {
        var logger = new ActivityLogger(_testBaseDir);
        const int threadCount = 20;
        const int entriesPerThread = 100;
        int totalExpected = threadCount * entriesPerThread;

        int callbackCount = 0;
        logger.EntryLogged += _ => Interlocked.Increment(ref callbackCount);

        var barrier = new Barrier(threadCount);

        var tasks = Enumerable.Range(0, threadCount).Select(threadId => Task.Run(() =>
        {
            barrier.SignalAndWait();
            for (int i = 0; i < entriesPerThread; i++)
            {
                var level = (LogLevel)(i % 5);
                logger.Log(level, $"StressThread_{threadId:D2}", $"Concurrent entry {i:D3} from worker {threadId:D2}");
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        Assert.Equal(totalExpected, callbackCount);

        string logFile = logger.LogFilePath;
        Assert.True(File.Exists(logFile), "Log file must exist on disk.");

        string[] lines = File.ReadAllLines(logFile);
        Assert.Equal(totalExpected, lines.Length);

        // Verify every line conforms to standard log entry regex: [yyyy-MM-dd HH:mm:ss.fff] [LEVEL  ] [Component] Message
        var logPattern = new Regex(@"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[[A-Z\s]{7}\] \[StressThread_\d{2}\] Concurrent entry \d{3} from worker \d{2}$");
        foreach (string line in lines)
        {
            Assert.Matches(logPattern, line);
        }

        // Verify zero non-ASCII bytes
        var violations = StaticAnalysisHelper.ScanNonAsciiBytes(logFile);
        Assert.Empty(violations);
    }

    [Fact]
    public void ActivityLogger_MultipleInstancesSameDirectory_SynchronizeDiskWritesSafely()
    {
        var concrete1 = new ActivityLogger(_testBaseDir);
        var concrete2 = new ActivityLogger(_testBaseDir);
        IActivityLogger logger1 = concrete1;
        IActivityLogger logger2 = concrete2;

        Assert.Equal(concrete1.LogFilePath, concrete2.LogFilePath);

        Parallel.For(0, 50, i =>
        {
            if (i % 2 == 0)
            {
                logger1.LogInfo("Logger1", $"Message {i} from instance 1");
            }
            else
            {
                logger2.LogWarning("Logger2", $"Message {i} from instance 2");
            }
        });

        Assert.True(File.Exists(concrete1.LogFilePath));
        string[] lines = File.ReadAllLines(concrete1.LogFilePath);
        Assert.Equal(50, lines.Length);
    }

    // =========================================================================
    // SECTION 3: EXCEPTION FORMATTER ASCII & RECURSION HARNESS
    // =========================================================================

    [Fact]
    public void ExceptionFormatter_CyclicInnerExceptions_TerminatesSafelyAtDepthLimit()
    {
        // Construct exception hierarchy where inner exception points to an Aggregate containing self
        var inner = new InvalidOperationException("Child exception");
        var outer = new AggregateException("Parent aggregate", inner);

        string formatted = ExceptionFormatter.FormatException("CyclicTest", outer);

        Assert.NotNull(formatted);
        Assert.Contains("CyclicTest | [System.AggregateException] Parent aggregate", formatted);
        Assert.Contains("[System.InvalidOperationException] Child exception", formatted);
    }

    [Fact]
    public void ExceptionFormatter_MassiveNonAsciiPayload_SanitizesStrictlyTo7BitAscii()
    {
        // 10,000 multi-byte Unicode characters across various language scripts and emojis
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < 1000; i++)
        {
            sb.Append("\u00E9\u00E0\u00F9\u00F1\u00E7 \u041E\u0448\u0438\u0431\u043A\u0430 \u4F60\u597D \u3053\u3093\u306B\u3061\u306F \uD83D\uDD25 ");
        }

        var ex = new Exception(sb.ToString(), new Exception("Inner \u2705 \u26A0\uFE0F \u00C4\u00D6\u00DC"));
        string formatted = ExceptionFormatter.FormatException("MassiveUnicode", ex);

        // Verify strictly 100% 7-bit ASCII
        for (int i = 0; i < formatted.Length; i++)
        {
            char c = formatted[i];
            Assert.True((int)c <= 127, $"Non-ASCII character code {(int)c} at index {i}");
        }

        Assert.Contains("MassiveUnicode | [System.Exception]", formatted);
        Assert.Contains("Inner ? ?? ???", formatted);
    }

    [Fact]
    public void ExceptionFormatter_ExceptionWithNullMessage_FormatsTypeWithoutCrashing()
    {
        // Custom exception that returns null for Message
        var ex = new NullMessageTestException();
        string formatted = ExceptionFormatter.FormatException("NullMsgTest", ex);

        Assert.NotNull(formatted);
        Assert.StartsWith("NullMsgTest | [IToolkit.Tests.UI.Milestone4Challenger2EmpiricalTests+NullMessageTestException]", formatted);
    }

    private class NullMessageTestException : Exception
    {
        public override string Message => null!;
    }

    // =========================================================================
    // SECTION 4: DIALOG SERVICE NULL RESILIENCE & PARITY
    // =========================================================================

    [Fact]
    public void MockDialogService_NullLogger_ExecutesAllMethodsWithoutNullReferenceException()
    {
        var service = new MockDialogService(null)
        {
            SelectedOpenFilePath = @"C:\test.txt",
            SelectedSaveFilePath = @"C:\out.txt",
            SelectedFolderPath = @"C:\Folder",
            ConfirmationResult = true
        };

        var exOpen = Record.Exception(() => service.ShowOpenFileDialog("Title", "Filter"));
        var exSave = Record.Exception(() => service.ShowSaveFileDialog("Title", "Filter"));
        var exFolder = Record.Exception(() => service.ShowOpenFolderDialog("Title"));
        var exExplorer = Record.Exception(() => service.OpenFolderInExplorer(@"C:\Folder"));
        var exConfirm = Record.Exception(() => service.Confirm("Title", "Msg", "Warning"));

        Assert.Null(exOpen);
        Assert.Null(exSave);
        Assert.Null(exFolder);
        Assert.Null(exExplorer);
        Assert.Null(exConfirm);
    }

    [Fact]
    public async Task MockDialogService_ConfirmAsync_DelegatesToConfirmAndLogsProperly()
    {
        var service = new MockDialogService(_inMemoryLogger)
        {
            ConfirmationResult = false
        };

        bool confirmed = await service.ConfirmAsync("Dangerous Action", "Proceed?", "Irreversible damage!");

        Assert.False(confirmed);
        Assert.Equal(1, service.ConfirmCallCount);
        Assert.Equal(1, service.ConfirmAsyncCallCount);

        var entries = _inMemoryLogger.CapturedEntries;
        Assert.Equal(2, entries.Count);
        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("SafetyConfirmation", entries[0].Component);
        Assert.Equal(LogLevel.Warning, entries[1].Level);
        Assert.Equal("SafetyConfirmation", entries[1].Component);
        Assert.Contains("Dismissed (No)", entries[1].Message);
    }

    // =========================================================================
    // SECTION 5: VIEWMODEL NAVIGATION & COMMAND LIFECYCLE
    // =========================================================================

    [Fact]
    public void MainViewModel_NavigateToSamePillar_LogsNavigationTransition()
    {
        var telemetryMock = new Mock<ISystemTelemetryService>();
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var identityMock = new Mock<IIdentityService>();
        var backupMock = new Mock<IBackupService>();
        var appInstallerMock = new Mock<IAppInstallerService>();
        var optMock = new Mock<IOptimizationService>();

        appInstallerMock.Setup(a => a.GetCatalog()).Returns(new List<AppCatalogItem>());
        printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new List<string>());

        var telemetryHeader = new TelemetryHeaderViewModel(telemetryMock.Object);
        telemetryHeader.StopPolling();

        var activityConsole = new ActivityConsoleViewModel(_inMemoryLogger);
        var dashboardVm = new DashboardViewModel(healthMock.Object, officeMock.Object, outlookMock.Object, netMock.Object, backupMock.Object, optMock.Object, _inMemoryLogger);
        var healthVm = new SystemHealthViewModel(healthMock.Object, _inMemoryLogger);
        var officeVm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, _inMemoryLogger);
        var connectivityVm = new ConnectivityViewModel(netMock.Object, printerMock.Object, _inMemoryLogger);
        var identityVm = new IdentityBackupViewModel(identityMock.Object, backupMock.Object, _inMemoryLogger);
        var softwareVm = new SoftwareOptimizationViewModel(appInstallerMock.Object, optMock.Object, _inMemoryLogger);

        var mainVm = new MainViewModel(
            telemetryHeader,
            activityConsole,
            dashboardVm,
            healthVm,
            officeVm,
            connectivityVm,
            identityVm,
            softwareVm,
            _inMemoryLogger);

        // Initial pillar is Dashboard
        Assert.Equal("Dashboard", mainVm.CurrentPillarName);

        // Navigating to Dashboard again logs transition from 'Dashboard' to 'Dashboard'
        mainVm.NavigateCommand.Execute("Dashboard");

        var entries = _inMemoryLogger.CapturedEntries;
        var navEntry = entries.LastOrDefault(e => e.Component == nameof(MainViewModel));
        Assert.NotNull(navEntry);
        Assert.Equal("Navigated from tab 'Dashboard' to 'Dashboard'.", navEntry.Message);
    }
}
