namespace IToolkit.Core.Services.SystemHealth;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Pillar 1: System Health & Maintenance.
/// </summary>
public interface ISystemHealthService
{
    DismScanResult RunDismCheckHealth();
    DismScanResult RunDismScanHealth();
    DismScanResult RunDismRestoreHealth(string? source = null, bool limitAccess = false);
    SfcScanResult RunSfcScan();
    (DismScanResult DismResult, SfcScanResult SfcResult) RunDismSfcPipeline(string? source = null, bool limitAccess = false);
    WindowsUpdateResetResult ResetWindowsUpdateComponents();
    WindowsUpdateBlockResult BlockWindowsUpdates();
    WindowsUpdateBlockResult UnblockWindowsUpdates();
    TimeSyncResult SyncSystemTime(string? ntpServers = null);
    WmiRepairResult RepairWmiRepository();
    ComponentCleanupResult CleanWinSxS(bool resetBase = false);
    StorageCleanupResult RunUnifiedDiskCleanup(int tempAgeHoursThreshold = 24);
}
