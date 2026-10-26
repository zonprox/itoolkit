namespace IToolkit.Tests.Services;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Tests.StaticAnalysis;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge verification tests for Milestone 2:
/// Rigorously validates reflection instantiation, parameterless constructors,
/// structured logging across file/folder pickers, explorer launches, exception handling,
/// and safety confirmation prompts in WpfDialogService and MockDialogService.
/// </summary>
public class Milestone2Challenger1EmpiricalTests : IDisposable
{
    private readonly string _tempDirectory;
    private readonly List<ActivityLogEntry> _loggedEntries = new();
    private readonly EmpiricalChallengeLogger _testLogger;

    public Milestone2Challenger1EmpiricalTests()
    {
        _tempDirectory = Path.Combine(Path.GetTempPath(), $"IToolkit_M2Challenger_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDirectory);
        _testLogger = new EmpiricalChallengeLogger(_loggedEntries);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempDirectory))
            {
                Directory.Delete(_tempDirectory, recursive: true);
            }
        }
        catch
        {
            // Best effort cleanup in test temp
        }
    }

    private class EmpiricalChallengeLogger : IActivityLogger
    {
        private readonly List<ActivityLogEntry> _sink;

        public EmpiricalChallengeLogger(List<ActivityLogEntry> sink)
        {
            _sink = sink;
        }

        public event Action<ActivityLogEntry>? EntryLogged;

        public void Log(LogLevel level, string component, string message)
        {
            var entry = new ActivityLogEntry(DateTime.UtcNow, level, component, message);
            _sink.Add(entry);
            EntryLogged?.Invoke(entry);
        }

        public void LogInfo(string component, string message) => Log(LogLevel.Info, component, message);
        public void LogWarning(string component, string message) => Log(LogLevel.Warning, component, message);
        public void LogError(string component, string message) => Log(LogLevel.Error, component, message);
        public void LogSuccess(string component, string message) => Log(LogLevel.Success, component, message);
        public void LogDebug(string component, string message) => Log(LogLevel.Debug, component, message);
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

    private static (bool Success, Type? Type, string? FailureReason) TryLoadWpfDialogServiceType()
    {
        string appAssemblyPath = GetAppAssemblyPath();
        if (!File.Exists(appAssemblyPath))
        {
            return (false, null, $"Assembly not found at: {appAssemblyPath}");
        }

        try
        {
            var appAssembly = Assembly.LoadFrom(appAssemblyPath);
            var type = appAssembly.GetType("IToolkit.App.Services.WpfDialogService");
            return (type != null, type, type == null ? "Type IToolkit.App.Services.WpfDialogService not found" : null);
        }
        catch (FileLoadException ex)
        {
            return (false, null, $"FileLoadException: {ex.Message}");
        }
        catch (BadImageFormatException ex)
        {
            return (false, null, $"BadImageFormatException: {ex.Message}");
        }
        catch (PlatformNotSupportedException ex)
        {
            return (false, null, $"PlatformNotSupportedException: {ex.Message}");
        }
    }

    private record WpfMetadataInfo(
        bool Found,
        int ConstructorCount,
        bool HasParameterlessConstructor,
        bool HasSingleParameterConstructor,
        List<string> InterfaceNames,
        List<string> MethodNames);

    private static WpfMetadataInfo InspectWpfDialogServiceMetadata()
    {
        string assemblyPath = GetAppAssemblyPath();
        Assert.True(File.Exists(assemblyPath), $"Assembly must exist at {assemblyPath}");

        using var stream = File.OpenRead(assemblyPath);
        using var peReader = new PEReader(stream);
        MetadataReader reader = peReader.GetMetadataReader();

        bool found = false;
        int ctorCount = 0;
        bool hasParamless = false;
        bool hasSingleParam = false;
        var interfaces = new List<string>();
        var methods = new List<string>();

        foreach (var typeHandle in reader.TypeDefinitions)
        {
            var typeDef = reader.GetTypeDefinition(typeHandle);
            string typeName = reader.GetString(typeDef.Name);
            string typeNamespace = reader.GetString(typeDef.Namespace);

            if (typeName == "WpfDialogService" && typeNamespace == "IToolkit.App.Services")
            {
                found = true;

                // Inspect Interfaces
                foreach (var ifaceHandle in typeDef.GetInterfaceImplementations())
                {
                    var iface = reader.GetInterfaceImplementation(ifaceHandle);
                    string ifaceName = iface.Interface.Kind switch
                    {
                        HandleKind.TypeReference => reader.GetString(reader.GetTypeReference((TypeReferenceHandle)iface.Interface).Name),
                        HandleKind.TypeDefinition => reader.GetString(reader.GetTypeDefinition((TypeDefinitionHandle)iface.Interface).Name),
                        _ => string.Empty
                    };
                    interfaces.Add(ifaceName);
                }

                // Inspect Methods and Constructors
                foreach (var methodHandle in typeDef.GetMethods())
                {
                    var methodDef = reader.GetMethodDefinition(methodHandle);
                    string methodName = reader.GetString(methodDef.Name);
                    methods.Add(methodName);

                    if (methodName == ".ctor")
                    {
                        ctorCount++;
                        var sigReader = reader.GetBlobReader(methodDef.Signature);
                        // Signature byte 0: CallingConvention (HASTHIS = 0x20)
                        sigReader.ReadByte();
                        // Signature byte 1: Parameter Count
                        int paramCount = sigReader.ReadCompressedInteger();
                        if (paramCount == 0)
                        {
                            hasParamless = true;
                        }
                        else if (paramCount == 1)
                        {
                            hasSingleParam = true;
                        }
                    }
                }
                break;
            }
        }

        return new WpfMetadataInfo(found, ctorCount, hasParamless, hasSingleParam, interfaces, methods);
    }

    // =========================================================================
    // 1. REFLECTION INSTANTIATION VIA PARAMETERLESS CONSTRUCTORS
    // =========================================================================

    [Fact]
    public void MockDialogService_ReflectionInstantiation_ParameterlessConstructor_Succeeds()
    {
        Type mockType = typeof(MockDialogService);

        // Verify explicit parameterless constructor exists
        ConstructorInfo? parameterlessCtor = mockType.GetConstructor(Type.EmptyTypes);
        Assert.NotNull(parameterlessCtor);

        // Reflection instantiation via Activator.CreateInstance(typeof(MockDialogService))
        object? instance = Activator.CreateInstance(mockType);
        Assert.NotNull(instance);
        Assert.IsType<MockDialogService>(instance);

        var service = (MockDialogService)instance;
        Assert.True(service.ConfirmationResult);
        Assert.True(service.OpenFolderInExplorerResult);
        Assert.Equal(0, service.ConfirmCallCount);
        Assert.Equal(0, service.OpenFolderInExplorerCallCount);
    }

    [Fact]
    public void MockDialogService_SingleParameterConstructor_SupportsLoggerInjection()
    {
        ConstructorInfo? mockLoggerCtor = typeof(MockDialogService).GetConstructor(new[] { typeof(IActivityLogger) });
        Assert.NotNull(mockLoggerCtor);

        object? mockInstance = Activator.CreateInstance(typeof(MockDialogService), new object?[] { _testLogger });
        Assert.NotNull(mockInstance);
        Assert.IsType<MockDialogService>(mockInstance);
    }

    [Fact]
    public void WpfDialogService_MetadataAndReflection_ParameterlessConstructor_Verified()
    {
        // 1. Verify compiled PE metadata from iToolKit.dll (architecture-independent check)
        var meta = InspectWpfDialogServiceMetadata();
        Assert.True(meta.Found, "IToolkit.App.Services.WpfDialogService must exist in iToolKit.dll metadata");
        Assert.True(meta.HasParameterlessConstructor, "WpfDialogService must have a parameterless constructor (.ctor()) in binary metadata");
        Assert.True(meta.HasSingleParameterConstructor, "WpfDialogService must have a 1-parameter constructor (.ctor(IActivityLogger)) in binary metadata");
        Assert.Contains("IDialogService", meta.InterfaceNames);
        Assert.Contains("ISafetyConfirmationService", meta.InterfaceNames);
        Assert.Contains("ShowOpenFileDialog", meta.MethodNames);
        Assert.Contains("ShowSaveFileDialog", meta.MethodNames);
        Assert.Contains("ShowOpenFolderDialog", meta.MethodNames);
        Assert.Contains("OpenFolderInExplorer", meta.MethodNames);
        Assert.Contains("Confirm", meta.MethodNames);
        Assert.Contains("ConfirmAsync", meta.MethodNames);

        // 2. Source code verification
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string wpfSource = File.ReadAllText(Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs"));
        Assert.Contains("public WpfDialogService() : this(null)", wpfSource);
        Assert.Contains("public WpfDialogService(IActivityLogger? logger = null)", wpfSource);

        // 3. If running on architecture compatible with iToolKit.dll, execute Activator.CreateInstance
        var (loadSuccess, wpfType, _) = TryLoadWpfDialogServiceType();
        if (loadSuccess && wpfType != null)
        {
            object? instance = Activator.CreateInstance(wpfType);
            Assert.NotNull(instance);
            Assert.Equal("WpfDialogService", instance.GetType().Name);

            object? loggerInstance = Activator.CreateInstance(wpfType, new object?[] { _testLogger });
            Assert.NotNull(loggerInstance);
        }
    }

    // =========================================================================
    // 2. LOGGING OF FILE AND FOLDER PICKERS (OPEN, CANCEL, SELECT)
    // =========================================================================

    [Fact]
    public void MockDialogService_ShowOpenFileDialog_LogsOpeningSelectionAndCancellation()
    {
        var service = new MockDialogService(_testLogger);

        // Case A: User cancels dialog (SelectedOpenFilePath is null)
        service.SelectedOpenFilePath = null;
        string? cancelResult = service.ShowOpenFileDialog("Select Image", "WIM (*.wim)|*.wim", @"C:\Images");
        Assert.Null(cancelResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Equal(LogLevel.Info, _loggedEntries[0].Level);
        Assert.Contains("Showing OpenFileDialog: Title='Select Image', Filter='WIM (*.wim)|*.wim', DefaultPath='C:\\Images'.", _loggedEntries[0].Message);

        Assert.Equal("DialogService", _loggedEntries[1].Component);
        Assert.Equal(LogLevel.Info, _loggedEntries[1].Level);
        Assert.Contains("OpenFileDialog cancelled by user (Title='Select Image').", _loggedEntries[1].Message);

        _loggedEntries.Clear();

        // Case B: User selects a file (SelectedOpenFilePath is non-null)
        service.SelectedOpenFilePath = @"C:\Images\custom_install.wim";
        string? selectResult = service.ShowOpenFileDialog("Select Image", "WIM (*.wim)|*.wim", @"C:\Images");
        Assert.Equal(@"C:\Images\custom_install.wim", selectResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Contains("Showing OpenFileDialog", _loggedEntries[0].Message);

        Assert.Equal("DialogService", _loggedEntries[1].Component);
        Assert.Equal(LogLevel.Info, _loggedEntries[1].Level);
        Assert.Contains("OpenFileDialog selected: 'C:\\Images\\custom_install.wim' (Title='Select Image').", _loggedEntries[1].Message);
    }

    [Fact]
    public void MockDialogService_ShowSaveFileDialog_LogsOpeningSelectionAndCancellation()
    {
        var service = new MockDialogService(_testLogger);

        // Case A: User cancels dialog
        service.SelectedSaveFilePath = null;
        string? cancelResult = service.ShowSaveFileDialog("Export PST", "PST (*.pst)|*.pst", "Default.pst", @"D:\Backups");
        Assert.Null(cancelResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Contains("Showing SaveFileDialog: Title='Export PST', Filter='PST (*.pst)|*.pst', DefaultFileName='Default.pst', DefaultPath='D:\\Backups'.", _loggedEntries[0].Message);

        Assert.Equal("DialogService", _loggedEntries[1].Component);
        Assert.Contains("SaveFileDialog cancelled by user (Title='Export PST').", _loggedEntries[1].Message);

        _loggedEntries.Clear();

        // Case B: User selects save destination
        service.SelectedSaveFilePath = @"D:\Backups\ExportedArchive.pst";
        string? selectResult = service.ShowSaveFileDialog("Export PST", "PST (*.pst)|*.pst", "Default.pst", @"D:\Backups");
        Assert.Equal(@"D:\Backups\ExportedArchive.pst", selectResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Contains("Showing SaveFileDialog", _loggedEntries[0].Message);
        Assert.Contains("SaveFileDialog selected: 'D:\\Backups\\ExportedArchive.pst' (Title='Export PST').", _loggedEntries[1].Message);
    }

    [Fact]
    public void MockDialogService_ShowOpenFolderDialog_LogsOpeningSelectionAndCancellation()
    {
        var service = new MockDialogService(_testLogger);

        // Case A: User cancels dialog
        service.SelectedFolderPath = null;
        string? cancelResult = service.ShowOpenFolderDialog("Select Target Directory", @"E:\Data");
        Assert.Null(cancelResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Contains("Showing OpenFolderDialog: Title='Select Target Directory', DefaultPath='E:\\Data'.", _loggedEntries[0].Message);

        Assert.Equal("DialogService", _loggedEntries[1].Component);
        Assert.Contains("OpenFolderDialog cancelled by user (Title='Select Target Directory').", _loggedEntries[1].Message);

        _loggedEntries.Clear();

        // Case B: User selects a folder
        service.SelectedFolderPath = @"E:\Data\UserProfiles";
        string? selectResult = service.ShowOpenFolderDialog("Select Target Directory", @"E:\Data");
        Assert.Equal(@"E:\Data\UserProfiles", selectResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Contains("Showing OpenFolderDialog", _loggedEntries[0].Message);
        Assert.Contains("OpenFolderDialog selected: 'E:\\Data\\UserProfiles' (Title='Select Target Directory').", _loggedEntries[1].Message);
    }

    // =========================================================================
    // 3. LOGGING OF EXPLORER LAUNCHES
    // =========================================================================

    [Fact]
    public void MockDialogService_OpenFolderInExplorer_LogsValidAndNullOrWhitespace()
    {
        var service = new MockDialogService(_testLogger);

        // Case A: Valid path
        bool validResult = service.OpenFolderInExplorer(@"C:\Logs\iToolKit");
        Assert.True(validResult);
        Assert.Single(_loggedEntries);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Equal(LogLevel.Info, _loggedEntries[0].Level);
        Assert.Contains("Launching Windows Explorer for folder: 'C:\\Logs\\iToolKit'.", _loggedEntries[0].Message);

        _loggedEntries.Clear();

        // Case B: Null path
        bool nullResult = service.OpenFolderInExplorer(null!);
        Assert.True(nullResult); // Mock defaults to OpenFolderInExplorerResult
        Assert.Single(_loggedEntries);
        Assert.Equal("DialogService", _loggedEntries[0].Component);
        Assert.Equal(LogLevel.Warning, _loggedEntries[0].Level);
        Assert.Contains("OpenFolderInExplorer called with null or empty path.", _loggedEntries[0].Message);

        _loggedEntries.Clear();

        // Case C: Empty path
        service.OpenFolderInExplorer(string.Empty);
        Assert.Single(_loggedEntries);
        Assert.Equal(LogLevel.Warning, _loggedEntries[0].Level);
        Assert.Contains("OpenFolderInExplorer called with null or empty path.", _loggedEntries[0].Message);

        _loggedEntries.Clear();

        // Case D: Whitespace path
        service.OpenFolderInExplorer("   ");
        Assert.Single(_loggedEntries);
        Assert.Equal(LogLevel.Warning, _loggedEntries[0].Level);
        Assert.Contains("OpenFolderInExplorer called with null or empty path.", _loggedEntries[0].Message);
    }

    [Fact]
    public void WpfDialogService_SourceVerification_OpenFolderInExplorer_LoggingAndExceptionContract()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string wpfSource = File.ReadAllText(Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs"));

        // 1. Verify null/empty guard logs Warning and returns false
        Assert.Contains("if (string.IsNullOrWhiteSpace(folderPath))", wpfSource);
        Assert.Contains("_logger?.LogWarning(\"DialogService\", \"OpenFolderInExplorer called with null or empty path.\");", wpfSource);

        // 2. Verify non-existent folder guard logs Warning and returns false
        Assert.Contains("_logger?.LogWarning(\"DialogService\", $\"Directory does not exist for Explorer launch: '{folderPath}'.\");", wpfSource);

        // 3. Verify launch info log before Process.Start
        Assert.Contains("_logger?.LogInfo(\"DialogService\", $\"Launching Windows Explorer for folder: '{folderPath}'.\");", wpfSource);

        // 4. Verify catch block logs Error with exception details and returns false
        Assert.Contains("catch (Exception ex)", wpfSource);
        Assert.Contains("_logger?.LogError(\"DialogService\", $\"Failed to launch Windows Explorer for folder '{folderPath}'\", ex);", wpfSource);
        Assert.Contains("return false;", wpfSource);
    }

    // =========================================================================
    // 4. LOGGING OF SAFETY CONFIRMATION PROMPTS (CONFIRM & CONFIRMASYNC)
    // =========================================================================

    [Fact]
    public void MockDialogService_Confirm_TrueChoice_LogsPromptAndConfirmedOutcome()
    {
        var service = new MockDialogService(_testLogger)
        {
            ConfirmationResult = true
        };

        bool result = service.Confirm("Disk Wipe", "Are you sure you want to clean drive C:?", "Data loss is irreversible.");
        Assert.True(result);

        Assert.Equal(2, _loggedEntries.Count);

        // 1. Prompt entry (Warning level, SafetyConfirmation component)
        Assert.Equal("SafetyConfirmation", _loggedEntries[0].Component);
        Assert.Equal(LogLevel.Warning, _loggedEntries[0].Level);
        Assert.Contains("Safety confirmation prompt displayed: 'Disk Wipe' - 'Are you sure you want to clean drive C:?\n\nWARNING:\nData loss is irreversible.'.", _loggedEntries[0].Message);

        // 2. Result entry (Info level, Confirmed (Yes))
        Assert.Equal("SafetyConfirmation", _loggedEntries[1].Component);
        Assert.Equal(LogLevel.Info, _loggedEntries[1].Level);
        Assert.Contains("Safety confirmation 'Disk Wipe' result: Confirmed (Yes).", _loggedEntries[1].Message);
    }

    [Fact]
    public void MockDialogService_Confirm_FalseChoice_LogsPromptAndDismissedOutcome()
    {
        var service = new MockDialogService(_testLogger)
        {
            ConfirmationResult = false
        };

        bool result = service.Confirm("Scrub Office", "Remove Office suite?", "All Office apps will be removed.");
        Assert.False(result);

        Assert.Equal(2, _loggedEntries.Count);

        // 1. Prompt entry
        Assert.Equal("SafetyConfirmation", _loggedEntries[0].Component);
        Assert.Equal(LogLevel.Warning, _loggedEntries[0].Level);
        Assert.Contains("Safety confirmation prompt displayed: 'Scrub Office'", _loggedEntries[0].Message);

        // 2. Result entry (Warning level, Dismissed (No))
        Assert.Equal("SafetyConfirmation", _loggedEntries[1].Component);
        Assert.Equal(LogLevel.Warning, _loggedEntries[1].Level);
        Assert.Contains("Safety confirmation 'Scrub Office' result: Dismissed (No).", _loggedEntries[1].Message);
    }

    [Fact]
    public async Task MockDialogService_ConfirmAsync_TrueAndFalse_LogsAccurately()
    {
        var service = new MockDialogService(_testLogger);

        // Async True
        service.ConfirmationResult = true;
        bool trueResult = await service.ConfirmAsync("Reset Winsock", "Reset network catalog?", "Active connections will drop.");
        Assert.True(trueResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Contains("Confirmed (Yes)", _loggedEntries[1].Message);

        _loggedEntries.Clear();

        // Async False
        service.ConfirmationResult = false;
        bool falseResult = await service.ConfirmAsync("Reset Winsock", "Reset network catalog?", "Active connections will drop.");
        Assert.False(falseResult);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Contains("Dismissed (No)", _loggedEntries[1].Message);
    }

    [Fact]
    public void MockDialogService_Confirm_WithoutWarningDetails_OmitsWarningHeaderInPrompt()
    {
        var service = new MockDialogService(_testLogger)
        {
            ConfirmationResult = true
        };

        service.Confirm("Simple Prompt", "Do you wish to proceed?", string.Empty);

        Assert.Equal(2, _loggedEntries.Count);
        Assert.Contains("Safety confirmation prompt displayed: 'Simple Prompt' - 'Do you wish to proceed?'.", _loggedEntries[0].Message);
        Assert.DoesNotContain("WARNING:", _loggedEntries[0].Message);
    }

    // =========================================================================
    // 5. NULL LOGGER ROBUSTNESS (PARAMETERLESS CONSTRUCTORS)
    // =========================================================================

    [Fact]
    public async Task MockDialogService_ParameterlessConstructor_SafelyOperatesWithoutNullReferenceException()
    {
        var mock = new MockDialogService();
        Assert.Null(Record.Exception(() => mock.ShowOpenFileDialog("Title", "Filter")));
        Assert.Null(Record.Exception(() => mock.ShowSaveFileDialog("Title", "Filter")));
        Assert.Null(Record.Exception(() => mock.ShowOpenFolderDialog("Title")));
        Assert.Null(Record.Exception(() => mock.OpenFolderInExplorer("C:\\NonExistent")));
        Assert.Null(Record.Exception(() => mock.Confirm("Title", "Msg", "Warn")));
        await mock.ConfirmAsync("Title", "Msg", "Warn");
    }

    // =========================================================================
    // 6. STATIC ANALYSIS OF APP.XAML.CS DIALOG LOGGING
    // =========================================================================

    [Fact]
    public void AppXamlCs_ContainsDialogServiceLoggingForMessageBoxCalls()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        Assert.True(File.Exists(appXamlCsPath));

        string code = File.ReadAllText(appXamlCsPath);

        // 1. Dispatcher Unhandled Exception Dialog
        Assert.Contains("logger.LogError(\"DialogService\", \"Displayed unhandled exception error dialog.\", args.Exception);", code);
        Assert.Contains("logger.LogInfo(\"DialogService\", \"User dismissed unhandled exception error dialog: [iToolKit Error] Result=OK\");", code);

        // 2. Elevation Required Prompt Dialog
        Assert.Contains("appLogger.LogWarning(\"DialogService\", \"Displayed elevation required dialog prompt.\");", code);
        Assert.Contains("appLogger.LogInfo(\"DialogService\", \"User dismissed elevation required dialog prompt: [iToolKit Error] Result=OK\");", code);

        // 3. Fatal Startup Exception Dialog
        Assert.Contains("logger.LogError(\"DialogService\", \"Displayed fatal startup error dialog.\", ex);", code);
        Assert.Contains("logger.LogInfo(\"DialogService\", \"User dismissed fatal startup error dialog: [iToolKit Error] Result=OK\");", code);
    }
}
