using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// The host's TIME ZONE — <c>timezone</c>, the same module name the Linux agent uses.
///
/// <para>One setting, two states (right or wrong), and it is here as the first module built on
/// <see cref="DeclarativeModule"/> — the skeleton is 20 lines of subclass instead of 380 lines of repetition,
/// which is the whole point of that base.</para>
///
/// <para>WINDOWS' ZONE IDS ARE NOT IANA'S. "W. Europe Standard Time" is the id here; "Europe/Berlin" is the
/// id on Linux, and the two are NOT interchangeable — a fleet-wide declaration written in one spelling fails
/// on half the hosts. This module takes Windows' own id and, when handed something that looks like an IANA
/// name, refuses with the Windows equivalent named rather than guessing at a mapping table that would rot.</para>
/// </summary>
public sealed class TimeZoneModule : DeclarativeModule
{
    public override string Name => "timezone";
    protected override string Noun => "time zone";
    protected override string[] States => ["present"];

    public override string Description =>
        "The host's time zone. `name` is WINDOWS' own zone id (\"W. Europe Standard Time\"), not an IANA name "
        + "— the two are different vocabularies and this module refuses an IANA name with the Windows "
        + "equivalent named instead of guessing. Reading it takes no parameters. Idempotent; `dry_run: true` "
        + "returns the plan.";

    public override IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = Prop("string", "The Windows time zone id. Omit to read the current one."),
            ["dry_run"] = DryRunProp(),
        },
    };

    /// <summary>The handful of IANA names a European fleet actually writes, so the refusal can name the
    /// Windows id instead of only complaining. Deliberately short: a full mapping is a data set (CLDR's
    /// windowsZones.xml), and half a data set embedded in a module is the thing that rots.</summary>
    private static readonly Dictionary<string, string> IanaHints = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Europe/Berlin"] = "W. Europe Standard Time",
        ["Europe/Vienna"] = "W. Europe Standard Time",
        ["Europe/Zurich"] = "W. Europe Standard Time",
        ["Europe/London"] = "GMT Standard Time",
        ["UTC"] = "UTC",
        ["Etc/UTC"] = "UTC",
        ["America/New_York"] = "Eastern Standard Time",
    };

    public override async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters,
                                                      bool dryRun, CancellationToken ct)
    {
        var wanted = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (wanted.Length == 0)
        {
            // A READ, because a module asked for nothing should tell you what is rather than fail.
            var current = await ReadAsync(parameters, ct);
            return new ModuleResult(false,
                $"the time zone is {current?["name"]} (UTC{current?["offset"]})", current);
        }
        if (wanted.Contains('/'))
        {
            var hint = IanaHints.GetValueOrDefault(wanted);
            throw new ArgumentException(
                $"name: \"{wanted}\" is an IANA zone name, and Windows uses its own ids"
                + (hint is null
                    ? ". Run this module with no parameters to see the current id, or `Get-TimeZone -ListAvailable` for all of them."
                    : $" — the Windows id for it is \"{hint}\".")
                + " The two vocabularies are not interchangeable, and mapping them by guess is how a "
                + "fleet-wide declaration silently sets the wrong zone.");
        }
        return await base.RunAsync(parameters, dryRun, ct);
    }

    protected override async Task<Dictionary<string, object?>?> ReadAsync(
        IReadOnlyDictionary<string, object?> parameters, CancellationToken ct)
    {
        var answer = await WindowsPowerShellBridge.RunJson(
            "$tz = Get-TimeZone", "[pscustomobject]@{ id = [string]$tz.Id; name = [string]$tz.DisplayName; "
            + "offset = [string]$tz.BaseUtcOffset; dst = [bool]$tz.SupportsDaylightSavingTime }",
            TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        return found.ValueKind != System.Text.Json.JsonValueKind.Object
            ? null
            : new Dictionary<string, object?>
            {
                ["name"] = found.String("id"),
                ["display_name"] = found.String("name"),
                ["offset"] = found.String("offset"),
                ["observes_dst"] = found.Bool("dst"),
            };
    }

    protected override Task<(List<string>, Dictionary<string, object?>)> CompareAsync(
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current,
        CancellationToken ct)
    {
        var wanted = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        var have = (string?)current?["name"] ?? "";
        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();
        if (!string.Equals(have, wanted, StringComparison.OrdinalIgnoreCase))
        {
            steps.Add("timezone");
            changes["timezone"] = new object?[] { have, wanted };
        }
        return Task.FromResult((steps, changes));
    }

    protected override List<string> BuildScript(IReadOnlyDictionary<string, object?> parameters,
        Dictionary<string, object?>? current, List<string> steps, Dictionary<string, object?> changes) =>
        [$"Set-TimeZone -Id {UserModule.Quote((string)parameters["name"]!)} -ErrorAction Stop"];
}

