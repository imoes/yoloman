using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// IIS — <c>windows_iis</c>: sites, their bindings and the application pools behind them.
///
/// <para>THREE OBJECTS, ONE MODULE, and the reason they are not three modules: a site is only meaningful with
/// its bindings and its pool. "Site Default Web Site is started" answers nothing on its own — the question is
/// always "what answers on port 80, from which folder, as which identity", and that spans all three. So one
/// read returns the whole picture and `object` selects what a write targets.</para>
///
/// <para>A SITE'S STATE AND ITS POOL'S STATE ARE DIFFERENT FACTS, both reported: a started site whose
/// application pool is stopped serves 503s, which is the most common IIS confusion there is and cannot be
/// expressed by one flag. Same for the bindings — a site started on a port nothing is bound to is up and
/// unreachable.</para>
///
/// <para>WHAT IT DOES NOT DO, said rather than half-done: web.config contents (that is the config plane, with
/// codecs, generations and rollback — an IIS module writing XML by hand would be a second config path),
/// certificates and SNI bindings beyond naming them, and the dozens of per-site settings behind
/// `Set-WebConfigurationProperty`. Those are refused with a sentence rather than approximated.</para>
/// </summary>
public sealed class IisModule : IModule
{
    public string Name => "windows_iis";

    public string Description =>
        "IIS sites, bindings and application pools. Without `name`: return every site (with its bindings, "
        + "physical path, pool and state) and every application pool (with its state, .NET runtime, pipeline "
        + "mode and identity). With `object` + `name`: ensure a site or an app pool is present/absent and "
        + "started/stopped — a site takes `physical_path`, `bindings` (\"http/*:8080:\" or \"https/*:443:host\") "
        + "and `app_pool`. Idempotent; `dry_run: true` returns the plan. web.config contents are NOT managed "
        + "here — that is the config plane, which has codecs, generations and rollback.";

    private static readonly string[] Objects = ["site", "app_pool"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["object"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["enum"] = Objects,
                ["description"] = "What a write targets: site or app_pool. Required with `name`.",
            },
            ["name"] = P("string", "The site or pool name. Omit to READ everything."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent", "started", "stopped" },
                ["description"] = "present/absent for existence, started/stopped for the running state "
                                  + "(which implies present). Default present.",
            },
            ["physical_path"] = P("string", "The site's content folder. Required when creating a site."),
            ["bindings"] = new Dictionary<string, object>
            {
                ["type"] = "array",
                ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Bindings as protocol/ip:port:hostname, e.g. [\"http/*:8080:\"]. Absent "
                                  + "means bindings are not part of the declaration; given, they are enforced.",
            },
            ["app_pool"] = P("string", "The application pool the site runs in. Created if missing."),
            ["managed_runtime"] = P("string", "For a pool: the .NET runtime version (\"v4.0\", or \"\" for "
                                              + "No Managed Code)."),
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    /// <summary>WebAdministration is a Windows PowerShell 5.1 module, which is exactly what the bridge is
    /// for. Imported per call rather than assumed: a host with IIS installed but the management tools absent
    /// answers with a sentence naming what is missing instead of an opaque "command not found".</summary>
    private const string Import =
        "if (-not (Get-Module -ListAvailable -Name WebAdministration)) { "
        + "throw 'the WebAdministration module is not present: IIS is installed without its management tools "
        + "on this host (install the Web-Mgmt-Console / RSAT-Web-Server feature), so it cannot be managed "
        + "from here.' }; Import-Module WebAdministration -ErrorAction Stop; ";

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("windows_iis manages IIS, which exists only on Windows.");
        }

        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            return await ReadAll(ct);
        }

        var target = (parameters.GetValueOrDefault("object") as string ?? "").ToLowerInvariant();
        if (!Objects.Contains(target))
        {
            throw new ArgumentException(
                $"object: required with `name`, and one of {string.Join(", ", Objects)} — a name alone is "
                + "ambiguous, since a site and a pool can share one.");
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent" or "started" or "stopped"))
        {
            throw new ArgumentException($"state: {state} is not one of present, absent, started, stopped.");
        }

        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;
        return target == "site"
            ? await EnsureSite(name, state, parameters, dryRun, ct)
            : await EnsurePool(name, state, parameters, dryRun, ct);
    }

