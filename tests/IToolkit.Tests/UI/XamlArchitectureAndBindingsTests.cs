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

        XDocument doc = XDocument.Parse(xaml);
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";

        // Verify FluentTabControlStyle defines stretch content alignment setters
        var tabControlStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute(x + "Key") == "FluentTabControlStyle");
        Assert.NotNull(tabControlStyle);
        var hAlignSetter = tabControlStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "HorizontalContentAlignment");
        Assert.NotNull(hAlignSetter);
        Assert.Equal("Stretch", (string?)hAlignSetter.Attribute("Value"));
        var vAlignSetter = tabControlStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "VerticalContentAlignment");
        Assert.NotNull(vAlignSetter);
        Assert.Equal("Stretch", (string?)vAlignSetter.Attribute("Value"));

        // Verify TabPanel is left-aligned in AST
        var tabPanel = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "TabPanel" && (string?)d.Attribute("IsItemsHost") == "True");
        Assert.NotNull(tabPanel);
        Assert.Equal("Left", (string?)tabPanel.Attribute("HorizontalAlignment"));

        // Verify PART_SelectedContentHost binds directly to template content alignment
        var contentHost = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "ContentPresenter" && (string?)d.Attribute(x + "Name") == "PART_SelectedContentHost");
        Assert.NotNull(contentHost);
        Assert.Equal("{TemplateBinding HorizontalContentAlignment}", (string?)contentHost.Attribute("HorizontalAlignment"));
        Assert.Equal("{TemplateBinding VerticalContentAlignment}", (string?)contentHost.Attribute("VerticalAlignment"));

        // Verify default styles for TabControl and TabItem are defined and based on Fluent styles
        var defaultTabControlStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute("TargetType") == "TabControl" && d.Attribute(x + "Key") == null);
        Assert.NotNull(defaultTabControlStyle);
        Assert.Equal("{StaticResource FluentTabControlStyle}", (string?)defaultTabControlStyle.Attribute("BasedOn"));

        var defaultTabItemStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute("TargetType") == "TabItem" && d.Attribute(x + "Key") == null);
        Assert.NotNull(defaultTabItemStyle);
        Assert.Equal("{StaticResource FluentTabItemStyle}", (string?)defaultTabItemStyle.Attribute("BasedOn"));
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

        // Verify 2 tabs (Automated New Default PST Pipeline is integrated into the per-user Edit Popup)
        Assert.Contains("Header=\"Click-to-Run &amp; App Quick Repairs\"", xaml);
        Assert.Contains("Header=\"Outlook MAPI Data Files\"", xaml);
        Assert.DoesNotContain("Header=\"Automated New Default PST Pipeline\"", xaml);

        // Verify inner ScrollViewers
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Click-to-Run &amp; App Quick Repairs", StringComparison.Ordinal), StringComparison.Ordinal) > 0);
        Assert.True(xaml.IndexOf("<ScrollViewer", xaml.IndexOf("Outlook MAPI Data Files", StringComparison.Ordinal), StringComparison.Ordinal) > 0);

        // Verify per-user Edit Popup & required bindings
        Assert.Contains("IsUserEditPopupOpen", xaml);
        Assert.Contains("OpenUserEditPopupCommand", xaml);
        Assert.Contains("OpenUserEditPopupForItemCommand", xaml);
        Assert.Contains("CloseUserEditPopupCommand", xaml);
        Assert.Contains("EditingUserHeaderSummary", xaml);
        Assert.Contains("EditingUserFilePath", xaml);
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
        Assert.Contains("RemediateAllPrintersCommand", xaml);
        Assert.Contains("RemediateClientBatchCommand", xaml);
        Assert.Contains("RemediateServerBatchCommand", xaml);
        Assert.Contains("AuditPointAndPrintPolicyCommand", xaml);
        Assert.Contains("RefreshPrinterConnectionsCommand", xaml);
        Assert.Contains("InspectSpoolerStatusCommand", xaml);
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

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void AllSixViews_PrimaryContainers_StretchFullWidthWithoutMaxWidthConstraints(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Verify view contains no MaxWidth constraint on any element
        Assert.DoesNotContain("MaxWidth", xaml);

        // Verify no element has HorizontalAlignment="Center"
        var centeredElements = doc.Descendants()
            .Where(d => ((string?)d.Attribute("HorizontalAlignment"))?.Trim() == "Center")
            .ToList();
        Assert.Empty(centeredElements);

        // Verify all ScrollViewers in the view disable horizontal scrollbars so content stretches rather than expands infinitely
        var scrollViewers = doc.Descendants().Where(d => d.Name.LocalName == "ScrollViewer").ToList();
        Assert.NotEmpty(scrollViewers);
        foreach (var sv in scrollViewers)
        {
            Assert.Equal("Disabled", (string?)sv.Attribute("HorizontalScrollBarVisibility"));
        }

        // Locate primary layout container element under UserControl or ScrollViewer
        var outerContainer = doc.Root!.Elements()
            .SelectMany(e => e.Name.LocalName == "ScrollViewer" ? e.Elements() : new[] { e })
            .FirstOrDefault(e => e.Attribute("Margin") != null);

        if (outerContainer == null)
        {
            outerContainer = doc.Root!.Elements().FirstOrDefault(e => e.Attribute("Margin") != null);
        }

        Assert.NotNull(outerContainer);
        Assert.Null(outerContainer.Attribute("MaxWidth"));
        Assert.Null(outerContainer.Attribute("Width"));
        Assert.Equal("Stretch", outerContainer.Attribute("HorizontalAlignment")?.Value);

        // If the view contains a TabControl, verify it stretches and has no width constraints
        var tabControl = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "TabControl");
        if (tabControl != null)
        {
            Assert.Null(tabControl.Attribute("MaxWidth"));
            Assert.Null(tabControl.Attribute("Width"));
            var hAlign = (string?)tabControl.Attribute("HorizontalAlignment");
            Assert.True(hAlign == null || hAlign == "Stretch", $"TabControl in {viewFileName} must stretch, but was {hAlign}");

            // Verify each TabItem's content root container and inner content panel also stretch without width constraints
            var tabItems = tabControl.Descendants().Where(d => d.Name.LocalName == "TabItem");
            foreach (var tab in tabItems)
            {
                var tabContainer = tab.Elements().FirstOrDefault();
                if (tabContainer != null)
                {
                    Assert.Null(tabContainer.Attribute("MaxWidth"));
                    Assert.Null(tabContainer.Attribute("Width"));
                    var tabHAlign = (string?)tabContainer.Attribute("HorizontalAlignment");
                    Assert.True(tabHAlign == null || tabHAlign == "Stretch", $"TabItem container in {viewFileName} must stretch, but was {tabHAlign}");

                    // Inspect inner content panel inside ScrollViewer
                    var innerContainer = tabContainer.Name.LocalName == "ScrollViewer"
                        ? tabContainer.Elements().FirstOrDefault()
                        : null;
                    if (innerContainer != null)
                    {
                        Assert.Null(innerContainer.Attribute("MaxWidth"));
                        Assert.Null(innerContainer.Attribute("Width"));
                        var innerHAlign = (string?)innerContainer.Attribute("HorizontalAlignment");
                        Assert.True(innerHAlign == null || innerHAlign == "Stretch", $"Inner panel inside TabItem ScrollViewer in {viewFileName} must stretch, but was {innerHAlign}");
                    }
                }
            }
        }
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    public void AllSixViews_CardsAndSurfaces_StretchFullWidthWithoutWidthConstraints(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Find all card borders
        var cardBorders = doc.Descendants().Where(d => d.Name.LocalName == "Border" &&
            (((string?)d.Attribute("Style"))?.Contains("FluentCardStyle") == true ||
             ((string?)d.Attribute("Background"))?.Contains("CardBackgroundFillColor") == true)).ToList();
        Assert.NotEmpty(cardBorders);

        foreach (var card in cardBorders)
        {
            Assert.Null(card.Attribute("Width"));
            Assert.Null(card.Attribute("MaxWidth"));
            var hAlign = (string?)card.Attribute("HorizontalAlignment");
            Assert.True(hAlign == null || hAlign == "Stretch", $"Card in {viewFileName} must stretch horizontally, but was {hAlign}");
        }

        // Find all UniformGrid layouts
        var uniformGrids = doc.Descendants().Where(d => d.Name.LocalName == "UniformGrid").ToList();
        foreach (var ug in uniformGrids)
        {
            Assert.Null(ug.Attribute("Width"));
            Assert.Null(ug.Attribute("MaxWidth"));
            var hAlign = (string?)ug.Attribute("HorizontalAlignment");
            Assert.True(hAlign == null || hAlign == "Stretch", $"UniformGrid in {viewFileName} must stretch horizontally, but was {hAlign}");
        }
    }

    [Fact]
    public void ConnectivityView_PointAndPrintFormGrid_InputColumnUsesResponsiveStarWidth()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "ConnectivityView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        // Locate Point & Print Tab (Tab 3) and find its form grid containing SelectedPreset ComboBox
        var tab3 = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "TabItem" && ((string?)d.Attribute("Header"))?.Contains("Point & Print") == true);
        Assert.NotNull(tab3);

        var formGrid = tab3.Descendants().FirstOrDefault(d => d.Name.LocalName == "Grid" && d.Descendants().Any(c => ((string?)c.Attribute("SelectedItem"))?.Contains("SelectedPreset") == true));
        Assert.NotNull(formGrid);

        var colDefs = formGrid.Element(formGrid.Name.Namespace + "Grid.ColumnDefinitions")?.Elements().ToList();
        Assert.NotNull(colDefs);
        Assert.Equal(4, colDefs.Count);
        Assert.Equal("170", (string?)colDefs[0].Attribute("Width"));
        Assert.Equal("*", (string?)colDefs[1].Attribute("Width")); // Responsive input column
        Assert.Equal("12", (string?)colDefs[2].Attribute("Width"));
        Assert.Equal("Auto", (string?)colDefs[3].Attribute("Width"));
    }

    [Theory]
    [InlineData("SystemHealthView.xaml", "CustomWimSource")]
    [InlineData("OfficeOutlookView.xaml", "RelocationDestinationDir")]
    [InlineData("OfficeOutlookView.xaml", "BackupDirectory")]
    [InlineData("OfficeOutlookView.xaml", "SourcePstPath")]
    [InlineData("OfficeOutlookView.xaml", "TargetPstPath")]
    [InlineData("ConnectivityView.xaml", "AvailableAdapters")]
    [InlineData("IdentityBackupView.xaml", "NewAdminPassword")]
    [InlineData("IdentityBackupView.xaml", "NewAccountUsername")]
    [InlineData("IdentityBackupView.xaml", "NewAccountPassword")]
    [InlineData("IdentityBackupView.xaml", "DomainTestName")]
    [InlineData("IdentityBackupView.xaml", "DomainUserSamName")]
    [InlineData("IdentityBackupView.xaml", "BackupDestinationDirectory")]
    [InlineData("IdentityBackupView.xaml", "RestoreBackupDirectory")]
    [InlineData("SoftwareOptimizationView.xaml", "CustomDebloatScriptUrl")]
    public void AllViews_FormInputGrids_UseResponsiveStarWidthColumns(string viewFileName, string bindingProperty)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        var inputControl = doc.Descendants().FirstOrDefault(d => d.Attributes().Any(a => a.Value.Contains(bindingProperty)));
        Assert.NotNull(inputControl);

        var formGrid = inputControl.Ancestors().FirstOrDefault(a => a.Name.LocalName == "Grid" && a.Elements().Any(e => e.Name.LocalName == "Grid.ColumnDefinitions"));
        Assert.NotNull(formGrid);

        var colDefs = formGrid.Element(formGrid.Name.Namespace + "Grid.ColumnDefinitions")?.Elements().ToList();
        Assert.NotNull(colDefs);

        // Ensure the column containing this specific input control is configured with responsive star width
        int inputColIndex = int.Parse((string?)inputControl.Attribute("Grid.Column") ?? "0");
        Assert.True(inputColIndex < colDefs.Count, $"Grid.Column ({inputColIndex}) exceeded column definitions count ({colDefs.Count}) in {viewFileName}");
        Assert.Equal("*", (string?)colDefs[inputColIndex].Attribute("Width"));
    }

    [Theory]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    public void ViewsWithDataGrids_ColumnsExpandWithResponsiveStarWidth(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        var dataGrids = doc.Descendants().Where(d => d.Name.LocalName == "DataGrid").ToList();
        Assert.NotEmpty(dataGrids);

        foreach (var dg in dataGrids)
        {
            Assert.Null(dg.Attribute("Width"));
            Assert.Null(dg.Attribute("MaxWidth"));
            var hAlign = (string?)dg.Attribute("HorizontalAlignment");
            Assert.True(hAlign == null || hAlign == "Stretch");

            var columns = dg.Descendants().Where(d => d.Name.LocalName.EndsWith("Column")).ToList();
            Assert.NotEmpty(columns);
            Assert.Contains(columns, col => (string?)col.Attribute("Width") == "*");
        }
    }

    [Fact]
    public void MainWindow_ContentControl_StretchesFullWorkspace()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        var contentControl = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "ContentControl" && ((string?)d.Attribute("Content"))?.Contains("CurrentPageViewModel") == true);
        Assert.NotNull(contentControl);
        Assert.Null(contentControl.Attribute("Width"));
        Assert.Null(contentControl.Attribute("MaxWidth"));
        var hAlign = (string?)contentControl.Attribute("HorizontalAlignment");
        Assert.True(hAlign == null || hAlign == "Stretch");
        Assert.Equal("Stretch", contentControl.Attribute("HorizontalContentAlignment")?.Value);
        Assert.Equal("Stretch", contentControl.Attribute("VerticalContentAlignment")?.Value);

        // Find the main workspace grid that splits navigation rail (Column 0, width 175) and workspace (Column 1, width *)
        var mainWorkspaceGrid = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Grid" && d.Element(d.Name.Namespace + "Grid.ColumnDefinitions") != null);
        Assert.NotNull(mainWorkspaceGrid);
        var colDefs = mainWorkspaceGrid.Element(mainWorkspaceGrid.Name.Namespace + "Grid.ColumnDefinitions")?.Elements().ToList();
        Assert.NotNull(colDefs);
        Assert.Equal(2, colDefs.Count);
        Assert.Equal("175", (string?)colDefs[0].Attribute("Width"));
        Assert.Equal("*", (string?)colDefs[1].Attribute("Width"));
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
    public void DashboardView_ContainsDetailedTelemetryBindings()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", "DashboardView.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);

        Assert.Contains("CpuUsagePercentage", xaml);
        Assert.Contains("MemoryPercentage", xaml);
        Assert.Contains("DiskFreeSpaceText", xaml);
        Assert.Contains("OsDescription", xaml);
        Assert.Contains("OsBuild", xaml);
        Assert.Contains("ElevationBadgeText", xaml);
        Assert.Contains("NetworkStatusText", xaml);
        Assert.Contains("ComputerName", xaml);
        Assert.Contains("DomainOrWorkgroup", xaml);
        Assert.Contains("CurrentUser", xaml);
        Assert.Contains("UserProfilePath", xaml);
        Assert.Contains("OsArchitecture", xaml);
        Assert.Contains("SystemUptime", xaml);
        Assert.Contains("SystemManufacturerModel", xaml);
        Assert.Contains("CpuModelName", xaml);
        Assert.Contains("GpuModelName", xaml);
        Assert.Contains("BiosAndSerial", xaml);
        Assert.Contains("AllDrivesSummary", xaml);
        Assert.Contains("PrimaryNetworkAdapter", xaml);
        Assert.Contains("Ipv4Address", xaml);
        Assert.Contains("DefaultGateway", xaml);
        Assert.Contains("DnsServers", xaml);
        Assert.Contains("MacAddress", xaml);
    }

    [Fact]
    public void MainWindow_ActivityConsole_IsNotDockedInMainWindow()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "MainWindow.xaml");
        Assert.True(File.Exists(path));

        string xaml = File.ReadAllText(path);
        Assert.DoesNotContain("ActivityConsoleView", xaml);
        Assert.DoesNotContain("GridSplitter", xaml);
        Assert.DoesNotContain("TelemetryHeaderView", xaml);

        XDocument doc = XDocument.Parse(xaml);
        var rootGrid = doc.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "Grid");
        Assert.NotNull(rootGrid);

        var rowDefs = rootGrid.Elements()
            .FirstOrDefault(e => e.Name.LocalName == "Grid.RowDefinitions")
            ?.Elements()
            .Where(e => e.Name.LocalName == "RowDefinition")
            .ToList();

        // RowDefinitions for telemetry header and split rows are removed; root Grid spans full height
        Assert.True(rowDefs == null || rowDefs.Count == 0);
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

    [Fact]
    public void AppXaml_DefinesFluentButtonStyles_WithRoundedBordersAndVisualStates()
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "App.xaml");
        Assert.True(File.Exists(path), $"App.xaml not found at: {path}");

        string xaml = File.ReadAllText(path);
        Assert.Contains("x:Key=\"FluentButtonStyle\"", xaml);
        Assert.Contains("x:Key=\"AccentButtonStyle\"", xaml);
        Assert.Contains("CornerRadius=\"4\"", xaml);

        XDocument doc = XDocument.Parse(xaml);
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";

        // 1. Verify FluentButtonStyle
        var fluentButtonStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute(x + "Key") == "FluentButtonStyle");
        Assert.NotNull(fluentButtonStyle);
        Assert.Equal("Button", (string?)fluentButtonStyle.Attribute("TargetType"));

        // Verify FluentButtonStyle setters
        Assert.Equal("{x:Null}", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "FocusVisualStyle")?.Attribute("Value"));
        Assert.Equal("{DynamicResource CardBackgroundFillColorDefaultBrush}", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Background")?.Attribute("Value"));
        Assert.Equal("{DynamicResource TextFillColorPrimaryBrush}", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Foreground")?.Attribute("Value"));
        Assert.Equal("{DynamicResource CardStrokeColorDefaultBrush}", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "BorderBrush")?.Attribute("Value"));
        Assert.Equal("1", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "BorderThickness")?.Attribute("Value"));
        Assert.Equal("12,5", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Padding")?.Attribute("Value"));
        Assert.Equal("12", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "FontSize")?.Attribute("Value"));
        Assert.Equal("Hand", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Cursor")?.Attribute("Value"));
        Assert.Equal("True", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "SnapsToDevicePixels")?.Attribute("Value"));
        Assert.Equal("Center", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "HorizontalContentAlignment")?.Attribute("Value"));
        Assert.Equal("Center", (string?)fluentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "VerticalContentAlignment")?.Attribute("Value"));

        // Verify FluentButtonStyle ContentPresenter properties
        var defaultPresenter = fluentButtonStyle.Descendants().FirstOrDefault(d => d.Name.LocalName == "ContentPresenter" && (string?)d.Attribute(x + "Name") == "ContentPresenter");
        Assert.NotNull(defaultPresenter);
        Assert.Equal("False", (string?)defaultPresenter.Attribute("Focusable"));
        Assert.Equal("True", (string?)defaultPresenter.Attribute("RecognizesAccessKey"));
        Assert.Equal("{TemplateBinding HorizontalContentAlignment}", (string?)defaultPresenter.Attribute("HorizontalAlignment"));
        Assert.Equal("{TemplateBinding VerticalContentAlignment}", (string?)defaultPresenter.Attribute("VerticalAlignment"));
        Assert.Equal("{TemplateBinding SnapsToDevicePixels}", (string?)defaultPresenter.Attribute("SnapsToDevicePixels"));

        // Verify FluentButtonStyle ControlTemplate and Border with CornerRadius="4"
        var defaultBorder = fluentButtonStyle.Descendants().FirstOrDefault(d => d.Name.LocalName == "Border" && (string?)d.Attribute(x + "Name") == "ButtonBorder");
        Assert.NotNull(defaultBorder);
        Assert.Equal("4", (string?)defaultBorder.Attribute("CornerRadius"));
        Assert.Equal("True", (string?)defaultBorder.Attribute("SnapsToDevicePixels"));
        Assert.Equal("{TemplateBinding Background}", (string?)defaultBorder.Attribute("Background"));
        Assert.Equal("{TemplateBinding BorderBrush}", (string?)defaultBorder.Attribute("BorderBrush"));
        Assert.Equal("{TemplateBinding BorderThickness}", (string?)defaultBorder.Attribute("BorderThickness"));
        Assert.Equal("{TemplateBinding Padding}", (string?)defaultBorder.Attribute("Padding"));

        // Verify triggers for FluentButtonStyle (IsKeyboardFocused, IsMouseOver, IsPressed, IsEnabled)
        var defaultTriggers = fluentButtonStyle.Descendants().Where(d => d.Name.LocalName == "Trigger").ToList();
        var kbFocusTrigger = defaultTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsKeyboardFocused" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(kbFocusTrigger);
        Assert.Contains(kbFocusTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && ((string?)s.Attribute("Value"))?.Contains("AccentFillColorDefaultBrush") == true);

        var mouseOverTrigger = defaultTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsMouseOver" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(mouseOverTrigger);
        Assert.Contains(mouseOverTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "Background" && ((string?)s.Attribute("Value"))?.Contains("SubtleFillColorSecondaryBrush") == true);
        Assert.Contains(mouseOverTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && (string?)s.Attribute("Value") == "#CBD5E1");
        Assert.Contains(mouseOverTrigger.Elements(), s => (string?)s.Attribute("Property") == "Foreground" && ((string?)s.Attribute("Value"))?.Contains("TextFillColorPrimaryBrush") == true);

        var isPressedTrigger = defaultTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsPressed" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(isPressedTrigger);
        Assert.Contains(isPressedTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "Background" && (string?)s.Attribute("Value") == "#E2E8F0");
        Assert.Contains(isPressedTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && (string?)s.Attribute("Value") == "#94A3B8");
        Assert.Contains(isPressedTrigger.Elements(), s => (string?)s.Attribute("Property") == "Foreground" && ((string?)s.Attribute("Value"))?.Contains("TextFillColorPrimaryBrush") == true);

        var isEnabledTrigger = defaultTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsEnabled" && (string?)t.Attribute("Value") == "False");
        Assert.NotNull(isEnabledTrigger);
        Assert.Contains(isEnabledTrigger.Elements(), s => (string?)s.Attribute("Property") == "Opacity" && (string?)s.Attribute("Value") == "0.5");

        // 2. Verify AccentButtonStyle
        var accentButtonStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute(x + "Key") == "AccentButtonStyle");
        Assert.NotNull(accentButtonStyle);
        Assert.Equal("Button", (string?)accentButtonStyle.Attribute("TargetType"));
        Assert.Equal("{StaticResource FluentButtonStyle}", (string?)accentButtonStyle.Attribute("BasedOn"));

        // Verify AccentButtonStyle setters
        Assert.Equal("{DynamicResource AccentFillColorDefaultBrush}", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Background")?.Attribute("Value"));
        Assert.Equal("#FFFFFF", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Foreground")?.Attribute("Value"));
        Assert.Equal("{DynamicResource AccentTextFillColorPrimaryBrush}", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "BorderBrush")?.Attribute("Value"));
        Assert.Equal("1", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "BorderThickness")?.Attribute("Value"));
        Assert.Equal("SemiBold", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "FontWeight")?.Attribute("Value"));
        Assert.Equal("Hand", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "Cursor")?.Attribute("Value"));
        Assert.Equal("True", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "SnapsToDevicePixels")?.Attribute("Value"));
        Assert.Equal("Center", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "HorizontalContentAlignment")?.Attribute("Value"));
        Assert.Equal("Center", (string?)accentButtonStyle.Elements().FirstOrDefault(e => (string?)e.Attribute("Property") == "VerticalContentAlignment")?.Attribute("Value"));

        // Verify AccentButtonStyle ContentPresenter properties
        var accentPresenter = accentButtonStyle.Descendants().FirstOrDefault(d => d.Name.LocalName == "ContentPresenter" && (string?)d.Attribute(x + "Name") == "ContentPresenter");
        Assert.NotNull(accentPresenter);
        Assert.Equal("False", (string?)accentPresenter.Attribute("Focusable"));
        Assert.Equal("True", (string?)accentPresenter.Attribute("RecognizesAccessKey"));
        Assert.Equal("{TemplateBinding HorizontalContentAlignment}", (string?)accentPresenter.Attribute("HorizontalAlignment"));
        Assert.Equal("{TemplateBinding VerticalContentAlignment}", (string?)accentPresenter.Attribute("VerticalAlignment"));
        Assert.Equal("{TemplateBinding SnapsToDevicePixels}", (string?)accentPresenter.Attribute("SnapsToDevicePixels"));

        // Verify AccentButtonStyle ControlTemplate and Border with CornerRadius="4"
        var accentBorder = accentButtonStyle.Descendants().FirstOrDefault(d => d.Name.LocalName == "Border" && (string?)d.Attribute(x + "Name") == "ButtonBorder");
        Assert.NotNull(accentBorder);
        Assert.Equal("4", (string?)accentBorder.Attribute("CornerRadius"));
        Assert.Equal("True", (string?)accentBorder.Attribute("SnapsToDevicePixels"));
        Assert.Equal("{TemplateBinding Background}", (string?)accentBorder.Attribute("Background"));
        Assert.Equal("{TemplateBinding BorderBrush}", (string?)accentBorder.Attribute("BorderBrush"));
        Assert.Equal("{TemplateBinding BorderThickness}", (string?)accentBorder.Attribute("BorderThickness"));
        Assert.Equal("{TemplateBinding Padding}", (string?)accentBorder.Attribute("Padding"));

        // Verify triggers for AccentButtonStyle (IsKeyboardFocused, IsMouseOver, IsPressed, IsEnabled)
        var accentTriggers = accentButtonStyle.Descendants().Where(d => d.Name.LocalName == "Trigger").ToList();
        var accentKbFocusTrigger = accentTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsKeyboardFocused" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(accentKbFocusTrigger);
        Assert.Contains(accentKbFocusTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && (string?)s.Attribute("Value") == "#004578");

        var accentMouseOverTrigger = accentTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsMouseOver" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(accentMouseOverTrigger);
        Assert.Contains(accentMouseOverTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "Background" && (string?)s.Attribute("Value") == "#1879CD");
        Assert.Contains(accentMouseOverTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && (string?)s.Attribute("Value") == "#005A9E");
        Assert.Contains(accentMouseOverTrigger.Elements(), s => (string?)s.Attribute("Property") == "Foreground" && (string?)s.Attribute("Value") == "#FFFFFF");

        var accentIsPressedTrigger = accentTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsPressed" && (string?)t.Attribute("Value") == "True");
        Assert.NotNull(accentIsPressedTrigger);
        Assert.Contains(accentIsPressedTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "Background" && (string?)s.Attribute("Value") == "#005A9E");
        Assert.Contains(accentIsPressedTrigger.Elements(), s => (string?)s.Attribute("TargetName") == "ButtonBorder" && (string?)s.Attribute("Property") == "BorderBrush" && (string?)s.Attribute("Value") == "#004578");
        Assert.Contains(accentIsPressedTrigger.Elements(), s => (string?)s.Attribute("Property") == "Foreground" && (string?)s.Attribute("Value") == "#FFFFFF");

        var accentIsEnabledTrigger = accentTriggers.FirstOrDefault(t => (string?)t.Attribute("Property") == "IsEnabled" && (string?)t.Attribute("Value") == "False");
        Assert.NotNull(accentIsEnabledTrigger);
        Assert.Contains(accentIsEnabledTrigger.Elements(), s => (string?)s.Attribute("Property") == "Opacity" && (string?)s.Attribute("Value") == "0.5");

        // 3. Verify implicit default Style for Button applies FluentButtonStyle
        var defaultImplicitButtonStyle = doc.Descendants().FirstOrDefault(d => d.Name.LocalName == "Style" && (string?)d.Attribute("TargetType") == "Button" && d.Attribute(x + "Key") == null);
        Assert.NotNull(defaultImplicitButtonStyle);
        Assert.Equal("{StaticResource FluentButtonStyle}", (string?)defaultImplicitButtonStyle.Attribute("BasedOn"));
    }

    [Theory]
    [InlineData("DashboardView.xaml")]
    [InlineData("SystemHealthView.xaml")]
    [InlineData("OfficeOutlookView.xaml")]
    [InlineData("ConnectivityView.xaml")]
    [InlineData("IdentityBackupView.xaml")]
    [InlineData("SoftwareOptimizationView.xaml")]
    [InlineData("ActivityConsoleView.xaml")]
    public void AllSevenViews_ButtonStylesAndLayoutConstraints_AreStandardized(string viewFileName)
    {
        string path = Path.Combine(SolutionRoot, "src", "IToolkit.App", "Views", viewFileName);
        Assert.True(File.Exists(path), $"View file not found: {path}");

        string xaml = File.ReadAllText(path);
        XDocument doc = XDocument.Parse(xaml);

        var buttons = doc.Descendants().Where(d => d.Name.LocalName == "Button").ToList();
        Assert.NotEmpty(buttons);

        foreach (var button in buttons)
        {
            string? style = (string?)button.Attribute("Style");
            // Must either inherit implicit default style or use AccentButtonStyle / FluentButtonStyle
            Assert.True(
                style == null ||
                style.Contains("AccentButtonStyle") ||
                style.Contains("FluentButtonStyle"),
                $"Button in {viewFileName} with content '{(string?)button.Attribute("Content")}' has unauthorized style: {style}");

            // Must not override template, corner radius, cursor, border thickness, or brushes inline
            Assert.Null(button.Element(button.Name.Namespace + "Button.Template"));
            Assert.Null(button.Attribute("CornerRadius"));
            Assert.Null(button.Attribute("Cursor"));
            Assert.Null(button.Attribute("BorderThickness"));
            Assert.Null(button.Attribute("Background"));
            Assert.Null(button.Attribute("Foreground"));
            Assert.Null(button.Attribute("BorderBrush"));

            // Verify button has non-empty content and non-empty command binding
            Assert.False(string.IsNullOrWhiteSpace((string?)button.Attribute("Content")),
                $"Button in {viewFileName} has empty Content attribute.");
            Assert.NotNull(button.Attribute("Command"));
            Assert.False(string.IsNullOrWhiteSpace((string?)button.Attribute("Command")),
                $"Button in {viewFileName} with content '{(string?)button.Attribute("Content")}' has empty Command attribute.");

            // Verify padding exists and has sensible constraints (compact layout friendly)
            string? paddingStr = (string?)button.Attribute("Padding");
            if (paddingStr != null)
            {
                string[] parts = paddingStr.Split(',');
                double horizPadding = double.Parse(parts[0].Trim());
                double vertPadding = parts.Length > 1 ? double.Parse(parts[1].Trim()) : horizPadding;

                Assert.True(horizPadding >= 4 && horizPadding <= 24, $"Button horizontal padding ({horizPadding}) in {viewFileName} is outside reasonable bounds.");
                Assert.True(vertPadding >= 1 && vertPadding <= 12, $"Button vertical padding ({vertPadding}) in {viewFileName} is outside reasonable bounds.");

                // If 4 parts specified, also validate right and bottom padding
                if (parts.Length == 4)
                {
                    double rightPadding = double.Parse(parts[2].Trim());
                    double bottomPadding = double.Parse(parts[3].Trim());
                    Assert.True(rightPadding >= 4 && rightPadding <= 24, $"Button right padding ({rightPadding}) in {viewFileName} is outside reasonable bounds.");
                    Assert.True(bottomPadding >= 1 && bottomPadding <= 12, $"Button bottom padding ({bottomPadding}) in {viewFileName} is outside reasonable bounds.");
                }
            }

            // Compact toolbar buttons in ActivityConsoleView must all have explicit Height <= 24
            if (viewFileName == "ActivityConsoleView.xaml")
            {
                Assert.NotNull(button.Attribute("Height"));
                double height = double.Parse(button.Attribute("Height")!.Value);
                Assert.True(height <= 24, $"ActivityConsoleView button height ({height}) exceeds 24.");
                Assert.Equal(22, height);
                Assert.Equal("8,2", (string?)button.Attribute("Padding"));
                Assert.Equal("11", (string?)button.Attribute("FontSize"));
                if ((string?)button.Attribute("Content") == "Dismiss")
                {
                    Assert.Equal("8,0,0,0", (string?)button.Attribute("Margin"));
                }
            }
            else
            {
                // Standard action buttons in other views must not have rigid fixed Height or Width that causes clipping on text/DPI scaling
                Assert.Null(button.Attribute("Height"));
                Assert.Null(button.Attribute("Width"));
            }
        }
    }
}

