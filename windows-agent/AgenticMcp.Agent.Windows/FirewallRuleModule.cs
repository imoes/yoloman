using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// THE WINDOWS FIREWALL, rule by rule — <c>windows_firewall_rule</c>.
///
/// <para>NOT CALLED `firewalld`, for the same reason `scheduled_task` is not called `cron`: firewalld has
/// zones and services, Windows has three profiles and a rule set, and the two models do not translate. The
/// Linux module keeps its name; the fleet's UI shows whichever the host has.</para>
///
/// <para>WHAT A RULE ACTUALLY IS, and why the read is two queries: `Get-NetFirewallRule` returns the rule
/// (name, direction, action, profiles, enabled) and NOT its ports — those live in a separate filter object,
/// as do the program, the addresses and the service. A "firewall rule" without its port is a row that cannot
/// answer the only question anybody asks of it ("is 8451 open?"), so the filters are fetched in bulk and
/// joined by InstanceID rather than per rule: measured on the test host, 400 rules × one filter query each is
/// minutes, and two bulk queries are about a second.</para>
///
/// <para>`enabled` AND `action` ARE DIFFERENT FACTS, and a row shows both: a disabled Allow rule and an
/// enabled Block rule both mean "not reachable", for different reasons and with different fixes. Same for the
/// PROFILES — a rule enabled only in the Domain profile is invisible to a host on a Public network, which is
/// the single most common reason a port that "has a rule" is closed.</para>
/// </summary>
public sealed class FirewallRuleModule : IModule
{
    public string Name => "windows_firewall_rule";

    public string Description =>
        "Windows firewall rules. Without `name`: list every rule with its direction, action, enabled state, "
        + "profiles and — joined from the separate filter objects — its ports, protocol, program and remote "
        + "addresses. With `name`: ensure a rule is present or absent and enabled or disabled — `direction` "
        + "(inbound/outbound), `action` (allow/block), `protocol`, `local_port`, `remote_address`, `program`, "
        + "`profile`. Idempotent: read and compared first; `dry_run: true` returns the plan. NOT `firewalld`: "
        + "zones and services do not translate to profiles and rules, so each platform keeps its own module.";