/// <summary>
/// A MACHINE-WIDE ENVIRONMENT VARIABLE — <c>environment</c>, the Linux agent's name for the same idea.
///
/// <para>SCOPE IS EXPLICIT AND HAS NO SAFE DEFAULT, so it is required: a Machine variable is visible to every
/// process and every service on the host, a User variable only to one account, and writing the second when
/// the first was meant produces a setting that "is there" and does nothing for the service that needed it.</para>
///
/// <para>AND IT DOES NOT REACH RUNNING PROCESSES. Windows hands the environment to a process when it starts;
/// changing a variable afterwards changes what the NEXT process sees. Services need restarting, and this
/// module says so in its answer rather than letting a caller conclude that a set variable is an applied
/// variable.</para>
/// </summary>
public sealed class EnvironmentVariableModule : DeclarativeModule
{
    public override string Name => "environment";
    protected override string Noun => "environment variable";

    public override string Description =>
        "A machine-wide or per-user environment variable. `name`, `value`, and `scope` (machine or user — "
        + "REQUIRED, because the wrong one produces a variable that exists and does nothing). `state: absent` "
        + "removes it. Idempotent; `dry_run: true` returns the plan. NOTE that a change reaches only processes "
        + "started AFTER it: running services keep the environment they were given.";

    public override IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = Prop("string", "The variable's name."),
            ["value"] = Prop("string", "Its value. Required unless state is absent."),
            ["scope"] = Choice("machine (every process on the host) or user (this account only). Required — "
                               + "there is no safe default.", "machine", "user"),
            ["state"] = Choice("Whether the variable should exist. Default present.", "present", "absent"),
            ["dry_run"] = DryRunProp(),
        },
        ["required"] = new[] { "name", "scope" },
    };

    private static string ScopeOf(IReadOnlyDictionary<string, object?> parameters)
    {
        var scope = (parameters.GetValueOrDefault("scope") as string ?? "").ToLowerInvariant();
        return scope is "machine" or "user"
            ? scope
            : throw new ArgumentException(
                "scope: required, and one of machine or user. A machine variable is visible to every service "
                + "on the host and a user variable only to one account; picking one by default would make "
                + "half of all uses of this module quietly wrong.");
    }

    protected override string Target(IReadOnlyDictionary<string, object?> parameters) =>
        $"{parameters.GetValueOrDefault("name")} ({ScopeOf(parameters)})";

    protected override async Task<Dictionary<string, object?>?> ReadAsync(
        IReadOnlyDictionary<string, object?> parameters, CancellationToken ct)
    {
        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            throw new ArgumentException("name: required — the variable to read or set.");
        }
        var scope = ScopeOf(parameters) == "machine" ? "Machine" : "User";
        var answer = await WindowsPowerShellBridge.RunJson(
            $"$v = [Environment]::GetEnvironmentVariable({UserModule.Quote(name)}, '{scope}')",
            "[pscustomobject]@{ present = ($null -ne $v); value = [string]$v }",
            TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object || !found.Bool("present"))
        {
            // Absent, which is different from empty: a variable set to "" exists and shadows nothing, and a
            // caller declaring "" must not be told it is already absent.
            return null;
        }
        return new Dictionary<string, object?>
        {
            ["name"] = name,
            ["value"] = found.String("value"),
            ["scope"] = ScopeOf(parameters),
        };
    }

    protected override Task<(List<string>, Dictionary<string, object?>)> CompareAsync(
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current,
        CancellationToken ct)
    {
        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        var wanted = parameters.GetValueOrDefault("value") as string;
        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();

        if (state == "absent")
        {
            if (current is not null)
            {
                steps.Add("remove");
                changes["remove"] = new object?[] { current["value"], null };
            }
            return Task.FromResult((steps, changes));
        }

        if (wanted is null)
        {
            throw new ArgumentException("value: required unless state is absent.");
        }
        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, wanted };
        }
        else if ((string?)current["value"] != wanted)
        {
            steps.Add("value");
            changes["value"] = new object?[] { current["value"], wanted };
        }
        return Task.FromResult((steps, changes));
    }

    protected override List<string> BuildScript(IReadOnlyDictionary<string, object?> parameters,
        Dictionary<string, object?>? current, List<string> steps, Dictionary<string, object?> changes)
    {
        var name = UserModule.Quote((string)parameters["name"]!);
        var scope = ScopeOf(parameters) == "machine" ? "Machine" : "User";
        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        // $null removes it; a quoted value sets it. Both go through the same call, which is why removal needs
        // no separate cmdlet.
        var value = state == "absent" ? "$null" : UserModule.Quote((string)parameters["value"]!);
        return [$"[Environment]::SetEnvironmentVariable({name}, {value}, '{scope}')"];
    }
}

