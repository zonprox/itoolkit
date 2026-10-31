namespace IToolkit.Core.Models;

using System;

/// <summary>
/// Operational status and metadata for an installed local or network printer.
/// </summary>
public record PrinterInfo(
    string Name,
    string DriverName,
    string PortName,
    bool IsDefault,
    bool IsNetwork,
    string Status,
    int PendingJobCount,
    string? ServerName = null,
    string? ShareName = null);

/// <summary>
/// Metadata and status for an individual print spooler job.
/// </summary>
public record PrinterJobInfo(
    int JobId,
    string DocumentName,
    string Owner,
    long SizeBytes,
    string Status,
    DateTime SubmittedTime);
