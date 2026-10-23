namespace IToolkit.Tests.PillarTests;

using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge tests authored by Challenger 1 to stress-test Pillars 1, 2, and 3.
/// </summary>
public class Pillars123EmpiricalChallengeTests
{
    private readonly MockRegistryService _registry;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockProcessRunner _processRunner;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly ResourceGuard _resourceGuard;

    private readonly OutlookService _outlookService;
    private readonly ConnectivityService _connectivityService;
    private readonly PrinterService _printerService;
    private readonly SystemHealthService _systemHealthService;

    public Pillars123EmpiricalChallengeTests()
    {
        _registry = new MockRegistryService();
        _fileSystem = new MockFileSystemService();
        _processRunner = new MockProcessRunner();
        _network = new MockNetworkService();
        _wmi = new MockWmiService();

        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _resourceGuard = new ResourceGuard(_fileSystem);

        _outlookService = new OutlookService(_registry, _atomicRegistry, _fileSystem, _lockGuard, _resourceGuard);
        _connectivityService = new ConnectivityService(_network, _processRunner, _registry, _atomicRegistry);
        _printerService = new PrinterService(_processRunner, _fileSystem, _registry, _atomicRegistry, _lockGuard, _wmi);
        _systemHealthService = new SystemHealthService(_processRunner, _fileSystem);
    }

    #region Pillar 2: MAPI Binary Decoding & Outlook Empirical Tests

    [Fact]
    public void MapiUnicodeDecoder_HandlesBoundaryAndCorruptByteSequences()
    {
        // 1. Null / empty / single byte
        Assert.Equal(string.Empty, OutlookService.DecodeMapiUnicode(null!));
        Assert.Equal(string.Empty, OutlookService.DecodeMapiUnicode(Array.Empty<byte>()));
        Assert.Equal(string.Empty, OutlookService.DecodeMapiUnicode(new byte[] { 0x41 }));

        // 2. Exact null terminator at position 0
        byte[] immediateNull = new byte[] { 0x00, 0x00, 0x41, 0x00 };
        Assert.Equal(string.Empty, OutlookService.DecodeMapiUnicode(immediateNull));

        // 3. String with no null terminator
        string plain = "C:\\Outlook\\Store.pst";
        byte[] noNull = Encoding.Unicode.GetBytes(plain);
        Assert.Equal(plain, OutlookService.DecodeMapiUnicode(noNull));

        // 4. String with trailing garbage after null terminator
        byte[] withGarbage = Encoding.Unicode.GetBytes(plain + "\0EXTRA_DATA_SHOULD_BE_IGNORED");
        Assert.Equal(plain, OutlookService.DecodeMapiUnicode(withGarbage));

        // 5. Odd length byte array without null terminator
        byte[] oddBytes = new byte[] { 0x41, 0x00, 0x42, 0x00, 0xFF }; // "AB" + trailing orphan byte
        string oddDecoded = OutlookService.DecodeMapiUnicode(oddBytes);
        Assert.StartsWith("AB", oddDecoded);
    }

    [Fact]
    public void MapiAnsiDecoder_HandlesBoundaryAndCorruptByteSequences()
    {
        // 1. Null / empty
        Assert.Equal(string.Empty, OutlookService.DecodeMapiAnsi(null!));
        Assert.Equal(string.Empty, OutlookService.DecodeMapiAnsi(Array.Empty<byte>()));

        // 2. Immediate null terminator
        Assert.Equal(string.Empty, OutlookService.DecodeMapiAnsi(new byte[] { 0x00, 0x41, 0x42 }));

        // 3. Normal path with null terminator and trailing noise
        string ansiPath = "C:\\Data\\Archive.ost";
        byte[] ansiBytes = Encoding.ASCII.GetBytes(ansiPath + "\0trailing_garbage");
        Assert.Equal(ansiPath, OutlookService.DecodeMapiAnsi(ansiBytes));

        // 4. No null terminator
        byte[] noNull = Encoding.ASCII.GetBytes(ansiPath);
        Assert.Equal(ansiPath, OutlookService.DecodeMapiAnsi(noNull));
    }

