using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// THE WINDOWS DHCP SERVER — <c>windows_dhcp</c>: its scopes, their utilisation, leases and reservations.
///
/// <para>THE ONE MODULE HERE THAT HANDS OUT ADDRESSES TO STRANGERS, and the design follows from that. A DHCP
/// server with an active scope answers broadcasts from every machine on its segment; a wrong scope does not
/// fail loudly on this host, it breaks OTHER hosts. So:</para>
/// <list type="bullet">
/// <item>a new scope is created INACTIVE unless `state: active` is stated explicitly — the safe half of the
/// decision is the default, and activating is a separate word the caller has to say;</item>
/// <item>every read reports whether this server is AUTHORIZED in Active Directory, because an unauthorized
/// server on a domain network stops answering by design while an unauthorized server on a workgroup network
/// answers happily — the same flag means opposite things, so the read says which case this host is;</item>
/// <item>a scope's utilisation is reported as free/in-use counts rather than a percentage, since "94% used"
/// and "3 addresses left" are the same fact and only one of them tells you what happens next.</item>
/// </list>
///
/// <para>WHAT IT DOES NOT DO: failover relationships, policies, superscopes, and vendor classes. Named rather
/// than approximated — each is a model of its own, and a half-supported failover relationship is worse than
/// none.</para>
/// </summary>
public sealed class DhcpServerModule : IModule
{
    public string Name => "windows_dhcp";

    public string Description =>
        "The Windows DHCP server. No arguments: whether it is authorized, its scopes with range, mask, state, "
        + "lease duration and how many addresses are free, plus the server-level options. `scope` alone: that "
        + "scope's leases and reservations. Writes: `object: scope` (create/remove/activate/deactivate a "
        + "scope) or `object: reservation` (pin an address to a MAC). A NEW SCOPE IS CREATED INACTIVE unless "
        + "state: active is stated — a DHCP scope answers every machine on its segment, so activating is a "
        + "separate decision. Idempotent; `dry_run: true` returns the plan. Failover, policies, superscopes "
        + "and vendor classes are not managed here.";

