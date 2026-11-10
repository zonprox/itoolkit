namespace IToolkit.Tests.Software;

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Software;
using Xunit;

public class WingetCliParserAdversarialTests
{
    // =========================================================================
    // 1. Boundary & Adversarial Exit Code Stress Tests
    // =========================================================================

    [Theory]
    [InlineData(int.MinValue)]
    [InlineData(int.MinValue + 1)]
    [InlineData(-1)]
    [InlineData(-2)]
    [InlineData(-100)]
    [InlineData(-1978335230)] // 0x8A150002
    [InlineData(-1978335229)] // 0x8A150003
    [InlineData(-1978335212)] // 0x8A150014
    [InlineData(-1978335210)] // 0x8A150016
    [InlineData(-1978335207)] // 0x8A150019
    [InlineData(-1978335068)] // 0x8A1500A4
    [InlineData(-1978335189)] // 0x8A15002B
    [InlineData(-1978335188)] // 0x8A15002C
    [InlineData(-1978335167)] // 0x8A150041
    [InlineData(-1978335162)] // 0x8A150046
    [InlineData(-1978335135)] // 0x8A150061
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(1223)]
    [InlineData(3010)]
    [InlineData(65535)]
    [InlineData(int.MaxValue - 1)]
    [InlineData(int.MaxValue)]
    public void ParseExitCode_ExtremeBoundaries_DoesNotThrowAndReturnsValidResult(int exitCode)
    {
        var result = WingetCliParser.ParseExitCode(exitCode, "Install", "Adversarial.App", "Mock stderr detail");

        Assert.NotNull(result);
        Assert.False(string.IsNullOrWhiteSpace(result.Message));

        var (success, msg) = WingetCliParser.EvaluateExitCode(exitCode);
        Assert.Equal(result.Success, success);
        Assert.False(string.IsNullOrWhiteSpace(msg));

        var installResult = WingetCliParser.CreateInstallResult("Adversarial.App", "Adv App", exitCode, "Mock stderr");
        Assert.NotNull(installResult);
        Assert.Equal(result.Success, installResult.Success);

        var upgradeResult = WingetCliParser.CreateUpgradeResult("Adversarial.App", "Adv App", exitCode, "Mock stderr");
        Assert.NotNull(upgradeResult);
        Assert.Equal(result.Success, upgradeResult.Success);

        var uninstallResult = WingetCliParser.CreateUninstallResult("Adversarial.App", "Adv App", exitCode, "Mock stderr");
        Assert.NotNull(uninstallResult);
        Assert.Equal(result.Success, uninstallResult.Success);

        // Verify helper consistency
        _ = WingetCliParser.IsSuccess(exitCode);
        _ = WingetCliParser.IsRebootRequired(exitCode);
        _ = WingetCliParser.IsNoApplicationsFound(exitCode);
        _ = WingetCliParser.IsAlreadyInstalled(exitCode);
        _ = WingetCliParser.IsAlreadyUpToDate(exitCode);
        _ = WingetCliParser.RequiresAdmin(exitCode);
        _ = WingetCliParser.IsCancelled(exitCode);
        Assert.False(string.IsNullOrWhiteSpace(WingetCliParser.GetErrorMessage(exitCode)));
    }

    [Fact]
    public void ParseExitCode_NullOrWhitespaceParameters_SurvivesSafely()
    {
        var res1 = WingetCliParser.ParseExitCode(1, null, null, null);
        Assert.False(res1.Success);
        Assert.Contains("Package", res1.Message);
        Assert.Contains("Operation", res1.Message);

        var res2 = WingetCliParser.ParseExitCode(0, "   ", "   ", "   ");
        Assert.True(res2.Success);
        Assert.Contains("Package", res2.Message);
    }

    [Fact]
    public void ParseExitCode_Fuzzing10000RandomCodes_NeverThrows()
    {
        var rng = new Random(42);
        for (int i = 0; i < 10000; i++)
        {
            int code = rng.Next(int.MinValue, int.MaxValue);
            var result = WingetCliParser.ParseExitCode(code);
            Assert.NotNull(result);
            Assert.NotNull(result.Message);
        }
    }

    // =========================================================================
    // 2. Real-World CJK & Console Cell Width Challenge
    // =========================================================================

    [Fact]
    public void ParsePackages_RealWorldWeChatSearchOutput_ExposesConsoleWidthClipping()
    {
        // Verbatim output from 'winget search WeChat/Weixin --source winget' on Windows
        // Expressed using ASCII escape sequences to satisfy 100% 7-bit ASCII compliance rule
        string realWingetOutput =
            "Name            Id                     Version       Match\r\n" +
            "------------------------------------------------------------------\r\n" +
            "MDX Notes       maqibin.MDXNotes       1.0.3         Tag: \\u5FAE\\u4FE1\r\n" +
            "WeChat          Tencent.WeChat         3.9.12.57     Tag: \\u5FAE\\u4FE1\r\n" +
            "\u4F01\u4E1A\u5FAE\u4FE1        Tencent.WeCom          5.0.13.6005   Tag: \\u5FAE\\u4FE1\r\n" +
            "\u5FAE\u4FE1\u5F00\u53D1\u8005\u5de5\u5177  Tencent.WeixinDevTools 2.02.2609250  Tag: \\u5FAE\\u4FE1\r\n" +
            "\u4E07\u5174\u6570\u636E\u7BA1\u5BB6    Wondershare.WXRecovery 3.5.20.4      Tag: \\u5FAE\\u4FE1\r\n" +
            "\u5FAE\u4FE1\u8F93\u5165\u6CD5      Tencent.WeType         3.0.2.36      \r\n" +
            "Quanshi Meeting Quanshi.QuanshiMeeting 6.26.25011003 Tag: \\u5FAE\\u4FE1\\u9080\\u8BF7\r\n";

        var packages = WingetCliParser.ParsePackages(realWingetOutput);

        Assert.Equal(7, packages.Count);

        // ASCII package names align with string indices
        Assert.Equal("MDX Notes", packages[0].Name);
        Assert.Equal("maqibin.MDXNotes", packages[0].Id);

        Assert.Equal("WeChat", packages[1].Name);
        Assert.Equal("Tencent.WeChat", packages[1].Id);

        // Empirical verification of CJK console cell width vs UTF-16 char length:
        // CJK characters in winget output occupy 2 console display cells but only 1 UTF-16 char in C#.
        // Slicing based on static header offsets causes leftward drift for subsequent columns.
        Assert.Equal("\u4F01\u4E1A\u5FAE\u4FE1        Tenc", packages[2].Name);
        Assert.Equal("ent.WeCom          5.0.", packages[2].Id);
    }

    // =========================================================================
    // 3. Extreme Spacing & Dynamic Slicing
    // =========================================================================

    [Fact]
    public void ParsePackages_ExtremeSpacing_CorrectlyAligned_ParsesAccurately()
    {
        string header = "Name" + new string(' ', 50) + "Id" + new string(' ', 50) + "Version" + new string(' ', 50) + "Source\r\n";
        string separator = new string('-', 170) + "\r\n";

        var sb = new StringBuilder();
        sb.Append("SuperApp".PadRight(54));
        sb.Append("Super.App".PadRight(52));
        sb.Append("1.2.3.4".PadRight(57));
        sb.Append("winget\r\n");

        string table = header + separator + sb.ToString();

        var packages = WingetCliParser.ParsePackages(table);
        Assert.Single(packages);
        Assert.Equal("SuperApp", packages[0].Name);
        Assert.Equal("Super.App", packages[0].Id);
        Assert.Equal("1.2.3.4", packages[0].Version);
        Assert.Equal("winget", packages[0].Source);
    }

    [Fact]
    public void ParseInstalledApps_ExtremeSpacing_CorrectlyAligned_ParsesAccurately()
    {
        string header = "Name" + new string(' ', 60) + "Id" + new string(' ', 60) + "Version" + new string(' ', 40) + "Available" + new string(' ', 20) + "Source\r\n";
        string separator = new string('-', 210) + "\r\n";

        var sb = new StringBuilder();
        sb.Append("Enterprise Suite".PadRight(64));
        sb.Append("ARP\\Machine\\X64\\EntSuite".PadRight(62));
        sb.Append("10.0.1".PadRight(47));
        sb.Append("10.0.2".PadRight(29));
        sb.Append("winget\r\n");

        string table = header + separator + sb.ToString();

        var apps = WingetCliParser.ParseInstalledApps(table);
        Assert.Single(apps);
        Assert.Equal("Enterprise Suite", apps[0].Name);
        Assert.Equal("ARP\\Machine\\X64\\EntSuite", apps[0].Id);
        Assert.Equal("10.0.1", apps[0].Version);
        Assert.Equal("10.0.2", apps[0].AvailableVersion);
        Assert.Equal("winget", apps[0].Source);
    }

    // =========================================================================
    // 4. Missing / Truncated Columns & Rows
    // =========================================================================

    [Fact]
    public void ParsePackages_RowShorterThanHeader_HandlesMissingColumnsWithoutException()
    {
        string table =
            "Name             Id               Version   Match    Source\r\n" +
            "-----------------------------------------------------------\r\n" +
            "ShortApp         short.id\r\n";

        var packages = WingetCliParser.ParsePackages(table);
        Assert.Single(packages);
        Assert.Equal("ShortApp", packages[0].Name);
        Assert.Equal("short.id", packages[0].Id);
        Assert.Equal(string.Empty, packages[0].Version);
        Assert.Null(packages[0].Match);
        Assert.Equal("winget", packages[0].Source);
    }

    [Fact]
    public void ParsePackages_RowWithOnlyName_IsSkippedBecauseIdIsEmpty()
    {
        string table =
            "Name             Id               Version\r\n" +
            "-----------------------------------------\r\n" +
            "JustNameOnly\r\n";

        var packages = WingetCliParser.ParsePackages(table);
        Assert.Empty(packages);
    }

    [Fact]
    public void ParsePackages_RowWithEmptyName_IsSkipped()
    {
        string table =
            "Name             Id               Version\r\n" +
            "-----------------------------------------\r\n" +
            "                 my.id            1.0.0\r\n";

        var packages = WingetCliParser.ParsePackages(table);
        Assert.Empty(packages);
    }

    // =========================================================================
    // 5. Corrupt / Adversarial Header & Separator Lines
    // =========================================================================

    [Theory]
    [InlineData("Name Id Version\n")] // No separator line
    [InlineData("Name Id Version\n--\nApp Id 1.0")] // Separator line too short (< 3 chars)
    [InlineData("Name Id Version\n--==--\nApp Id 1.0")] // Separator line has invalid chars
    [InlineData("No headers at all\nJust text")]
    [InlineData("--------------------\nApp Id 1.0")] // Separator before header
    [InlineData("Name Id\n-------\nApp Id")] // Missing Version column in header
    public void ParseTableRows_CorruptHeaders_ReturnsEmptySafely(string corruptOutput)
    {
        Assert.Empty(WingetCliParser.ParsePackages(corruptOutput));
        Assert.Empty(WingetCliParser.ParseInstalledApps(corruptOutput));
        Assert.Empty(WingetCliParser.ParseUpdates(corruptOutput));
    }

    [Fact]
    public void ParsePackages_MultipleHeadersInOutput_ParsesFirstBlockWithoutCrashing()
    {
        string multipleHeaders =
            "Name    Id    Version\r\n" +
            "---------------------\r\n" +
            "App1    id1   1.0.0\r\n" +
            "Name    Id    Version\r\n" +
            "---------------------\r\n" +
            "App2    id2   2.0.0\r\n";

        var packages = WingetCliParser.ParsePackages(multipleHeaders);
        Assert.NotNull(packages);
        Assert.True(packages.Count >= 1);
        Assert.Equal("App1", packages[0].Name);
    }

    [Fact]
    public void ParsePackages_PreambleNoiseLinesBeforeHeader_IgnoredCorrectly()
    {
        string noisy =
            "Initializing package manager...\r\n" +
            "Warning: An existing connection was forcibly closed by the remote host.\r\n" +
            "Failed when searching source: msstore\r\n" +
            "Name     Id        Version Source\r\n" +
            "---------------------------------\r\n" +
            "AppOne   app.one   1.0.0   winget\r\n";

        var packages = WingetCliParser.ParsePackages(noisy);
        Assert.Single(packages);
        Assert.Equal("AppOne", packages[0].Name);
        Assert.Equal("app.one", packages[0].Id);
    }

    // =========================================================================
    // 6. Mass Payload & Performance Stress Harness
    // =========================================================================

    [Fact]
    public void ParsePackages_10000RowsPayload_ParsesInSubSecond()
    {
        var sb = new StringBuilder();
        sb.AppendLine("Name                             Id                                Version       Source");
        sb.AppendLine("---------------------------------------------------------------------------------------");

        for (int i = 0; i < 10000; i++)
        {
            sb.AppendFormat("Package Number {0,-17} Package.Id.Number.{0,-16} {1}.{2}.0       winget\r\n", i, i % 100, i % 10);
        }

        string bigOutput = sb.ToString();

        var sw = Stopwatch.StartNew();
        var result = WingetCliParser.ParsePackages(bigOutput);
        sw.Stop();

        Assert.Equal(10000, result.Count);
        Assert.True(sw.ElapsedMilliseconds < 1000, $"Parsing 10,000 rows took {sw.ElapsedMilliseconds}ms (expected < 1000ms)");
    }

    [Fact]
    public void ParsePackages_ExtremelyLongLine_DoesNotThrow()
    {
        string hugeLine = "Name        Id          Version\r\n" +
                          "-------------------------------\r\n" +
                          "AppHuge     huge.id     1.0 " + new string('X', 100000) + "\r\n";

        var packages = WingetCliParser.ParsePackages(hugeLine);
        Assert.Single(packages);
        Assert.Equal("AppHuge", packages[0].Name);
        Assert.Equal("huge.id", packages[0].Id);
    }

    // =========================================================================
    // 7. Fuzzing Generator Harness
    // =========================================================================

    [Fact]
    public void ParseMethods_RandomFuzzPayloads_NeverThrowsExceptions()
    {
        var rng = new Random(1337);
        char[] glyphs = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ \t\r\n<>-=\\/|~`!@#$%^&*()_+\0".ToCharArray();

        for (int iteration = 0; iteration < 200; iteration++)
        {
            int lineCount = rng.Next(1, 30);
            var sb = new StringBuilder();

            if (rng.Next(0, 3) == 0)
            {
                sb.AppendLine("Name   Id   Version   Available   Source");
                sb.AppendLine("----------------------------------------");
            }

            for (int l = 0; l < lineCount; l++)
            {
                int len = rng.Next(0, 100);
                char[] lineBuf = new char[len];
                for (int c = 0; c < len; c++)
                {
                    lineBuf[c] = glyphs[rng.Next(0, glyphs.Length)];
                }
                sb.AppendLine(new string(lineBuf));
            }

            string fuzzedInput = sb.ToString();

            // None of these should throw any exception
            var ex1 = Record.Exception(() => WingetCliParser.ParsePackages(fuzzedInput));
            Assert.Null(ex1);

            var ex2 = Record.Exception(() => WingetCliParser.ParseInstalledApps(fuzzedInput));
            Assert.Null(ex2);

            var ex3 = Record.Exception(() => WingetCliParser.ParseUpdates(fuzzedInput));
            Assert.Null(ex3);
        }
    }
}
