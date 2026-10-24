namespace IToolkit.Tests.UI;

using System;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Office;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

public class XamlArchitectureAndBindingsTests
{
    private static readonly string SolutionRoot = FindSolutionRoot();

    private static string FindSolutionRoot()
    {
        string? current = AppDomain.CurrentDomain.BaseDirectory;
        while (current != null)
        {
            if (File.Exists(Path.Combine(current, "IToolkit.sln")))
            {
                return current;
            }
            current = Directory.GetParent(current)?.FullName;
        }
        throw new InvalidOperationException("Could not locate IToolkit.sln directory.");
    }

    [Fact]
    public void AppXaml_DefinesFluentTabStyles()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "App.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        Assert.Contains("x:Key=\"FluentTabControlStyle\"", xaml);
        Assert.Contains("x:Key=\"FluentTabItemStyle\"", xaml);
        Assert.Contains("TargetType=\"TabControl\"", xaml);
        Assert.Contains("TargetType=\"TabItem\"", xaml);
        Assert.Contains("SelectionIndicator", xaml);
    }

    [Fact]
    public void SystemHealthView_HasThreeTabsAndRequiredBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "SystemHealthView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify 3 tabs
        Assert.Contains("Header=\"Image &amp; File Integrity\"", xaml);
        Assert.Contains("Header=\"Windows Update &amp; WMI Salvage\"", xaml);
        Assert.Contains("Header=\"Storage &amp; WinSxS Cleanup\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Image &amp; File Integrity", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Windows Update &amp; WMI Salvage", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Storage &amp; WinSxS Cleanup", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify required bindings
        Assert.Contains("CustomWimSource", xaml);
        Assert.Contains("BrowseWimSourceCommand", xaml);
        Assert.Contains("OpenWimFolderCommand", xaml);
        Assert.Contains("LimitSourceAccess", xaml);
        Assert.Contains("WinSxSResetBase", xaml);
        Assert.Contains("RunDismSfcPipelineCommand", xaml);
        Assert.Contains("ResetWindowsUpdateCommand", xaml);
        Assert.Contains("BlockWindowsUpdatesCommand", xaml);
        Assert.Contains("UnblockWindowsUpdatesCommand", xaml);
        Assert.Contains("SyncSystemTimeCommand", xaml);
        Assert.Contains("RepairWmiCommand", xaml);
        Assert.Contains("RunUnifiedDiskCleanupCommand", xaml);
    }

    [Fact]
    public void OfficeOutlookView_HasThreeTabsAndRequiredBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "OfficeOutlookView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify 3 tabs
        Assert.Contains("Header=\"Click-to-Run &amp; App Quick Repairs\"", xaml);
        Assert.Contains("Header=\"Outlook MAPI Data Files\"", xaml);
        Assert.Contains("Header=\"Automated New Default PST Pipeline\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Click-to-Run &amp; App Quick Repairs", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Outlook MAPI Data Files", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Automated New Default PST Pipeline", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify required bindings
        Assert.Contains("RepairC2RCommand", xaml);
        Assert.Contains("ScrubOfficeSuiteCommand", xaml);
        Assert.Contains("RelocationDestinationDir", xaml);
        Assert.Contains("BrowseRelocationDirCommand", xaml);
        Assert.Contains("OpenRelocationDirCommand", xaml);
        Assert.Contains("RelocateSelectedPstCommand", xaml);
        Assert.Contains("CompactSelectedPstCommand", xaml);
        Assert.Contains("BackupDirectory", xaml);
        Assert.Contains("BrowseBackupDirCommand", xaml);
        Assert.Contains("OpenBackupDirCommand", xaml);
        Assert.Contains("BackupSelectedPstCommand", xaml);
        Assert.Contains("SourcePstPath", xaml);
        Assert.Contains("BrowseSourcePstCommand", xaml);
        Assert.Contains("TargetPstPath", xaml);
        Assert.Contains("BrowseTargetPstCommand", xaml);
        Assert.Contains("CreateAndSetDefaultPstCommand", xaml);
    }

    [Fact]
    public void ConnectivityView_HasThreeTabsAndRequiredBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "ConnectivityView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify 3 tabs
        Assert.Contains("Header=\"Network Stack &amp; Adapter Control\"", xaml);
        Assert.Contains("Header=\"SMB &amp; Print Spooler Subsystem\"", xaml);
        Assert.Contains("Header=\"Point &amp; Print Policies &amp; Diagnostics\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Network Stack &amp; Adapter Control", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("SMB &amp; Print Spooler Subsystem", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Point &amp; Print Policies &amp; Diagnostics", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify required bindings
        Assert.Contains("AvailableAdapters", xaml);
        Assert.Contains("SelectedAdapter", xaml);
        Assert.Contains("DisplayMemberPath=\"Name\"", xaml);
        Assert.Contains("RefreshAdaptersCommand", xaml);
        Assert.Contains("RestartAdapterCommand", xaml);
        Assert.Contains("FlushDnsCommand", xaml);
        Assert.Contains("RenewDhcpCommand", xaml);
        Assert.Contains("ResetWinsockCommand", xaml);
        Assert.Contains("ResetTcpIpCommand", xaml);
        Assert.Contains("RemediateNetworkStackCommand", xaml);
        Assert.Contains("ConfigureSmbSharingCommand", xaml);
        Assert.Contains("PurgeSpoolerCommand", xaml);
        Assert.Contains("RegisterSpoolerCommand", xaml);
        Assert.Contains("ResetNePortsCommand", xaml);
        Assert.Contains("ApplyPointAndPrintCommand", xaml);
        Assert.Contains("RemediatePrinterErrorCommand", xaml);
        Assert.Contains("DiagnosePrinterHostCommand", xaml);
    }

    [Fact]
    public void IdentityBackupView_HasThreeTabsAndRequiredBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "IdentityBackupView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify 3 tabs
        Assert.Contains("Header=\"Local Accounts &amp; Built-in Admin\"", xaml);
        Assert.Contains("Header=\"Active Directory Domain Reachability\"", xaml);
        Assert.Contains("Header=\"User Profile Backup &amp; Restore\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Local Accounts &amp; Built-in Admin", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Active Directory Domain Reachability", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("User Profile Backup &amp; Restore", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify required bindings
        Assert.Contains("EnableBuiltInAdminCommand", xaml);
        Assert.Contains("NewAdminPassword", xaml);
        Assert.Contains("ResetAdminPasswordCommand", xaml);
        Assert.Contains("NewAccountUsername", xaml);
        Assert.Contains("NewAccountPassword", xaml);
        Assert.Contains("NewAccountDescription", xaml);
        Assert.Contains("NewAccountIsAdmin", xaml);
        Assert.Contains("CreateAccountCommand", xaml);
        Assert.Contains("RemoveAccountCommand", xaml);
        Assert.Contains("DomainTestName", xaml);
        Assert.Contains("TestDomainReachabilityCommand", xaml);
        Assert.Contains("DomainUserSamName", xaml);
        Assert.Contains("UnlockDomainUserCommand", xaml);
        Assert.Contains("BackupDestinationDirectory", xaml);
        Assert.Contains("BrowseBackupDestinationCommand", xaml);
        Assert.Contains("OpenBackupDestinationCommand", xaml);
        Assert.Contains("RobocopyMirror", xaml);
        Assert.Contains("RestoreBackupDirectory", xaml);
        Assert.Contains("BrowseRestoreBackupCommand", xaml);
        Assert.Contains("OpenRestoreBackupCommand", xaml);
        Assert.Contains("RestoreProfileCommand", xaml);
        Assert.Contains("ValidateBackupManifestCommand", xaml);
    }

    [Fact]
    public void SoftwareOptimizationView_HasThreeTabsAndRequiredBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "SoftwareOptimizationView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify 3 tabs
        Assert.Contains("Header=\"Enterprise 8-App Catalog\"", xaml);
        Assert.Contains("Header=\"Default App Associations &amp; Winget Subsystem\"", xaml);
        Assert.Contains("Header=\"Verified Debloat &amp; Tweaking Suites\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Enterprise 8-App Catalog", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Default App Associations &amp; Winget Subsystem", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Verified Debloat &amp; Tweaking Suites", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify required bindings
        Assert.Contains("CatalogApps", xaml);
        Assert.Contains("SelectAllCommand", xaml);
        Assert.Contains("DeselectAllCommand", xaml);
        Assert.Contains("BatchInstallCommand", xaml);
        Assert.Contains("SetDefaultBrowserCommand", xaml);
        Assert.Contains("SetDefaultPdfViewerCommand", xaml);
        Assert.Contains("ConfigureUblockPolicyCommand", xaml);
        Assert.Contains("CheckWingetStatusCommand", xaml);
        Assert.Contains("RepairWingetCommand", xaml);
        Assert.Contains("UpgradeAllPackagesCommand", xaml);
        Assert.Contains("LaunchWin11DebloatCommand", xaml);
        Assert.Contains("CustomDebloatScriptUrl", xaml);
        Assert.Contains("ExecuteCustomDebloatCommand", xaml);
    }

    [Fact]
    public async Task ConnectivityViewModel_RefreshAdaptersCommand_ExecutesProperly()
    {
        var netMock = new Mock<IConnectivityService>();
        var printerMock = new Mock<IPrinterService>();
        var networkServiceMock = new Mock<INetworkService>();
        var loggerMock = new Mock<IActivityLogger>();

        networkServiceMock.Setup(n => n.GetAdapters()).Returns(new[]
        {
            new NetworkAdapterInfo("1", "Ethernet 1", "Intel GbE", "AA-BB-CC-DD-EE-FF", "Up", new[] { "192.168.1.10" })
        });

        var vm = new ConnectivityViewModel(netMock.Object, printerMock.Object, loggerMock.Object, networkServiceMock.Object);
        Assert.True(vm.RefreshAdaptersCommand.CanExecute(null));

        await vm.RefreshAdaptersCommand.ExecuteAsync(null);

        Assert.Single(vm.AvailableAdapters);
        Assert.Equal("Ethernet 1", vm.AvailableAdapters[0].Name);
        Assert.Equal("Ethernet 1", vm.NetworkAdapterName);
    }

    [Fact]
    public void OfficeOutlookViewModel_AliasedCommands_RouteToUnderlyingCommands()
    {
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var loggerMock = new Mock<IActivityLogger>();

        var vm = new OfficeOutlookViewModel(officeMock.Object, outlookMock.Object, loggerMock.Object);

        Assert.Same(vm.RunPstPipelineCommand, vm.CreateAndSetDefaultPstCommand);
        Assert.Same(vm.RelocatePstCommand, vm.RelocateSelectedPstCommand);
        Assert.Same(vm.BackupPstCommand, vm.BackupSelectedPstCommand);
        Assert.Same(vm.CompactPstCommand, vm.CompactSelectedPstCommand);
    }

    [Fact]
    public void MainWindow_CompactWindowDimensions_Enforced()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);
        XElement root = doc.Root!;

        double width = double.Parse(root.Attribute("Width")?.Value ?? "0");
        double height = double.Parse(root.Attribute("Height")?.Value ?? "0");
        double minWidth = double.Parse(root.Attribute("MinWidth")?.Value ?? "0");
        double minHeight = double.Parse(root.Attribute("MinHeight")?.Value ?? "0");

        Assert.True(width <= 960 && width > 0, $"MainWindow Width ({width}) must be <= 960");
        Assert.True(height <= 600 && height > 0, $"MainWindow Height ({height}) must be <= 600");
        Assert.True(minWidth <= 800 && minWidth > 0, $"MainWindow MinWidth ({minWidth}) must be <= 800");
        Assert.True(minHeight <= 500 && minHeight > 0, $"MainWindow MinHeight ({minHeight}) must be <= 500");
    }

    [Fact]
    public void MainWindow_SlimNavigationRail_EnforcesCompactDimensionsAndSingleLineItems()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify left navigation rail column width <= 185 and >= 160
        var colDef = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "ColumnDefinition" && (string?)d.Attribute("Width") != "*");
        Assert.NotNull(colDef);
        double railWidth = double.Parse(colDef.Attribute("Width")!.Value);
        Assert.True(railWidth <= 185 && railWidth >= 160, $"Left navigation rail column width ({railWidth}) must be between 160 and 185");

        // Verify exactly 6 navigation RadioButtons for the 6 pillars
        var navRadios = doc.Descendants().Where(d => d.Name.LocalName == "RadioButton" && (string?)d.Attribute("GroupName") == "PillarNav").ToList();
        Assert.Equal(6, navRadios.Count);

        // Verify each navigation RadioButton has single-line label (exactly 1 TextBlock, no secondary description TextBlock)
        foreach (var radio in navRadios)
        {
            var textBlocks = radio.Descendants().Where(d => d.Name.LocalName == "TextBlock").ToList();
            Assert.True(textBlocks.Count == 1, $"Pillar nav RadioButton must contain exactly 1 TextBlock (single-line label), but found {textBlocks.Count}");
        }
    }

    [Fact]
    public void TelemetryHeaderView_UltraSlimSingleLineLayout_Enforced()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "TelemetryHeaderView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Find root container Border padding and verify vertical padding <= 6
        var border = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Border" && d.Attribute("Padding") != null);
        Assert.NotNull(border);
        string paddingStr = border.Attribute("Padding")!.Value.Trim();
        string[] parts = paddingStr.Split(',');
        double vertPadding = parts.Length switch
        {
            1 => double.Parse(parts[0]),
            2 => double.Parse(parts[1]),
            4 => Math.Max(double.Parse(parts[1]), double.Parse(parts[3])),
            _ => throw new FormatException($"Invalid padding format: {paddingStr}")
        };
        Assert.True(vertPadding <= 6, $"TelemetryHeaderView vertical padding ({vertPadding}) must be <= 6");

        // Verify all 8 telemetry bindings are present in XAML
        Assert.Contains("OsDescription", xaml);
        Assert.Contains("OsBuild", xaml);
        Assert.Contains("ElevationBadgeText", xaml);
        Assert.Contains("CpuUsageText", xaml);
        Assert.Contains("MemoryUsageText", xaml);
        Assert.Contains("DiskFreeSpaceText", xaml);
        Assert.Contains("NetworkStatusText", xaml);
        Assert.Contains("ActiveTaskDescription", xaml);
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void AllSixViews_DoNotContain_OversizedPageTitlesOrSubtitles(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path), $"View file not found: {path}");

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("FluentPageTitleStyle", xaml);
        Assert.DoesNotContain("FluentPageSubtitleStyle", xaml);
    }

    [Fact]
    public void AppXaml_CompactStyleConstraints_Enforced()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "App.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // FluentCardStyle Padding <= 12 and Margin bottom <= 8
        var cardStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute(XName.Get("Key", "http://schemas.microsoft.com/winfx/2006/xaml")) == "FluentCardStyle");
        Assert.NotNull(cardStyle);

        var cardPaddingSetter = cardStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Padding");
        Assert.NotNull(cardPaddingSetter);
        string cardPadVal = cardPaddingSetter.Attribute("Value")!.Value.Trim();
        string[] padParts = cardPadVal.Split(',');
        double maxCardPad = padParts.Select(double.Parse).Max();
        Assert.True(maxCardPad <= 12, $"FluentCardStyle Padding ({cardPadVal}) must be <= 12");

        var cardMarginSetter = cardStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Margin");
        Assert.NotNull(cardMarginSetter);
        string cardMarginVal = cardMarginSetter.Attribute("Value")!.Value.Trim();
        string[] marginParts = cardMarginVal.Split(',');
        double bottomMargin = marginParts.Length switch
        {
            1 => double.Parse(marginParts[0]),
            2 => double.Parse(marginParts[1]),
            4 => double.Parse(marginParts[3]),
            _ => throw new FormatException($"Invalid margin format: {cardMarginVal}")
        };
        Assert.True(bottomMargin <= 8, $"FluentCardStyle bottom margin ({bottomMargin}) must be <= 8");

        // FluentTabItemStyle vertical Padding <= 6
        var tabItemStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute(XName.Get("Key", "http://schemas.microsoft.com/winfx/2006/xaml")) == "FluentTabItemStyle");
        Assert.NotNull(tabItemStyle);

        var tabPadSetter = tabItemStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Padding");
        Assert.NotNull(tabPadSetter);
        string tabPadVal = tabPadSetter.Attribute("Value")!.Value.Trim();
        string[] tabPadParts = tabPadVal.Split(',');
        double tabVertPad = tabPadParts.Length switch
        {
            1 => double.Parse(tabPadParts[0]),
            2 => double.Parse(tabPadParts[1]),
            4 => Math.Max(double.Parse(tabPadParts[1]), double.Parse(tabPadParts[3])),
            _ => throw new FormatException($"Invalid padding format: {tabPadVal}")
        };
        Assert.True(tabVertPad <= 6, $"FluentTabItemStyle vertical padding ({tabVertPad}) must be <= 6");
    }

    [Fact]
    public void ActivityConsoleView_CompactDimensionsAndToolbar_Enforced()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "ActivityConsoleView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);
        XElement root = doc.Root!;

        double minHeight = double.Parse(root.Attribute("MinHeight")?.Value ?? "0");
        Assert.True(minHeight <= 32 && minHeight > 0, $"ActivityConsoleView MinHeight ({minHeight}) must be <= 32");

        // RowDefinition 0 (Toolbar) height
        var firstRowDef = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "RowDefinition");
        Assert.NotNull(firstRowDef);
        double row0Height = double.Parse(firstRowDef.Attribute("Height")?.Value ?? "0");
        Assert.True(row0Height <= 32 && row0Height > 0, $"ActivityConsoleView toolbar RowDefinition Height ({row0Height}) must be <= 32");

        // Verify key bindings preserved
        Assert.Contains("ConsoleHeight", xaml);
        Assert.Contains("TotalCount", xaml);
        Assert.Contains("ExecutionStatus", xaml);
        Assert.Contains("SearchFilter", xaml);
        Assert.Contains("SelectedLevelFilter", xaml);
        Assert.Contains("AutoScroll", xaml);
        Assert.Contains("CopyLogCommand", xaml);
        Assert.Contains("ClearLogCommand", xaml);
        Assert.Contains("ToggleExpandedCommand", xaml);
        Assert.Contains("ShowCompletionBanner", xaml);
        Assert.Contains("CompletionMessage", xaml);
        Assert.Contains("DismissCompletionCommand", xaml);
        Assert.Contains("FilteredEntries", xaml);
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void AllSixViews_OuterMargins_AreCompact(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Locate primary layout container element under UserControl or ScrollViewer
        var outerContainer = doc.Root!.Elements()
            .SelectMany(e => e.Name.LocalName == "ScrollViewer" ? e.Elements() : new[] { e })
            .FirstOrDefault(e => e.Attribute("Margin") != null);

        if (outerContainer == null)
        {
            outerContainer = doc.Root!.Elements().FirstOrDefault(e => e.Attribute("Margin") != null);
        }

        Assert.NotNull(outerContainer);
        string marginStr = outerContainer.Attribute("Margin")!.Value.Trim();
        string[] parts = marginStr.Split(',');
        foreach (var part in parts)
        {
            double val = double.Parse(part.Trim());
            Assert.True(val <= 12, $"Outer container Margin in {viewFileName} had component {val} > 12 (margin='{marginStr}')");
        }
    }

    [Fact]
    public void DashboardView_HasRequiredQuickActionBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "DashboardView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);

        Assert.Contains("IsNotBusy", xaml);
        Assert.Contains("QuickSystemRepairCommand", xaml);
        Assert.Contains("SystemHealthStatus", xaml);
        Assert.Contains("QuickMailRepairCommand", xaml);
        Assert.Contains("OfficeStatus", xaml);
        Assert.Contains("QuickNetworkResetCommand", xaml);
        Assert.Contains("NetworkStatus", xaml);
        Assert.Contains("QuickDiskCleanupCommand", xaml);
        Assert.Contains("QuickSoftwareUpgradeCommand", xaml);
        Assert.Contains("SoftwareStatus", xaml);
        Assert.Contains("QuickProfileBackupCommand", xaml);
        Assert.Contains("BackupStatus", xaml);
    }

    [Fact]
    public void MainWindow_ActivityConsole_IsNotDockedInMainWindow()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("ActivityConsoleView", xaml);
        Assert.DoesNotContain("GridSplitter", xaml);

        XDocument doc = XDocument.Parse(xaml);
        var rootGrid = doc.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "Grid");
        Assert.NotNull(rootGrid);

        var rowDefs = rootGrid.Elements()
            .FirstOrDefault(e => e.Name.LocalName == "Grid.RowDefinitions")
            ?.Elements()
            .Where(e => e.Name.LocalName == "RowDefinition")
            .ToList();

        Assert.NotNull(rowDefs);
        Assert.Equal(2, rowDefs.Count);
    }

    [Fact]
    public void MainWindow_BrandHeader_DoesNotContainSecondarySubtitleClutter()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("Utility Suite", xaml);
        Assert.Contains("iToolKit", xaml);
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void AllSixViews_DoNotContain_VerboseDescriptionsOrStatusBanners(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path), $"View file not found: {path}");

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("FluentSectionDescriptionStyle", xaml);
        Assert.DoesNotContain("FluentStatusBannerStyle", xaml);
    }

    [Fact]
    public void App_DoesNotDefine_ObsoleteStyles()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "App.xaml");
        Assert.True(File.Exists(path), $"App.xaml not found at: {path}");

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("FluentSectionDescriptionStyle", xaml);
        Assert.DoesNotContain("FluentStatusBannerStyle", xaml);
    }

    [Fact]
    public void ActivityLogWindow_ExistsAndHostsActivityConsole()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "ActivityLogWindow.xaml");
        Assert.True(File.Exists(path), $"ActivityLogWindow.xaml not found at: {path}");

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);
        XElement root = doc.Root!;

        Assert.Equal("iToolKit - Activity Log", root.Attribute("Title")?.Value);
        Assert.Equal("CenterOwner", root.Attribute("WindowStartupLocation")?.Value);
        Assert.Equal("True", root.Attribute("ShowInTaskbar")?.Value);
        Assert.Equal("780", root.Attribute("Width")?.Value);
        Assert.Equal("460", root.Attribute("Height")?.Value);
        Assert.Equal("600", root.Attribute("MinWidth")?.Value);
        Assert.Equal("320", root.Attribute("MinHeight")?.Value);
        Assert.Contains("<views:ActivityConsoleView", xaml);

        bool containsConsoleElement = root.Descendants()
            .Any(e => e.Name.LocalName == "ActivityConsoleView");
        Assert.True(containsConsoleElement, "ActivityLogWindow.xaml must embed an ActivityConsoleView element.");
    }
}
