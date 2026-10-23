namespace IToolkit.Core.Abstractions;

using System.Text;

/// <summary>
/// Abstraction for filesystem operations, disk headroom calculations, and file integrity hashing.
/// </summary>
public interface IFileSystemService
{
    bool FileExists(string path);
    bool DirectoryExists(string path);
    void CreateDirectory(string path);
    void DeleteFile(string path);
    void DeleteDirectory(string path, bool recursive = true);
    void CopyFile(string source, string destination, bool overwrite = true);
    void MoveFile(string source, string destination);
    void MoveDirectory(string source, string destination);
    void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true);
    long GetFileSize(string path);
    long GetAvailableFreeSpace(string path);
    bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2);
    string ComputeSha256(string path);
    Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default);
    bool IsFileLocked(string path);
    void CreateSymbolicLink(string linkPath, string targetPath);
    string ReadAllText(string path, Encoding? encoding = null);
    void WriteAllText(string path, string contents, Encoding? encoding = null);
    byte[] ReadAllBytes(string path);
    void WriteAllBytes(string path, byte[] bytes);
    Stream OpenRead(string path);
    DateTime GetLastWriteTimeUtc(string path);
    IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly);
    IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly);
}
