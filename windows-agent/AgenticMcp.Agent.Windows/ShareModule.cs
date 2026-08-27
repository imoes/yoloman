using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// SMB SHARES on this host — <c>share</c>: what is shared, to whom, and with which share-level rights.
///
/// <para>IT MANAGES THE SHARE, NOT THE FOLDER, and that is the single most misread thing about file serving on
/// Windows. A path reached over SMB is governed by TWO independent access lists: the SHARE permissions (this
/// module) and the NTFS permissions on the directory (not this module). The effective right is the more
/// restrictive of the two, so a share granting Everyone:Full whose folder grants Users:Read is a read-only
/// share — and a module that reported only its own half would explain a "permission denied" with the wrong
/// answer. Every read here therefore says which list it is showing, and the NTFS side is named as absent
/// rather than left to be assumed.</para>
///
/// <para>THE DEFAULT SHARES ARE LISTED, NOT HIDDEN. C$, ADMIN$ and IPC$ exist on every Windows host and are
/// exactly what a reader auditing exposure needs to see; they are flagged (`special: true`) so a caller can
/// tell them from something an operator created, and refused as targets for removal, because deleting ADMIN$
/// breaks remote management including this agent's own installer.</para>
/// </summary>
public sealed class ShareModule : IModule
{
    public string Name => "share";