    private static readonly string[] Directions = ["inbound", "outbound"];
    private static readonly string[] Actions = ["allow", "block"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = P("string", "The rule's name (its DisplayName). Omit to LIST every rule."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the rule should exist. Default present.",
            },
            ["enabled"] = P("boolean", "Whether the rule applies. A DISABLED RULE STILL EXISTS — and a "
                                       + "disabled Allow rule blocks traffic just as an enabled Block rule "
                                       + "does, for a different reason."),
            ["direction"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = Directions,
                ["description"] = "inbound or outbound. Required when creating.",
            },
            ["action"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = Actions,
                ["description"] = "allow or block. Required when creating.",
            },
            ["protocol"] = P("string", "TCP, UDP, ICMPv4, or Any. Default TCP when a port is given."),
            ["local_port"] = P("string", "Port or ports: \"8451\", \"80,443\", \"8000-8100\", or Any."),
            ["remote_address"] = P("string", "Restrict to a remote address or CIDR, e.g. 10.32.0.0/16."),
            ["program"] = P("string", "Restrict to a program's full path."),
            ["profile"] = P("string", "Profiles the rule applies in: Domain, Private, Public, Any "
                                      + "(comma-separated). A RULE ENABLED ONLY IN Domain IS NOT IN EFFECT on "
                                      + "a host whose network is classified Public — the commonest reason a "
                                      + "port with a rule is still closed. Default Any."),
            ["description"] = P("string", "Free text shown in the firewall console."),
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "windows_firewall_rule manages the Windows firewall; on Linux the equivalent is the "
                + "`firewalld` module, whose zone/service model is different and keeps its own name.");
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
            if (current is null)
            {
                return new ModuleResult(false, $"firewall rule {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["existed"] = false });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove firewall rule {name}",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                $"Remove-NetFirewallRule -DisplayName {UserModule.Quote(name)} -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            if (await Read(name, ct) is not null)
            {
                throw new InvalidOperationException(
                    $"Remove-NetFirewallRule reported success but {name} still exists.");
            }
            return new ModuleResult(true, $"removed firewall rule {name}",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        return await EnsurePresent(name, parameters, current, dryRun, ct);
    }

    private static async Task<ModuleResult> ListAll(CancellationToken ct)
    {
        // TWO BULK QUERIES, JOINED BY InstanceID — not one query per rule. A rule's ports, program and
        // addresses live in separate filter objects, and asking per rule is a CIM round trip per rule: 400
        // rules that way is minutes. Fetched whole and indexed here instead.
        const string setup =
            "$ports = @{}; foreach ($f in Get-NetFirewallPortFilter) { $ports[$f.InstanceID] = $f }; "
            + "$apps = @{}; foreach ($f in Get-NetFirewallApplicationFilter) { $apps[$f.InstanceID] = $f }; "
            + "$addrs = @{}; foreach ($f in Get-NetFirewallAddressFilter) { $addrs[$f.InstanceID] = $f }; "
            + "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($r in Get-NetFirewallRule) { "
            + "  $p = $ports[$r.InstanceID]; $a = $apps[$r.InstanceID]; $ad = $addrs[$r.InstanceID]; "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = [string]$r.DisplayName; id = [string]$r.Name; "
            + "    enabled = [bool]$r.Enabled; direction = [string]$r.Direction; action = [string]$r.Action; "
            + "    profile = [string]$r.Profile; group = [string]$r.DisplayGroup; "
            + "    description = [string]$r.Description; "
            + "    protocol = if ($p) { [string]$p.Protocol } else { '' }; "
            + "    local_port = if ($p) { ([string[]]$p.LocalPort) -join ',' } else { '' }; "
            + "    remote_port = if ($p) { ([string[]]$p.RemotePort) -join ',' } else { '' }; "
            + "    program = if ($a) { [string]$a.Program } else { '' }; "
            + "    remote_address = if ($ad) { ([string[]]$ad.RemoteAddress) -join ',' } else { '' } }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(5), ct);

        var rows = new List<Dictionary<string, object?>>();
        foreach (var rule in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var enabled = rule.Bool("enabled");
            var action = rule.String("action").ToLowerInvariant();
            rows.Add(new Dictionary<string, object?>
            {
                ["name"] = rule.String("name"),
                ["id"] = rule.String("id"),
                ["enabled"] = enabled,
                ["direction"] = rule.String("direction").ToLowerInvariant(),
                ["action"] = action,
                ["profile"] = rule.String("profile"),
                ["group"] = rule.String("group"),
                ["protocol"] = rule.String("protocol"),
                ["local_port"] = rule.String("local_port"),
                ["remote_port"] = rule.String("remote_port"),
                ["program"] = rule.String("program"),
                ["remote_address"] = rule.String("remote_address"),
                // THE ANSWER TO THE QUESTION ACTUALLY BEING ASKED. "Is this rule letting traffic through" is
                // not `action` and not `enabled` but both together, and a reader who checks one of them is
                // the reader who reopens the ticket.
                ["effect"] = (enabled, action) switch
                {
                    (false, _) => "no effect — the rule exists but is disabled",
                    (true, "allow") => "allows",
                    (true, "block") => "blocks",
                    _ => $"enabled, action {action}",
                },
                ["description"] = rule.String("description"),
            });
        }

        rows.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"],
                                           StringComparison.OrdinalIgnoreCase));
        var active = rows.Count(r => r["enabled"] is true);
        var inbound = rows.Count(r => (string?)r["direction"] == "inbound" && r["enabled"] is true);
        return new ModuleResult(false,
            $"{rows.Count} firewall rule(s), {active} enabled ({inbound} of them inbound) — a rule's effect "
            + "is its action AND its enabled state AND its profiles together, which is why all three are in "
            + "every row",
            new Dictionary<string, object?> { ["rules"] = rows, ["count"] = rows.Count },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = rows.Count });
    }

    private static async Task<Dictionary<string, object?>?> Read(string name, CancellationToken ct)
    {
        var quoted = UserModule.Quote(name);
        var setup =
            "$out = @(); $r = Get-NetFirewallRule -DisplayName " + quoted + " -ErrorAction SilentlyContinue | "
            + "  Select-Object -First 1; "
            + "if ($r) { "
            + "  $p = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue; "
            + "  $a = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue; "
            + "  $ad = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue; "
            + "  $out = @([pscustomobject]@{ name = [string]$r.DisplayName; id = [string]$r.Name; "
            + "    enabled = [bool]$r.Enabled; direction = [string]$r.Direction; action = [string]$r.Action; "
            + "    profile = [string]$r.Profile; description = [string]$r.Description; "
            + "    protocol = if ($p) { [string]$p.Protocol } else { '' }; "
            + "    local_port = if ($p) { ([string[]]$p.LocalPort) -join ',' } else { '' }; "
            + "    program = if ($a) { [string]$a.Program } else { '' }; "
            + "    remote_address = if ($ad) { ([string[]]$ad.RemoteAddress) -join ',' } else { '' } }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return null;
        }
        return new Dictionary<string, object?>
        {
            ["name"] = found.String("name"),
            ["id"] = found.String("id"),
            ["enabled"] = found.Bool("enabled"),
            ["direction"] = found.String("direction").ToLowerInvariant(),
            ["action"] = found.String("action").ToLowerInvariant(),
            ["profile"] = found.String("profile"),
            ["protocol"] = found.String("protocol"),
            ["local_port"] = found.String("local_port"),
            ["program"] = found.String("program"),
            ["remote_address"] = found.String("remote_address"),
            ["description"] = found.String("description"),
        };
    }

    /// <summary>
    /// Do two address specifications mean the same thing? Compares each comma-separated entry with its
    /// IPv4 prefix length expanded to a dotted netmask, which is the form Windows stores — so "10.32.0.0/16"
    /// and "10.32.0.0/255.255.0.0" are one address, and anything this cannot parse falls back to a plain
    /// comparison rather than being declared equal on a guess.
    /// </summary>
    private static bool SameAddress(string? one, string? other)
    {
        static string Normalise(string value)
        {
            var parts = value.Split('/');
            if (parts.Length != 2 || !int.TryParse(parts[1], out var prefix) || prefix is < 0 or > 32)
            {
                return value.Trim();
            }
            // prefix → dotted mask, big-endian, which is how a netmask is written.
            var mask = prefix == 0 ? 0u : uint.MaxValue << (32 - prefix);
            return $"{parts[0].Trim()}/{mask >> 24 & 0xFF}.{mask >> 16 & 0xFF}.{mask >> 8 & 0xFF}.{mask & 0xFF}";
        }

        var left = (one ?? "").Split(',').Select(v => Normalise(v)).OrderBy(v => v, StringComparer.OrdinalIgnoreCase);
        var right = (other ?? "").Split(',').Select(v => Normalise(v)).OrderBy(v => v, StringComparer.OrdinalIgnoreCase);
        return left.SequenceEqual(right, StringComparer.OrdinalIgnoreCase);
    }

    private static async Task<ModuleResult> EnsurePresent(string name,
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current, bool dryRun,
        CancellationToken ct)
    {
        var direction = (parameters.GetValueOrDefault("direction") as string ?? "").ToLowerInvariant();
        var action = (parameters.GetValueOrDefault("action") as string ?? "").ToLowerInvariant();
        var protocol = parameters.GetValueOrDefault("protocol") as string;
        var localPort = parameters.GetValueOrDefault("local_port") as string;
        var remoteAddress = parameters.GetValueOrDefault("remote_address") as string;
        var program = parameters.GetValueOrDefault("program") as string;
        var profile = parameters.GetValueOrDefault("profile") as string ?? "Any";
        var description = parameters.GetValueOrDefault("description") as string;
        var enabled = parameters.GetValueOrDefault("enabled") as bool?;

        if (current is null)
        {
            var missing = new List<string>();
            if (direction.Length == 0) { missing.Add("direction"); }
            if (action.Length == 0) { missing.Add("action"); }
            if (missing.Count > 0)
            {
                throw new ArgumentException(
                    $"{string.Join(" and ", missing)}: required to create a firewall rule. direction is one of "
                    + $"{string.Join(", ", Directions)}, action one of {string.Join(", ", Actions)}. A rule "
                    + "without both would have to be guessed, and the wrong guess either opens a host or "
                    + "silently protects nothing.");
            }
            if (!Directions.Contains(direction)) { throw new ArgumentException($"direction: {direction} is not one of {string.Join(", ", Directions)}."); }
            if (!Actions.Contains(action)) { throw new ArgumentException($"action: {action} is not one of {string.Join(", ", Actions)}."); }
            if (string.IsNullOrWhiteSpace(localPort) && string.IsNullOrWhiteSpace(program))
            {
                // A rule matching everything is almost never the intent, and an accidental Allow-Any-inbound
                // is the worst outcome this module could produce. Named rather than created.
                throw new ArgumentException(
                    "local_port or program: at least one is required. A rule with neither matches ALL traffic "
                    + "in that direction, and an accidental allow-everything is not something this module will "
                    + "create by omission — pass local_port: \"Any\" explicitly if that is really the intent.");
            }
        }

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();

        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, $"{name} ({direction} {action} {localPort ?? program})" };
        }
        else
        {
            void Compare(string key, string? want, object? have)
            {
                if (string.IsNullOrWhiteSpace(want)) { return; }
                if (string.Equals(want, (string?)have, StringComparison.OrdinalIgnoreCase)) { return; }
                // ADDRESSES ARE COMPARED NORMALISED. Measured on the host: a rule declared with
                // `10.32.0.0/16` is STORED by Windows as `10.32.0.0/255.255.0.0`, so the plain string
                // comparison found a difference on every single run — the second identical call reported
                // "updated: remote_address" and would have rewritten that rule forever. An idempotence check
                // that never converges is worse than none: it hides the real changes in noise.
                if (key == "remote_address" && SameAddress(want, (string?)have)) { return; }
                steps.Add(key);
                changes[key] = new object?[] { have, want };
            }
            Compare("direction", direction, current["direction"]);
            Compare("action", action, current["action"]);
            Compare("local_port", localPort, current["local_port"]);
            Compare("protocol", protocol, current["protocol"]);
            Compare("remote_address", remoteAddress, current["remote_address"]);
            Compare("program", program, current["program"]);
            if (enabled is not null && current["enabled"] is bool isEnabled && isEnabled != enabled)
            {
                steps.Add("enabled");
                changes["enabled"] = new object?[] { isEnabled, enabled };
            }
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"firewall rule {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "present", ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} firewall rule {name}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                {
                    ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = new List<string>();
        if (current is null)
        {
            var create = $"New-NetFirewallRule -DisplayName {UserModule.Quote(name)} "
                         + $"-Direction {(direction == "inbound" ? "Inbound" : "Outbound")} "
                         + $"-Action {(action == "allow" ? "Allow" : "Block")} "
                         + $"-Profile {UserModule.Quote(profile)} -ErrorAction Stop";
            if (!string.IsNullOrWhiteSpace(localPort))
            {
                // TCP by default when a port is given, because a port without a protocol is not a rule
                // Windows can make — and stating the default beats letting the cmdlet pick.
                create += $" -Protocol {UserModule.Quote(protocol ?? "TCP")} "
                          + $"-LocalPort {UserModule.Quote(localPort)}";
            }
            else if (!string.IsNullOrWhiteSpace(protocol))
            {
                create += $" -Protocol {UserModule.Quote(protocol)}";
            }
            if (!string.IsNullOrWhiteSpace(program)) { create += $" -Program {UserModule.Quote(program)}"; }
            if (!string.IsNullOrWhiteSpace(remoteAddress)) { create += $" -RemoteAddress {UserModule.Quote(remoteAddress)}"; }
            if (!string.IsNullOrWhiteSpace(description)) { create += $" -Description {UserModule.Quote(description)}"; }
            if (enabled is false) { create += " -Enabled False"; }
            script.Add(create + " | Out-Null");
        }
        else
        {
            var set = new List<string>();
            if (changes.ContainsKey("direction")) { set.Add($"-Direction {(direction == "inbound" ? "Inbound" : "Outbound")}"); }
            if (changes.ContainsKey("action")) { set.Add($"-Action {(action == "allow" ? "Allow" : "Block")}"); }
            if (changes.ContainsKey("local_port")) { set.Add($"-LocalPort {UserModule.Quote(localPort!)}"); }
            if (changes.ContainsKey("protocol")) { set.Add($"-Protocol {UserModule.Quote(protocol!)}"); }
            if (changes.ContainsKey("remote_address")) { set.Add($"-RemoteAddress {UserModule.Quote(remoteAddress!)}"); }
            if (changes.ContainsKey("program")) { set.Add($"-Program {UserModule.Quote(program!)}"); }
            if (changes.ContainsKey("enabled")) { set.Add($"-Enabled {(enabled is true ? "True" : "False")}"); }
            if (set.Count > 0)
            {
                script.Add($"Set-NetFirewallRule -DisplayName {UserModule.Quote(name)} "
                           + string.Join(" ", set) + " -ErrorAction Stop");
            }
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);

        var after = await Read(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the firewall operations reported success but rule {name} does not exist afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} firewall rule {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }
}
