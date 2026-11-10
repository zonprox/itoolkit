namespace IToolkit.Tests.Software;

using System;
using System.Collections.Generic;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Xunit;

public class WingetCliParserTests
{
    private const string SampleSearchOutput =
        "Name             Id               Version   Match    Source\r\n" +
        "-----------------------------------------------------------\r\n" +
        "7-Zip            7zip.7zip        24.09              winget\r\n" +
        "7-Zip (x86)      7zip.7zip.x86    24.09     Tag: zip winget\r\n" +
        "NanaZip          M2Team.NanaZip   3.1.1000  Tag: 7z  winget\r\n";

    private const string SampleInstalledOutput =
        "Name                                                 Id                                        Version          Available Source\r\n" +
        "--------------------------------------------------------------------------------------------------------------------------------\r\n" +
        "Autodesk AutoCAD 2021 - English                      ARP\\Machine\\X64\\AutoCAD 2021 - English    24.0.47.0                  \r\n" +
        "Git                                                  Git.Git                                   2.55.0.5         2.56.0.4  winget\r\n" +
        "RustDesk                                             ARP\\Machine\\X64\\RustDesk                  1.5.1                      \r\n" +
        "UltraVNC                                             uvncbvba.UltraVNC                         1.8.3.2                    winget\r\n";

    private const string SampleAvailableUpdatesOutput =
        "Name   Id           Version  Available Source\r\n" +
        "---------------------------------------------\r\n" +
        "Git    Git.Git      2.55.0.5 2.56.0.4  winget\r\n" +
        "Zalo   VNGCorp.Zalo 24.1.1   24.2.0    winget\r\n" +
        "2 upgrades available.\r\n";

    // ================= 1. Search Table Parsing Tests =================

    [Fact]
    public void ParsePackages_StandardOutputWithMatchAndSource_ParsesAllColumns()
    {
        string output =
            "Name                               Id                        Version         Match         Source\n" +
            "-------------------------------------------------------------------------------------------------\n" +
            "7-Zip                              7zip.7zip                 26.06           Moniker: 7zip winget\n" +
            "NanaZip                            M2Team.NanaZip            7.0.1882.0      Tag: 7zip     winget\n";

        var packages = WingetCliParser.ParsePackages(output);

        Assert.Equal(2, packages.Count);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("26.06", packages[0].Version);
        Assert.Equal("Moniker: 7zip", packages[0].Match);
        Assert.Equal("winget", packages[0].Source);

        Assert.Equal("NanaZip", packages[1].Name);
        Assert.Equal("M2Team.NanaZip", packages[1].Id);
        Assert.Equal("7.0.1882.0", packages[1].Version);
        Assert.Equal("Tag: 7zip", packages[1].Match);
        Assert.Equal("winget", packages[1].Source);
    }

    [Fact]
    public void ParseSearchResults_StandardTable_ReturnsParsedPackages()
    {
        var packages = WingetCliParser.ParseSearchResults(SampleSearchOutput);

        Assert.NotNull(packages);
        Assert.Equal(3, packages.Count);

        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("24.09", packages[0].Version);
        Assert.True(string.IsNullOrEmpty(packages[0].Match));
        Assert.Equal("winget", packages[0].Source);

        Assert.Equal("7-Zip (x86)", packages[1].Name);
        Assert.Equal("7zip.7zip.x86", packages[1].Id);
        Assert.Equal("24.09", packages[1].Version);
        Assert.Equal("Tag: zip", packages[1].Match);
        Assert.Equal("winget", packages[1].Source);

        Assert.Equal("NanaZip", packages[2].Name);
        Assert.Equal("M2Team.NanaZip", packages[2].Id);
        Assert.Equal("3.1.1000", packages[2].Version);
        Assert.Equal("Tag: 7z", packages[2].Match);
        Assert.Equal("winget", packages[2].Source);
    }

    [Fact]
    public void ParsePackages_OmittedSourceColumn_DefaultsSourceToWinget()
    {
        string output =
            "Name     Id        Version Match\n" +
            "-----------------------------------------\n" +
            "7-Zip    7zip.7zip 26.06   Moniker: 7zip\n" +
            "7zr      7zip.7zr  26.06                \n";

        var packages = WingetCliParser.ParsePackages(output);

        Assert.Equal(2, packages.Count);
        Assert.Equal("winget", packages[0].Source);
        Assert.Equal("Moniker: 7zip", packages[0].Match);
        Assert.Equal("winget", packages[1].Source);
        Assert.Null(packages[1].Match);
    }

