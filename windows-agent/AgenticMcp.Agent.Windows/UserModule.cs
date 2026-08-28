using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// A LOCAL WINDOWS ACCOUNT IN A DECLARED STATE, under the name the fleet already uses (<c>user</c>) and with
/// the parameters the Accounts screen already sends.
///
/// <para>Idempotent the way every write module here is: the account is READ first, compared field by field,
/// and an already-correct account reports <c>changed: false</c> with what it holds. `dry_run` returns the same
/// comparison as a plan without touching anything.</para>
///
/// <para>WHAT IT REFUSES, and why refusing beats ignoring. The Linux `user` module takes `uid`, `shell`,
/// `home`, `create_home`, `system` and `remove`; three of those cannot be honoured on Windows at all. A module
/// that accepted them and quietly did nothing would let a runbook state something false about a host and pass
/// — the operator reads "uid: 1500" in the playbook, the host has 1003, and nothing anywhere says so. So each
/// one is refused with the reason and, where there is one, the Windows equivalent:</para>
/// <list type="bullet">
/// <item><c>uid</c> — the SAM assigns the RID; it cannot be chosen. (It CAN be read: see `getent`.)</item>
/// <item><c>shell</c> — there is no login shell to set.</item>
/// <item><c>home</c>/<c>create_home</c> — the profile directory is created by Windows at first sign-in and
/// its path follows the account name; setting it is a per-account registry redirection, which is a different
/// operation and would need its own module.</item>
/// <item><c>system</c> — "system account" on Windows means a built-in SID (LocalSystem, NetworkService), not
/// a flag on a created account.</item>
/// </list>
///
/// <para>THE PASSWORD NEVER TOUCHES THE COMMAND LINE. It goes to the child shell in its environment (see
/// WindowsPowerShellBridge), because a command line is readable by anything that can query Win32_Process. It
/// is also redacted out of the operation log by parameter name, and it is never read back — a password cannot
/// be compared, so `changed` never claims to know whether it differed.</para>
/// </summary>
public sealed class UserModule : IModule
{
    public string Name => "user";

