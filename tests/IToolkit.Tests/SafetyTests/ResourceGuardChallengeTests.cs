namespace IToolkit.Tests.SafetyTests;

using System.Text;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class ResourceGuardChallengeTests
{
    private readonly MockFileSystemService _fileSystem = new();
    private readonly ResourceGuard _guard;

    public ResourceGuardChallengeTests()
    {
        _guard = new ResourceGuard(_fileSystem);
    }

    #region 1. 1.2x Headroom Boundary & Edge Cases

    [Theory]
    // Integer multiples
    [InlineData(1000L, 1200L)]
    [InlineData(10_000L, 12_000L)]
    [InlineData(1_000_000L, 1_200_000L)]
    // Ceiling rounding (non-integer products)
    [InlineData(1L, 2L)]         // 1 * 1.2 = 1.2 -> 2
    [InlineData(2L, 3L)]         // 2 * 1.2 = 2.4 -> 3
    [InlineData(3L, 4L)]         // 3 * 1.2 = 3.6 -> 4
    [InlineData(4L, 5L)]         // 4 * 1.2 = 4.8 -> 5
    [InlineData(5L, 6L)]         // 5 * 1.2 = 6.0 -> 6
    [InlineData(6L, 8L)]         // 6 * 1.2 = 7.2 -> 8
    [InlineData(7L, 9L)]         // 7 * 1.2 = 8.4 -> 9
    [InlineData(101L, 122L)]     // 101 * 1.2 = 121.2 -> 122
    // Large values (50 GB, 100 GB)
    [InlineData(53_687_091_200L, 64_424_509_440L)]
    [InlineData(107_374_182_400L, 128_849_018_880L)]
    // Zero and negative
    [InlineData(0L, 0L)]
    [InlineData(-1L, 0L)]
    [InlineData(-999L, 0L)]
    public void CalculateRequiredHeadroom_EvaluatesAccurateCeiling(long required, long expected)
    {
        long actual = ResourceGuard.CalculateRequiredHeadroom(required);
        Assert.Equal(expected, actual);
    }

    [Fact]
    public void CheckDiskSpace_Exact1_2xBoundary_AcceptsExact_RejectsOneByteLess()
    {
        const string path = "C:\\Target";
        long required = 53_687_091_200L; // 50 GB
        long expectedHeadroom = 64_424_509_440L; // 60 GB (exact 1.2x)

        // Case 1: Exactly 1 byte less than required 1.2x headroom
        _fileSystem.SetAvailableFreeSpace(expectedHeadroom - 1);
        Assert.False(_guard.CheckDiskSpace(path, required));

        // Case 2: Exactly 1.2x headroom
        _fileSystem.SetAvailableFreeSpace(expectedHeadroom);
        Assert.True(_guard.CheckDiskSpace(path, required));

        // Case 3: Exactly 1 byte more than 1.2x headroom
        _fileSystem.SetAvailableFreeSpace(expectedHeadroom + 1);
        Assert.True(_guard.CheckDiskSpace(path, required));
    }

    [Fact]
    public void ValidateDiskSpace_OneByteBelowCeiling_ThrowsDescriptiveException()
    {
        const string path = "D:\\Profiles";
        long required = 7L; // 7 * 1.2 = 8.4 -> ceil = 9

        // 8 bytes available: less than ceil(8.4) = 9
        _fileSystem.SetAvailableFreeSpace(8);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            _guard.ValidateDiskSpace(path, required));

        Assert.Contains("Insufficient disk space", ex.Message);
        Assert.Contains("9 bytes", ex.Message);
    }

    [Fact]
    public void ValidateDiskSpace_ExactCeiling_SucceedsWithoutException()
    {
        const string path = "D:\\Profiles";
        long required = 7L; // ceil(7 * 1.2) = 9

        _fileSystem.SetAvailableFreeSpace(9);
        _guard.ValidateDiskSpace(path, required); // Should not throw
    }

    [Fact]
    public void Headroom_OverflowBehavior_Inspection()
    {
        // When required exceeds long.MaxValue / 1.2 (~7.68 exabytes),
        // let's observe what CalculateRequiredHeadroom returns.
        long largeValue = 7_000_000_000_000_000_000L; // 7 exabytes (within long range after * 1.2)
        long result = ResourceGuard.CalculateRequiredHeadroom(largeValue);
        Assert.True(result > largeValue, "Result must be greater than required bytes");

        // Extreme value near long.MaxValue
        long extreme = long.MaxValue;
        long extremeResult = ResourceGuard.CalculateRequiredHeadroom(extreme);
        Assert.Equal(long.MaxValue, extremeResult);
    }

    #endregion

    #region 2. SHA-256 Calculation & Test Vectors

    [Fact]
    public void ComputeSha256_EmptyFile_ReturnsStandardNistEmptyHash()
    {
        const string emptyPath = "C:\\empty.txt";
        _fileSystem.WriteAllBytes(emptyPath, Array.Empty<byte>());

        string hash = _guard.ComputeSha256(emptyPath);
        const string expectedEmptyHash = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";

        Assert.Equal(expectedEmptyHash, hash);
    }

    [Fact]
    public void ComputeSha256_StandardNistVectorAbc_ReturnsCorrectHash()
    {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        const string path = "C:\\abc.txt";
        _fileSystem.WriteAllBytes(path, Encoding.ASCII.GetBytes("abc"));

        string hash = _guard.ComputeSha256(path);
        const string expectedHash = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";

        Assert.Equal(expectedHash, hash);
    }

    [Fact]
    public void ComputeSha256_StreamMatchesFileComputation()
    {
        byte[] data = Encoding.UTF8.GetBytes("The quick brown fox jumps over the lazy dog");
        const string path = "C:\\fox.txt";
        _fileSystem.WriteAllBytes(path, data);

        string fileHash = _guard.ComputeSha256(path);

        using var memoryStream = new MemoryStream(data);
        string streamHash = ResourceGuard.ComputeSha256(memoryStream);

        Assert.Equal(fileHash, streamHash);
        Assert.Equal("D7A8FBB307D7809469CA9ABCB0082E4F8D5651E46D3CDB762D02D0BF37C9E592", fileHash);
    }

    [Fact]
    public void VerifyFileHash_CaseInsensitiveMatching_Succeeds()
    {
        const string path = "C:\\fox.txt";
        _fileSystem.WriteAllBytes(path, Encoding.UTF8.GetBytes("The quick brown fox jumps over the lazy dog"));

        // Uppercase, lowercase, mixed-case
        Assert.True(_guard.VerifyFileHash(path, "D7A8FBB307D7809469CA9ABCB0082E4F8D5651E46D3CDB762D02D0BF37C9E592"));
        Assert.True(_guard.VerifyFileHash(path, "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"));
        Assert.False(_guard.VerifyFileHash(path, "0000000000000000000000000000000000000000000000000000000000000000"));
    }

    [Fact]
    public void VerifyFilesMatch_NonExistentFiles_ReturnsFalse()
    {
        const string existing = "C:\\exists.bin";
        _fileSystem.WriteAllBytes(existing, new byte[] { 1, 2, 3 });

        Assert.False(_guard.VerifyFilesMatch(existing, "C:\\nonexistent.bin"));
        Assert.False(_guard.VerifyFilesMatch("C:\\nonexistent.bin", existing));
        Assert.False(_guard.VerifyFilesMatch("C:\\none1.bin", "C:\\none2.bin"));
    }

    #endregion

    #region 3. Cryptographic Manifest Validation & Corruption Detection

    [Fact]
    public void ValidateManifest_DetectsBitFlipCorruption_EvenWithSameFileSize()
    {
        const string root = "C:\\SourceRoot";
        string filePath = $"{root}\\critical.dat";

        // Create 1KB random-like byte buffer
        byte[] original = new byte[1024];
        for (int i = 0; i < original.Length; i++) original[i] = (byte)(i % 256);
        _fileSystem.WriteAllBytes(filePath, original);

        // Generate manifest
        var manifest = _guard.GenerateCleanupManifest(root, new[] { filePath });
        Assert.Single(manifest.Files);

        // Corrupt exactly 1 byte in the middle (size remains identical at 1024)
        byte[] corrupted = (byte[])original.Clone();
        corrupted[512] ^= 0xFF; // flip bits
        _fileSystem.WriteAllBytes(filePath, corrupted);

        // Validate
        var result = _guard.ValidateManifest(manifest);

        // Assert failure and detection
        Assert.False(result.IsValid);
        Assert.Equal(0, result.MatchedFiles);
        Assert.Empty(result.MissingFiles);
        Assert.Single(result.MismatchedFiles);
        Assert.Equal("critical.dat", result.MismatchedFiles[0]);
    }

    [Fact]
    public void ValidateManifest_DetectsTruncationCorruption_SizeDifference()
    {
        const string root = "C:\\SourceRoot";
        string filePath = $"{root}\\payload.bin";

        _fileSystem.WriteAllBytes(filePath, new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 });
        var manifest = _guard.GenerateCleanupManifest(root, new[] { filePath });

        // Truncate file from 8 bytes to 4 bytes
        _fileSystem.WriteAllBytes(filePath, new byte[] { 1, 2, 3, 4 });

        var result = _guard.ValidateManifest(manifest);

        Assert.False(result.IsValid);
        Assert.Single(result.MismatchedFiles);
    }

    [Fact]
    public void ValidateManifest_DetectsMissingDeletedFiles()
    {
        const string root = "C:\\SourceRoot";
        string file1 = $"{root}\\f1.txt";
        string file2 = $"{root}\\f2.txt";

        _fileSystem.WriteAllText(file1, "Content 1");
        _fileSystem.WriteAllText(file2, "Content 2");

        var manifest = _guard.GenerateCleanupManifest(root, new[] { file1, file2 });

        // Delete file2
        _fileSystem.DeleteFile(file2);

        var result = _guard.ValidateManifest(manifest);

        Assert.False(result.IsValid);
        Assert.Equal(1, result.MatchedFiles);
        Assert.Single(result.MissingFiles);
        Assert.Equal("f2.txt", result.MissingFiles[0]);
        Assert.Empty(result.MismatchedFiles);
    }

    [Fact]
    public void ValidateManifest_MultiFileMixedStatus_ReportsExactCounts()
    {
        const string root = "C:\\Root";
        string fileIntact = $"{root}\\intact.dat";
        string fileCorrupt = $"{root}\\corrupt.dat";
        string fileDeleted = $"{root}\\deleted.dat";

        _fileSystem.WriteAllText(fileIntact, "Intact");
        _fileSystem.WriteAllText(fileCorrupt, "Before corruption");
        _fileSystem.WriteAllText(fileDeleted, "Will be removed");

        var manifest = _guard.GenerateCleanupManifest(root, new[] { fileIntact, fileCorrupt, fileDeleted });

        // Mutate
        _fileSystem.WriteAllText(fileCorrupt, "Corrupted content!");
        _fileSystem.DeleteFile(fileDeleted);

        var result = _guard.ValidateManifest(manifest);

        Assert.False(result.IsValid);
        Assert.Equal(3, result.TotalFiles);
        Assert.Equal(1, result.MatchedFiles);
        Assert.Single(result.MismatchedFiles);
        Assert.Contains("corrupt.dat", result.MismatchedFiles);
        Assert.Single(result.MissingFiles);
        Assert.Contains("deleted.dat", result.MissingFiles);
    }

    [Fact]
    public void Manifest_SaveAndLoad_RoundTripPreservesIntegrity()
    {
        const string root = "C:\\SaveLoad";
        string file1 = $"{root}\\doc.txt";
        _fileSystem.WriteAllText(file1, "Hello manifest persistence");

        var originalManifest = _guard.GenerateCleanupManifest(root, new[] { file1 });

        const string manifestDiskPath = "C:\\SaveLoad\\manifest.json";
        _guard.SaveManifest(originalManifest, manifestDiskPath);

        Assert.True(_fileSystem.FileExists(manifestDiskPath));

        var loadedManifest = _guard.LoadManifest(manifestDiskPath);

        Assert.Equal(originalManifest.ManifestId, loadedManifest.ManifestId);
        Assert.Equal(originalManifest.SourceRoot, loadedManifest.SourceRoot);
        Assert.Equal(originalManifest.TotalSizeBytes, loadedManifest.TotalSizeBytes);
        Assert.Single(loadedManifest.Files);
        Assert.Equal(originalManifest.Files[0].Sha256Hash, loadedManifest.Files[0].Sha256Hash);

        // Validation with loaded manifest passes against disk
        var validation = _guard.ValidateManifest(loadedManifest);
        Assert.True(validation.IsValid);
    }

    #endregion
}