    private static readonly string[] Objects = ["scope", "reservation"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["object"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = Objects,
                ["description"] = "What a write targets: scope or reservation.",
            },
            ["scope"] = P("string", "The scope id (its network address, e.g. 10.32.28.0). Alone it READS that "
                                    + "scope's leases and reservations."),
            ["start_range"] = P("string", "First address the scope hands out. Required when creating."),
            ["end_range"] = P("string", "Last address the scope hands out. Required when creating."),
            ["subnet_mask"] = P("string", "The scope's mask, e.g. 255.255.255.0. Required when creating."),
            ["scope_name"] = P("string", "A human name for the scope."),
            ["lease_duration_hours"] = P("number", "Lease duration in hours. Default 8."),
            ["router"] = P("string", "The default gateway handed to clients (option 3)."),
            ["dns_servers"] = new Dictionary<string, object>
            {
                ["type"] = "array",
                ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "DNS servers handed to clients (option 6).",
            },
            ["ip_address"] = P("string", "For a reservation: the address to pin."),
            ["mac_address"] = P("string", "For a reservation: the client's MAC, e.g. 00-15-5d-01-02-03."),
            ["client_name"] = P("string", "For a reservation: a name for the reserved client."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent", "active", "inactive" },
                ["description"] = "present creates the scope INACTIVE (it hands out nothing); active makes it "
                                  + "answer; inactive stops it answering without deleting it; absent removes "
                                  + "it with its leases.",
            },
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    private const string Import =
        "if (-not (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) { "
        + "throw 'the DhcpServer PowerShell module is not present: the DHCP role is installed without its "
        + "management tools on this host (install RSAT-DHCP), so it cannot be managed from here.' }; ";

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "windows_dhcp manages the Windows DHCP server; isc-dhcp or kea on Linux is a config file and "
                + "belongs to the config plane.");
        }

        var scope = (parameters.GetValueOrDefault("scope") as string ?? "").Trim();
        var target = (parameters.GetValueOrDefault("object") as string ?? "").ToLowerInvariant();
        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;

        if (target.Length == 0)
        {
            return scope.Length == 0 ? await ReadServer(ct) : await ReadScope(scope, ct);
        }
        if (!Objects.Contains(target))
        {
            throw new ArgumentException($"object: {target} is not one of {string.Join(", ", Objects)}.");
        }
        if (scope.Length == 0)
        {
            throw new ArgumentException("scope: required for any write — both a scope and a reservation live "
                                        + "inside one.");
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent" or "active" or "inactive"))
        {
            throw new ArgumentException(
                $"state: {state} is not one of present, absent, active, inactive.");
        }

        return target == "scope"
            ? await EnsureScope(scope, state, parameters, dryRun, ct)
            : await EnsureReservation(scope, state, parameters, dryRun, ct);
    }

    private static async Task<ModuleResult> ReadServer(CancellationToken ct)
    {
        const string setup = Import
            // AUTHORIZATION FIRST, because it decides whether anything below matters. Get-DhcpServerInDC needs
            // a domain; on a workgroup host it fails, and that failure is itself the answer — an unauthorized
            // server on a workgroup network serves anyway.
            + "$authorized = $null; $authError = ''; "
            + "try { $me = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName; "
            + "  $authorized = @(Get-DhcpServerInDC -ErrorAction Stop | "
            + "    Where-Object { $_.DnsName -eq $me }).Count -gt 0 } "
            + "catch { $authError = $_.Exception.Message }; "
            + "$scopes = New-Object System.Collections.ArrayList; "
            + "foreach ($s in Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) { "
            + "  $stats = $null; try { $stats = Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId "
            + "    -ErrorAction Stop } catch { }; "
            + "  $opts = @(); try { $opts = @(Get-DhcpServerv4OptionValue -ScopeId $s.ScopeId "
            + "    -ErrorAction Stop | ForEach-Object { [string]$_.OptionId + '=' + (($_.Value) -join ',') }) } catch { }; "
            + "  [void]$scopes.Add([pscustomobject]@{ id = [string]$s.ScopeId; name = [string]$s.Name; "
            + "    state = [string]$s.State; start = [string]$s.StartRange; end = [string]$s.EndRange; "
            + "    mask = [string]$s.SubnetMask; lease_hours = [int64]$s.LeaseDuration.TotalHours; "
            + "    free = if ($stats) { [int64]$stats.Free } else { $null }; "
            + "    in_use = if ($stats) { [int64]$stats.InUse } else { $null }; "
            + "    reserved = if ($stats) { [int64]$stats.Reserved } else { $null }; "
            + "    options = $opts }) }; "
            + "$serverOptions = @(); try { $serverOptions = @(Get-DhcpServerv4OptionValue -ErrorAction Stop | "
            + "  ForEach-Object { [string]$_.OptionId + '=' + (($_.Value) -join ',') }) } catch { }";
        var answer = await WindowsPowerShellBridge.RunJson(
            setup,
            "[pscustomobject]@{ authorized = $authorized; auth_error = $authError; scopes = @($scopes); "
            + "server_options = @($serverOptions) }",
            TimeSpan.FromMinutes(3), ct);

        var root = answer.Items.FirstOrDefault();
        var scopes = new List<Dictionary<string, object?>>();
        if (root.ValueKind == System.Text.Json.JsonValueKind.Object
            && root.TryGetProperty("scopes", out var scopeArray))
        {
            foreach (var scope in scopeArray.EnumerateArrayOrEmpty())
            {
                var state = scope.String("state").ToLowerInvariant();
                var free = scope.Long("free");
                var inUse = scope.Long("in_use");
                scopes.Add(new Dictionary<string, object?>
                {
                    ["id"] = scope.String("id"),
                    ["name"] = scope.String("name"),
                    ["state"] = state,
                    ["start_range"] = scope.String("start"),
                    ["end_range"] = scope.String("end"),
                    ["subnet_mask"] = scope.String("mask"),
                    ["lease_hours"] = scope.Long("lease_hours"),
                    ["free"] = free,
                    ["in_use"] = inUse,
                    ["reserved"] = scope.Long("reserved"),
                    // COUNTS, and the sentence an operator needs. "94% used" and "3 left" are the same fact
                    // and only the second says what happens at the next boot storm.
                    ["capacity_note"] = free is null
                        ? "utilisation could not be read"
                        : $"{free} address(es) free, {inUse} in use"
                          + (free == 0 ? " — the next client to ask gets nothing" : ""),
                    ["answers"] = state == "active"
                        ? "yes — this scope answers clients on its segment"
                        : "no — the scope exists but is inactive, so it hands out nothing",
                    ["options"] = scope.StringArray("options"),
                });
            }
        }

        var authorized = root.ValueKind == System.Text.Json.JsonValueKind.Object
                         && root.TryGetProperty("authorized", out var auth)
                         && auth.ValueKind == System.Text.Json.JsonValueKind.True;
        var authError = root.String("auth_error");
        var active = scopes.Count(s => (string?)s["state"] == "active");

        return new ModuleResult(false,
            $"{scopes.Count} scope(s), {active} active; "
            + (authError.Length > 0
                ? "authorization could not be checked (no domain to ask), and an unauthorized DHCP server on "
                  + "a workgroup network still answers"
                : authorized
                    ? "this server is authorized in Active Directory"
                    : "this server is NOT authorized in Active Directory and will refuse to answer on a "
                      + "domain network"),
            new Dictionary<string, object?>
            {
                ["authorized"] = authError.Length > 0 ? null : authorized,
                // THE SAME FLAG MEANS OPPOSITE THINGS on a domain and on a workgroup host, so the reading is
                // spelled out rather than left to the reader.
                ["authorization_note"] = authError.Length > 0
                    ? "could not be determined: " + authError + " — on a host with no domain this is expected, "
                      + "and such a server answers clients regardless of authorization"
                    : authorized
                        ? "authorized in AD"
                        : "not authorized in AD; on a domain network the service refuses to serve, on a "
                          + "workgroup network it serves anyway",
                ["scopes"] = scopes,
                ["server_options"] = root.StringArray("server_options"),
                ["not_managed_here"] = "failover relationships, policies, superscopes and vendor classes",
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = scopes.Count });
    }

    private static async Task<ModuleResult> ReadScope(string scope, CancellationToken ct)
    {
        var setup = Import
            + "$leases = @(); try { $leases = @(Get-DhcpServerv4Lease -ScopeId " + UserModule.Quote(scope)
            + " -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; "
            + "  mac = [string]$_.ClientId; name = [string]$_.HostName; state = [string]$_.AddressState; "
            + "  expires = if ($_.LeaseExpiryTime) { $_.LeaseExpiryTime.ToString('o') } else { '' } } }) } catch { }; "
            + "$res = @(); try { $res = @(Get-DhcpServerv4Reservation -ScopeId " + UserModule.Quote(scope)
            + " -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; "
            + "  mac = [string]$_.ClientId; name = [string]$_.Name } }) } catch { }";
        var answer = await WindowsPowerShellBridge.RunJson(
            setup, "[pscustomobject]@{ leases = @($leases); reservations = @($res) }",
            TimeSpan.FromMinutes(3), ct);

        var root = answer.Items.FirstOrDefault();
        var leases = new List<Dictionary<string, object?>>();
        if (root.TryGetProperty("leases", out var leaseArray))
        {
            foreach (var lease in leaseArray.EnumerateArrayOrEmpty())
            {
                leases.Add(new Dictionary<string, object?>
                {
                    ["ip"] = lease.String("ip"),
                    ["mac"] = lease.String("mac"),
                    ["client_name"] = lease.String("name"),
                    // Windows' own word — Active, Declined, Expired, ActiveReservation. Passed through: a
                    // declined address is a duplicate-IP report from a client, which is a fact worth seeing.
                    ["state"] = lease.String("state"),
                    ["expires"] = lease.String("expires"),
                });
            }
        }
        var reservations = new List<Dictionary<string, object?>>();
        if (root.TryGetProperty("reservations", out var resArray))
        {
            foreach (var reservation in resArray.EnumerateArrayOrEmpty())
            {
                reservations.Add(new Dictionary<string, object?>
                {
                    ["ip"] = reservation.String("ip"),
                    ["mac"] = reservation.String("mac"),
                    ["client_name"] = reservation.String("name"),
                });
            }
        }

        return new ModuleResult(false,
            $"{leases.Count} lease(s) and {reservations.Count} reservation(s) in scope {scope}",
            new Dictionary<string, object?>
            {
                ["scope"] = scope, ["leases"] = leases, ["reservations"] = reservations,
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = leases.Count + reservations.Count });
    }

    private static async Task<Dictionary<string, object?>?> ReadOneScope(string scope, CancellationToken ct)
    {
        var setup = Import
            + "$out = @(); $s = Get-DhcpServerv4Scope -ScopeId " + UserModule.Quote(scope)
            + " -ErrorAction SilentlyContinue; "
            + "if ($s) { $out = @([pscustomobject]@{ id = [string]$s.ScopeId; name = [string]$s.Name; "
            + "  state = [string]$s.State; start = [string]$s.StartRange; end = [string]$s.EndRange; "
            + "  mask = [string]$s.SubnetMask; lease_hours = [int64]$s.LeaseDuration.TotalHours }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        return found.ValueKind != System.Text.Json.JsonValueKind.Object
            ? null
            : new Dictionary<string, object?>
            {
                ["id"] = found.String("id"),
                ["name"] = found.String("name"),
                ["state"] = found.String("state").ToLowerInvariant(),
                ["start_range"] = found.String("start"),
                ["end_range"] = found.String("end"),
                ["subnet_mask"] = found.String("mask"),
                ["lease_hours"] = found.Long("lease_hours"),
            };
    }

    private static async Task<ModuleResult> EnsureScope(string scope, string state,
        IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var current = await ReadOneScope(scope, ct);
        var start = parameters.GetValueOrDefault("start_range") as string;
        var end = parameters.GetValueOrDefault("end_range") as string;
        var mask = parameters.GetValueOrDefault("subnet_mask") as string;
        var scopeName = parameters.GetValueOrDefault("scope_name") as string ?? scope;
        var leaseHours = (int)(parameters.GetValueOrDefault("lease_duration_hours") as double? ?? 8);
        var router = parameters.GetValueOrDefault("router") as string;
        var dnsServers = UserModule.AsStringList(parameters.GetValueOrDefault("dns_servers"));

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"DHCP scope {scope} is already absent",
                    new Dictionary<string, object?> { ["scope"] = scope, ["state"] = "absent" });
            }
            if (dryRun)
            {
                return new ModuleResult(true,
                    $"would remove DHCP scope {scope} ({current["start_range"]}–{current["end_range"]}) WITH "
                    + "its leases and reservations — every client holding one keeps its address until the "
                    + "lease expires and then gets nothing",
                    new Dictionary<string, object?> { ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-DhcpServerv4Scope -ScopeId {UserModule.Quote(scope)} -Force -ErrorAction Stop",
                "@()", TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed DHCP scope {scope} with its leases and reservations",
                new Dictionary<string, object?> { ["scope"] = scope, ["state"] = "absent", ["before"] = current });
        }

        if (current is null)
        {
            var missing = new List<string>();
            if (string.IsNullOrWhiteSpace(start)) { missing.Add("start_range"); }
            if (string.IsNullOrWhiteSpace(end)) { missing.Add("end_range"); }
            if (string.IsNullOrWhiteSpace(mask)) { missing.Add("subnet_mask"); }
            if (missing.Count > 0)
            {
                throw new ArgumentException(
                    $"{string.Join(", ", missing)}: required to create a DHCP scope. A range and a mask cannot "
                    + "be guessed — a wrong one does not fail on this host, it hands wrong addresses to other "
                    + "people's machines.");
            }
        }

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();
        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, $"{scope} {start}–{end}/{mask}" };
        }
        else
        {
            void Compare(string key, string? want, object? have)
            {
                if (string.IsNullOrWhiteSpace(want) || string.Equals(want, (string?)have,
                                                                     StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
                steps.Add(key);
                changes[key] = new object?[] { have, want };
            }
            Compare("start_range", start, current["start_range"]);
            Compare("end_range", end, current["end_range"]);
            Compare("subnet_mask", mask, current["subnet_mask"]);
        }

        var wantedActive = state switch { "active" => true, "inactive" => false, _ => (bool?)null };
        var isActive = current is not null && (string?)current["state"] == "active";
        if (wantedActive is not null && isActive != wantedActive)
        {
            steps.Add(wantedActive is true ? "activate" : "deactivate");
            changes["state"] = new object?[] { current?["state"] ?? "(absent)", state };
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"DHCP scope {scope} is already as declared",
                new Dictionary<string, object?> { ["scope"] = scope, ["current"] = current });
        }
        if (dryRun)
        {
            var note = current is null && wantedActive is not true
                ? " — and it would be created INACTIVE: `state: active` is the word that makes a scope answer "
                  + "clients, and it is not implied by creating one"
                : "";
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} DHCP scope {scope}: "
                + string.Join(", ", steps) + note,
                new Dictionary<string, object?>
                { ["scope"] = scope, ["plan"] = steps, ["changes"] = changes, ["before"] = current });
        }

        var script = new List<string> { Import.TrimEnd(' ', ';') };
        if (current is null)
        {
            // INACTIVE BY DEFAULT. The one place in this whole agent where the default is chosen because the
            // other option affects machines that are not this one.
            script.Add($"Add-DhcpServerv4Scope -Name {UserModule.Quote(scopeName)} "
                       + $"-StartRange {UserModule.Quote(start!)} -EndRange {UserModule.Quote(end!)} "
                       + $"-SubnetMask {UserModule.Quote(mask!)} "
                       + $"-LeaseDuration (New-TimeSpan -Hours {leaseHours}) "
                       + $"-State {(wantedActive is true ? "Active" : "Inactive")} -ErrorAction Stop");
        }
        else
        {
            var set = new List<string>();
            if (changes.ContainsKey("start_range") || changes.ContainsKey("end_range"))
            {
                set.Add($"-StartRange {UserModule.Quote(start ?? (string)current["start_range"]!)} "
                        + $"-EndRange {UserModule.Quote(end ?? (string)current["end_range"]!)}");
            }
            if (wantedActive is not null && changes.ContainsKey("state"))
            {
                set.Add($"-State {(wantedActive is true ? "Active" : "Inactive")}");
            }
            if (set.Count > 0)
            {
                script.Add($"Set-DhcpServerv4Scope -ScopeId {UserModule.Quote(scope)} "
                           + string.Join(" ", set) + " -ErrorAction Stop");
            }
        }
        if (!string.IsNullOrWhiteSpace(router))
        {
            script.Add($"Set-DhcpServerv4OptionValue -ScopeId {UserModule.Quote(scope)} "
                       + $"-Router {UserModule.Quote(router)} -ErrorAction Stop");
        }
        if (dnsServers.Count > 0)
        {
            script.Add($"Set-DhcpServerv4OptionValue -ScopeId {UserModule.Quote(scope)} -DnsServer "
                       + $"@({string.Join(",", dnsServers.Select(UserModule.Quote))}) -ErrorAction Stop");
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);
        var after = await ReadOneScope(scope, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the DHCP operations reported success but scope {scope} does not exist afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} DHCP scope {scope}: {string.Join(", ", steps)} "
            + $"— it is now {after["state"]}",
            new Dictionary<string, object?>
            {
                ["scope"] = scope, ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    private static async Task<ModuleResult> EnsureReservation(string scope, string state,
        IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var ip = (parameters.GetValueOrDefault("ip_address") as string ?? "").Trim();
        var mac = (parameters.GetValueOrDefault("mac_address") as string ?? "").Trim();
        var clientName = parameters.GetValueOrDefault("client_name") as string;

        if (ip.Length == 0)
        {
            throw new ArgumentException("ip_address: required — a reservation is an address pinned to a client.");
        }
        if (state == "present" && mac.Length == 0)
        {
            throw new ArgumentException("mac_address: required to create a reservation — it is the client the "
                                        + "address is pinned to.");
        }

        var setup = Import
            + "$out = @(); $r = Get-DhcpServerv4Reservation -ScopeId " + UserModule.Quote(scope)
            + " -IPAddress " + UserModule.Quote(ip) + " -ErrorAction SilentlyContinue; "
            + "if ($r) { $out = @([pscustomobject]@{ ip = [string]$r.IPAddress; mac = [string]$r.ClientId; "
            + "  name = [string]$r.Name }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        var current = found.ValueKind == System.Text.Json.JsonValueKind.Object
            ? new Dictionary<string, object?>
            {
                ["ip"] = found.String("ip"), ["mac"] = found.String("mac"), ["client_name"] = found.String("name"),
            }
            : null;

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"reservation for {ip} in {scope} is already absent",
                    new Dictionary<string, object?> { ["scope"] = scope, ["ip"] = ip });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove the reservation {ip} → {current["mac"]}",
                    new Dictionary<string, object?> { ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-DhcpServerv4Reservation -ScopeId {UserModule.Quote(scope)} "
                       + $"-IPAddress {UserModule.Quote(ip)} -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed the reservation for {ip}",
                new Dictionary<string, object?> { ["scope"] = scope, ["ip"] = ip, ["before"] = current });
        }

        // MACs compare without their separators: 00-15-5d-01-02-03, 00155d010203 and 00:15:5d:01:02:03 are one
        // client, and a comparison that missed that would re-write the same reservation on every run.
        static string Bare(string value) => new(value.Where(char.IsLetterOrDigit).ToArray());
        if (current is not null && string.Equals(Bare((string?)current["mac"] ?? ""), Bare(mac),
                                                 StringComparison.OrdinalIgnoreCase))
        {
            return new ModuleResult(false, $"{ip} is already reserved for {current["mac"]}",
                new Dictionary<string, object?> { ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                current is null ? $"would reserve {ip} for {mac}"
                                : $"would move the reservation for {ip} from {current["mac"]} to {mac}",
                new Dictionary<string, object?> { ["plan"] = current is null ? "create" : "update",
                                                 ["before"] = current });
        }

        var script = new List<string> { Import.TrimEnd(' ', ';') };
        if (current is not null)
        {
            script.Add($"Remove-DhcpServerv4Reservation -ScopeId {UserModule.Quote(scope)} "
                       + $"-IPAddress {UserModule.Quote(ip)} -ErrorAction Stop");
        }
        var add = $"Add-DhcpServerv4Reservation -ScopeId {UserModule.Quote(scope)} "
                  + $"-IPAddress {UserModule.Quote(ip)} -ClientId {UserModule.Quote(mac)} -ErrorAction Stop";
        if (!string.IsNullOrWhiteSpace(clientName)) { add += $" -Name {UserModule.Quote(clientName)}"; }
        script.Add(add);

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);
        return new ModuleResult(true,
            current is null ? $"reserved {ip} for {mac}" : $"moved the reservation for {ip} to {mac}",
            new Dictionary<string, object?>
            { ["scope"] = scope, ["ip"] = ip, ["mac"] = mac, ["before"] = current });
    }
}