    [Fact]
    public void ParsePackages_ExactSearchWithoutMatchOrSource_ParsesNameIdVersion()
    {
        string output =
            "Name  Id        Version\n" +
            "-----------------------\n" +
            "7-Zip 7zip.7zip 26.06\n";

        var packages = WingetCliParser.ParsePackages(output);

        Assert.Single(packages);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("26.06", packages[0].Version);
        Assert.Null(packages[0].Match);
        Assert.Equal("winget", packages[0].Source);
    }

    [Fact]
    public void ParseSearchResults_WithMsStoreWarning_IgnoresWarningLineAndParsesTable()
    {
        string outputWithWarning =
            "Failed when searching source; results will not be included: msstore\r\n" +
            "Name   Id        Version Match Source\r\n" +
            "-------------------------------------\r\n" +
            "7-Zip  7zip.7zip 24.09         winget\r\n";

        var packages = WingetCliParser.ParseSearchResults(outputWithWarning);

        Assert.Single(packages);
        Assert.Equal("7-Zip", packages[0].Name);
        Assert.Equal("7zip.7zip", packages[0].Id);
        Assert.Equal("winget", packages[0].Source);
    }

    [Fact]
    public void ParseSearchResults_WithTruncationMarker_SkipsTruncationLine()
    {
        string outputWithTruncation =
            SampleSearchOutput +
            "<additional entries truncated due to result limit>\r\n";

        var packages = WingetCliParser.ParseSearchResults(outputWithTruncation);

        Assert.Equal(3, packages.Count);
        Assert.DoesNotContain(packages, p => p.Name.Contains("additional entries"));
    }

    [Fact]
    public void ParseSearchResults_WideColumnsAndAppNamesWithSpaces_PreservesInternalSpaces()
    {
        string wideTable =
            "Name                                                 Id                                        Version          Match Source\r\n" +
            "----------------------------------------------------------------------------------------------------------------------------\r\n" +
            "Autodesk AutoCAD 2021 - English                      ARP\\Machine\\X64\\AutoCAD 2021 - English    24.0.47.0              winget\r\n" +
            "Microsoft Visual C++ 2015-2022 Redistributable (x64) Microsoft.VCRedist.2015+.x64              14.40.33810.0         winget\r\n";

        var packages = WingetCliParser.ParseSearchResults(wideTable);

        Assert.Equal(2, packages.Count);
        Assert.Equal("Autodesk AutoCAD 2021 - English", packages[0].Name);
        Assert.Equal("ARP\\Machine\\X64\\AutoCAD 2021 - English", packages[0].Id);
        Assert.Equal("24.0.47.0", packages[0].Version);

        Assert.Equal("Microsoft Visual C++ 2015-2022 Redistributable (x64)", packages[1].Name);
        Assert.Equal("Microsoft.VCRedist.2015+.x64", packages[1].Id);
        Assert.Equal("14.40.33810.0", packages[1].Version);
    }

    // ================= 2. Installed Apps Table Parsing Tests =================

    [Fact]
    public void ParseInstalledApps_MixedArpAndWinget_ParsesCorrectly()
    {
        var apps = WingetCliParser.ParseInstalledApps(SampleInstalledOutput);

        Assert.Equal(4, apps.Count);

        // ARP package without Available version and without Source
        Assert.Equal("Autodesk AutoCAD 2021 - English", apps[0].Name);
        Assert.Equal("ARP\\Machine\\X64\\AutoCAD 2021 - English", apps[0].Id);
        Assert.Equal("24.0.47.0", apps[0].Version);
        Assert.Null(apps[0].AvailableVersion);
        Assert.Equal(string.Empty, apps[0].Source);

        // Winget package with available update
        Assert.Equal("Git", apps[1].Name);
        Assert.Equal("Git.Git", apps[1].Id);
        Assert.Equal("2.55.0.5", apps[1].Version);
        Assert.Equal("2.56.0.4", apps[1].AvailableVersion);
        Assert.Equal("winget", apps[1].Source);

        // ARP package
        Assert.Equal("RustDesk", apps[2].Name);
        Assert.Equal("ARP\\Machine\\X64\\RustDesk", apps[2].Id);
        Assert.Equal("1.5.1", apps[2].Version);
        Assert.Null(apps[2].AvailableVersion);

        // Winget package without available update
        Assert.Equal("UltraVNC", apps[3].Name);
        Assert.Equal("uvncbvba.UltraVNC", apps[3].Id);
        Assert.Equal("1.8.3.2", apps[3].Version);
        Assert.Null(apps[3].AvailableVersion);
        Assert.Equal("winget", apps[3].Source);
    }

