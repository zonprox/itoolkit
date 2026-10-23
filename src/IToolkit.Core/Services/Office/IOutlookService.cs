namespace IToolkit.Core.Services.Office;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Outlook MAPI profiles, PST/OST management, and mail subsystem repair.
/// </summary>
public interface IOutlookService
{
    IReadOnlyList<MapiDataFileInfo> DiscoverDataFiles();
    QuickMailRepairResult QuickMailAndCacheRepair(string? profileName = null);
    OperationResult ExpandDataFileLimitsTo100GB();
    PstPipelineResult RunNewDefaultPstPipeline(string targetPstPath, string? sourcePstPath = null);
    DataFileRelocationResult RelocateDataFile(string sourceFilePath, string destinationDirectory);
    OperationResult BackupDataFile(string sourceFilePath, string backupDirectory);
    OperationResult RestoreDataFile(string backupFilePath, string targetFilePath, string expectedSha256);
    OperationResult CompactDataFile(string filePath);
}
