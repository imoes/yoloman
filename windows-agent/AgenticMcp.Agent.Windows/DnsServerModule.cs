using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// THE WINDOWS DNS SERVER — <c>windows_dns</c>: its zones and the records in them.
///
/// <para>TWO LEVELS, ONE MODULE, for the same reason IIS keeps sites and pools together: a record without its
/// zone is not addressable, and "does this name resolve here" spans both. A read with no arguments returns
/// every zone; a read with `zone` returns that zone's records; a write targets a zone or a record.</para>
///
/// <para>THIS IS THE SERVER'S OWN DATA, not what the host resolves. A DNS server can host a zone for
/// example.com and still resolve example.com through a forwarder, so a reader must not take a zone here as
/// "what this machine believes". The zone rows say where each zone's data lives (`zone_type`: primary,
/// secondary, forwarder, stub) and whether it is AD-integrated, because those decide who may change it — a
/// secondary zone is read-only by definition and a write to it is refused with that reason rather than
/// attempted.</para>
///
/// <para>DELETING A ZONE IS NOT DELETING A RECORD. Removing a primary zone drops every name in it at once,
/// which is why removal is a separate declaration on the zone and never a side effect of changing records.</para>
/// </summary>
public sealed class DnsServerModule : IModule
{
    public string Name => "windows_dns";

    public string Description =>
        "The Windows DNS server's zones and records. No arguments: every zone with its type, whether it is "
        + "AD-integrated or read-only, and how many records it holds. `zone` alone: that zone's records. "
        + "`object: zone` + `zone` + `state`: create or remove a primary zone. `object: record` + `zone` + "
        + "`name` + `type` + `value`: ensure a record (A, AAAA, CNAME, TXT, MX, PTR) exists or does not. "
        + "Idempotent; `dry_run: true` returns the plan. A secondary or stub zone is read-only and a write to "
        + "one is refused with that reason. This is the SERVER's data, not what this host resolves.";

