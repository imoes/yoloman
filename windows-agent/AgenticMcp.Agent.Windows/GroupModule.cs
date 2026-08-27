using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// A LOCAL WINDOWS GROUP IN A DECLARED STATE — the counterpart to <see cref="UserModule"/>, under the name
/// the fleet already uses (<c>group</c>).
///
/// <para>Same rules, for the same reasons: read first and compare, so an already-correct group reports
/// <c>changed: false</c>; `dry_run` returns the plan; a parameter that cannot be honoured is refused with its
/// reason instead of ignored (`gid` — Windows assigns a group's RID itself).</para>
///
/// <para>MEMBERSHIP IS DECLARED FROM THE GROUP'S SIDE HERE, and from the account's side in `user`. Two ways to
/// state one fact is normally a design smell, and it is kept on purpose only because the two answer different
/// questions an operator actually asks — "who is in Administrators" (a group policy) and "which groups does
/// this service account need" (an account policy). What makes it safe is that neither invents a default:
/// `members` absent means membership is not part of this declaration, exactly as `groups` absent does in
/// `user`. Only a stated list is enforced.</para>
/// </summary>
public sealed class GroupModule : IModule
{
    public string Name => "group";

    public string Description =>
        "Ensure a LOCAL Windows group is present or absent, with its description and (optionally) its exact "
        + "membership. Idempotent: read and compared first, an already-correct group reports changed:false. "
        + "`dry_run: true` returns the plan. `members` absent means membership is left alone; given, it is "
        + "enforced (use append:true to add only). `gid` is refused — Windows assigns the RID itself. An "
        + "ansible.windows.win_group task maps here.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object> { ["type"] = "string", ["description"] = "The group name." },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the group should exist. Default present.",
            },
            ["description"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["description"] = "The group's description as Computer Management shows it.",
            },
            ["members"] = new Dictionary<string, object>
            {
                ["type"] = "array",
                ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Accounts that must be in the group. Local names, or DOMAIN\\\\name. Absent "
                                  + "means membership is not part of this declaration.",
            },
            ["append"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["description"] = "True: only add the listed members. False (default, when members is given): "
                                  + "the list is the WHOLE membership and anything else is removed.",
            },
            ["dry_run"] = new Dictionary<string, object>
            {
                ["type"] = "boolean", ["description"] = "Report what would change without applying it.",
            },
        },
        ["required"] = new[] { "name" },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "group (this implementation) manages Windows local groups; on Linux the Go agent's "
                + "groupadd/groupmod implementation answers the same name.");
        }

        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            throw new ArgumentException("name: required — the group to ensure.");
        }
        if (parameters.TryGetValue("gid", out var gid) && gid is not null and not "")
        {
            throw new ArgumentException(
                "gid: not supported on Windows — the SAM assigns a group's RID and it cannot be chosen. "
                + "`getent database=group` reports the RID a group was given.");
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
            if (current is null)
            {
                return new ModuleResult(false, $"group {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["existed"] = false });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove group {name} (SID {current["sid"]})",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                $"Remove-LocalGroup -Name {UserModule.Quote(name)} -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            if (await Read(name, ct) is not null)
            {
                throw new InvalidOperationException(
                    $"Remove-LocalGroup reported success but {name} still exists on the host.");
            }
            return new ModuleResult(true, $"removed group {name}",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        var description = parameters.GetValueOrDefault("description") as string;
        var append = parameters.GetValueOrDefault("append") is true;
        var declaresMembers = parameters.ContainsKey("members");
        var wanted = UserModule.AsStringList(parameters.GetValueOrDefault("members"));

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();

        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new[] { null, name };
        }
        else if (!string.IsNullOrEmpty(description) && (string?)current["description"] != description)
        {
            steps.Add("description");
            changes["description"] = new[] { current["description"], description };
        }

        var have = current is null ? [] : (List<string>)current["members"]!;
        // Membership comparison is on the LEAF NAME. Get-LocalGroupMember answers fully qualified
        // ("HOSTNAME\\Administrator", "NT AUTHORITY\\Authenticated Users") while an operator declares
        // "Administrator" — comparing the strings whole would make every run report a change and re-add a
        // member that is already there. A caller who states a qualified name gets it compared qualified.
        var toAdd = declaresMembers
            ? wanted.Where(w => !have.Any(h => SameMember(h, w))).ToList()
            : [];
        // REFUSED RATHER THAN GUESSED: if the current membership could not be read in full (a deleted or
        // untranslatable SID, which is ordinary on a domain-joined host), then "everything not in my list"
        // includes members nobody could see — and enforcing it would delete them. The caller is told what
        // went wrong and can either fix the group or pass append:true, which never removes anything.
        if (declaresMembers && !append && current?["member_error"] is string readError)
        {
            throw new InvalidOperationException(
                $"refusing to enforce exact membership of {name}: its current members could not all be read "
                + $"({readError}), so anything unreadable would be treated as \"not in the list\" and "
                + "removed. Pass append:true to add without removing, or resolve the unreadable member first.");
        }
        var toRemove = declaresMembers && !append
            ? have.Where(h => !wanted.Any(w => SameMember(h, w))).ToList()
            : [];
        if (toAdd.Count > 0) { steps.Add("members+"); changes["members_add"] = toAdd; }
        if (toRemove.Count > 0) { steps.Add("members-"); changes["members_remove"] = toRemove; }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"group {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "present", ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} group {name}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                {
                    ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = new List<string>();
        if (current is null)
        {
            var create = $"New-LocalGroup -Name {UserModule.Quote(name)} -ErrorAction Stop";
            if (!string.IsNullOrEmpty(description)) { create += $" -Description {UserModule.Quote(description)}"; }
            script.Add(create + " | Out-Null");
        }
        else if (changes.ContainsKey("description"))
        {
            script.Add($"Set-LocalGroup -Name {UserModule.Quote(name)} "
                       + $"-Description {UserModule.Quote(description!)} -ErrorAction Stop");
        }
        foreach (var member in toAdd)
        {
            script.Add($"Add-LocalGroupMember -Group {UserModule.Quote(name)} "
                       + $"-Member {UserModule.Quote(member)} -ErrorAction Stop");
        }
        foreach (var member in toRemove)
        {
            script.Add($"Remove-LocalGroupMember -Group {UserModule.Quote(name)} "
                       + $"-Member {UserModule.Quote(member)} -ErrorAction Stop");
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);

        var after = await Read(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the group operations reported success but {name} does not exist on the host afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} group {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    /// <summary>Do two member spellings name the same account? Equal whole, or equal after the last
    /// backslash — "HOSTNAME\\deploy" and "deploy" are the same member of a local group.</summary>
    private static bool SameMember(string one, string other)
    {
        static string Leaf(string value)
        {
            var cut = value.LastIndexOf('\\');
            return cut >= 0 ? value[(cut + 1)..] : value;
        }
        return string.Equals(one, other, StringComparison.OrdinalIgnoreCase)
               || string.Equals(Leaf(one), Leaf(other), StringComparison.OrdinalIgnoreCase);
    }

    private static async Task<Dictionary<string, object?>?> Read(string name, CancellationToken ct)
    {
        var setup =
            "$out = @(); $g = Get-LocalGroup -Name " + UserModule.Quote(name) + " -ErrorAction SilentlyContinue; "
            + "if ($g) { $members = @(); $err = ''; "
            + "  try { $members = @(Get-LocalGroupMember -SID $g.SID -ErrorAction Stop | "
            + "        ForEach-Object { $_.Name }) } catch { $err = $_.Exception.Message }; "
            + "  $out = @([pscustomobject]@{ name = $g.Name; sid = $g.SID.Value; description = $g.Description; "
            + "    members = $members; member_error = $err }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return null;
        }
        var error = found.String("member_error");
        return new Dictionary<string, object?>
        {
            ["name"] = found.String("name"),
            ["sid"] = found.String("sid"),
            ["description"] = found.String("description"),
            ["members"] = found.StringArray("members"),
            // Carried, because a membership comparison against a list that could not be fully read would
            // otherwise silently "remove" the members it failed to see.
            ["member_error"] = string.IsNullOrWhiteSpace(error) ? null : error,
        };
    }
}