    [Fact]
    public void DiscoverDataFiles_DiscoversBothAnsiAndUnicodeMapiProfilesRecursively()
    {
        // Setup Unicode profile
        string uniProfileKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Default\UniSubKey";
        _registry.CreateKey(uniProfileKey);
        string uniPath = @"C:\Mail\UnicodeMailbox.pst";
        _registry.SetValue(uniProfileKey, "001f6700", Encoding.Unicode.GetBytes(uniPath + "\0"), RegistryValueKind.Binary);
        _registry.SetValue(uniProfileKey, "001f3001", Encoding.Unicode.GetBytes("Unicode Mailbox\0"), RegistryValueKind.Binary);
        _fileSystem.WriteAllBytes(uniPath, new byte[5000]);

        // Setup ANSI profile under Windows Messaging Subsystem
        string ansiProfileKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles\Legacy\AnsiSubKey";
        _registry.CreateKey(ansiProfileKey);
        string ansiPath = @"C:\Mail\AnsiStore.ost";
        _registry.SetValue(ansiProfileKey, "001e6700", Encoding.ASCII.GetBytes(ansiPath + "\0"), RegistryValueKind.Binary);
        _fileSystem.WriteAllBytes(ansiPath, new byte[3000]);

        var discovered = _outlookService.DiscoverDataFiles();

        Assert.Equal(2, discovered.Count);

        var uniEntry = discovered.FirstOrDefault(d => d.FilePath.Equals(uniPath, StringComparison.OrdinalIgnoreCase));
        Assert.NotNull(uniEntry);
        Assert.True(uniEntry.IsPst);
        Assert.False(uniEntry.IsOst);
        Assert.Equal("Unicode Mailbox", uniEntry.DisplayName);
        Assert.Equal(5000, uniEntry.FileSizeBytes);

        var ansiEntry = discovered.FirstOrDefault(d => d.FilePath.Equals(ansiPath, StringComparison.OrdinalIgnoreCase));
        Assert.NotNull(ansiEntry);
        Assert.True(ansiEntry.IsOst);
        Assert.False(ansiEntry.IsPst);
        Assert.Equal(3000, ansiEntry.FileSizeBytes);
    }

    [Fact]
    public void QuickMailRepair_StrictlyPurgesNonAutocompleteRoamCache_AndSetsImmediateSend()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string roamCache = Path.Combine(localAppData, "Microsoft", "Outlook", "RoamCache");
        _fileSystem.CreateDirectory(roamCache);

        // Populate RoamCache files
        string auto1 = Path.Combine(roamCache, "Stream_Autocomplete_0_ABCDEF123456.dat");
        string auto2 = Path.Combine(roamCache, "stream_autocomplete_lowercase.dat");
        string calendarCache = Path.Combine(roamCache, "Stream_Calendar_01.dat");
        string generalCache = Path.Combine(roamCache, "RoamCache_Index.dat");
        string falseAuto = Path.Combine(roamCache, "Stream_Autocomplete_NotDat.txt");

        _fileSystem.WriteAllText(auto1, "nk2_data_1");
        _fileSystem.WriteAllText(auto2, "nk2_data_2");
        _fileSystem.WriteAllText(calendarCache, "calendar_data");
        _fileSystem.WriteAllText(generalCache, "index_data");
        _fileSystem.WriteAllText(falseAuto, "wrong_extension");

        var repairResult = _outlookService.QuickMailAndCacheRepair();

        Assert.True(repairResult.Success);
        Assert.True(repairResult.StuckOutboxCleared);
        Assert.True(repairResult.AutocompletePreserved);
        Assert.True(repairResult.RoamCacheCleaned);

        // Autocomplete .dat files MUST exist
        Assert.True(_fileSystem.FileExists(auto1));
        Assert.True(_fileSystem.FileExists(auto2));

        // Other cache files MUST be purged
        Assert.False(_fileSystem.FileExists(calendarCache));
        Assert.False(_fileSystem.FileExists(generalCache));
        Assert.False(_fileSystem.FileExists(falseAuto));