    [Fact]
    public void ParseInstalledApps_WhenAvailableColumnOmitted_ParsesRemainingColumns()
    {
        string omittedAvailableOutput =
            "Name     Id                Version Source\r\n" +
            "------------------------------------------\r\n" +
            "UltraVNC uvncbvba.UltraVNC 1.8.3.2 winget\r\n";

        var apps = WingetCliParser.ParseInstalledApps(omittedAvailableOutput);

        Assert.Single(apps);
        Assert.Equal("UltraVNC", apps[0].Name);
        Assert.Equal("uvncbvba.UltraVNC", apps[0].Id);
        Assert.Equal("1.8.3.2", apps[0].Version);
        Assert.Null(apps[0].AvailableVersion);
        Assert.Equal("winget", apps[0].Source);
    }

    [Fact]
    public void ParseInstalledApps_WithTruncationMarker_SkipsTruncationLine()
    {
        string outputWithTruncation =
            SampleInstalledOutput +
            "<additional entries truncated due to result limit>\r\n";

        var apps = WingetCliParser.ParseInstalledApps(outputWithTruncation);

        Assert.Equal(4, apps.Count);
        Assert.DoesNotContain(apps, a => a.Name.Contains("additional entries"));
    }

    // ================= 3. Available Updates Table Parsing Tests =================

    [Fact]
    public void ParseAvailableUpdates_WithSummaryCount_FiltersSummaryLineAndParsesItems()
    {
        var updates = WingetCliParser.ParseAvailableUpdates(SampleAvailableUpdatesOutput);

        Assert.Equal(2, updates.Count);

        Assert.Equal("Git", updates[0].Name);
        Assert.Equal("Git.Git", updates[0].Id);
        Assert.Equal("2.55.0.5", updates[0].InstalledVersion);
        Assert.Equal("2.56.0.4", updates[0].AvailableVersion);
        Assert.Equal("winget", updates[0].Source);

        Assert.Equal("Zalo", updates[1].Name);
        Assert.Equal("VNGCorp.Zalo", updates[1].Id);
        Assert.Equal("24.1.1", updates[1].InstalledVersion);
        Assert.Equal("24.2.0", updates[1].AvailableVersion);
        Assert.Equal("winget", updates[1].Source);
    }

    [Fact]
    public void ParseAvailableUpdates_SingleUpgrade_FiltersSingularSummaryLine()
    {
        string singleUpgradeOutput =
            "Name Id      Version  Available Source\r\n" +
            "--------------------------------------\r\n" +
            "Git  Git.Git 2.55.0.5 2.56.0.4  winget\r\n" +
            "1 upgrade available.\r\n";

        var updates = WingetCliParser.ParseAvailableUpdates(singleUpgradeOutput);

        Assert.Single(updates);
        Assert.Equal("Git", updates[0].Name);
    }

    [Fact]
    public void ParseAvailableUpdates_WithPinnedNotice_SkipsPinnedNoticeLine()
    {
        string outputWithPinned =
            "Name Id      Version  Available Source\r\n" +
            "--------------------------------------\r\n" +
            "Git  Git.Git 2.55.0.5 2.56.0.4  winget\r\n" +
            "1 upgrade available.\r\n" +
            "1 package has pins that prevent upgrade. Use --include-pinned to see them.\r\n";

        var updates = WingetCliParser.ParseAvailableUpdates(outputWithPinned);

        Assert.Single(updates);
        Assert.Equal("Git", updates[0].Name);
    }

    [Theory]
    [InlineData("No available upgrade found.")]
    [InlineData("No package found matching input criteria.")]
    [InlineData("")]
    public void ParseAvailableUpdates_NoUpdatesAvailable_ReturnsEmptyList(string output)
    {
        var updates = WingetCliParser.ParseAvailableUpdates(output);

        Assert.NotNull(updates);
        Assert.Empty(updates);
    }