    private static async Task<ModuleResult> ReadAll(CancellationToken ct)
    {
        const string setup = Import
            + "$sites = New-Object System.Collections.ArrayList; "
            + "foreach ($s in Get-Website) { "
            + "  $b = @($s.Bindings.Collection | ForEach-Object { "
            + "        [string]$_.protocol + '/' + [string]$_.bindingInformation }); "
            + "  [void]$sites.Add([pscustomobject]@{ name = [string]$s.Name; id = [int64]$s.ID; "
            + "    state = [string]$s.State; path = [string]$s.PhysicalPath; "
            + "    app_pool = [string]$s.ApplicationPool; bindings = $b }) }; "
            + "$pools = New-Object System.Collections.ArrayList; "
            + "foreach ($p in Get-ChildItem IIS:\\AppPools) { "
            + "  [void]$pools.Add([pscustomobject]@{ name = [string]$p.Name; state = [string]$p.State; "
            + "    runtime = [string]$p.managedRuntimeVersion; pipeline = [string]$p.managedPipelineMode; "
            + "    identity = [string]$p.processModel.identityType; "
            + "    start_mode = [string]$p.startMode }) }";
        var answer = await WindowsPowerShellBridge.RunJson(
            setup, "[pscustomobject]@{ sites = @($sites); pools = @($pools) }", TimeSpan.FromMinutes(3), ct);

        var root = answer.Items.FirstOrDefault();
        var poolStates = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var pools = new List<Dictionary<string, object?>>();
        if (root.ValueKind == System.Text.Json.JsonValueKind.Object
            && root.TryGetProperty("pools", out var poolArray))
        {
            foreach (var pool in poolArray.EnumerateArrayOrEmpty())
            {
                var poolName = pool.String("name");
                var poolState = pool.String("state").ToLowerInvariant();
                poolStates[poolName] = poolState;
                pools.Add(new Dictionary<string, object?>
                {
                    ["name"] = poolName,
                    ["state"] = poolState,
                    // "" is a real value and means No Managed Code — a pool for a static site or a reverse
                    // proxy. Rendered as the words IIS itself shows, because an empty cell reads as unknown.
                    ["managed_runtime"] = pool.String("runtime") is { Length: 0 } ? "(no managed code)" : pool.String("runtime"),
                    ["pipeline"] = pool.String("pipeline"),
                    ["identity"] = pool.String("identity"),
                    ["start_mode"] = pool.String("start_mode"),
                });
            }
        }

        var sites = new List<Dictionary<string, object?>>();
        if (root.ValueKind == System.Text.Json.JsonValueKind.Object
            && root.TryGetProperty("sites", out var siteArray))
        {
            foreach (var site in siteArray.EnumerateArrayOrEmpty())
            {
                var siteState = site.String("state").ToLowerInvariant();
                var poolName = site.String("app_pool");
                var poolState = poolStates.GetValueOrDefault(poolName, "unknown");
                var bindings = site.StringArray("bindings");
                sites.Add(new Dictionary<string, object?>
                {
                    ["name"] = site.String("name"),
                    ["id"] = site.Long("id"),
                    ["state"] = siteState,
                    ["physical_path"] = site.String("path"),
                    ["app_pool"] = poolName,
                    ["app_pool_state"] = poolState,
                    ["bindings"] = bindings,
                    ["bindings_summary"] = bindings.Count > 0 ? string.Join(", ", bindings) : "(none — nothing "
                        + "reaches this site)",
                    // THE ANSWER TO "DOES THIS SITE SERVE", which is not the site's state alone: a started
                    // site with a stopped pool answers 503, and a started site with no binding answers
                    // nothing at all. Both are invisible if only one flag is read.
                    ["serving"] = (siteState, poolState, bindings.Count) switch
                    {
                        (_, _, 0) => "no — the site has no binding, so nothing reaches it",
                        ("started", "started", _) => "yes",
                        ("started", "stopped", _) => "no — the site is started but its application pool is "
                                                     + "stopped, which answers 503",
                        ("stopped", _, _) => "no — the site is stopped",
                        _ => $"unclear — site {siteState}, pool {poolState}",
                    },
                });
            }
        }

        sites.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"], StringComparison.OrdinalIgnoreCase));
        pools.Sort((a, b) => string.Compare((string?)a["name"], (string?)b["name"], StringComparison.OrdinalIgnoreCase));
        var serving = sites.Count(s => (string?)s["serving"] == "yes");
        return new ModuleResult(false,
            $"{sites.Count} site(s), {serving} actually serving, {pools.Count} application pool(s) — a site "
            + "serves only when it is started AND its pool is started AND it has a binding",
            new Dictionary<string, object?>
            {
                ["sites"] = sites,
                ["app_pools"] = pools,
                ["web_config"] = "not managed by this module — file contents belong to the config plane, which "
                                 + "has codecs, generations and rollback",
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = sites.Count + pools.Count });
    }

