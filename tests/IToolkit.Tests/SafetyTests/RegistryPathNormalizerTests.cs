namespace IToolkit.Tests.SafetyTests;

using IToolkit.Core.Utilities;
using Xunit;

public class RegistryPathNormalizerTests
{
    [Theory]
    [InlineData(@"HKLM\Software\App\", @"HKEY_LOCAL_MACHINE\Software\App")]
    [InlineData(@"HKLM\Software\App\\\", @"HKEY_LOCAL_MACHINE\Software\App")]
    [InlineData(@"HKCU/Software/App/", @"HKEY_CURRENT_USER\Software\App")]
    [InlineData(@"HKLM:\", @"HKEY_LOCAL_MACHINE")]
    [InlineData(@"HKLM\", @"HKEY_LOCAL_MACHINE")]
    [InlineData(@"HKCU", @"HKEY_CURRENT_USER")]
    [InlineData(@"HKEY_LOCAL_MACHINE\Software\Test\", @"HKEY_LOCAL_MACHINE\Software\Test")]
    [InlineData(@"CustomHive\Path\Sub\", @"CustomHive\Path\Sub")]
    public void ToStandardFormat_StripsTrailingSlashesConsistently(string input, string expected)
    {
        string actual = RegistryPathNormalizer.ToStandardFormat(input);
        Assert.Equal(expected, actual);
    }

    [Theory]
    [InlineData(@"HKLM\Software\App\", "HKEY_LOCAL_MACHINE", @"Software\App")]
    [InlineData(@"HKCU\", "HKEY_CURRENT_USER", "")]
    [InlineData(@"HKLM", "HKEY_LOCAL_MACHINE", "")]
    public void TrySplitHiveAndSubKey_HandlesTrailingSlashesCleanly(string input, string expectedHive, string expectedSubKey)
    {
        bool success = RegistryPathNormalizer.TrySplitHiveAndSubKey(input, out string hive, out string subKey);
        Assert.True(success);
        Assert.Equal(expectedHive, hive);
        Assert.Equal(expectedSubKey, subKey);
    }
}
