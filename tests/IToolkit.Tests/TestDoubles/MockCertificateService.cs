namespace IToolkit.Tests.TestDoubles;

using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using IToolkit.Core.Abstractions;

/// <summary>
/// In-memory test double for ICertificateService with genuine X509Certificate2 generation and PFX export.
/// </summary>
public class MockCertificateService : ICertificateService
{
    private readonly Dictionary<string, List<X509Certificate2>> _stores = new(StringComparer.OrdinalIgnoreCase);

    public void AddCertificate(string storeName, X509Certificate2 certificate)
    {
        if (!_stores.TryGetValue(storeName, out var list))
        {
            list = new List<X509Certificate2>();
            _stores[storeName] = list;
        }
        list.Add(certificate);
    }

    public X509Certificate2 AddSelfSignedCertificate(string storeName, string subject = "CN=IToolkitTest")
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest(subject, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365));
        AddCertificate(storeName, cert);
        return cert;
    }

    public IReadOnlyList<X509Certificate2> GetCertificates(string storeName, StoreLocation location = StoreLocation.CurrentUser)
    {
        return _stores.TryGetValue(storeName, out var list) ? list.ToList() : Array.Empty<X509Certificate2>();
    }

    public byte[] ExportCertificatesToPfx(IEnumerable<X509Certificate2> certificates, string? password = null)
    {
        var collection = new X509Certificate2Collection();
        foreach (var cert in certificates)
        {
            collection.Add(cert);
        }

        if (collection.Count == 0)
        {
            return Array.Empty<byte>();
        }

        return collection.Export(X509ContentType.Pfx, password) ?? Array.Empty<byte>();
    }
}