    private static async Task<Dictionary<string, object?>?> ReadSite(string name, CancellationToken ct)
    {
        var setup = Import
            + "$out = @(); $s = Get-Website -Name " + UserModule.Quote(name) + " -ErrorAction SilentlyContinue; "
            + "if ($s) { $out = @([pscustomobject]@{ name = [string]$s.Name; state = [string]$s.State; "
            + "  path = [string]$s.PhysicalPath; app_pool = [string]$s.ApplicationPool; "
            + "  bindings = @($s.Bindings.Collection | ForEach-Object { "
            + "    [string]$_.protocol + '/' + [string]$_.bindingInformation }) }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        return found.ValueKind != System.Text.Json.JsonValueKind.Object
            ? null
            : new Dictionary<string, object?>
            {
                ["name"] = found.String("name"),
                ["state"] = found.String("state").ToLowerInvariant(),
                ["physical_path"] = found.String("path"),
                ["app_pool"] = found.String("app_pool"),
                ["bindings"] = found.StringArray("bindings"),
            };
    }

    private static async Task<Dictionary<string, object?>?> ReadPool(string name, CancellationToken ct)
    {
        var setup = Import
            + "$out = @(); $p = Get-Item ('IIS:\\AppPools\\' + " + UserModule.Quote(name)
            + ") -ErrorAction SilentlyContinue; "
            + "if ($p) { $out = @([pscustomobject]@{ name = [string]$p.Name; state = [string]$p.State; "
            + "  runtime = [string]$p.managedRuntimeVersion; identity = [string]$p.processModel.identityType }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        return found.ValueKind != System.Text.Json.JsonValueKind.Object
            ? null
            : new Dictionary<string, object?>
            {
                ["name"] = found.String("name"),
                ["state"] = found.String("state").ToLowerInvariant(),
                ["managed_runtime"] = found.String("runtime"),
                ["identity"] = found.String("identity"),
            };
    }