    // ================= 4. Exit Code Evaluation Tests =================

    [Theory]
    [InlineData(0, true, false, false, false)]
    [InlineData(3010, true, true, false, false)]
    [InlineData(unchecked((int)0x8A15002B), true, false, true, false)]
    [InlineData(unchecked((int)0x8A150061), true, false, false, false)]
    [InlineData(1223, false, false, false, true)]
    [InlineData(unchecked((int)0x8A150019), false, false, false, false)]
    [InlineData(unchecked((int)0x8A150014), false, false, false, false)]
    public void ParseExitCode_KeyCodes_ProduceAccurateFlags(
        int exitCode,
        bool expectedSuccess,
        bool expectedReboot,
        bool expectedUpToDate,
        bool expectedCancelled)
    {
        var result = WingetCliParser.ParseExitCode(exitCode, "Install", "7zip.7zip");

        Assert.Equal(expectedSuccess, result.Success);
        Assert.Equal(expectedReboot, result.RebootRequired);
        Assert.Equal(expectedUpToDate, result.AlreadyUpToDate);
        Assert.Equal(expectedCancelled, result.CancelledByUser);
    }

    [Fact]
    public void ParseExitCode_RequiresAdmin_SetsRequiresAdminFlag()
    {
        var result = WingetCliParser.ParseExitCode(WingetCliParser.ExitCodeCommandRequiresAdmin, "Install", "7zip.7zip");
        Assert.False(result.Success);
        Assert.True(result.RequiresAdmin);
        Assert.Contains("administrator privileges", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(0, true, "Success")]
    [InlineData(3010, true, "Reboot required")]
    [InlineData(-1978335189, true, "Already up-to-date")]
    [InlineData(-1978335212, false, "No package found")]
    [InlineData(-1978335210, false, "Multiple packages")]
    [InlineData(-1978335068, false, "Administrator")]
    [InlineData(1223, false, "cancelled")]
    [InlineData(1, false, "failed")]
    public void EvaluateExitCode_StandardExitCodes_ReturnsExpectedStatus(int exitCode, bool expectedSuccess, string messageKeyword)
    {
        var (success, message) = WingetCliParser.EvaluateExitCode(exitCode);

        Assert.Equal(expectedSuccess, success);
        Assert.Contains(messageKeyword, message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void CreateInstallResult_MapsToAppInstallResultCorrectly()
    {
        var result = WingetCliParser.CreateInstallResult("7zip.7zip", "7-Zip", 0);

        Assert.Equal("7zip.7zip", result.AppId);
        Assert.Equal("7-Zip", result.DisplayName);
        Assert.Equal("Winget", result.MethodUsed);
        Assert.True(result.Success);
        Assert.True(result.TempCleanedUp);
    }

    [Fact]
    public void QuickCheckHelpers_ValidateExitCodesDirectly()
    {
        Assert.True(WingetCliParser.IsSuccess(0));
        Assert.False(WingetCliParser.IsSuccess(1));

        Assert.True(WingetCliParser.IsRebootRequired(3010));
        Assert.False(WingetCliParser.IsRebootRequired(0));

        Assert.True(WingetCliParser.IsNoApplicationsFound(unchecked((int)0x8A150014)));
        Assert.True(WingetCliParser.IsAlreadyInstalled(unchecked((int)0x8A150061)));
        Assert.True(WingetCliParser.IsAlreadyUpToDate(unchecked((int)0x8A15002B)));
        Assert.True(WingetCliParser.RequiresAdmin(unchecked((int)0x8A150019)));
        Assert.True(WingetCliParser.RequiresAdmin(-1978335068));
        Assert.True(WingetCliParser.IsCancelled(1223));
        Assert.NotEmpty(WingetCliParser.GetErrorMessage(1));
    }

    // ================= 5. Adversarial & Malformed Input Tests =================

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   \r\n   ")]
    [InlineData("Some random text without headers")]
    [InlineData("Name Id Version\nNo dashes separator\nfoo bar baz")]
    public void ParseMethods_MalformedInput_ReturnsEmptySafely(string? malformed)
    {
        Assert.Empty(WingetCliParser.ParsePackages(malformed));
        Assert.Empty(WingetCliParser.ParseInstalledApps(malformed));
        Assert.Empty(WingetCliParser.ParseUpdates(malformed));
    }
}