/// <summary>
/// WHETHER THIS HOST IS WAITING FOR A REBOOT — <c>pending_reboot</c>, read-only.
///
/// <para>A read, not a declaration, and it exists because "awaiting-restart" is a state this system already
/// reports for a feature install and had no way to confirm afterwards. Windows records a pending reboot in
/// FOUR unrelated places, each set by a different subsystem, and any one of them means the host has work
/// deferred to its next boot. A check that looked at one of them would answer "no" to a host that is waiting.</para>
///
/// <para>Every source is reported separately AND as an aggregate, because they mean different things: a
/// Component-Based Servicing flag comes from a feature or update install, a File Rename Operation from a
/// locked file that will be replaced at boot, and a pending computer rename from exactly that.</para>
/// </summary>
public sealed class PendingRebootModule : IModule
{
    public string Name => "pending_reboot";

    public string Description =>
        "Whether this Windows host is waiting for a reboot, and WHY — the four independent places Windows "
        + "records it (Component-Based Servicing, Windows Update, pending file renames, a pending computer "
        + "rename), each reported separately plus the aggregate. Read-only, takes no parameters.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>(),
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "pending_reboot reads Windows' own pending-reboot markers; on Linux the equivalent is "
                + "/var/run/reboot-required, which the Go agent's needs-restarting check reads.");
        }

        const string setup =
            "$cbs = Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending'; "
            + "$wu = Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\WindowsUpdate\\Auto Update\\RebootRequired'; "
            + "$rename = $false; "
            + "try { $active = (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ActiveComputerName' -ErrorAction Stop).ComputerName; "
            + "  $pending = (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ComputerName' -ErrorAction Stop).ComputerName; "
            + "  $rename = ($active -ne $pending) } catch { }; "
            + "$renames = @(); "
            + "try { $renames = @((Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager' "
            + "  -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations) } catch { }";
        var answer = await WindowsPowerShellBridge.RunJson(
            setup,
            "[pscustomobject]@{ cbs = [bool]$cbs; windows_update = [bool]$wu; computer_rename = [bool]$rename; "
            + "pending_file_renames = @($renames).Count }",
            TimeSpan.FromMinutes(2), ct);

        var found = answer.Items.FirstOrDefault();
        var cbs = found.Bool("cbs");
        var wu = found.Bool("windows_update");
        var rename = found.Bool("computer_rename");
        var renames = found.Long("pending_file_renames") ?? 0;
        var pending = cbs || wu || rename || renames > 0;

        var reasons = new List<string>();
        if (cbs) { reasons.Add("a feature or update install is waiting for the next boot (Component-Based Servicing)"); }
        if (wu) { reasons.Add("Windows Update has staged work"); }
        if (rename) { reasons.Add("the computer's name has been changed and takes effect at boot"); }
        if (renames > 0) { reasons.Add($"{renames} file(s) are locked and get replaced at boot"); }

        return new ModuleResult(false,
            pending
                ? "this host is waiting for a reboot: " + string.Join("; ", reasons)
                : "no reboot is pending — none of the four markers Windows uses is set",
            new Dictionary<string, object?>
            {
                ["pending"] = pending,
                ["reasons"] = reasons,
                // EACH SOURCE SEPARATELY, because they are different facts with different fixes and an
                // aggregate boolean hides which one it was.
                ["component_based_servicing"] = cbs,
                ["windows_update"] = wu,
                ["computer_rename"] = rename,
                ["pending_file_renames"] = renames,
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = reasons.Count });
    }
}