    private static async Task<ModuleResult> EnsureSite(string name, string state,
        IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var current = await ReadSite(name, ct);
        var path = parameters.GetValueOrDefault("physical_path") as string;
        var pool = parameters.GetValueOrDefault("app_pool") as string;
        var declaresBindings = parameters.ContainsKey("bindings");
        var bindings = UserModule.AsStringList(parameters.GetValueOrDefault("bindings"));

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"site {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["existed"] = false });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove site {name} ({current["physical_path"]})",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-Website -Name {UserModule.Quote(name)} -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed site {name} — its content folder is left in place",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        if (current is null && string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("physical_path: required to create a site — the folder it serves.");
        }
        if (current is null && !declaresBindings)
        {
            throw new ArgumentException(
                "bindings: required to create a site. A site with no binding is started and unreachable, "
                + "which is a state nobody asks for on purpose — state e.g. [\"http/*:8080:\"].");
        }

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();
        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, $"{name} → {path}" };
        }
        else
        {
            if (!string.IsNullOrWhiteSpace(path)
                && !string.Equals(((string?)current["physical_path"] ?? "").TrimEnd('\\'), path.TrimEnd('\\'),
                                  StringComparison.OrdinalIgnoreCase))
            {
                steps.Add("physical_path");
                changes["physical_path"] = new object?[] { current["physical_path"], path };
            }
            if (!string.IsNullOrWhiteSpace(pool) && !string.Equals((string?)current["app_pool"], pool,
                                                                   StringComparison.OrdinalIgnoreCase))
            {
                steps.Add("app_pool");
                changes["app_pool"] = new object?[] { current["app_pool"], pool };
            }
            if (declaresBindings)
            {
                var have = (List<string>)current["bindings"]!;
                var missing = bindings.Where(b => !have.Contains(b, StringComparer.OrdinalIgnoreCase)).ToList();
                var extra = have.Where(b => !bindings.Contains(b, StringComparer.OrdinalIgnoreCase)).ToList();
                if (missing.Count > 0 || extra.Count > 0)
                {
                    steps.Add("bindings");
                    changes["bindings"] = new Dictionary<string, object?> { ["add"] = missing, ["remove"] = extra };
                }
            }
            var wantedRunning = state switch { "started" => true, "stopped" => false, _ => (bool?)null };
            if (wantedRunning is not null && ((string?)current["state"] == "started") != wantedRunning)
            {
                steps.Add("running");
                changes["running"] = new object?[] { current["state"], state };
            }
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"site {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} site {name}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                { ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current });
        }

        var script = new List<string> { Import.TrimEnd(' ', ';') };
        if (current is null)
        {
            var first = ParseBinding(bindings[0]);
            var create = $"New-Website -Name {UserModule.Quote(name)} "
                         + $"-PhysicalPath {UserModule.Quote(path!)} -Port {first.Port} -Force -ErrorAction Stop";
            if (!string.IsNullOrWhiteSpace(first.Host)) { create += $" -HostHeader {UserModule.Quote(first.Host)}"; }
            if (!string.IsNullOrWhiteSpace(pool)) { create += $" -ApplicationPool {UserModule.Quote(pool)}"; }
            script.Add(create + " | Out-Null");
            foreach (var extraBinding in bindings.Skip(1).Select(ParseBinding))
            {
                script.Add($"New-WebBinding -Name {UserModule.Quote(name)} -Protocol {UserModule.Quote(extraBinding.Protocol)} "
                           + $"-Port {extraBinding.Port} -IPAddress {UserModule.Quote(extraBinding.Ip)} "
                           + $"-HostHeader {UserModule.Quote(extraBinding.Host)} -ErrorAction Stop");
            }
        }
        else
        {
            if (changes.ContainsKey("physical_path"))
            {
                script.Add($"Set-ItemProperty ('IIS:\\Sites\\' + {UserModule.Quote(name)}) "
                           + $"-Name physicalPath -Value {UserModule.Quote(path!)} -ErrorAction Stop");
            }
            if (changes.ContainsKey("app_pool"))
            {
                script.Add($"Set-ItemProperty ('IIS:\\Sites\\' + {UserModule.Quote(name)}) "
                           + $"-Name applicationPool -Value {UserModule.Quote(pool!)} -ErrorAction Stop");
            }
            if (changes.GetValueOrDefault("bindings") is Dictionary<string, object?> bindingChange)
            {
                foreach (var spec in ((List<string>?)bindingChange["remove"]) ?? [])
                {
                    var parsed = ParseBinding(spec);
                    script.Add($"Remove-WebBinding -Name {UserModule.Quote(name)} -Protocol {UserModule.Quote(parsed.Protocol)} "
                               + $"-Port {parsed.Port} -IPAddress {UserModule.Quote(parsed.Ip)} "
                               + $"-HostHeader {UserModule.Quote(parsed.Host)} -ErrorAction Stop");
                }
                foreach (var spec in ((List<string>?)bindingChange["add"]) ?? [])
                {
                    var parsed = ParseBinding(spec);
                    script.Add($"New-WebBinding -Name {UserModule.Quote(name)} -Protocol {UserModule.Quote(parsed.Protocol)} "
                               + $"-Port {parsed.Port} -IPAddress {UserModule.Quote(parsed.Ip)} "
                               + $"-HostHeader {UserModule.Quote(parsed.Host)} -ErrorAction Stop");
                }
            }
        }
        if (state == "started" || current is null)
        {
            script.Add($"Start-Website -Name {UserModule.Quote(name)} -ErrorAction SilentlyContinue");
        }
        else if (state == "stopped")
        {
            script.Add($"Stop-Website -Name {UserModule.Quote(name)} -ErrorAction Stop");
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(4), ct);
        var after = await ReadSite(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the IIS operations reported success but site {name} does not exist afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} site {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    /// <summary>"http/*:8080:" → (http, *, 8080, ""). IIS' own binding-information format, which is exactly
    /// what the read returns, so a declaration can be copied out of a read without translation.</summary>
    private static (string Protocol, string Ip, int Port, string Host) ParseBinding(string spec)
    {
        var slash = spec.IndexOf('/');
        var protocol = slash > 0 ? spec[..slash] : "http";
        var rest = slash > 0 ? spec[(slash + 1)..] : spec;
        var parts = rest.Split(':');
        var ip = parts.Length > 0 && parts[0].Length > 0 ? parts[0] : "*";
        var port = parts.Length > 1 && int.TryParse(parts[1], out var parsed) ? parsed
            : throw new ArgumentException(
                $"bindings: \"{spec}\" has no port — the format is protocol/ip:port:hostname, "
                + "e.g. http/*:8080: (the same form a read returns, so a declaration can be copied out of one)");
        var host = parts.Length > 2 ? parts[2] : "";
        return (protocol, ip, port, host);
    }

    private static async Task<ModuleResult> EnsurePool(string name, string state,
        IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var current = await ReadPool(name, ct);
        var runtime = parameters.GetValueOrDefault("managed_runtime") as string;

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"application pool {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent" });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove application pool {name}",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                Import + $"Remove-WebAppPool -Name {UserModule.Quote(name)} -ErrorAction Stop", "@()",
                TimeSpan.FromMinutes(2), ct);
            return new ModuleResult(true, $"removed application pool {name}",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();
        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new object?[] { null, name };
        }
        else
        {
            if (runtime is not null && !string.Equals((string?)current["managed_runtime"], runtime,
                                                      StringComparison.OrdinalIgnoreCase))
            {
                steps.Add("managed_runtime");
                changes["managed_runtime"] = new object?[] { current["managed_runtime"], runtime };
            }
            var wantedRunning = state switch { "started" => true, "stopped" => false, _ => (bool?)null };
            if (wantedRunning is not null && ((string?)current["state"] == "started") != wantedRunning)
            {
                steps.Add("running");
                changes["running"] = new object?[] { current["state"], state };
            }
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"application pool {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} application pool {name}: "
                + string.Join(", ", steps),
                new Dictionary<string, object?>
                { ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current });
        }

        var script = new List<string> { Import.TrimEnd(' ', ';') };
        if (current is null)
        {
            script.Add($"New-WebAppPool -Name {UserModule.Quote(name)} -Force -ErrorAction Stop | Out-Null");
        }
        if (changes.ContainsKey("managed_runtime"))
        {
            script.Add($"Set-ItemProperty ('IIS:\\AppPools\\' + {UserModule.Quote(name)}) "
                       + $"-Name managedRuntimeVersion -Value {UserModule.Quote(runtime!)} -ErrorAction Stop");
        }
        if (state == "stopped")
        {
            script.Add($"Stop-WebAppPool -Name {UserModule.Quote(name)} -ErrorAction Stop");
        }
        else if (state == "started" || current is null)
        {
            script.Add($"Start-WebAppPool -Name {UserModule.Quote(name)} -ErrorAction SilentlyContinue");
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);
        var after = await ReadPool(name, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the IIS operations reported success but application pool {name} does not exist afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} application pool {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }
}
