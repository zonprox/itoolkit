namespace IToolkit.Core.Abstractions;

using System.Security.Cryptography.X509Certificates;

/// <summary>
/// Abstraction for Windows certificate store querying and PFX export.
/// </summary>
public interface ICertificateService
{
    /// <summary>
    /// Retrieves certificates from the specified certificate store and location.
    /// </summary>
    IReadOnlyList<X509Certificate2> GetCertificates(string storeName, StoreLocation location = StoreLocation.CurrentUser);

    /// <summary>
    /// Exports the specified certificates to a PKCS #12 (.pfx) binary payload.
    /// </summary>
    byte[] ExportCertificatesToPfx(IEnumerable<X509Certificate2> certificates, string? password = null);
}
