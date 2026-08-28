using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// The host's LOCAL ACCOUNTS, answering to the name Bossman's Accounts screen already calls
/// (<c>getent</c>, <c>database: passwd | group</c>) and in the field layout it already parses.
///
/// <para>WHY IT WEARS A UNIX NAME, which is the only interesting decision here. The Accounts screen reads
/// `data[].fields` as colon-separated passwd/group records. A Windows-shaped answer would need a second
/// renderer and a branch on the OS in every consumer, so the fleet's INTERFACE stays the passwd layout — and
/// the mapping turns out to be honest rather than a costume:</para>
/// <list type="bullet">
/// <item>`uid` is the SID's RELATIVE IDENTIFIER, which is a real integer identity on Windows, not an
/// invention. And it lines up: built-in accounts are Administrator 500, Guest 501, DefaultAccount 503 —
/// all below 1000 — while accounts somebody created start at 1001. So the screen's `system = uid &lt; 1000`
/// rule, written for Linux, is correct here for the same reason it is correct there.</item>
/// <item>`gecos` is the account's FullName, falling back to its Description — the same "who is this" slot.</item>
/// <item>`home` is the profile path where Windows keeps one; empty for accounts that have never signed in,
/// because inventing `C:\Users\name` would state a directory that does not exist.</item>
/// <item>`gid` is EMPTY, not 0 or 545. A Windows local user has no primary group in the Unix sense; writing
/// one in would be the one field of this mapping that is a guess, and the screen shows an absent gid.</item>
/// <item>`shell` is empty for the same reason. There is no login shell to name.</item>
/// </list>
/// <para>WHAT UNIX HAS NO SLOT FOR travels beside the record instead of being dropped: `sid` (the full
/// identity — the RID alone is only unique within this machine), `enabled` (a disabled Windows account still
/// exists, which no passwd field expresses), `last_logon` and `password_expires`. Nothing is lost, and nothing
/// is squeezed into a field that means something else.</para>
/// </summary>
public sealed class GetentModule : IModule
{
    public string Name => "getent";

