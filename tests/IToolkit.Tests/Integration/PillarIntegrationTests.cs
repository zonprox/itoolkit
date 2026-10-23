namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class PillarIntegrationTests
{
    [Fact]
    public void SystemHealth_EndToEndPipeline_DismSfcUpdateResetWmiAndDiskCleanup_ExecutesSuccessfully()
    {
        // Arrange
        var processRunner = new MockProcessRunner();
        var fileSystem = new MockFileSystemService();
        var logger = new TestActivityLogger();
        var systemHealth = new SystemHealthService(processRunner, fileSystem, logger);

        // 1. Configure DISM & SFC results
        processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth",
            new ProcessExecutionResult(0, "The restore operation completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("sfc.exe /scannow",
            new ProcessExecutionResult(1, "Windows Resource Protection found corrupt files and successfully repaired them.", string.Empty, false));

        // 2. Configure Windows Update reset commands
        foreach (var svc in SystemHealthService.WindowsUpdateServices)
        {
            processRunner.SetCommandResult($"net stop {svc} /y", new ProcessExecutionResult(0, $"{svc} stopped.", string.Empty, false));
            processRunner.SetCommandResult($"sc.exe config {svc} start= auto", new ProcessExecutionResult(0, "Config set.", string.Empty, false));
            processRunner.SetCommandResult($"sc.exe config {svc} start= demand", new ProcessExecutionResult(0, "Config set.", string.Empty, false));
            processRunner.SetCommandResult($"net start {svc}", new ProcessExecutionResult(0, $"{svc} started.", string.Empty, false));
        }
        foreach (var dll in SystemHealthService.WindowsUpdateDlls)
        {
            processRunner.SetCommandResult($"regsvr32.exe /s {dll}", new ProcessExecutionResult(0, string.Empty, string.Empty, false));
        }
        processRunner.SetCommandResult("netsh winsock reset", new ProcessExecutionResult(0, "Winsock reset.", string.Empty, false));
        processRunner.SetCommandResult("netsh winhttp reset proxy", new ProcessExecutionResult(0, "Direct access.", string.Empty, false));

        // Seed Windows Update directories
        fileSystem.CreateDirectory(@"C:\Windows\SoftwareDistribution");
        fileSystem.WriteAllText(@"C:\Windows\SoftwareDistribution\ReportingEvents.log", "Stale events");
        fileSystem.CreateDirectory(@"C:\Windows\System32\catroot2");
        fileSystem.WriteAllText(@"C:\Windows\System32\catroot2\timestamp.log", "Catalog log");

        // 3. Configure WMI commands
        processRunner.SetCommandResult("winmgmt.exe /verifyrepository",
            new ProcessExecutionResult(1, "WMI repository is INCONSISTENT", string.Empty, false));
        processRunner.SetCommandResult("winmgmt.exe /salvagerepository",
            new ProcessExecutionResult(0, "WMI repository has been salvaged", string.Empty, false));

        // 4. Configure WinSxS & Storage Cleanup
        processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /StartComponentCleanup",
            new ProcessExecutionResult(0, "Component store cleaned.", string.Empty, false));

        // Seed temp & log files (stale > 24h vs recent < 24h)
        fileSystem.CreateDirectory(@"C:\Windows\Temp");
        fileSystem.WriteAllText(@"C:\Windows\Temp\stale_installer.tmp", "old temporary data");
        fileSystem.SetLastWriteTime(@"C:\Windows\Temp\stale_installer.tmp", DateTime.UtcNow.AddHours(-48));

        fileSystem.WriteAllText(@"C:\Windows\Temp\active_lock.tmp", "recent data in use");
        fileSystem.SetLastWriteTime(@"C:\Windows\Temp\active_lock.tmp", DateTime.UtcNow.AddHours(-2));

        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string cbsDir = Path.Combine(sysRoot, "Logs", "CBS");
        fileSystem.CreateDirectory(cbsDir);
        string persistLog = Path.Combine(cbsDir, "CbsPersist_archive.log");
        fileSystem.WriteAllText(persistLog, "old CBS logs");
        fileSystem.SetLastWriteTime(persistLog, DateTime.UtcNow.AddHours(-72));

        // Act - Step 1: DISM & SFC Combo
        var (dismRes, sfcRes) = systemHealth.RunDismSfcPipeline();

        // Act - Step 2: Windows Update Components Reset
        var wuResult = systemHealth.ResetWindowsUpdateComponents();

        // Act - Step 3: WMI Repository Audit & Salvage
        var wmiResult = systemHealth.RepairWmiRepository();

        // Act - Step 4: Unified Storage Cleanup (24h threshold)
        var storageResult = systemHealth.RunUnifiedDiskCleanup(tempAgeHoursThreshold: 24);

        // Assert
        // DISM & SFC
        Assert.True(dismRes.Success);
        Assert.False(dismRes.NeedsReboot);
        Assert.True(sfcRes.Success);
        Assert.True(sfcRes.IntegrityViolationsFound);
        Assert.True(sfcRes.SuccessfullyRepaired);

        // Windows Update
        Assert.True(wuResult.Success);
        Assert.Equal(4, wuResult.StoppedServices.Count);
        Assert.Equal(2, wuResult.RenamedDirectories.Count);
        Assert.Equal(35, wuResult.ReRegisteredDllCount);
        Assert.Equal(4, wuResult.RestartedServices.Count);

        // WMI
        Assert.True(wmiResult.Success);
        Assert.True(wmiResult.Salvaged);
        Assert.False(wmiResult.Reset);

        // Storage Cleanup
        Assert.True(storageResult.BytesReclaimed > 0);
        Assert.False(fileSystem.FileExists(@"C:\Windows\Temp\stale_installer.tmp"), "Stale file (>48h) should have been deleted.");
        Assert.True(fileSystem.FileExists(@"C:\Windows\Temp\active_lock.tmp"), "Recent file (<2h) must be strictly preserved.");
        Assert.False(fileSystem.FileExists(persistLog), "Stale log file (>72h) should have been deleted.");

        // Activity Logger
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("DISM RestoreHealth followed by SFC"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Windows Update reset completed"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("WMI repository"));
        Assert.Contains(logger.CapturedEntries, e => e.Message.Contains("Unified Storage Cleanup"));
    }

    [Fact]
    public void OfficeOutlook_RemediationPipeline_C2RRepair_TokenPurge_LimitExpansion_PstCloning_ExecutesSuccessfully()
    {
        // Arrange
        var registry = new MockRegistryService();
        var fileSystem = new MockFileSystemService();
        var processRunner = new MockProcessRunner();
        var outlookCom = new MockOutlookComService();
        var atomicRegistry = new AtomicRegistryService(registry, fileSystem);
        var lockGuard = new ProcessLockGuard(processRunner, fileSystem);
        var resourceGuard = new ResourceGuard(fileSystem);
        var logger = new TestActivityLogger();

        var officeSuite = new OfficeSuiteService(processRunner, fileSystem, registry, atomicRegistry, lockGuard, logger);
        var outlookService = new OutlookService(registry, atomicRegistry, fileSystem, lockGuard, resourceGuard, outlookCom, logger);

        // 1. Simulate running Office processes
        processRunner.AddProcess(1001, "OUTLOOK", "Microsoft Outlook", exitsOnClose: true);
        processRunner.AddProcess(1002, "WINWORD", "Microsoft Word", exitsOnClose: true);

        // 2. Configure C2R service commands
        processRunner.SetCommandResult("sc.exe query ClickToRunSvc",
            new ProcessExecutionResult(0, "STATE : 4 RUNNING", string.Empty, false));

        // 3. Seed Office Token / Identity folders
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string oneAuthDir = Path.Combine(localAppData, "Microsoft", "OneAuth");
        string identityCacheDir = Path.Combine(localAppData, "Microsoft", "IdentityCache");
        fileSystem.CreateDirectory(oneAuthDir);
        fileSystem.WriteAllText(Path.Combine(oneAuthDir, "token.dat"), "encrypted_token");
        fileSystem.CreateDirectory(identityCacheDir);
        fileSystem.WriteAllText(Path.Combine(identityCacheDir, "adal.cache"), "adal_token");

        // Seed Identity registry keys
        string identityKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity\Identities";
        registry.CreateKey(identityKey);
        registry.SetValue(identityKey, "DefaultUser", "user@contoso.com", RegistryValueKind.String);

        // 4. Seed source PST file
        string sourcePst = @"C:\Users\TestUser\Documents\Outlook Files\Archive.pst";
        string targetPst = @"D:\OutlookFiles\PrimaryStore2026.pst";
        fileSystem.CreateDirectory(Path.GetDirectoryName(sourcePst)!);
        fileSystem.WriteAllBytes(sourcePst, new byte[2048]);

        // Seed Outlook COM non-excluded user folders
        outlookCom.SeedFolder(sourcePst, "Projects");
        outlookCom.SeedFolder(sourcePst, "Archive2025");
        outlookCom.SeedFolder(sourcePst, "Clients");
        outlookCom.SeedRule(sourcePst, "Move Project Emails");

        // Act - Step 1: Repair C2R Service
        bool c2rServiceRepaired = officeSuite.RepairClickToRunService();

        // Act - Step 2: Reset Office Identity & WAM Tokens (requires closing processes)
        var identityResetResult = officeSuite.ResetOfficeIdentityCache();

        // Act - Step 3: Expand PST/OST registry limits to 100GB
        var limitResult = outlookService.ExpandDataFileLimitsTo100GB();

        // Act - Step 4: Run Bundled New Default PST Pipeline
        var pstResult = outlookService.RunNewDefaultPstPipeline(targetPst, sourcePst);

        // Assert
        Assert.True(c2rServiceRepaired);

        // Running processes were closed
        Assert.False(processRunner.IsProcessRunning("OUTLOOK"));
        Assert.False(processRunner.IsProcessRunning("WINWORD"));

        // Identity Cache purged
        Assert.True(identityResetResult.Success);
        Assert.False(fileSystem.DirectoryExists(oneAuthDir), "OneAuth cache directory should be removed.");
        Assert.False(fileSystem.DirectoryExists(identityCacheDir), "IdentityCache directory should be removed.");

        // Registry limits expanded to 100GB (102400 MB)
        Assert.True(limitResult.Success);
        string pstKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\PST";
        Assert.Equal(102400, registry.GetValue<int>(pstKey, "MaxLargeFileSize"));
        Assert.Equal(97280, registry.GetValue<int>(pstKey, "WarnLargeFileSize"));

        // New default PST pipeline
        Assert.True(pstResult.Success);
        Assert.True(fileSystem.FileExists(targetPst));
        Assert.Equal(3, pstResult.FoldersClonedCount);
        Assert.Equal(1, pstResult.RulesMigratedCount);
        Assert.True(pstResult.IsDefaultSet);

        // Default store registry pointer updated
        string searchKey = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Search";
        Assert.Equal(targetPst, registry.GetValue<string>(searchKey, "DefaultStorePath"));
    }

    [Fact]
    public void NetworkAndPrinter_RemediationPipeline_StackReset_Flush_SpoolerRestart_ErrorCodeRemediation_ExecutesSuccessfully()
    {
        // Arrange
        var registry = new MockRegistryService();
        var fileSystem = new MockFileSystemService();
        var processRunner = new MockProcessRunner();
        var network = new MockNetworkService(fileSystem);
        var wmi = new MockWmiService();
        var atomicRegistry = new AtomicRegistryService(registry, fileSystem);
        var lockGuard = new ProcessLockGuard(processRunner, fileSystem);
        var logger = new TestActivityLogger();

        var connectivity = new ConnectivityService(network, processRunner, registry, atomicRegistry, logger);
        var printer = new PrinterService(processRunner, fileSystem, registry, atomicRegistry, lockGuard, wmi, logger);

        // 1. Configure network command results
        processRunner.SetCommandResult("ipconfig /flushdns", new ProcessExecutionResult(0, "Successfully flushed the DNS Resolver Cache.", string.Empty, false));
        processRunner.SetCommandResult("ipconfig /release", new ProcessExecutionResult(0, "IP released.", string.Empty, false));
        processRunner.SetCommandResult("ipconfig /renew", new ProcessExecutionResult(0, "IP renewed.", string.Empty, false));
        processRunner.SetCommandResult("arp -d *", new ProcessExecutionResult(0, "ARP table cleared.", string.Empty, false));
        processRunner.SetCommandResult("route -f", new ProcessExecutionResult(0, "Route table cleared.", string.Empty, false));
        processRunner.SetCommandResult("netsh winsock reset", new ProcessExecutionResult(0, "Winsock reset successfully.", string.Empty, false));
        processRunner.SetCommandResult("netsh int ip reset", new ProcessExecutionResult(0, "Resetting interface, OK.", string.Empty, false));
        processRunner.SetCommandResult("net stop nlasvc /y", new ProcessExecutionResult(0, "NLA stopped.", string.Empty, false));
        processRunner.SetCommandResult("net start nlasvc", new ProcessExecutionResult(0, "NLA started.", string.Empty, false));
        processRunner.SetCommandResult("netsh winhttp reset proxy", new ProcessExecutionResult(0, "Direct access.", string.Empty, false));

        // 2. Configure spooler service & files
        processRunner.AddProcess(3001, "spoolsv", "Print Spooler SubSystem", exitsOnClose: false); // Hung process
        processRunner.SetCommandResult("net stop spooler /y", new ProcessExecutionResult(0, "Spooler stopped.", string.Empty, false));
        processRunner.SetCommandResult("net start spooler", new ProcessExecutionResult(0, "Spooler started.", string.Empty, false));

        string spoolDir = @"C:\Windows\System32\spool\PRINTERS";
        fileSystem.CreateDirectory(spoolDir);
        fileSystem.WriteAllText(Path.Combine(spoolDir, "00001.spl"), "corrupt print spool payload");
        fileSystem.WriteAllText(Path.Combine(spoolDir, "00001.shd"), "spool shadow file");
        fileSystem.WriteAllText(Path.Combine(spoolDir, "FP00001.tmp"), "temporary spool buffer");

        // Act - Step 1: Execute Full Network Stack Remediation
        var netRemediation = connectivity.RemediateNetworkStack();

        // Act - Step 2: Configure SMB Guest Auth for network shares
        var smbResult = connectivity.ConfigureSmbSharing();

        // Act - Step 3: Purge Print Spooler Queue & Kill Hung spoolsv
        var spoolerResult = printer.PurgeSpoolerQueue();

        // Act - Step 4: Remediate Printer RPC Auth Error (0x0000011b)
        var err11b = printer.RemediatePrinterError("0x0000011b");

        // Act - Step 5: Remediate Point & Print CopyFiles Error (0x00000709)
        var err709 = printer.RemediatePrinterError("0x00000709");

        // Act - Step 6: Apply Compatibility Preset
        bool presetApplied = printer.ApplyPointAndPrintPreset(PointAndPrintPreset.Compatibility);

        // Act - Step 7: Diagnose Printer Ports
        network.SetPortOpen("192.168.1.50", 9100, true);
        network.SetPortOpen("192.168.1.50", 445, true);
        network.SetPortOpen("192.168.1.50", 135, false);
        var portDiag = connectivity.DiagnosePrinterPortConnectivity("192.168.1.50");

        // Assert
        // Network Remediation
        Assert.True(netRemediation.Success);
        Assert.True(netRemediation.DnsFlushed);
        Assert.True(netRemediation.DhcpRenewed);
        Assert.True(netRemediation.ArpCleared);
        Assert.True(netRemediation.WinsockReset);
        Assert.True(netRemediation.TcpIpReset);
        Assert.True(netRemediation.NlaReset);
        Assert.True(netRemediation.ProxyReset);

        // SMB guest auth enabled
        Assert.True(smbResult.Success);
        string smbKey = @"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters";
        Assert.Equal(1, registry.GetValue<int>(smbKey, "AllowInsecureGuestAuth"));

        // Spooler queue purged & restarted
        Assert.True(spoolerResult.Success);
        Assert.True(spoolerResult.SpoolFilesPurged);
        Assert.Equal(3, spoolerResult.PurgedFilesCount);
        Assert.True(spoolerResult.SpoolerRestarted);
        Assert.False(fileSystem.FileExists(Path.Combine(spoolDir, "00001.spl")));
        Assert.False(fileSystem.FileExists(Path.Combine(spoolDir, "00001.shd")));

        // 0x0000011b registry remediation
        Assert.True(err11b.Success);
        string printParamKey = @"HKLM\System\CurrentControlSet\Control\Print";
        Assert.Equal(0, registry.GetValue<int>(printParamKey, "RpcAuthnLevelPrivacyEnabled"));

        // 0x00000709 registry remediation
        Assert.True(err709.Success);
        string rpcKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC";
        Assert.Equal(1, registry.GetValue<int>(rpcKey, "RpcUseNamedPipeProtocol"));
        Assert.Equal(7, registry.GetValue<int>(rpcKey, "RpcProtocols"));

        // Point & Print preset
        Assert.True(presetApplied);
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        Assert.Equal(0, registry.GetValue<int>(pnpKey, "RestrictDriverInstallationToAdministrators"));

        // Port diagnostics
        Assert.True(portDiag.IsRawPortOpen);
        Assert.True(portDiag.IsSmbPortOpen);
        Assert.False(portDiag.IsRpcPortOpen);
    }

    [Fact]
    public void IdentityAndBackup_Pipeline_AccountCrud_Sid500Admin_DomainTest_ProfileAndManifest_ExecutesSuccessfully()
    {
        // Arrange
        var registry = new MockRegistryService();
        var fileSystem = new MockFileSystemService();
        var processRunner = new MockProcessRunner();
        var network = new MockNetworkService(fileSystem);
        var wmi = new MockWmiService();
        var resourceGuard = new ResourceGuard(fileSystem);
        var logger = new TestActivityLogger();

        var identity = new IdentityService(processRunner, fileSystem, registry, network, wmi, logger);
        var backup = new BackupService(processRunner, fileSystem, registry, resourceGuard, null, logger);

        // 1. Seed WMI with localized SID-500 Administrator (e.g. French locale)
        wmi.SetQueryResult("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True", new[]
        {
            new Dictionary<string, object?>
            {
                ["Name"] = "Administrateur",
                ["SID"] = "S-1-5-21-999-888-777-500",
                ["Disabled"] = true,
                ["Lockout"] = false
            },
            new Dictionary<string, object?>
            {
                ["Name"] = "StandardUser",
                ["SID"] = "S-1-5-21-999-888-777-1001",
                ["Disabled"] = false,
                ["Lockout"] = false
            }
        });

        // 2. Configure account commands
        processRunner.SetCommandResult("net user SupportAdmin P@ssword2026! /add /comment:\"IT Support User\"",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net localgroup Administrators SupportAdmin /add",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net user SupportAdmin /active:yes",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net user SupportAdmin /active:no",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net user SupportAdmin /delete",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net user Administrateur /active:yes",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));
        processRunner.SetCommandResult("net user Administrateur \"NewAdminP@ss!\"",
            new ProcessExecutionResult(0, "The command completed successfully.", string.Empty, false));

        // 3. Configure domain ports
        network.SetHostResolvable("corp.ad.contoso.com", true);
        network.SetPortOpen("corp.ad.contoso.com", 88, true);   // Kerberos
        network.SetPortOpen("corp.ad.contoso.com", 389, true);  // LDAP
        network.SetPortOpen("corp.ad.contoso.com", 445, true);  // SMB

        // 4. Seed user profile registry & file system
        string userSid = "S-1-5-21-999-888-777-1001";
        string profileRoot = @"C:\Users\StandardUser";
        registry.CreateKey($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}");
        registry.SetValue($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}", "ProfileImagePath", profileRoot, RegistryValueKind.String);

        // Seed profile folders & files
        fileSystem.CreateDirectory(Path.Combine(profileRoot, "Desktop"));
        fileSystem.CreateDirectory(Path.Combine(profileRoot, "Documents"));
        fileSystem.WriteAllText(Path.Combine(profileRoot, "Desktop", "Notes.txt"), "Important project documentation.");
        fileSystem.WriteAllText(Path.Combine(profileRoot, "Documents", "Budget.xlsx"), "Financial spreadsheet content.");

        // Seed OneDrive redirection
        string oneDrivePath = Path.Combine(profileRoot, "OneDrive");
        fileSystem.CreateDirectory(oneDrivePath);
        string shellFoldersKey = @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders";
        registry.CreateKey(shellFoldersKey);
        registry.SetValue(shellFoldersKey, "Personal", Path.Combine(oneDrivePath, "Documents"), RegistryValueKind.String);

        // Act - Step 1: Local Account CRUD
        bool created = identity.CreateLocalAccount("SupportAdmin", "P@ssword2026!", "IT Support User", addToAdminGroup: true);
        bool unlocked = identity.UnlockLocalAccount("SupportAdmin");
        bool disabled = identity.SetAccountEnabled("SupportAdmin", false);
        bool deleted = identity.RemoveLocalAccount("SupportAdmin");

        // Act - Step 2: Language-Agnostic SID-500 Admin
        var adminAccount = identity.GetBuiltInAdministrator();
        bool adminEnabled = identity.EnableBuiltInAdministrator();
        bool adminPasswordReset = identity.ResetBuiltInAdministratorPassword("NewAdminP@ss!");

        // Act - Step 3: Zero-RSAT Domain Reachability
        var domainResult = identity.TestDomainReachability("corp.ad.contoso.com");

        // Act - Step 4: Profile Discovery & OneDrive Detection
        var profileMap = backup.GetUserProfileMap("StandardUser");

        // Act - Step 5: Backup Manifest Creation & Verification
        string manifestPath = @"D:\Backups\iToolKit_Backup_Manifest.json";
        fileSystem.CreateDirectory(@"D:\Backups");
        var manifest = backup.CreateBackupManifest(profileRoot, manifestPath);
        var validation = backup.ValidateBackupManifest(profileRoot, manifestPath);

        // Assert
        // CRUD
        Assert.True(created);
        Assert.True(unlocked);
        Assert.True(disabled);
        Assert.True(deleted);

        // SID-500 Admin
        Assert.NotNull(adminAccount);
        Assert.Equal("Administrateur", adminAccount.Username);
        Assert.Equal("S-1-5-21-999-888-777-500", adminAccount.Sid);
        Assert.True(adminEnabled);
        Assert.True(adminPasswordReset);

        // Domain
        Assert.True(domainResult.IsReachable);
        Assert.True(domainResult.KerberosPortOpen);
        Assert.True(domainResult.LdapPortOpen);
        Assert.True(domainResult.SmbPortOpen);

        // Profile & OneDrive
        Assert.Equal(profileRoot, profileMap.ProfilePath);
        Assert.True(profileMap.IsOneDriveRedirected);

        // Manifest
        Assert.True(fileSystem.FileExists(manifestPath));
        Assert.Equal(2, manifest.Files.Count);
        Assert.True(validation.IsIntact);
        Assert.Equal(2, validation.MatchedCount);
        Assert.Empty(validation.MissingFiles);
        Assert.Empty(validation.CorruptedFiles);
    }

    [Fact]
    public void SoftwareOptimization_Pipeline_CatalogCheck_InstallModes_Policies_DebloatLaunch_ExecutesSuccessfully()
    {
        // Arrange
        var registry = new MockRegistryService();
        var fileSystem = new MockFileSystemService();
        var processRunner = new MockProcessRunner();
        var network = new MockNetworkService(fileSystem);
        var lockGuard = new ProcessLockGuard(processRunner, fileSystem);
        var logger = new TestActivityLogger();

        var appInstaller = new AppInstallerService(processRunner, fileSystem, registry, lockGuard, network, logger);
        var optimization = new OptimizationService(processRunner, fileSystem, network, logger);

        // 1. Verify 8-app catalog
        var catalog = appInstaller.GetCatalog();
        Assert.Equal(8, catalog.Count);

        var wingetApps = catalog.Where(a => a.InstallMode == AppInstallMode.WingetWithFallback).ToList();
        var nonWingetApps = catalog.Where(a => a.InstallMode != AppInstallMode.WingetWithFallback).ToList();

        Assert.Equal(4, wingetApps.Count);
        Assert.All(wingetApps, a => Assert.NotNull(a.WingetId));

        Assert.Equal(4, nonWingetApps.Count);
        Assert.All(nonWingetApps, a => Assert.Null(a.WingetId));

        // 2. Configure Winget installation failure -> Direct download fallback for Chrome
        processRunner.SetCommandResult("winget.exe install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements",
            new ProcessExecutionResult(1603, string.Empty, "Winget installation failed.", false));

        // Seed direct download installer execution
        string tempDir = Path.GetTempPath();
        processRunner.SetCommandResult("chrome_installer.exe /silent /install",
            new ProcessExecutionResult(0, "Chrome installed successfully.", string.Empty, false));

        // 3. Configure Non-Winget UniKey installation (Archive extract & temp cleanup)
        string unikeyZip = Path.Combine(tempDir, "unikey43RC5-200929-win64.zip");
        // Seed archive extraction in MockFileSystem
        fileSystem.SetZipExtractionHandler(unikeyZip, targetDir =>
        {
            fileSystem.WriteAllText(Path.Combine(targetDir, "UniKeyNT.exe"), "executable binary");
        });

        // Act - Step 1: Install Chrome (triggers fallback)
        var chromeResult = appInstaller.InstallApplication("Chrome");

        // Act - Step 2: Install UniKey (downloads to temp, extracts, cleans temp)
        var unikeyResult = appInstaller.InstallApplication("UniKey");

        // Act - Step 3: Default Applications & Policies
        bool browserSet = appInstaller.SetDefaultBrowser("chrome.exe");
        bool pdfSet = appInstaller.SetDefaultPdfViewer("FoxitPDFReader.exe");
        bool ublockConfigured = appInstaller.ConfigureUblockOriginLitePolicy();
        bool shortcutCreated = appInstaller.CreateDesktopShortcut("Google Chrome", @"C:\Program Files\Google\Chrome\Application\chrome.exe");

        // Act - Step 4: Debloat Launcher Pre-flight Checks
        network.IsInternetAvailable = false;
        var offlineDebloat = optimization.LaunchWin11Debloat();

        network.IsInternetAvailable = true;
        var onlineDebloat = optimization.LaunchWin11Debloat();

        // Assert
        // Chrome fallback success
        Assert.True(chromeResult.Success);
        Assert.Equal("DirectDownload", chromeResult.MethodUsed);

        // UniKey direct install & temp cleanup
        Assert.True(unikeyResult.Success);
        Assert.False(fileSystem.FileExists(unikeyZip), "Temporary installer archive in %TEMP% must be deleted after installation.");

        // Policies
        Assert.True(browserSet);
        Assert.True(pdfSet);
        Assert.True(ublockConfigured);
        Assert.True(shortcutCreated);

        string ublockKey = @"HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist";
        Assert.True(registry.ValueExists(ublockKey, "1"));

        // Debloat Pre-Flight Guard
        Assert.False(offlineDebloat.ExecutionSuccess);
        Assert.Contains("Pre-flight internet check failed", offlineDebloat.Message);
        Assert.True(onlineDebloat.ExecutionSuccess);
    }

    [Fact]
    public void CrossPillar_SystemAndProductivityRecovery_FullSuite_ExecutesCleanly()
    {
        // Arrange
        var registry = new MockRegistryService();
        var fileSystem = new MockFileSystemService();
        var processRunner = new MockProcessRunner();
        var network = new MockNetworkService(fileSystem);
        var wmi = new MockWmiService();
        var atomicRegistry = new AtomicRegistryService(registry, fileSystem);
        var lockGuard = new ProcessLockGuard(processRunner, fileSystem);
        var resourceGuard = new ResourceGuard(fileSystem);
        var logger = new TestActivityLogger();

        var systemHealth = new SystemHealthService(processRunner, fileSystem, logger);
        var connectivity = new ConnectivityService(network, processRunner, registry, atomicRegistry, logger);
        var printer = new PrinterService(processRunner, fileSystem, registry, atomicRegistry, lockGuard, wmi, logger);
        var outlook = new OutlookService(registry, atomicRegistry, fileSystem, lockGuard, resourceGuard, null, logger);
        var backup = new BackupService(processRunner, fileSystem, registry, resourceGuard, null, logger);

        // Setup Mock Responses across all services
        processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("sfc.exe /scannow", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("netsh int ip reset", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("netsh winsock reset", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("ipconfig /flushdns", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("net stop spooler /y", new ProcessExecutionResult(0, "OK", string.Empty, false));
        processRunner.SetCommandResult("net start spooler", new ProcessExecutionResult(0, "OK", string.Empty, false));

        // Seed Outlook roamcache
        string roamCache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Outlook", "RoamCache");
        fileSystem.CreateDirectory(roamCache);
        string autoFile = Path.Combine(roamCache, "Stream_Autocomplete_0_ABCD.dat");
        string staleFile = Path.Combine(roamCache, "Stream_Calendar_0_XYZ.dat");
        fileSystem.WriteAllText(autoFile, "autocomplete stream");
        fileSystem.WriteAllText(staleFile, "stale calendar cache");

        // Seed user profile
        string userSid = "S-1-5-21-123-456-789-1001";
        string userHome = @"C:\Users\ActiveTechnician";
        registry.CreateKey($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}");
        registry.SetValue($@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{userSid}", "ProfileImagePath", userHome, RegistryValueKind.String);
        fileSystem.CreateDirectory(userHome);
        fileSystem.WriteAllText(Path.Combine(userHome, "Config.xml"), "<config/>");

        // Act
        // 1. System Health
        var (dismRes, sfcRes) = systemHealth.RunDismSfcPipeline();

        // 2. Network Remediation
        var netRes = connectivity.RemediateNetworkStack();

        // 3. Spooler Queue
        var spoolerRes = printer.PurgeSpoolerQueue();

        // 4. Outlook Mail Repair
        var mailRes = outlook.QuickMailAndCacheRepair();

        // 5. Backup Manifest
        string manifestOut = @"D:\Backups\TechProfile_Manifest.json";
        fileSystem.CreateDirectory(@"D:\Backups");
        var manifest = backup.CreateBackupManifest(userHome, manifestOut);

        // Assert
        Assert.True(dismRes.Success);
        Assert.True(sfcRes.Success);
        Assert.True(netRes.Success);
        Assert.True(spoolerRes.Success);
        Assert.True(mailRes.Success);
        Assert.True(mailRes.AutocompletePreserved);
        Assert.True(fileSystem.FileExists(autoFile), "AutoComplete stream MUST be preserved.");
        Assert.False(fileSystem.FileExists(staleFile), "Stale calendar cache should be cleaned.");
        Assert.True(fileSystem.FileExists(manifestOut));
        Assert.Single(manifest.Files);

        // Verify activity logs emitted across all 5 steps
        Assert.True(logger.CapturedEntries.Count >= 5);
    }
}