    public string Description =>
        "SMB shares. Without `name`: list every share with its path, description, share-level permissions and "
        + "whether it is one of Windows' built-in administrative shares. With `name`: ensure it is present or "
        + "absent — `path` (required when creating), `description`, and the principals for `full_access`, "
        + "`change_access` and `read_access`. Idempotent: read and compared first; `dry_run: true` returns the "
        + "plan. THIS MANAGES SHARE PERMISSIONS ONLY — the folder's NTFS permissions are a separate access "
        + "list and the effective right is the more restrictive of the two, so a share can be read-only "
        + "because of the folder while this module reports Full.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = P("string", "Share name (without the host part). Omit to LIST every share."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the share should exist. Default present.",
            },
            ["path"] = P("string", "The local folder to share, e.g. D:\\\\data. Required when creating."),
            ["description"] = P("string", "The share's description, as Explorer shows it."),
            ["full_access"] = Principals("Principals granted FULL share access, e.g. [\"Administrators\"]."),
            ["change_access"] = Principals("Principals granted CHANGE (read+write) share access."),
            ["read_access"] = Principals("Principals granted READ share access."),
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    private static Dictionary<string, object> Principals(string description) => new()
    {
        ["type"] = "array",
        ["items"] = new Dictionary<string, object> { ["type"] = "string" },
        ["description"] = description + " Absent means this list is not part of the declaration; given, it is "
                                      + "enforced exactly.",
    };

    public bool Writes => true;

    /// <summary>Windows' own shares. Never removed by this module: ADMIN$ and IPC$ carry remote management,
    /// including the path this agent's own installer uses.</summary>
    private static readonly HashSet<string> Special =
        new(StringComparer.OrdinalIgnoreCase) { "ADMIN$", "IPC$", "PRINT$", "FAX$" };

    private static bool IsSpecial(string name) =>
        Special.Contains(name) || (name.Length == 2 && name.EndsWith('$') && char.IsLetter(name[0]));

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "share (this implementation) manages SMB shares through Windows' SmbShare cmdlets; on Linux a "
                + "Samba share is a config file and belongs to the config/template path.");
        }

        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            return await ListAll(ct);
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent"))
        {
            throw new ArgumentException($"state: {state} is not one of present, absent.");
        }

        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;
        var current = await Read(name, ct);

        if (state == "absent")
        {
            if (IsSpecial(name))
            {
                throw new ArgumentException(
                    $"{name} is one of Windows' administrative shares and this module will not remove it: "
                    + "ADMIN$, IPC$ and the drive shares carry remote management, including the path this "
                    + "agent's own installer uses. Disable them through policy if that is really the intent.");
            }
            if (current is null)
            {
                return new ModuleResult(false, $"share {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["existed"] = false });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove share {name} (path {current["path"]})",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                $"Remove-SmbShare -Name {UserModule.Quote(name)} -Force -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            if (await Read(name, ct) is not null)
            {
                throw new InvalidOperationException(
                    $"Remove-SmbShare reported success but {name} is still shared.");
            }
            return new ModuleResult(true, $"removed share {name}",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        return await EnsurePresent(name, parameters, current, dryRun, ct);
    }

    private static async Task<ModuleResult> ListAll(CancellationToken ct)
    {
        // Get-SmbShare for the shares, Get-SmbShareAccess per share for the permissions — two cmdlets because
        // Windows keeps them apart. The access read is guarded per share: a share whose ACL cannot be read
        // (it happens on the special ones) still belongs in the list, with the reason instead of an empty
        // permission list that would read as "nobody has access".
        const string setup =
            "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($s in Get-SmbShare) { "
            + "  $acl = @(); $err = ''; "
            + "  try { $acl = @(Get-SmbShareAccess -Name $s.Name -ErrorAction Stop | ForEach-Object { "
            + "        [string]$_.AccountName + '=' + [string]$_.AccessRight + '/' + [string]$_.AccessControlType }) } "
            + "  catch { $err = $_.Exception.Message }; "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = $s.Name; path = [string]$s.Path; description = [string]$s.Description; "
            + "    type = [string]$s.ShareType; special = [bool]$s.Special; "
            + "    folder_enumeration_mode = [string]$s.FolderEnumerationMode; "
            + "    caching_mode = [string]$s.CachingMode; encrypt = [bool]$s.EncryptData; "
            + "    access = $acl; access_error = $err }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(3), ct);

        var rows = new List<Dictionary<string, object?>>();
        foreach (var share in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var shareName = share.String("name");
            var access = share.StringArray("access");
            var error = share.String("access_error");
            rows.Add(new Dictionary<string, object?>
            {
                ["name"] = shareName,
                ["path"] = share.String("path"),
                ["description"] = share.String("description"),
                ["type"] = share.String("type").ToLowerInvariant(),
                // Windows' own flag, plus our own reading of the name: a drive share (C$) is special without
                // Windows always saying so.
                ["special"] = share.Bool("special") || IsSpecial(shareName),
                ["encrypted"] = share.Bool("encrypt"),
                ["folder_enumeration_mode"] = share.String("folder_enumeration_mode"),
                ["caching_mode"] = share.String("caching_mode"),
                // WHICH ACCESS LIST THIS IS, on every row. The folder's NTFS list is the other half and the
                // effective right is the more restrictive of the two; a reader who forgets that debugs the
                // wrong list.
                ["access_kind"] = "smb-share-permissions",
                ["access"] = access,
                ["access_summary"] = access.Count > 0 ? string.Join(", ", access)
                    : (error.Length > 0 ? "(could not be read)" : "(none granted)"),
                ["access_error"] = error.Length > 0 ? error : null,
                ["ntfs_permissions"] = "not read by this module — the folder's own access list is separate, "
                                       + "and the effective right is the more restrictive of the two",
            });
        }

        rows.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"],
                                           StringComparison.OrdinalIgnoreCase));
        var created = rows.Count(r => r["special"] is not true);
        return new ModuleResult(false,
            $"{rows.Count} share(s), {created} beyond Windows' built-in administrative shares — SHARE "
            + "permissions only; each folder's NTFS list is a separate access list and the stricter of the "
            + "two wins",
            new Dictionary<string, object?> { ["shares"] = rows, ["count"] = rows.Count },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = rows.Count });
    }

    private static async Task<Dictionary<string, object?>?> Read(string name, CancellationToken ct)
    {
        var setup =
            "$out = @(); $s = Get-SmbShare -Name " + UserModule.Quote(name) + " -ErrorAction SilentlyContinue; "
            + "if ($s) { $acl = @(); try { $acl = @(Get-SmbShareAccess -Name $s.Name -ErrorAction Stop | "
            + "    ForEach-Object { [string]$_.AccountName + '=' + [string]$_.AccessRight }) } catch { }; "
            + "  $out = @([pscustomobject]@{ name = $s.Name; path = [string]$s.Path; "
            + "    description = [string]$s.Description; special = [bool]$s.Special; access = $acl }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return null;
        }
        return new Dictionary<string, object?>
        {
            ["name"] = found.String("name"),
            ["path"] = found.String("path"),
            ["description"] = found.String("description"),
            ["special"] = found.Bool("special"),
            ["access"] = found.StringArray("access"),
        };
    }

    private static async Task<ModuleResult> EnsurePresent(string name,
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current, bool dryRun,
        CancellationToken ct)
    {
        var path = parameters.GetValueOrDefault("path") as string;
        var description = parameters.GetValueOrDefault("description") as string;
        // PRINCIPALS GO THROUGH THEIR SIDs. "Everyone" is Jeder on this host, and New-SmbShare answers a name
        // it cannot map with "Zuordnungen von Kontennamen und Sicherheitskennungen wurden nicht durchgeführt"
        // — measured, and it is why a fleet-wide declaration has to be written in well-known names and
        // translated per host (see WindowsPrincipals).
        var wanted = new (string Right, List<string> Principals)[]
        {
            ("Full", WindowsPrincipals.Resolve(UserModule.AsStringList(parameters.GetValueOrDefault("full_access")))),
            ("Change", WindowsPrincipals.Resolve(UserModule.AsStringList(parameters.GetValueOrDefault("change_access")))),
            ("Read", WindowsPrincipals.Resolve(UserModule.AsStringList(parameters.GetValueOrDefault("read_access")))),
        };
        var declaresAccess = parameters.ContainsKey("full_access") || parameters.ContainsKey("change_access")
                             || parameters.ContainsKey("read_access");

        if (current is null && string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("path: required to create a share — the local folder to share.");
        }

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();
        var have = current is null ? [] : (List<string>)current["access"]!;

        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, $"{name} → {path}" };
        }
        else
        {
            if (!string.IsNullOrWhiteSpace(path)
                && !string.Equals(((string?)current["path"] ?? "").TrimEnd('\\'), path.TrimEnd('\\'),
                                  StringComparison.OrdinalIgnoreCase))
            {
                // A SHARE CANNOT BE REPOINTED, and pretending otherwise would silently delete and recreate it
                // — losing its permissions and dropping every connected client. Refused with what to do.
                throw new InvalidOperationException(
                    $"share {name} already points at {current["path"]}; Windows cannot move a share to "
                    + $"{path}. Remove it (state: absent) and create it again if that is the intent — which "
                    + "drops its permissions and disconnects clients, so it should be a decision, not a "
                    + "side effect.");
            }
            if (description is not null && (string?)current["description"] != description)
            {
                steps.Add("description");
                changes["description"] = new object?[] { current["description"], description };
            }
        }

        var wantedPairs = wanted
            .SelectMany(w => w.Principals.Select(p => $"{p}={w.Right}"))
            .ToList();
        if (declaresAccess)
        {
            var toGrant = wantedPairs.Where(w => !have.Any(h => SamePair(h, w))).ToList();
            var toRevoke = have.Where(h => !wantedPairs.Any(w => SamePair(h, w))).ToList();
            if (toGrant.Count > 0) { steps.Add("grant"); changes["grant"] = toGrant; }
            if (toRevoke.Count > 0) { steps.Add("revoke"); changes["revoke"] = toRevoke; }
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"share {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "present", ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} share {name}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                {
                    ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = new List<string>();
        if (current is null)
        {
            var create = $"New-SmbShare -Name {UserModule.Quote(name)} -Path {UserModule.Quote(path!)} "
                         + "-ErrorAction Stop";
            if (!string.IsNullOrWhiteSpace(description))
            {
                create += $" -Description {UserModule.Quote(description)}";
            }
            foreach (var (right, principals) in wanted.Where(w => w.Principals.Count > 0))
            {
                var flag = right switch { "Full" => "-FullAccess", "Change" => "-ChangeAccess", _ => "-ReadAccess" };
                create += $" {flag} @({string.Join(",", principals.Select(UserModule.Quote))})";
            }
            script.Add(create + " | Out-Null");
        }
        else
        {
            if (changes.ContainsKey("description"))
            {
                script.Add($"Set-SmbShare -Name {UserModule.Quote(name)} "
                           + $"-Description {UserModule.Quote(description!)} -Force -ErrorAction Stop");
            }
            foreach (var pair in (List<string>?)changes.GetValueOrDefault("revoke") ?? [])
            {
                var account = pair.Split('=')[0];
                script.Add($"Revoke-SmbShareAccess -Name {UserModule.Quote(name)} "
                           + $"-AccountName {UserModule.Quote(account)} -Force -ErrorAction Stop | Out-Null");
            }
            foreach (var pair in (List<string>?)changes.GetValueOrDefault("grant") ?? [])
            {
                var parts = pair.Split('=');
                script.Add($"Grant-SmbShareAccess -Name {UserModule.Quote(name)} "
                           + $"-AccountName {UserModule.Quote(parts[0])} -AccessRight {parts[1]} -Force "
                           + "-ErrorAction Stop | Out-Null");
            }
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);

        var after = await Read(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the share operations reported success but {name} is not shared afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} share {name}: {string.Join(", ", steps)} — SHARE "
            + "permissions; the folder's NTFS list is separate and the stricter of the two wins",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    /// <summary>"BUILTIN\\Administrators=Full" and "Administrators=Full" are the same grant. Compared on the
    /// leaf account and the right, for the same reason group membership is.</summary>
    private static bool SamePair(string one, string other)
    {
        static (string Account, string Right) Parse(string pair)
        {
            var parts = pair.Split('=', 2);
            var account = parts[0];
            var cut = account.LastIndexOf('\\');
            return (cut >= 0 ? account[(cut + 1)..] : account, parts.Length > 1 ? parts[1].Split('/')[0] : "");
        }
        var (accountOne, rightOne) = Parse(one);
        var (accountTwo, rightTwo) = Parse(other);
        // WindowsPrincipals.Same, so "Everyone" and "Jeder" are one account here — without it the idempotence
        // check on a localised host would revoke and re-grant the same right on every run, forever.
        return WindowsPrincipals.Same(accountOne, accountTwo)
               && string.Equals(rightOne, rightTwo, StringComparison.OrdinalIgnoreCase);
    }
}
