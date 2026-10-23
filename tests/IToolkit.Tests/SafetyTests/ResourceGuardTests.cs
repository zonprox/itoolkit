namespace IToolkit.Tests.SafetyTests;

using System.Text;
using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class ResourceGuardTests
{
    private readonly MockFileSystemService _fileSystem = new();
    private readonly ResourceGuard _guard;

    public ResourceGuardTests()
    {
        _guard = new ResourceGuard(_fileSystem);
    }

    [Theory]
    [InlineData(1000, 1200)]      // 1000 * 1.2 = 1200
    [InlineData(101, 122)]        // 101 * 1.2 = 121.2 -> ceiling 122
    [InlineData(0, 0)]            // 0 -> 0
    [InlineData(-50, 0)]          // negative -> 0
    [InlineData(1000000, 1200000)]
    public void CalculateRequiredHeadroom_ComputesExactMathCeilingWith1_2x(long required, long expected)
    {
        long actual = ResourceGuard.CalculateRequiredHeadroom(required);
        Assert.Equal(expected, actual);
    }

    [Fact]
    public void ValidateDiskSpace_WhenAvailableSpaceBelow1_2xThreshold_ThrowsInvalidOperationException()
    {
        // Arrange: 1000 B required needs 1200 B headroom; only 1199 B available
        const string targetDir = "D:\\DataMigration";
        _fileSystem.SetAvailableFreeSpace(1199);

        // Act & Assert
        var ex = Assert.Throws<InvalidOperationException>(() =>
            _guard.ValidateDiskSpace(targetDir, 1000));

        Assert.Contains("Insufficient disk space", ex.Message);
        Assert.Contains("1,200", ex.Message); // Required threshold
    }

    [Theory]
    [InlineData(1000, 1200)] // Exactly 1.2x
    [InlineData(1000, 1201)] // Above 1.2x
    [InlineData(1000, 5000)] // Well above
    [InlineData(0, 0)]       // Zero required
    public void ValidateDiskSpace_WhenAvailableSpaceMeetsOrExceedsThreshold_Succeeds(long required, long available)
    {
        // Arrange
        const string targetDir = "D:\\BackupStore";
        _fileSystem.SetAvailableFreeSpace(available);

        // Act & Assert (does not throw)
        _guard.ValidateDiskSpace(targetDir, required);
    }

    [Fact]
    public void CheckDiskSpace_ReturnsExpectedBooleanAcrossBoundaries()
    {
        const string targetDir = "C:\\Store";

        _fileSystem.SetAvailableFreeSpace(1199);
        Assert.False(_guard.CheckDiskSpace(targetDir, 1000));

        _fileSystem.SetAvailableFreeSpace(1200);
        Assert.True(_guard.CheckDiskSpace(targetDir, 1000));

        _fileSystem.SetAvailableFreeSpace(1201);
        Assert.True(_guard.CheckDiskSpace(targetDir, 1000));
    }

    [Fact]
    public void ComputeSha256_ComputesCorrectKnownHash()
    {
        // Arrange: Standard known SHA-256 test vector
        // SHA-256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2ecce61
        const string filePath = "C:\\test\\vector.txt";
        _fileSystem.WriteAllBytes(filePath, Encoding.ASCII.GetBytes("hello world"));

        // Act
        string hash = _guard.ComputeSha256(filePath);

        // Assert
        Assert.Equal("B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9", hash);
    }

    [Fact]
    public void VerifyFilesMatch_WhenIdentical_ReturnsTrue_WhenDifferent_ReturnsFalse()
    {
        // Arrange
        const string file1 = "C:\\data\\source.bin";
        const string file2 = "D:\\data\\copy.bin";
        const string file3 = "D:\\data\\corrupted.bin";

        byte[] payload1 = new byte[] { 0x10, 0x20, 0x30, 0x40, 0x50 };
        byte[] payload2 = new byte[] { 0x10, 0x20, 0x30, 0x40, 0x50 };
        byte[] payload3 = new byte[] { 0x10, 0x20, 0x30, 0x40, 0x99 }; // 1 byte altered

        _fileSystem.WriteAllBytes(file1, payload1);
        _fileSystem.WriteAllBytes(file2, payload2);
        _fileSystem.WriteAllBytes(file3, payload3);

        // Act & Assert
        Assert.True(_guard.VerifyFilesMatch(file1, file2));
        Assert.False(_guard.VerifyFilesMatch(file1, file3));
    }

    [Fact]
    public void GenerateAndValidateManifest_WhenFilesUnchanged_ValidationPasses()
    {
        // Arrange
        const string sourceRoot = "C:\\Profiles\\User1";
        string file1 = $"{sourceRoot}\\doc.txt";
        string file2 = $"{sourceRoot}\\sub\\image.png";

        _fileSystem.WriteAllText(file1, "Document content");
        _fileSystem.WriteAllBytes(file2, new byte[] { 0x89, 0x50, 0x4E, 0x47 });

        // Act: Generate manifest
        var manifest = _guard.GenerateCleanupManifest(sourceRoot, new[] { file1, file2 });

        // Assert manifest structure
        Assert.Equal(2, manifest.Files.Count);
        Assert.Equal(sourceRoot, manifest.SourceRoot);
        Assert.True(manifest.TotalSizeBytes > 0);

        // Act: Validate manifest
        var validation = _guard.ValidateManifest(manifest);

        // Assert validation outcome
        Assert.True(validation.IsValid);
        Assert.Equal(2, validation.MatchedFiles);
        Assert.Empty(validation.MissingFiles);
        Assert.Empty(validation.MismatchedFiles);
    }

    [Fact]
    public void ValidateManifest_WhenFileIsModified_DetectsMismatch()
    {
        // Arrange
        const string sourceRoot = "C:\\Profiles\\User2";
        string file1 = $"{sourceRoot}\\important.dat";
        _fileSystem.WriteAllText(file1, "Original data");

        var manifest = _guard.GenerateCleanupManifest(sourceRoot, new[] { file1 });

        // Alter file content
        _fileSystem.WriteAllText(file1, "Tampered data");

        // Act
        var validation = _guard.ValidateManifest(manifest);

        // Assert
        Assert.False(validation.IsValid);
        Assert.Equal(0, validation.MatchedFiles);
        Assert.Single(validation.MismatchedFiles);
    }

    [Fact]
    public void ValidateManifest_WhenFileIsDeleted_DetectsMissingFile()
    {
        // Arrange
        const string sourceRoot = "C:\\Profiles\\User3";
        string file1 = $"{sourceRoot}\\file_to_delete.log";
        _fileSystem.WriteAllText(file1, "Log message");

        var manifest = _guard.GenerateCleanupManifest(sourceRoot, new[] { file1 });

        // Delete file
        _fileSystem.DeleteFile(file1);

        // Act
        var validation = _guard.ValidateManifest(manifest);

        // Assert
        Assert.False(validation.IsValid);
        Assert.Single(validation.MissingFiles);
    }
}