        // Registry check: "Send Mail Immediately" must be DWORD 1
        string mailOpt = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Options\Mail";
        Assert.Equal(1, _registry.GetValue<int>(mailOpt, "Send Mail Immediately"));
    }

    [Fact]
    public void ExpandDataFileLimitsTo100GB_SetsAllFourDwordValuesInAllFourHives()
    {
        var result = _outlookService.ExpandDataFileLimitsTo100GB();

        Assert.True(result.Success);

        string[] targetKeys =
        {
            @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\PST",
            @"HKCU\Software\Microsoft\Office\16.0\Outlook\PST",
            @"HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\OST",
            @"HKCU\Software\Microsoft\Office\16.0\Outlook\OST"
        };

        foreach (var key in targetKeys)
        {
            Assert.True(_registry.KeyExists(key), $"Key '{key}' must exist");
            Assert.Equal(102400, _registry.GetValue<int>(key, "MaxLargeFileSize"));
            Assert.Equal(97280, _registry.GetValue<int>(key, "WarnLargeFileSize"));
            Assert.Equal(102400, _registry.GetValue<int>(key, "MaxFileSize"));
            Assert.Equal(97280, _registry.GetValue<int>(key, "WarnFileSize"));

            Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(key, "MaxLargeFileSize"));
            Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(key, "WarnLargeFileSize"));
            Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(key, "MaxFileSize"));
            Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(key, "WarnFileSize"));
        }
    }

    #endregion

    #region Pillar 3: Connectivity & Printer Empirical Tests

    [Fact]
    public void ConfigureSmbSharing_ConfiguresLanmanParameters_AndRecursivelySetsInterfaceNetbios()
    {
        // Pre-create simulated network interfaces
        string ifacesKey = @"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces";
        _registry.CreateKey(ifacesKey);
        _registry.CreateKey($@"{ifacesKey}\Tcpip_{{A1B2C3D4-0001}}");
        _registry.CreateKey($@"{ifacesKey}\Tcpip_{{A1B2C3D4-0002}}");

        var result = _connectivityService.ConfigureSmbSharing();

        Assert.True(result.Success);
        Assert.True(result.InsecureGuestAuthEnabled);
        Assert.True(result.NetbiosEnabled);

        // LanmanWorkstation check
        string lanman = @"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters";
        Assert.Equal(1, _registry.GetValue<int>(lanman, "AllowInsecureGuestAuth"));
        Assert.Equal(0, _registry.GetValue<int>(lanman, "RequireSecuritySignature"));
        Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(lanman, "AllowInsecureGuestAuth"));
        Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(lanman, "RequireSecuritySignature"));

        // NetBT Parameters root
        string netbt = @"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters";
        Assert.Equal(1, _registry.GetValue<int>(netbt, "NetbiosOptions"));
        Assert.Equal(RegistryValueKind.DWord, _registry.GetValueKind(netbt, "NetbiosOptions"));

        // NetBT interface subkeys
        Assert.Equal(1, _registry.GetValue<int>($@"{ifacesKey}\Tcpip_{{A1B2C3D4-0001}}", "NetbiosOptions"));
        Assert.Equal(1, _registry.GetValue<int>($@"{ifacesKey}\Tcpip_{{A1B2C3D4-0002}}", "NetbiosOptions"));

        // 5 SMB services auto & started
        foreach (var svc in ConnectivityService.SmbServices)
        {
            Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals($"sc.exe config {svc} start= auto"));
            Assert.Contains(_processRunner.ExecutedCommands, c => c.Equals($"net start {svc}"));
        }
    }

    [Theory]
    [InlineData("0x0000011B", true)]
    [InlineData("0X00000709", true)]
    [InlineData("0x0000007c", true)]
    [InlineData("0x0000007E", true)]
    [InlineData("0x00000BCB", true)]
    [InlineData("0x00000002", true)]
    [InlineData("0x00000006", true)]
    [InlineData("0x00000057", true)]
    [InlineData("0x000003E3", true)]
    [InlineData("spoolercrash", true)]
    [InlineData("NEPORTCONFLICT", true)]
    [InlineData("RefreshConnections", true)]
    [InlineData("NonExistentErrorCode", false)]
    public void RemediatePrinterError_SupportsAll12CatalogCodesCaseInsensitively(string code, bool expectedSuccess)
    {
        var result = _printerService.RemediatePrinterError(code);

        Assert.Equal(expectedSuccess, result.Success);
        Assert.Equal(expectedSuccess, result.PolicyApplied);
        if (!expectedSuccess)
        {
            Assert.Equal("Unknown error code", result.RemediationAction);
        }
    }

    [Fact]
    public void RemediatePrinterError_ThrowsArgumentException_OnNullOrWhitespace()
    {
        Assert.Throws<ArgumentNullException>(() => _printerService.RemediatePrinterError(null!));
        Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError("   "));
    }

    [Fact]
    public void RemediatePrinterError_SpecificRemediations_SetCorrectRegistryAndCommands()
    {
        // Test 0x0000011b remediation
        var res11b = _printerService.RemediatePrinterError("0x0000011b");
        Assert.True(res11b.Success);
        Assert.Equal(0, _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Control\Print", "RpcAuthnLevelPrivacyEnabled"));
        Assert.Equal(1, _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "RegisterSpoolerRemoteRpcEndPoint"));

        // Test 0x00000709 remediation
        var res709 = _printerService.RemediatePrinterError("0x00000709");
        Assert.True(res709.Success);
        Assert.Equal(1, _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC", "RpcUseNamedPipeProtocol"));
        Assert.Equal(7, _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC", "RpcProtocols"));
        Assert.Equal(1, _registry.GetValue<int>(@"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows", "UserSelectedDefault"));
        Assert.Equal(1, _registry.GetValue<int>(@"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows", "LegacyDefaultPrinterMode"));

        // Test 0x0000007c remediation
        var res7c = _printerService.RemediatePrinterError("0x0000007c");
        Assert.True(res7c.Success);
        Assert.Equal(1, _registry.GetValue<int>(@"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers", "CopyFilesPolicy"));

        // Test 0x00000bcb remediation
        var resBcb = _printerService.RemediatePrinterError("0x00000bcb");
        Assert.True(resBcb.Success);
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        Assert.Equal(0, _registry.GetValue<int>(pnpKey, "RestrictDriverInstallationToAdministrators"));
        Assert.Equal(1, _registry.GetValue<int>(pnpKey, "NoWarningNoElevationOnInstall"));
        Assert.Equal(2, _registry.GetValue<int>(pnpKey, "UpdatePromptSettings"));
    }

    #endregion

    #region Pillar 1: System Health Storage Cleanup Empirical Tests

    [Fact]
    public void RunUnifiedDiskCleanup_PreservesActiveCbsAndDismLogs_DeletesPersistLogsAndCrashDumps()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";

        string cbsDir = Path.Combine(sysRoot, "Logs", "CBS");
        string dismDir = Path.Combine(sysRoot, "Logs", "DISM");
        _fileSystem.CreateDirectory(cbsDir);
        _fileSystem.CreateDirectory(dismDir);

        string activeCbs = Path.Combine(cbsDir, "CBS.log");
        string persistCbs = Path.Combine(cbsDir, "CbsPersist_20261023_120000.log");
        _fileSystem.WriteAllText(activeCbs, "active_cbs");
        _fileSystem.WriteAllText(persistCbs, "old_cbs");

        string activeDism = Path.Combine(dismDir, "dism.log");
        string persistDism = Path.Combine(dismDir, "dism.log.1");
        _fileSystem.WriteAllText(activeDism, "active_dism");
        _fileSystem.WriteAllText(persistDism, "old_dism");

        string dump = Path.Combine(sysRoot, "MEMORY.DMP");
        _fileSystem.WriteAllBytes(dump, new byte[1000]);

        var result = _systemHealthService.RunUnifiedDiskCleanup(tempAgeHoursThreshold: 24);

        Assert.True(result.Success);
        Assert.True(_fileSystem.FileExists(activeCbs), "Active CBS.log must NEVER be deleted");
        Assert.True(_fileSystem.FileExists(activeDism), "Active dism.log must NEVER be deleted");
        Assert.False(_fileSystem.FileExists(persistCbs), "CbsPersist_*.log should be deleted");
        Assert.False(_fileSystem.FileExists(persistDism), "dism.log.* should be deleted");
        Assert.False(_fileSystem.FileExists(dump), "MEMORY.DMP should be deleted");
    }

    #endregion
}
