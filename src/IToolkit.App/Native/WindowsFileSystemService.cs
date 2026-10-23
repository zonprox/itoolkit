namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;

public class WindowsFileSystemService : IFileSystemService
{
    public bool FileExists(string path) => File.Exists(path);
    public bool DirectoryExists(string path) => Directory.Exists(path);
    public void CreateDirectory(string path) => Directory.CreateDirectory(path);
    public void DeleteFile(string path) { if (File.Exists(path)) File.Delete(path); }
    public void DeleteDirectory(string path, bool recursive = true) { if (Directory.Exists(path)) Directory.Delete(path, recursive); }
    public void CopyFile(string source, string destination, bool overwrite = true) => File.Copy(source, destination, overwrite);
    public void MoveFile(string source, string destination) => File.Move(source, destination, true);
    public void MoveDirectory(string source, string destination) => Directory.Move(source, destination);

    public void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true) =>
        ZipFile.ExtractToDirectory(zipFilePath, destinationDirectory, overwrite);

    public long GetFileSize(string path) => new FileInfo(path).Length;

    public long GetAvailableFreeSpace(string path)
    {
        string root = Path.GetPathRoot(Path.GetFullPath(path)) ?? "C:\\";
        return new DriveInfo(root).AvailableFreeSpace;
    }

    public bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2)
    {
        long needed = (long)Math.Ceiling(requiredBytes * safetyMultiplier);
        return GetAvailableFreeSpace(path) >= needed;
    }

    public string ComputeSha256(string path)
    {
        using var stream = File.OpenRead(path);
        byte[] hash = SHA256.HashData(stream);
        return Convert.ToHexString(hash);
    }

    public async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, true);
        byte[] hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(hash);
    }

    public bool IsFileLocked(string path)
    {
        if (!File.Exists(path)) return false;
        try
        {
            using var stream = File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            return false;
        }
        catch (IOException)
        {
            return true;
        }
    }

    public void CreateSymbolicLink(string linkPath, string targetPath)
    {
        if (File.Exists(targetPath)) File.CreateSymbolicLink(linkPath, targetPath);
        else Directory.CreateSymbolicLink(linkPath, targetPath);
    }

    public string ReadAllText(string path, Encoding? encoding = null) =>
        encoding != null ? File.ReadAllText(path, encoding) : File.ReadAllText(path);

    public void WriteAllText(string path, string contents, Encoding? encoding = null)
    {
        if (encoding != null) File.WriteAllText(path, contents, encoding);
        else File.WriteAllText(path, contents);
    }

    public byte[] ReadAllBytes(string path) => File.ReadAllBytes(path);
    public void WriteAllBytes(string path, byte[] bytes) => File.WriteAllBytes(path, bytes);
    public Stream OpenRead(string path) => File.OpenRead(path);
    public DateTime GetLastWriteTimeUtc(string path) => File.GetLastWriteTimeUtc(path);
    public IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
        Directory.EnumerateFiles(path, searchPattern, searchOption);
    public IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
        Directory.EnumerateDirectories(path, searchPattern, searchOption);
}
