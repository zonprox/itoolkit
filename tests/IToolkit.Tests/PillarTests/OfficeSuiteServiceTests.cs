namespace IToolkit.Tests.PillarTests;

using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class OfficeSuiteServiceTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly OfficeSuiteService _service;

    public OfficeSuiteServiceTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _service = new OfficeSuiteService(_processRunner, _fileSystem, _registry, _atomicRegistry, _lockGuard);
    }

    [Fact]
    public void RepairClickToRunService_StartsService_AndCleansCorruptZeroByteXmlFiles()
    {
        string progData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        string releasesDir = Path.Combine(progData, "Microsoft", "ClickToRun", "ProductReleases");
        _fileSystem.CreateDirectory(releasesDir);

        string zeroByteXml = Path.Combine(releasesDir, "corrupted.xml");
        string validXml = Path.Combine(releasesDir, "valid.xml");

        _fileSystem.WriteAllBytes(zeroByteXml, Array.Empty<byte>());
        _fileSystem.WriteAllText(validXml, "<release id='1'/>");

        bool result = _service.RepairClickToRunService();

        Assert.True(result);
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start ClickToRunSvc"));
        Assert.False(_fileSystem.FileExists(zeroByteXml), "0-byte XML files should be deleted");
        Assert.True(_fileSystem.FileExists(validXml), "Valid XML files should be preserved");
    }

    [Fact]
    public void RunClickToRunRepair_InvokesCorrectArguments_ForQuickAndOnline()
    {
        var quickRes = _service.RunClickToRunRepair(online: false);
        var onlineRes = _service.RunClickToRunRepair(online: true);

        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("RepairType=QuickRepair"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("RepairType=FullRepair"));
    }

    [Fact]
    public void ResetOfficeIdentityCache_DeletesRegistryIdentities_AndPurgesTokenFolders()
    {
        string identityKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity\Identities";
        string profileKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity\Profiles";
        _registry.CreateKey(identityKey);
        _registry.CreateKey(profileKey);

        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string idCacheDir = Path.Combine(localAppData, "Microsoft", "IdentityCache");
        string oneAuthDir = Path.Combine(localAppData, "Microsoft", "OneAuth");
        _fileSystem.CreateDirectory(idCacheDir);
        _fileSystem.CreateDirectory(oneAuthDir);

        var result = _service.ResetOfficeIdentityCache();

        Assert.True(result.Success);
        Assert.False(_registry.KeyExists(identityKey));
        Assert.False(_registry.KeyExists(profileKey));
        Assert.False(_fileSystem.DirectoryExists(idCacheDir));
        Assert.False(_fileSystem.DirectoryExists(oneAuthDir));
    }

    [Theory]
    [InlineData(true, 1)]
    [InlineData(false, 0)]
    public void SetHardwareAcceleration_UpdatesRegistryKeysAcrossOfficeSuite(bool disable, int expectedDword)
    {
        var result = _service.SetHardwareAcceleration(disable);

        Assert.True(result.Success);

        var keys = new[]
        {
            @"HKCU\Software\Microsoft\Office\16.0\Common\Graphics",
            @"HKCU\Software\Microsoft\Office\16.0\Word\Options",
            @"HKCU\Software\Microsoft\Office\16.0\Excel\Options",
            @"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Options"
        };

        foreach (var key in keys)
        {
            Assert.True(_registry.KeyExists(key));
            var val = _registry.GetValue<int>(key, "DisableHardwareAcceleration");
            Assert.Equal(expectedDword, val);
        }

        var pptSlideVal = _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Options", "DisableSlideShowHardwareAcceleration");
        Assert.Equal(expectedDword, pptSlideVal);
    }

    [Fact]
    public void WordQuickRepair_ResetsNormalDotm_DisablesAddIns_CleansLocks_AndResetsRegistry()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        // Setup Normal.dotm
        string templateDir = Path.Combine(appData, "Microsoft", "Templates");
        _fileSystem.CreateDirectory(templateDir);
        string normalDotm = Path.Combine(templateDir, "Normal.dotm");
        _fileSystem.WriteAllText(normalDotm, "dotm_content");

        // Setup startup add-in
        string startupDir = Path.Combine(appData, "Microsoft", "Word", "STARTUP");
        _fileSystem.CreateDirectory(startupDir);
        string addIn = Path.Combine(startupDir, "plugin.dotm");
        _fileSystem.WriteAllText(addIn, "plugin_content");

        // Setup orphaned lock file
        string lockFile = Path.Combine(appData, "~$Document.docx");
        _fileSystem.WriteAllText(lockFile, "lock");

        // Setup Word registry
        _registry.CreateKey(@"HKCU\Software\Microsoft\Office\16.0\Word\Data");
        _registry.CreateKey(@"HKCU\Software\Microsoft\Office\16.0\Word\Options");

        var result = _service.WordQuickRepair();

        Assert.True(result.Success);
        Assert.True(result.NormalDotmReset);
        Assert.False(_fileSystem.FileExists(normalDotm), "Normal.dotm should have been moved/backed up");
        Assert.True(_fileSystem.FileExists(addIn + ".disabled"), "Add-in must be renamed to .disabled");
        Assert.False(_fileSystem.FileExists(lockFile), "Orphaned lock file should be removed");
        Assert.False(_registry.KeyExists(@"HKCU\Software\Microsoft\Office\16.0\Word\Data"));
    }

    [Fact]
    public void ExcelQuickRepair_IsolatesAddIns_PreservingPersonalWorkbook_AndResetsDde()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string xlStart = Path.Combine(appData, "Microsoft", "Excel", "XLSTART");
        _fileSystem.CreateDirectory(xlStart);

        string personalXlsb = Path.Combine(xlStart, "personal.xlsb");
        string rogueAddIn = Path.Combine(xlStart, "bad_macro.xlam");

        _fileSystem.WriteAllText(personalXlsb, "personal_macros");
        _fileSystem.WriteAllText(rogueAddIn, "rogue_content");

        // Excel options
        _registry.CreateKey(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options");
        _registry.SetValue(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options", "IgnoreRemoteRequests", 1, RegistryValueKind.DWord);

        var result = _service.ExcelQuickRepair();

        Assert.True(result.Success);
        Assert.True(_fileSystem.FileExists(personalXlsb), "personal.xlsb must be preserved!");
        Assert.False(_fileSystem.FileExists(rogueAddIn), "Non-personal add-ins should be isolated");

        // DDE repair: IgnoreRemoteRequests must be 0, Calculation must be 1
        var ignoreReq = _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options", "IgnoreRemoteRequests");
        var calc = _registry.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options", "Calculation");
        Assert.Equal(0, ignoreReq);
        Assert.Equal(1, calc);
    }

    [Fact]
    public void PowerPointQuickRepair_PurgesCache_AndResiliency()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string pptCache = Path.Combine(localAppData, "Microsoft", "Office", "16.0", "PowerPoint", "Cache");
        _fileSystem.CreateDirectory(pptCache);

        string resKey = @"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Resiliency\DisabledItems";
        _registry.CreateKey(resKey);

        var result = _service.PowerPointQuickRepair();

        Assert.True(result.Success);
        Assert.False(_fileSystem.DirectoryExists(pptCache));
        Assert.False(_registry.KeyExists(resKey));
    }

    [Fact]
    public void ScrubOfficeSuiteCleanly_TerminatesProcesses_StopsServices_AndRemovesTokens()
    {
        _processRunner.AddProcess(101, "WINWORD");
        _processRunner.AddProcess(102, "EXCEL");

        string tokensPath = @"C:\ProgramData\Microsoft\OfficeSoftwareProtectionPlatform\tokens.dat";
        _fileSystem.WriteAllText(tokensPath, "licensing_tokens");

        var result = _service.ScrubOfficeSuiteCleanly();

        Assert.True(result.Success);
        Assert.Equal(2, result.ProcessesTerminated);
        Assert.Equal(3, result.ServicesStopped);
        Assert.False(_fileSystem.FileExists(tokensPath));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("schtasks.exe /delete"));
    }
}