    public string Description =>
        "Ensure a LOCAL Windows account is present or absent, with its full name, description, enabled state, "
        + "password policy and local group memberships. Idempotent: the account is read and compared first, "
        + "and an already-correct account reports changed:false. `dry_run: true` returns the plan. An "
        + "ansible.windows.win_user task maps here. Parameters that cannot be honoured on Windows (uid, shell, "
        + "home, create_home, system) are REFUSED with the reason rather than ignored. Domain accounts are out "
        + "of scope: this is the local SAM.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = Prop("string", "The account name, e.g. \"deploy\"."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the account should exist. Default present.",
            },
            ["comment"] = Prop("string", "The account's full name (the GECOS slot on Linux)."),
            ["description"] = Prop("string", "Windows' own Description field, shown in Computer Management."),
            ["password"] = Prop("string",
                "Set the account's password. Never logged, never read back — so a run that sets a password "
                + "reports changed:true because it cannot know whether the old one differed."),
            ["enabled"] = Prop("boolean", "Whether the account may sign in. A DISABLED ACCOUNT STILL EXISTS, "
                                          + "which is why this is separate from state."),
            ["password_never_expires"] = Prop("boolean", "Whether the password expiry policy applies."),
            ["groups"] = new Dictionary<string, object>
            {
                ["type"] = "array",
                ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Local groups this account must belong to, e.g. [\"Administrators\"].",
            },
            ["append"] = Prop("boolean",
                "True: add to the account's current groups. False (default): the listed groups are the WHOLE "
                + "membership and anything else is removed."),
            ["dry_run"] = Prop("boolean", "Report what would change without applying it."),
        },
        ["required"] = new[] { "name" },
    };

    private static Dictionary<string, object> Prop(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    /// <summary>Parameters this module cannot honour, each with what to do instead. Refused, not ignored: a
    /// silently dropped parameter lets a runbook assert something untrue about a host and still pass.</summary>
    private static readonly Dictionary<string, string> Unhonourable = new(StringComparer.OrdinalIgnoreCase)
    {
        ["uid"] = "Windows assigns the account's RID itself and it cannot be chosen. `getent` reports the RID "
                  + "an account was given.",
        ["shell"] = "a Windows account has no login shell.",
        ["home"] = "the profile directory is created by Windows at first sign-in and follows the account name; "
                   + "redirecting it is a separate per-account registry setting, not part of creating a user.",
        ["create_home"] = "see `home`: Windows creates the profile at first sign-in, not at account creation.",
        ["system"] = "on Windows a system account is a built-in SID (LocalSystem, NetworkService), not a flag "
                     + "on an account somebody creates.",
        ["remove"] = "removing an account does not delete its profile here; use the `file` module on the "
                     + "profile path if that is what you mean, so the deletion is visible in the plan.",
    };

    private const string PasswordVariable = "AGENTIC_SECRET_NEW_PASSWORD";

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "user (this implementation) manages Windows local accounts; on Linux the Go agent's "
                + "useradd/usermod implementation answers the same name.");
        }

        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            throw new ArgumentException("name: required — the account to ensure.");
        }

        foreach (var (key, reason) in Unhonourable)
        {
            if (parameters.TryGetValue(key, out var given) && given is not null
                && !(given is string s && s.Length == 0))
            {
                throw new ArgumentException($"{key}: not supported on Windows — {reason}");
            }
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent"))
        {
            throw new ArgumentException($"state: {state} is not one of present, absent.");
        }

        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;
        var current = await Read(name, ct);

        return state == "absent"
            ? await EnsureAbsent(name, current, dryRun, ct)
            : await EnsurePresent(name, parameters, current, dryRun, ct);
    }

    /// <summary>What the host says about this account right now: null when it does not exist.</summary>
    private static async Task<Dictionary<string, object?>?> Read(string name, CancellationToken ct)
    {
        var quoted = Quote(name);
        var setup =
            "$out = @(); $u = Get-LocalUser -Name " + quoted + " -ErrorAction SilentlyContinue; "
            + "if ($u) { "
            + "  $groups = @(Get-LocalGroup | Where-Object { "
            + "    @(Get-LocalGroupMember -SID $_.SID -ErrorAction SilentlyContinue | "
            + "      Where-Object { $_.SID.Value -eq $u.SID.Value }).Count -gt 0 } | ForEach-Object { $_.Name }); "
            + "  $out = @([pscustomobject]@{ name = $u.Name; sid = $u.SID.Value; full_name = $u.FullName; "
            + "    description = $u.Description; enabled = [bool]$u.Enabled; "
            + "    password_never_expires = ($null -eq $u.PasswordExpires); groups = $groups }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return null;
        }
        return new Dictionary<string, object?>
        {
            ["name"] = found.String("name"),
            ["sid"] = found.String("sid"),
            ["comment"] = found.String("full_name"),
            ["description"] = found.String("description"),
            ["enabled"] = found.Bool("enabled"),
            ["password_never_expires"] = found.Bool("password_never_expires"),
            ["groups"] = found.StringArray("groups"),
        };
    }

    private static async Task<ModuleResult> EnsureAbsent(string name, Dictionary<string, object?>? current,
                                                         bool dryRun, CancellationToken ct)
    {
        if (current is null)
        {
            return new ModuleResult(false, $"account {name} is already absent", new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "absent", ["existed"] = false,
            });
        }
        if (dryRun)
        {
            return new ModuleResult(true, $"would remove account {name} (SID {current["sid"]})",
                new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
        }
        await WindowsPowerShellBridge.RunJson(
            $"Remove-LocalUser -Name {Quote(name)} -ErrorAction Stop", "@()", TimeSpan.FromMinutes(2), ct);
        var after = await Read(name, ct);
        if (after is not null)
        {
            // THE EXIT CODE IS A CLAIM, THE STATE IS THE EVIDENCE — the rule windows_capability was fixed
            // with, applied from the start here.
            throw new InvalidOperationException(
                $"Remove-LocalUser reported success but {name} still exists on the host.");
        }
        return new ModuleResult(true, $"removed account {name}",
            new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
    }

    private static async Task<ModuleResult> EnsurePresent(string name,
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current, bool dryRun,
        CancellationToken ct)
    {
        var comment = parameters.GetValueOrDefault("comment") as string;
        var description = parameters.GetValueOrDefault("description") as string;
        var password = parameters.GetValueOrDefault("password") as string;
        var enabled = parameters.GetValueOrDefault("enabled") as bool?;
        var neverExpires = parameters.GetValueOrDefault("password_never_expires") as bool?;
        var append = parameters.GetValueOrDefault("append") is true;
        var wanted = AsStringList(parameters.GetValueOrDefault("groups"));

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();

        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new[] { null, name };
        }
        else
        {
            void Compare(string key, object? want, object? have)
            {
                if (want is null || Equals(want, have))
                {
                    return;
                }
                steps.Add(key);
                changes[key] = new[] { have, want };
            }

            Compare("comment", comment, current["comment"]);
            Compare("description", description, current["description"]);
            Compare("enabled", enabled, current["enabled"]);
            Compare("password_never_expires", neverExpires, current["password_never_expires"]);
        }

        var have = current is null ? [] : (List<string>)current["groups"]!;
        var toAdd = wanted.Where(g => !have.Contains(g, StringComparer.OrdinalIgnoreCase)).ToList();
        // append:false means the listed groups are the WHOLE membership. Only ever computed when the caller
        // actually stated a list — `groups` absent means "leave membership alone", not "remove everything",
        // and confusing those two would strip Administrators off an account on the first careless call.
        var toRemove = !append && parameters.ContainsKey("groups")
            ? have.Where(g => !wanted.Contains(g, StringComparer.OrdinalIgnoreCase)).ToList()
            : [];
        if (toAdd.Count > 0)
        {
            steps.Add("groups+");
            changes["groups_add"] = toAdd;
        }
        if (toRemove.Count > 0)
        {
            steps.Add("groups-");
            changes["groups_remove"] = toRemove;
        }
        if (password is not null)
        {
            // A PASSWORD CANNOT BE COMPARED, so setting one is always a change and says so rather than
            // pretending to know whether it differed.
            steps.Add("password");
            changes["password"] = "set (not comparable, so always reported as a change)";
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"account {name} is already as declared", new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["current"] = current,
            });
        }

        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} {name}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                {
                    ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = new List<string>();
        var environment = new Dictionary<string, string>();
        if (password is not null)
        {
            environment[PasswordVariable] = password;
            script.Add($"$pw = ConvertTo-SecureString $env:{PasswordVariable} -AsPlainText -Force");
        }

        if (current is null)
        {
            var create = $"New-LocalUser -Name {Quote(name)} -ErrorAction Stop";
            create += password is not null ? " -Password $pw" : " -NoPassword";
            if (!string.IsNullOrEmpty(comment)) { create += $" -FullName {Quote(comment)}"; }
            if (!string.IsNullOrEmpty(description)) { create += $" -Description {Quote(description)}"; }
            if (neverExpires is true) { create += " -PasswordNeverExpires"; }
            script.Add(create + " | Out-Null");
            if (enabled is false) { script.Add($"Disable-LocalUser -Name {Quote(name)} -ErrorAction Stop"); }
        }
        else
        {
            var set = new List<string>();
            if (!string.IsNullOrEmpty(comment) && changes.ContainsKey("comment")) { set.Add($"-FullName {Quote(comment)}"); }
            if (!string.IsNullOrEmpty(description) && changes.ContainsKey("description")) { set.Add($"-Description {Quote(description)}"); }
            if (password is not null) { set.Add("-Password $pw"); }
            if (neverExpires is not null && changes.ContainsKey("password_never_expires"))
            {
                set.Add($"-PasswordNeverExpires ${neverExpires.ToString()!.ToLowerInvariant()}");
            }
            if (set.Count > 0)
            {
                script.Add($"Set-LocalUser -Name {Quote(name)} {string.Join(" ", set)} -ErrorAction Stop");
            }
            if (changes.ContainsKey("enabled"))
            {
                script.Add(enabled is true
                    ? $"Enable-LocalUser -Name {Quote(name)} -ErrorAction Stop"
                    : $"Disable-LocalUser -Name {Quote(name)} -ErrorAction Stop");
            }
        }

        foreach (var group in toAdd)
        {
            script.Add($"Add-LocalGroupMember -Group {Quote(group)} -Member {Quote(name)} -ErrorAction Stop");
        }
        foreach (var group in toRemove)
        {
            script.Add($"Remove-LocalGroupMember -Group {Quote(group)} -Member {Quote(name)} -ErrorAction Stop");
        }

        // Each statement announces itself first, so a failure halfway through says what had already been
        // applied instead of leaving the caller to guess (the bridge carries stdout into the error).
        await WindowsPowerShellBridge.RunJson(string.Join("; ", Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct, environment);

        var after = await Read(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the account operations reported success but {name} does not exist on the host afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} account {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    /// <summary>Each statement preceded by a marker naming what it does, so the bridge's error can report
    /// how far a multi-step apply got. The marker is the statement itself, shortened — a hand-written label
    /// per step would be a second description of the same thing and would drift from it.</summary>
    internal static IEnumerable<string> Announced(IEnumerable<string> statements)
    {
        foreach (var statement in statements)
        {
            var label = statement.Length > 90 ? statement[..90] : statement;
            yield return $"Write-Output {Quote("did: " + label)}";
            yield return statement;
        }
    }

    internal static List<string> AsStringList(object? value) => value switch
    {
        null => [],
        string single => single.Length == 0 ? [] : [single],
        System.Text.Json.JsonElement element => element.ValueKind == System.Text.Json.JsonValueKind.Array
            ? element.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0).ToList()
            : [],
        IEnumerable<object?> many => many.Select(v => v?.ToString() ?? "").Where(s => s.Length > 0).ToList(),
        _ => [value.ToString() ?? ""],
    };

    /// <summary>A PowerShell single-quoted literal: the only quoting where nothing inside is expanded, and a
    /// doubled quote is the escape. An account name with a space or an apostrophe is not exotic.</summary>
    internal static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
}
