namespace IToolkit.Core.Services.Identity;

using IToolkit.Core.Models;

/// <summary>
/// Service contract for Local User Account administration and Zero-RSAT Domain management.
/// </summary>
public interface IIdentityService
{
    IReadOnlyList<LocalAccountItem> GetLocalAccounts();
    bool CreateLocalAccount(string username, string password, string? description = null, bool addToAdminGroup = false);
    bool UnlockLocalAccount(string username);
    bool SetAccountEnabled(string username, bool enabled);
    bool RemoveLocalAccount(string username, string? sid = null);

    // Language-agnostic SID-500 Admin
    LocalAccountItem? GetBuiltInAdministrator();
    bool EnableBuiltInAdministrator();
    bool ResetBuiltInAdministratorPassword(string newPassword);

    // Zero-RSAT Domain
    DomainReachabilityResult TestDomainReachability(string domainName);
    DomainUserInfo? GetDomainUser(string domain, string username);
    bool UnlockDomainUser(string domain, string username);
    bool JoinDomain(string domain, string? username = null, string? password = null);
    bool DisjoinDomain(string workgroupName = "WORKGROUP");
}