    private static readonly string[] Objects = ["zone", "record"];
    private static readonly string[] RecordTypes = ["A", "AAAA", "CNAME", "TXT", "MX", "PTR"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["object"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = Objects,
                ["description"] = "What a write targets: zone or record.",
            },
            ["zone"] = P("string", "The zone name, e.g. example.com. Alone (without `object`) it READS that "
                                   + "zone's records."),
            ["name"] = P("string", "For a record: the name inside the zone (\"www\", or \"@\" for the zone "
                                   + "itself)."),
            ["type"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = RecordTypes,
                ["description"] = "The record type. Required for a record write.",
            },
            ["value"] = P("string", "The record's data: an address for A/AAAA, a target for CNAME/MX/PTR, the "
                                    + "text for TXT."),
            ["ttl_seconds"] = P("number", "Time to live. Default 3600."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the zone or record should exist. Default present.",
            },
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    private const string Import =
        "if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) { "
        + "throw 'the DnsServer PowerShell module is not present: the DNS role is installed without its "
        + "management tools on this host (install RSAT-DNS-Server), so it cannot be managed from here.' }; ";

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "windows_dns manages the Windows DNS server; a BIND or dnsmasq zone on Linux is a config file "
                + "and belongs to the config plane.");
        }

        var zone = (parameters.GetValueOrDefault("zone") as string ?? "").Trim();
        var target = (parameters.GetValueOrDefault("object") as string ?? "").ToLowerInvariant();
        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;

        if (target.Length == 0)
        {
            // A read, and which read depends on whether a zone was named. No `object` means nothing is being
            // written, which is the safest reading of an incomplete request.
            return zone.Length == 0 ? await ListZones(ct) : await ListRecords(zone, ct);
        }
        if (!Objects.Contains(target))
        {
            throw new ArgumentException($"object: {target} is not one of {string.Join(", ", Objects)}.");
        }
        if (zone.Length == 0)
        {
            throw new ArgumentException("zone: required for any write — a record has no address without it.");
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent"))
        {
            throw new ArgumentException($"state: {state} is not one of present, absent.");
        }

        return target == "zone"
            ? await EnsureZone(zone, state, dryRun, ct)
            : await EnsureRecord(zone, state, parameters, dryRun, ct);
    }

    private static async Task<ModuleResult> ListZones(CancellationToken ct)
    {
        const string setup = Import
            + "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($z in Get-DnsServerZone) { "
            + "  $count = -1; try { $count = @(Get-DnsServerResourceRecord -ZoneName $z.ZoneName "
            + "    -ErrorAction Stop).Count } catch { }; "
            + "  [void]$out.Add([pscustomobject]@{ name = [string]$z.ZoneName; type = [string]$z.ZoneType; "
            + "    ad_integrated = [bool]$z.IsDsIntegrated; reverse = [bool]$z.IsReverseLookupZone; "
            + "    read_only = [bool]$z.IsReadOnly; paused = [bool]$z.IsPaused; shutdown = [bool]$z.IsShutdown; "
            + "    dynamic_update = [string]$z.DynamicUpdate; file = [string]$z.ZoneFile; "
            + "    record_count = $count }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(3), ct);

        var rows = new List<Dictionary<string, object?>>();
        foreach (var zone in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var type = zone.String("type").ToLowerInvariant();
            var count = zone.Long("record_count");
            rows.Add(new Dictionary<string, object?>
            {
                ["name"] = zone.String("name"),
                ["zone_type"] = type,
                ["ad_integrated"] = zone.Bool("ad_integrated"),
                ["reverse"] = zone.Bool("reverse"),
                // WHO MAY CHANGE IT, which is not one flag: a secondary zone is read-only because its data
                // comes from elsewhere, and a paused zone is writable but answers nothing.
                ["writable"] = type == "primary" && !zone.Bool("read_only"),
                ["writable_reason"] = (type, zone.Bool("read_only")) switch
                {
                    ("primary", false) => "primary and writable here",
                    ("primary", true) => "primary but marked read-only on this server",
                    ("secondary", _) => "secondary — its data is transferred from the master, so it cannot be "
                                        + "edited here",
                    ("stub", _) => "stub — it holds only the master's name servers",
                    ("forwarder", _) => "conditional forwarder — it holds no records, it points elsewhere",
                    _ => $"zone type {type}",
                },
                ["paused"] = zone.Bool("paused"),
                ["dynamic_update"] = zone.String("dynamic_update"),
                ["file"] = zone.String("file"),
                // -1 means the count could not be read, which is not the same as an empty zone.
                ["record_count"] = count is null or < 0 ? null : count,
                ["record_count_note"] = count is null or < 0 ? "could not be read" : null,
            });
        }

        rows.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"], StringComparison.OrdinalIgnoreCase));
        var writable = rows.Count(r => r["writable"] is true);
        return new ModuleResult(false,
            $"{rows.Count} DNS zone(s), {writable} writable on this server — this is the SERVER's own data, "
            + "not what this host resolves",
            new Dictionary<string, object?> { ["zones"] = rows, ["count"] = rows.Count },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = rows.Count });
    }

    private static async Task<ModuleResult> ListRecords(string zone, CancellationToken ct)
    {
        var setup = Import
            + "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($r in Get-DnsServerResourceRecord -ZoneName " + UserModule.Quote(zone)
            + " -ErrorAction Stop) { "
            + "  $data = ''; "
            + "  if ($r.RecordData.IPv4Address) { $data = [string]$r.RecordData.IPv4Address } "
            + "  elseif ($r.RecordData.IPv6Address) { $data = [string]$r.RecordData.IPv6Address } "
            + "  elseif ($r.RecordData.HostNameAlias) { $data = [string]$r.RecordData.HostNameAlias } "
            + "  elseif ($r.RecordData.NameServer) { $data = [string]$r.RecordData.NameServer } "
            + "  elseif ($r.RecordData.MailExchange) { $data = [string]$r.RecordData.MailExchange } "
            + "  elseif ($r.RecordData.PtrDomainName) { $data = [string]$r.RecordData.PtrDomainName } "
            + "  elseif ($r.RecordData.DescriptiveText) { $data = [string]$r.RecordData.DescriptiveText } "
            + "  elseif ($r.RecordData.PrimaryServer) { $data = [string]$r.RecordData.PrimaryServer } "
            + "  else { $data = [string]$r.RecordData }; "
            + "  [void]$out.Add([pscustomobject]@{ name = [string]$r.HostName; type = [string]$r.RecordType; "
            + "    data = $data; ttl = [int64]$r.TimeToLive.TotalSeconds; "
            + "    timestamp = if ($r.Timestamp) { $r.Timestamp.ToString('o') } else { '' } }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(3), ct);

        var rows = new List<Dictionary<string, object?>>();
        foreach (var record in answer.Items)
        {
            rows.Add(new Dictionary<string, object?>
            {
                ["zone"] = zone,
                ["name"] = record.String("name"),
                ["type"] = record.String("type"),
                ["value"] = record.String("data"),
                ["ttl_seconds"] = record.Long("ttl"),
                // A timestamp means the record was registered DYNAMICALLY (by a client, over DDNS); a static
                // record has none. That distinction decides whether editing it by hand will survive.
                ["dynamic"] = record.String("timestamp").Length > 0,
                ["registered_at"] = record.String("timestamp") is { Length: > 0 } stamp ? stamp : null,
            });
        }

        rows.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"], StringComparison.OrdinalIgnoreCase));
        var dynamicCount = rows.Count(r => r["dynamic"] is true);
        return new ModuleResult(false,
            $"{rows.Count} record(s) in {zone}, {dynamicCount} of them registered dynamically (a dynamic "
            + "record is re-registered by its client, so editing it by hand does not last)",
            new Dictionary<string, object?> { ["zone"] = zone, ["records"] = rows, ["count"] = rows.Count },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = rows.Count });
    }

    private static async Task<Dictionary<string, object?>?> ReadZone(string zone, CancellationToken ct)
    {
        var setup = Import
            + "$out = @(); $z = Get-DnsServerZone -Name " + UserModule.Quote(zone)
            + " -ErrorAction SilentlyContinue; "
            + "if ($z) { $out = @([pscustomobject]@{ name = [string]$z.ZoneName; type = [string]$z.ZoneType; "
            + "  read_only = [bool]$z.IsReadOnly; ad_integrated = [bool]$z.IsDsIntegrated; "
            + "  file = [string]$z.ZoneFile }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        return found.ValueKind != System.Text.Json.JsonValueKind.Object
            ? null
            : new Dictionary<string, object?>
            {
                ["name"] = found.String("name"),
                ["zone_type"] = found.String("type").ToLowerInvariant(),
                ["read_only"] = found.Bool("read_only"),
                ["ad_integrated"] = found.Bool("ad_integrated"),
                ["file"] = found.String("file"),
            };
    }

    private static async Task<ModuleResult> EnsureZone(string zone, string state, bool dryRun,
                                                      CancellationToken ct)
    {
        var current = await ReadZone(zone, ct);

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"DNS zone {zone} is already absent",
                    new Dictionary<string, object?> { ["zone"] = zone, ["state"] = "absent" });
            }
            if (dryRun)
            {
                return new ModuleResult(true,
                    $"would remove DNS zone {zone} — WITH EVERY RECORD IN IT, since a zone is not a container "
                    + "one empties first",
                    new Dictionary<string, object?> { ["zone"] = zone, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-DnsServerZone -Name {UserModule.Quote(zone)} -Force -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed DNS zone {zone} and every record in it",
                new Dictionary<string, object?> { ["zone"] = zone, ["state"] = "absent", ["before"] = current });
        }

        if (current is not null)
        {
            return new ModuleResult(false, $"DNS zone {zone} already exists ({current["zone_type"]})",
                new Dictionary<string, object?> { ["zone"] = zone, ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true, $"would create the primary DNS zone {zone} (file-backed)",
                new Dictionary<string, object?> { ["zone"] = zone, ["plan"] = "create" });
        }

        // FILE-BACKED PRIMARY, explicitly. An AD-integrated zone needs a domain controller and replicates to
        // every other one — a very different act, and not something to pick by default on a member server.
        await WindowsPowerShellBridge.RunJson(
            Import + $"Add-DnsServerPrimaryZone -Name {UserModule.Quote(zone)} "
                   + $"-ZoneFile {UserModule.Quote(zone + ".dns")} -ErrorAction Stop", "@()",
            TimeSpan.FromMinutes(2), ct);
        var after = await ReadZone(zone, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"Add-DnsServerPrimaryZone reported success but zone {zone} does not exist afterwards.");
        }
        return new ModuleResult(true, $"created the primary DNS zone {zone}",
            new Dictionary<string, object?> { ["zone"] = zone, ["state"] = "present", ["after"] = after });
    }

    private static async Task<ModuleResult> EnsureRecord(string zone, string state,
        IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        var type = (parameters.GetValueOrDefault("type") as string ?? "").ToUpperInvariant();
        var value = (parameters.GetValueOrDefault("value") as string ?? "").Trim();
        var ttl = (int)(parameters.GetValueOrDefault("ttl_seconds") as double? ?? 3600);

        if (name.Length == 0 || type.Length == 0)
        {
            throw new ArgumentException("name and type: both required for a record — a record is addressed by "
                                        + "zone, name and type together.");
        }
        if (!RecordTypes.Contains(type))
        {
            throw new ArgumentException(
                $"type: {type} is not one of {string.Join(", ", RecordTypes)}. The rest of DNS' record types "
                + "exist, and are deliberately not half-supported here — use the `powershell` module where the "
                + "full Add-DnsServerResourceRecord surface is visible.");
        }
        if (state == "present" && value.Length == 0)
        {
            throw new ArgumentException("value: required to create a record.");
        }

        var zoneInfo = await ReadZone(zone, ct);
        if (zoneInfo is null)
        {
            throw new ArgumentException(
                $"zone: {zone} does not exist on this server. Create it first (object: zone) — a record "
                + "written into a zone that does not exist would be a record nobody can find.");
        }
        if ((string?)zoneInfo["zone_type"] != "primary" || zoneInfo["read_only"] is true)
        {
            // REFUSED WITH THE REASON, not attempted: a secondary zone's data comes from its master, and
            // "the write failed" would send the reader to this server instead of to the one that owns it.
            throw new InvalidOperationException(
                $"zone {zone} is {zoneInfo["zone_type"]}"
                + (zoneInfo["read_only"] is true ? " and read-only" : "")
                + " on this server, so its records cannot be changed here. A secondary zone is edited on its "
                + "master and transferred; a stub or forwarder holds no records at all.");
        }

        // The existing record with this name AND type — a name can hold several types at once, and comparing
        // by name alone would call an A record and a TXT record the same thing.
        var setup = Import
            + "$out = @(); $r = Get-DnsServerResourceRecord -ZoneName " + UserModule.Quote(zone)
            + " -Name " + UserModule.Quote(name) + " -RRType " + UserModule.Quote(type)
            + " -ErrorAction SilentlyContinue | Select-Object -First 1; "
            + "if ($r) { $data = ''; "
            + "  if ($r.RecordData.IPv4Address) { $data = [string]$r.RecordData.IPv4Address } "
            + "  elseif ($r.RecordData.IPv6Address) { $data = [string]$r.RecordData.IPv6Address } "
            + "  elseif ($r.RecordData.HostNameAlias) { $data = [string]$r.RecordData.HostNameAlias } "
            + "  elseif ($r.RecordData.MailExchange) { $data = [string]$r.RecordData.MailExchange } "
            + "  elseif ($r.RecordData.PtrDomainName) { $data = [string]$r.RecordData.PtrDomainName } "
            + "  elseif ($r.RecordData.DescriptiveText) { $data = [string]$r.RecordData.DescriptiveText } "
            + "  else { $data = [string]$r.RecordData }; "
            + "  $out = @([pscustomobject]@{ name = [string]$r.HostName; type = [string]$r.RecordType; "
            + "    data = $data; ttl = [int64]$r.TimeToLive.TotalSeconds }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var existing = answer.Items.FirstOrDefault();
        var have = existing.ValueKind == System.Text.Json.JsonValueKind.Object
            ? new Dictionary<string, object?>
            {
                ["name"] = existing.String("name"), ["type"] = existing.String("type"),
                ["value"] = existing.String("data"), ["ttl_seconds"] = existing.Long("ttl"),
            }
            : null;

        if (state == "absent")
        {
            if (have is null)
            {
                return new ModuleResult(false, $"{type} record {name} in {zone} is already absent",
                    new Dictionary<string, object?> { ["zone"] = zone, ["name"] = name, ["type"] = type });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove the {type} record {name} in {zone} ({have["value"]})",
                    new Dictionary<string, object?> { ["plan"] = "remove", ["before"] = have });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-DnsServerResourceRecord -ZoneName {UserModule.Quote(zone)} "
                       + $"-Name {UserModule.Quote(name)} -RRType {UserModule.Quote(type)} -Force "
                       + "-ErrorAction Stop", "@()", TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed the {type} record {name} in {zone}",
                new Dictionary<string, object?> { ["zone"] = zone, ["name"] = name, ["type"] = type,
                                                 ["before"] = have });
        }

        if (have is not null && string.Equals((string?)have["value"], value, StringComparison.OrdinalIgnoreCase)
            && (long?)have["ttl_seconds"] == ttl)
        {
            return new ModuleResult(false, $"the {type} record {name} in {zone} is already {value}",
                new Dictionary<string, object?> { ["current"] = have });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                have is null
                    ? $"would create the {type} record {name}.{zone} → {value} (ttl {ttl}s)"
                    : $"would change the {type} record {name}.{zone} from {have["value"]} to {value}",
                new Dictionary<string, object?> { ["plan"] = have is null ? "create" : "update",
                                                 ["before"] = have, ["value"] = value });
        }

        var script = new List<string> { Import.TrimEnd(' ', ';') };
        if (have is not null)
        {
            // Remove and re-add rather than Set-DnsServerResourceRecord: the Set form needs the old record
            // object rebuilt exactly, and getting that subtly wrong writes a second record instead of
            // replacing the first — measured behaviour of that cmdlet family, and a duplicate A record is a
            // name that resolves to two addresses at random.
            script.Add($"Remove-DnsServerResourceRecord -ZoneName {UserModule.Quote(zone)} "
                       + $"-Name {UserModule.Quote(name)} -RRType {UserModule.Quote(type)} -Force "
                       + "-ErrorAction Stop");
        }
        var add = $"Add-DnsServerResourceRecord -ZoneName {UserModule.Quote(zone)} "
                  + $"-Name {UserModule.Quote(name)} -TimeToLive (New-TimeSpan -Seconds {ttl}) "
                  + "-ErrorAction Stop";
        add += type switch
        {
            "A" => $" -A -IPv4Address {UserModule.Quote(value)}",
            "AAAA" => $" -AAAA -IPv6Address {UserModule.Quote(value)}",
            "CNAME" => $" -CName -HostNameAlias {UserModule.Quote(value)}",
            "TXT" => $" -Txt -DescriptiveText {UserModule.Quote(value)}",
            "MX" => $" -MX -MailExchange {UserModule.Quote(value)} -Preference 10",
            _ => $" -Ptr -PtrDomainName {UserModule.Quote(value)}",
        };
        script.Add(add);

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);
        return new ModuleResult(true,
            have is null
                ? $"created the {type} record {name}.{zone} → {value}"
                : $"changed the {type} record {name}.{zone} from {have["value"]} to {value}",
            new Dictionary<string, object?>
            {
                ["zone"] = zone, ["name"] = name, ["type"] = type, ["value"] = value,
                ["ttl_seconds"] = ttl, ["before"] = have,
            });
    }
}
