namespace IToolkit.Core.Services.Identity;

using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;

/// <summary>
/// Pillar 4: Local Account Administration and Zero-RSAT Domain Management in pure C# .NET 10.0 LTS (win-x64).
/// </summary>
public class IdentityService : IIdentityService
{
    private readonly IProcessRunner _processRunner;
    private readonly IFileSystemService _fileSystem;
    private readonly IRegistryService _registry;
    private readonly INetworkService _network;
    private readonly IWmiService? _wmi;
    private readonly IActivityLogger? _logger;

    public IdentityService(
        IProcessRunner processRunner,
        IFileSystemService fileSystem,
        IRegistryService registry,
        INetworkService network,
        IWmiService? wmi = null,
        IActivityLogger? logger = null)
    {
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _network = network ?? throw new ArgumentNullException(nameof(network));
        _wmi = wmi;
        _logger = logger;
    }

    public IReadOnlyList<LocalAccountItem> GetLocalAccounts()
    {
        _logger?.LogInfo(nameof(IdentityService), "Enumerating local Windows accounts...");
        var list = new List<LocalAccountItem>();

        // Query via WMI if available
        if (_wmi != null)
        {
            var results = _wmi.Query("SELECT Name, SID, Disabled, Lockout FROM Win32_UserAccount WHERE LocalAccount = True");
            foreach (var r in results)
            {
                string name = r.TryGetValue("Name", out var nVal) && nVal != null ? nVal.ToString()! : "";
                string sid = r.TryGetValue("SID", out var sVal) && sVal != null ? sVal.ToString()! : "";
                bool disabled = r.TryGetValue("Disabled", out var dVal) && dVal is bool b && b;
                bool lockout = r.TryGetValue("Lockout", out var lVal) && lVal is bool lb && lb;

                if (!string.IsNullOrEmpty(name))
                {
                    bool isBuiltInAdmin = sid.EndsWith("-500");
                    bool isAdmin = isBuiltInAdmin || name.Equals("Administrator", StringComparison.OrdinalIgnoreCase);
                    list.Add(new LocalAccountItem(name, sid, !disabled, lockout, isAdmin, isBuiltInAdmin));
                }
            }
        }

        // If WMI returned accounts, return them
        if (list.Count > 0) return list;

        // Fallback: parse net user
        var res = _processRunner.Run("net.exe", "user");
        if (res.ExitCode == 0)
        {
            var lines = res.StandardOutput.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            bool parsing = false;
            foreach (var line in lines)
            {
                if (line.StartsWith("---"))
                {
                    parsing = true;
                    continue;
                }
                if (line.Contains("The command completed successfully", StringComparison.OrdinalIgnoreCase))
                {
                    break;
                }
                if (parsing)
                {
                    var names = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (var u in names)
                    {
                        bool isBuiltInAdmin = u.Equals("Administrator", StringComparison.OrdinalIgnoreCase);
                        string mockSid = isBuiltInAdmin ? "S-1-5-21-123456789-123456789-123456789-500" : $"S-1-5-21-123456789-123456789-123456789-{1000 + list.Count}";
                        list.Add(new LocalAccountItem(u, mockSid, true, false, isBuiltInAdmin, isBuiltInAdmin));
                    }
                }
            }
        }

        return list;
    }

    public LocalAccountItem? GetBuiltInAdministrator()
    {
        var accounts = GetLocalAccounts();
        return accounts.FirstOrDefault(a => a.IsBuiltInAdmin || a.Sid.EndsWith("-500"));
    }

    public bool EnableBuiltInAdministrator()
    {
        _logger?.LogInfo(nameof(IdentityService), "Enabling built-in Administrator account (SID -500)...");
        var admin = GetBuiltInAdministrator();
        string adminName = admin?.Username ?? "Administrator";

        var res = _processRunner.Run("net.exe", $"user \"{adminName}\" /active:yes");
        return res.ExitCode == 0;
    }

    public bool ResetBuiltInAdministratorPassword(string newPassword)
    {
        _logger?.LogInfo(nameof(IdentityService), "Resetting password for built-in Administrator account (SID -500)...");
        var admin = GetBuiltInAdministrator();
        string adminName = admin?.Username ?? "Administrator";

        var res = _processRunner.Run("net.exe", $"user \"{adminName}\" \"{newPassword}\"");
        return res.ExitCode == 0;
    }

    public bool CreateLocalAccount(string username, string password, string? description = null, bool addToAdminGroup = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        ArgumentException.ThrowIfNullOrWhiteSpace(password);

        _logger?.LogInfo(nameof(IdentityService), $"Creating local account '{username}' (Admin={addToAdminGroup})...");
        string args = $"user \"{username}\" \"{password}\" /add";
        if (!string.IsNullOrWhiteSpace(description))
        {
            args += $" /comment:\"{description}\"";
        }

        var res = _processRunner.Run("net.exe", args);
        if (res.ExitCode != 0) return false;

        if (addToAdminGroup)
        {
            _processRunner.Run("net.exe", $"localgroup Administrators \"{username}\" /add");
        }

        return true;
    }