    public string Description =>
        "Read the host's local accounts: `database: passwd` for users, `group` for groups. Windows local "
        + "accounts presented in the passwd/group field layout the fleet's Accounts view reads — `uid` is the "
        + "SID's relative identifier (built-ins below 1000, created accounts from 1001), and the full SID, "
        + "enabled flag and last logon travel beside each record. Read-only; creating and removing accounts is "
        + "the `user` / `group` module. Domain accounts are NOT in here: this is the local SAM, and asking a "
        + "member server for the domain's users would be a different question with a different answer.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["database"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "passwd", "group" },
                ["description"] = "passwd = local users, group = local groups with their members.",
            },
        },
        ["required"] = new[] { "database" },
    };

    public bool Writes => false;

    /// <summary>The trailing number of a SID: S-1-5-21-…-1001 → 1001. Windows' own account number, which is
    /// why this module can honestly fill a uid field at all.</summary>
    private static string RidOf(string? sid)
    {
        if (string.IsNullOrWhiteSpace(sid))
        {
            return "";
        }
        var last = sid.LastIndexOf('-');
        return last >= 0 && last < sid.Length - 1 ? sid[(last + 1)..] : "";
    }

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "getent (this implementation) reads the Windows local account database; on Linux the Go "
                + "agent's implementation reads the real getent.");
        }

        var database = (parameters.GetValueOrDefault("database") as string ?? "").ToLowerInvariant();
        return database switch
        {
            "passwd" => await Users(ct),
            "group" => await Groups(ct),
            // Named, with the two that work: a bare "unsupported database" would leave the caller guessing
            // whether this agent has a different spelling for shadow or hosts.
            _ => throw new ArgumentException(
                $"database: {(database.Length == 0 ? "(missing)" : database)} is not available on Windows — the "
                + "local SAM answers `passwd` (users) and `group` (groups). There is no shadow database to "
                + "read (Windows never exposes password material) and no hosts/services database behind this "
                + "module."),
        };
    }

    private static async Task<ModuleResult> Users(CancellationToken ct)
    {
        // The LocalAccounts module is PowerShell 5.1's, which is why this goes through the bridge rather than
        // through a .NET API: System.DirectoryServices.AccountManagement pulls in a much larger surface for
        // the same three properties, and the bridge is already the way every other Windows module asks.
        const string setup =
            "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($u in Get-LocalUser) { "
            + "  $p = ''; try { $p = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | "
            + "        Where-Object { $_.SID -eq $u.SID.Value } | Select-Object -First 1).LocalPath } catch { }; "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = $u.Name; sid = $u.SID.Value; full_name = $u.FullName; description = $u.Description; "
            + "    enabled = [bool]$u.Enabled; home = $p; "
            + "    last_logon = if ($u.LastLogon) { $u.LastLogon.ToString('o') } else { '' }; "
            + "    password_expires = if ($u.PasswordExpires) { $u.PasswordExpires.ToString('o') } else { '' } }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);

        var entries = new List<Dictionary<string, object?>>();
        foreach (var user in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var name = user.String("name");
            var sid = user.String("sid");
            var gecos = user.String("full_name");
            if (string.IsNullOrWhiteSpace(gecos))
            {
                gecos = user.String("description");
            }
            entries.Add(new Dictionary<string, object?>
            {
                ["name"] = name,
                // name:x:uid:gid:gecos:home:shell — seven slots, and the two that have no Windows meaning are
                // left EMPTY rather than filled with a plausible number.
                ["fields"] = new[] { name, "x", RidOf(sid), "", gecos, user.String("home"), "" },
                ["sid"] = sid,
                ["enabled"] = user.Bool("enabled"),
                ["last_logon"] = user.String("last_logon"),
                ["password_expires"] = user.String("password_expires"),
            });
        }

        var disabled = entries.Count(e => e["enabled"] is false);
        return new ModuleResult(false,
            $"{entries.Count} local user(s), {disabled} disabled — the local SAM, not the domain",
            entries, new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = entries.Count });
    }

    private static async Task<ModuleResult> Groups(CancellationToken ct)
    {
        // Members are resolved per group, and a FAILURE TO RESOLVE ONE IS NOT A FAILURE OF THE LIST:
        // Get-LocalGroupMember throws on a group holding a SID it cannot translate (a deleted domain account,
        // a WELL-KNOWN sid it does not know), which on a domain-joined host is normal. The group still exists
        // and still belongs in the answer, so the error is recorded per group instead of aborting.
        const string setup =
            "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($g in Get-LocalGroup) { "
            + "  $members = @(); $err = ''; "
            + "  try { $members = @(Get-LocalGroupMember -SID $g.SID -ErrorAction Stop | "
            + "        ForEach-Object { $_.Name }) } catch { $err = $_.Exception.Message }; "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = $g.Name; sid = $g.SID.Value; description = $g.Description; "
            + "    members = $members; member_error = $err }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);

        var entries = new List<Dictionary<string, object?>>();
        var unresolved = 0;
        foreach (var group in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var name = group.String("name");
            var members = group.StringArray("members");
            var error = group.String("member_error");
            if (!string.IsNullOrWhiteSpace(error))
            {
                unresolved++;
            }
            entries.Add(new Dictionary<string, object?>
            {
                ["name"] = name,
                // name:x:gid:members — members comma-joined, exactly as /etc/group spells them.
                ["fields"] = new[] { name, "x", RidOf(group.String("sid")), string.Join(",", members) },
                ["sid"] = group.String("sid"),
                ["description"] = group.String("description"),
                // The reason a member list is short, where it is short. Silence here would read as "empty
                // group", which is a different fact.
                ["member_error"] = string.IsNullOrWhiteSpace(error) ? null : error,
            });
        }

        var msg = $"{entries.Count} local group(s)";
        if (unresolved > 0)
        {
            msg += $" — {unresolved} could not have all members resolved (usually a deleted or unknown SID); "
                   + "the reason is on each group";
        }
        return new ModuleResult(false, msg, entries,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = entries.Count });
    }
}