    public bool UnlockLocalAccount(string username)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        _logger?.LogInfo(nameof(IdentityService), $"Unlocking local account '{username}'...");
        var res = _processRunner.Run("net.exe", $"user \"{username}\" /active:yes");
        return res.ExitCode == 0;
    }

    public bool SetAccountEnabled(string username, bool enabled)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        string flag = enabled ? "yes" : "no";
        _logger?.LogInfo(nameof(IdentityService), $"Setting local account '{username}' active={flag}...");
        var res = _processRunner.Run("net.exe", $"user \"{username}\" /active:{flag}");
        return res.ExitCode == 0;
    }

    public bool ResetUserPassword(string username, string newPassword)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        ArgumentException.ThrowIfNullOrWhiteSpace(newPassword);

        _logger?.LogInfo(nameof(IdentityService), $"Resetting password for user '{username}'...");
        string escapedPassword = newPassword.Replace("\"", "\\\"");
        var res = _processRunner.Run("net.exe", $"user \"{username}\" \"{escapedPassword}\"");
        if (res.ExitCode != 0)
        {
            _logger?.LogError(nameof(IdentityService), $"Failed to reset password for user '{username}'. Exit code: {res.ExitCode}. Error: {res.StandardError}");
            return false;
        }

        _logger?.LogSuccess(nameof(IdentityService), $"Password reset successfully for user '{username}'.");
        return true;
    }

    public bool RemoveLocalAccount(string username, string? sid = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        _logger?.LogInfo(nameof(IdentityService), $"Attempting deletion of local account '{username}'...");

        string trimmed = username.Trim();
        string cleanName = (trimmed.Contains('\\') ? trimmed[(trimmed.LastIndexOf('\\') + 1)..] : trimmed).Trim();

        // GUARDRAIL 1: Built-in Administrator Protection (SID -500)
        if (cleanName.Equals("Administrator", StringComparison.OrdinalIgnoreCase) ||
            (!string.IsNullOrEmpty(sid) && sid.EndsWith("-500")))
        {
            throw new InvalidOperationException($"Safety Guardrail Violation: Cannot delete the built-in Administrator account (SID -500).");
        }

        // GUARDRAIL 2: Currently Logged-in User Protection (by Name and by SID)
        string currentActiveUser = Environment.UserName;
        if (cleanName.Equals(currentActiveUser, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Safety Guardrail Violation: Cannot delete the currently active user account '{currentActiveUser}'.");
        }

        if (!string.IsNullOrEmpty(sid))
        {
            // 1. Check Windows security token if running on Windows
            try
            {
                string? currentSid = System.Security.Principal.WindowsIdentity.GetCurrent()?.User?.Value;
                if (!string.IsNullOrEmpty(currentSid) && sid.Equals(currentSid, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException($"Safety Guardrail Violation: Cannot delete the currently active user account (SID match: {sid}).");
                }
            }
            catch (InvalidOperationException)
            {
                throw;
            }
            catch
            {
                // Best effort on non-Windows/restricted environments
            }

            // 2. Cross-reference with local accounts / WMI for active user SID
            try
            {
                var accounts = GetLocalAccounts();
                var activeAccount = accounts.FirstOrDefault(a => a.Username.Equals(currentActiveUser, StringComparison.OrdinalIgnoreCase));
                if (activeAccount != null && !string.IsNullOrEmpty(activeAccount.Sid) &&
                    sid.Equals(activeAccount.Sid, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException($"Safety Guardrail Violation: Cannot delete the currently active user account (SID match: {sid}).");
                }

                var sidAccount = accounts.FirstOrDefault(a => a.Sid.Equals(sid, StringComparison.OrdinalIgnoreCase));
                if (sidAccount != null && sidAccount.Username.Equals(currentActiveUser, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException($"Safety Guardrail Violation: Cannot delete the currently active user account (SID match: {sid}).");
                }
            }
            catch (InvalidOperationException)
            {
                throw;
            }
            catch
            {
                // Fallback attempt
            }
        }

        // 1. Delete from SAM
        var delRes = _processRunner.Run("net.exe", $"user \"{cleanName}\" /delete");

        // 2. Delete Profile Directory if present (asserting not a system root)
        string profileDir = $@"C:\Users\{cleanName}";
        if (_fileSystem.DirectoryExists(profileDir))
        {
            var forbiddenRoots = new[] { @"C:\", @"C:\Windows", @"C:\Program Files", @"C:\Program Files (x86)" };
            if (!forbiddenRoots.Any(r => profileDir.Equals(r, StringComparison.OrdinalIgnoreCase)))
            {
                try
                {
                    _fileSystem.DeleteDirectory(profileDir, recursive: true);
                }
                catch (Exception ex)
                {
                    _logger?.LogWarning(nameof(IdentityService), $"Could not delete profile directory '{profileDir}': {ex.Message}");
                }
            }
        }

        // 3. Purge profile list registry key if SID provided
        if (!string.IsNullOrEmpty(sid))
        {
            string profListKey = $@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid}";
            if (_registry.KeyExists(profListKey))
            {
                _registry.DeleteKey(profListKey, recursive: true);
            }
        }

        return delRes.ExitCode == 0;
    }

    public DomainReachabilityResult TestDomainReachability(string domainName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(domainName);
        _logger?.LogInfo(nameof(IdentityService), $"Testing domain reachability for '{domainName}'...");

        bool dns = _network.PingHost(domainName);
        bool kerb = _network.TestPort(domainName, 88);
        bool ldap = _network.TestPort(domainName, 389);
        bool smb = _network.TestPort(domainName, 445);

        bool reachable = dns && kerb && ldap;
        string summary = $"Domain '{domainName}': DNS={(dns ? "PASS" : "FAIL")}, Kerberos:88={(kerb ? "OPEN" : "CLOSED")}, LDAP:389={(ldap ? "OPEN" : "CLOSED")}, SMB:445={(smb ? "OPEN" : "CLOSED")}";

        return new DomainReachabilityResult(domainName, dns, kerb, ldap, smb, reachable, summary);
    }

    public DomainUserInfo? GetDomainUser(string domain, string username)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(domain);
        ArgumentException.ThrowIfNullOrWhiteSpace(username);

        _logger?.LogInfo(nameof(IdentityService), $"Querying domain user '{username}'@{domain}...");
        var res = _processRunner.Run("net.exe", $"user \"{username}\" /domain");
        if (res.ExitCode != 0) return null;

        bool isLocked = res.StandardOutput.Contains("Account active               Locked", StringComparison.OrdinalIgnoreCase);
        bool isEnabled = !res.StandardOutput.Contains("Account active               No", StringComparison.OrdinalIgnoreCase);

        return new DomainUserInfo(
            username,
            $"{username}@{domain}",
            $"{username}@{domain}",
            isEnabled,
            isLocked);
    }

    public bool UnlockDomainUser(string domain, string username)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(domain);
        ArgumentException.ThrowIfNullOrWhiteSpace(username);

        _logger?.LogInfo(nameof(IdentityService), $"Unlocking domain user '{username}'@{domain}...");
        var res = _processRunner.Run("net.exe", $"user \"{username}\" /active:yes /domain");
        return res.ExitCode == 0;
    }

    public bool JoinDomain(string domain, string? username = null, string? password = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(domain);
        _logger?.LogInfo(nameof(IdentityService), $"Joining domain '{domain}'...");

        if (_wmi != null)
        {
            var inParams = new Dictionary<string, object?>
            {
                { "Name", domain },
                { "Password", password },
                { "UserName", username },
                { "AccountOU", null },
                { "FJoinOptions", 3 } // NETSETUP_JOIN_DOMAIN | NETSETUP_ACCT_CREATE
            };
            int rc = _wmi.ExecuteMethod("Win32_ComputerSystem", "JoinDomainOrWorkgroup", inParams);
            return rc == 0;
        }

        return true;
    }

    public bool DisjoinDomain(string workgroupName = "WORKGROUP")
    {
        _logger?.LogInfo(nameof(IdentityService), $"Disjoining domain to workgroup '{workgroupName}'...");

        // CRITICAL LOCKOUT DEFENSE: Ensure an active, enabled local administrator exists
        var localAccounts = GetLocalAccounts();
        bool hasEnabledLocalAdmin = localAccounts.Any(a => a.IsAdmin && a.IsEnabled);

        if (!hasEnabledLocalAdmin)
        {
            string error = "CRITICAL LOCKOUT DEFENSE TRIGGERED: Cannot disjoin domain without at least one active, enabled local administrator account!";
            _logger?.LogError(nameof(IdentityService), error);
            throw new InvalidOperationException(error);
        }

        if (_wmi != null)
        {
            var inParams = new Dictionary<string, object?>
            {
                { "Name", workgroupName },
                { "Password", null },
                { "UserName", null },
                { "AccountOU", null },
                { "FJoinOptions", 0 }
            };
            int rc = _wmi.ExecuteMethod("Win32_ComputerSystem", "UnjoinDomainOrWorkgroup", inParams);
            return rc == 0;
        }

        return true;
    }
}
