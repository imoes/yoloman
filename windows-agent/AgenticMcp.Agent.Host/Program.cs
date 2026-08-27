using System.Net.Http.Json;
using System.Text.Json;
using AgenticMcp.Agent.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// The agent process: a listener that answers the endpoints Bossman polls, a collection loop that fills the
// store, and a one-time enrolment handshake. Routing only — every body it serves is a pure function in
// AgenticMcp.Agent.Core, which is where the agreement with Bossman is tested.
//
// Configuration comes from the environment, so the Windows service registration is a set of variables and
// not a second config format:
//
//   AGENT_NAME       what Bossman calls this host          (default: the machine name)
//   AGENT_TOKEN      the bearer token Bossman must present (default: generated and printed once)
//   AGENT_LISTEN     host:port to listen on                (default: 0.0.0.0:8051, the Go agent's port)
//   AGENT_ADDRESS    the host:port Bossman can reach       (default: AGENT_LISTEN)
//   BOSSMAN_URL      enrol against this Bossman on start   (default: no enrolment, just listen)
//   AGENT_WRITE      "true" opens the write gate           (default: closed)
//   AGENT_STATE_DIR  where the TLS cert and the pinned keys live (default: ./state)

var name = Environment.GetEnvironmentVariable("AGENT_NAME") ?? Environment.MachineName;
var listen = Environment.GetEnvironmentVariable("AGENT_LISTEN") ?? "0.0.0.0:8051";
var address = Environment.GetEnvironmentVariable("AGENT_ADDRESS") ?? listen;
var bossmanUrl = Environment.GetEnvironmentVariable("BOSSMAN_URL");
var writeEnabled = string.Equals(Environment.GetEnvironmentVariable("AGENT_WRITE"), "true",
    StringComparison.OrdinalIgnoreCase);
var token = Environment.GetEnvironmentVariable("AGENT_TOKEN");
var tokenWasGenerated = string.IsNullOrEmpty(token);
if (tokenWasGenerated)
{
    token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
}

var stateDir = Environment.GetEnvironmentVariable("AGENT_STATE_DIR") ?? "state";
Directory.CreateDirectory(stateDir);
var pinPath = Path.Combine(stateDir, "bossman-public-key.pem");

// ENROL BEFORE LISTENING. The reply carries the public key this agent will pin, so a listener started first
// would be up for a moment with nothing to authorise — and "reachable but trusts nobody" is a state worth
// not having. Bossman's poller retries on its own schedule, so nothing is lost by binding a second later.
if (!string.IsNullOrWhiteSpace(bossmanUrl))
{
    try
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        var response = await http.PostAsJsonAsync(bossmanUrl.TrimEnd('/') + "/api/v1/enroll",
            new EnrollRequest(name, token!, address, null));
        var body = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
        {
            // Not fatal: the listener still serves, and a manually registered agent is a supported path. But
            // the reason is printed, because "the agent is up and Bossman does not know it" is exactly the
            // confusing state this message exists to prevent.
            Console.Error.WriteLine($"enrolment refused by {bossmanUrl}: {(int)response.StatusCode} {body}");
        }
        else
        {
            var reply = JsonSerializer.Deserialize<EnrollResponse>(body);
            if (!string.IsNullOrWhiteSpace(reply?.BossmanPublicKey))
            {
                // Written to disk, so the pin survives a restart without re-enrolling — the same reason the
                // Go agent keeps it in tls.trusted_client_keys rather than in memory.
                await File.WriteAllTextAsync(pinPath, reply.BossmanPublicKey);
            }

            Console.WriteLine($"enrolled with {bossmanUrl} as {name}, agent_id={reply?.AgentId ?? "(none)"}");
        }
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"enrolment against {bossmanUrl} failed: {ex.Message}");
    }
}

// The keys whose client certificate this agent accepts. An agent with no pin yet still listens and still
// answers /healthz — it just cannot be polled, and it says so rather than refusing connections without a
// reason.
var pins = new List<TlsAuth.TrustedKey>();
if (File.Exists(pinPath))
{
    pins.Add(TlsAuth.LoadTrustedKeyPem("bossman", await File.ReadAllTextAsync(pinPath)));
}

var serverCert = TlsAuth.EnsureServerCertificate(Path.Combine(stateDir, "agent-tls.pfx"), name);

// THE INBOUND FIREWALL RULE, before binding. A Windows Server blocks inbound traffic by default, so an agent
// that enrols and reports itself reachable at a port nothing can reach is a host that LOOKS managed and is
// not — and that state is invisible from the host (the log says "listening") while showing up on the server
// as a poll error, which reads as a network fault. Idempotent by rule name; a failure is reported and does
// not stop the listener, because a host whose firewall is managed by policy is a legitimate case.
var listenPort = int.TryParse(listen.Split(':').Last(), out var parsedPort) ? parsedPort : 8051;
string firewallNote;
#if WINDOWS
var firewall = AgenticMcp.Agent.Windows.WindowsFirewall.EnsurePortOpen(listenPort);
firewallNote = firewall.Detail;
#else
firewallNote = "not Windows: the inbound rule is the installer's job here (packaging/postinst opens the "
               + "port in ufw/firewalld/iptables)";
#endif

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls($"https://{listen}");
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.ConfigureHttpsDefaults(https =>
    {
        https.ServerCertificate = serverCert;
        // ALLOW, not Require: a rejected handshake gives the caller no reason, and "no client certificate"
        // has to be answerable with a sentence. The check itself is in the middleware below.
        https.ClientCertificateMode = Microsoft.AspNetCore.Server.Kestrel.Https.ClientCertificateMode.AllowCertificate;
        // The chain is deliberately not validated: the pin is the public key, so a CA that nothing checks
        // would only add a way for a valid identity to be refused.
        https.AllowAnyClientCertificate();
    });
});
builder.Services.AddSingleton(new MetricStore());

// The collectors, in the order they are reported. The runtime one answers what .NET knows on any OS; the WMI
// one answers what Windows knows. They do NOT overlap and neither is a fallback for the other — a host runs
// both and the store merges them, because they are answers to different questions.
var collectors = new List<IMetricCollector> { new RuntimeMetricCollector() };
#if WINDOWS
collectors.Add(new AgenticMcp.Agent.Windows.WmiMetricCollector());
#endif

var app = builder.Build();
var log = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("agent");
var store = app.Services.GetRequiredService<MetricStore>();

// The module registry. Every Linux-only module is LISTED with the reason it cannot work here — see
// UnsupportedModule for why an omission would be the wrong answer.
var powershellModule = new AgenticMcp.Agent.Modules.PowerShellModule();
var modules = new ModuleRegistry(writeEnabled)
    .Add(powershellModule)
    .Add(new AgenticMcp.Agent.Modules.FileModule())
    .Add(new AgenticMcp.Agent.Modules.CopyModule())
#if WINDOWS
    .Add(new AgenticMcp.Agent.Windows.RegistryModule())
    .Add(new AgenticMcp.Agent.Windows.ServiceModule())
    // windows_feature shares the ONE PowerShell host with the `powershell` module rather than opening a
    // second runspace: one module path, one timeout, one place where the streams are separated.
    .Add(new AgenticMcp.Agent.Windows.WindowsFeatureModule())
    .Add(new AgenticMcp.Agent.Windows.PackageModule())
#else
    // THE MIRROR IMAGE of apt/systemd below: on a non-Windows host these are listed with the reason they
    // cannot work, so the listing is the same shape whichever way round the platform is. An agent that
    // simply omitted them would be as unreadable in this direction as in the other.
    .Add(new UnsupportedModule("registry", "there is no Windows registry on this platform"))
    .Add(new UnsupportedModule("package",
        "this build's package providers are the Windows ones (msi, installer, winget, choco, appx, "
        + "PackageManagement); on Linux the apt/yum/dnf modules do this job",
        instead: "apt"))
    .Add(new UnsupportedModule("windows_feature",
        "Windows Server roles and features exist only on Windows; on Linux the package catalogue's role "
        + "bindings do this job",
        instead: "role"))
    .Add(new UnsupportedModule("service",
        "this build has no service control manager; on Linux the Go agent's `service` module does this",
        instead: "powershell"))
#endif
    .Add(new UnsupportedModule("apt", "Windows has no APT package database", instead: "winget"))
    .Add(new UnsupportedModule("yum", "Windows has no YUM/DNF package database", instead: "winget"))
    .Add(new UnsupportedModule("dnf", "Windows has no YUM/DNF package database", instead: "winget"))
    .Add(new UnsupportedModule("systemd",
        "Windows services are managed by the service control manager, not by systemd units",
        instead: "service"))
    .Add(new UnsupportedModule("selinux", "SELinux is a Linux kernel facility"))
    .Add(new UnsupportedModule("firewalld", "firewalld is a Linux service",
        instead: "windows_firewall"))
    .Add(new UnsupportedModule("cron",
        "Windows schedules work with triggers, principals and conditions rather than five cron fields — a "
        + "different concept, so it has a different name",
        instead: "scheduled_task"));

// ---- authentication -------------------------------------------------------------------------------------
// Bearer token, spelled exactly as the Go agent's REST layer spells it (internal/server/rest.go). mTLS is
// milestone 6's job; until then the token is what Bossman was handed at enrolment, so the two ends already
// agree on the credential even though the transport is not yet pinned.
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/healthz"))
    {
        await next();
        return;
    }

    var header = ctx.Request.Headers.Authorization.ToString();
    const string prefix = "Bearer ";
    var given = header.StartsWith(prefix, StringComparison.Ordinal) ? header[prefix.Length..] : null;
    if (given != token)
    {
        ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await ctx.Response.WriteAsJsonAsync(new { error = "a valid bearer token is required" });
        return;
    }

    // BOTH credentials, like the Go agent: the token says which agent you are talking to, the client
    // certificate says who you are. Checked here rather than in the handshake so every refusal can name its
    // reason instead of appearing as a dropped connection.
    if (pins.Count > 0)
    {
        var presented = ctx.Connection.ClientCertificate;
        if (presented is null)
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await ctx.Response.WriteAsJsonAsync(new
            {
                error = "a TLS client certificate is required; this agent pins the public key it was "
                        + "enrolled with",
            });
            return;
        }

        if (!TlsAuth.MatchesAny(presented, pins, out _))
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            await ctx.Response.WriteAsJsonAsync(new
            {
                error = "this client certificate's public key is not pinned by this agent",
                presented_subject = presented.Subject,
            });
            return;
        }
    }

    await next();
});

// ---- the endpoints Bossman polls ------------------------------------------------------------------------
app.MapGet("/healthz", () => Results.Ok(new { status = "ok", agent = name }));

app.MapGet("/api/v1/metrics", (HttpRequest req) =>
{
    var now = DateTimeOffset.UtcNow;
    if (!Endpoints.TryParseTimeBound(req.Query["from"], now, TimeSpan.FromHours(-1), out var from, out var err))
    {
        return Results.BadRequest(new { error = $"from: {err}" });
    }

    if (!Endpoints.TryParseTimeBound(req.Query["to"], now, TimeSpan.Zero, out var to, out err))
    {
        return Results.BadRequest(new { error = $"to: {err}" });
    }

    return Results.Json(store.Dump(from, to));
});

app.MapGet("/api/v1/metrics/{metric}", (string metric, HttpRequest req) =>
{
    var now = DateTimeOffset.UtcNow;
    if (!Endpoints.TryParseTimeBound(req.Query["from"], now, TimeSpan.FromHours(-1), out var from, out var err))
    {
        return Results.BadRequest(new { error = $"from: {err}" });
    }

    if (!Endpoints.TryParseTimeBound(req.Query["to"], now, TimeSpan.Zero, out var to, out err))
    {
        return Results.BadRequest(new { error = $"to: {err}" });
    }

    var labels = Endpoints.LabelFilter(req.Query.Select(q =>
        new KeyValuePair<string, string?>(q.Key, q.Value.ToString())));
    return Results.Json(store.Query(metric, from, to, labels));
});

app.MapGet("/api/v1/tools", () => Results.Json(modules.Describe()));

// POST /api/v1/tools/{name} — the ONE call every action goes through, same path and same body as the Go
// agent's handleToolCall: a JSON object of the module's parameters, with `dry_run: true` asking for a
// preview instead of a change.
app.MapPost("/api/v1/tools/{name}", async (string name, HttpRequest req, CancellationToken ct) =>
{
    var module = modules.Find(name);
    if (module is null)
    {
        // The name, not just a 404: an orchestrator that mistyped a module needs to know which one it asked
        // for, and one that targeted the wrong OS needs to know this host has a listing to look at.
        return Results.NotFound(new { error = $"no such tool on this agent: {name}" });
    }

    Dictionary<string, object?> parameters = [];
    if (req.ContentLength is > 0)
    {
        var body = await JsonSerializer.DeserializeAsync<Dictionary<string, JsonElement>>(req.Body,
            cancellationToken: ct);
        foreach (var (key, value) in body ?? [])
        {
            parameters[key] = value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Number => value.GetDouble(),
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.Null => null,
                _ => value.ToString(),
            };
        }
    }

    // `dry_run` in the BODY, exactly as the Go agent reads it — a caller asks for a preview the same way on
    // either platform, or the two agents would need two runbooks.
    var dryRun = parameters.TryGetValue("dry_run", out var d) && d is true;

    try
    {
        return Results.Json(await module.RunAsync(parameters, dryRun, ct));
    }
    catch (PlatformNotSupportedException ex)
    {
        // 501, and the reason. This is the refusal the listing already announced with supported:false; a plan
        // written for the wrong OS learns WHY here rather than getting a bare error.
        return Results.Json(new { error = ex.Message }, statusCode: StatusCodes.Status501NotImplemented);
    }
    catch (Exception ex) when (ex is ArgumentException or DirectoryNotFoundException or FormatException
                                  or FileNotFoundException or IOException
                                  or InvalidOperationException or TimeoutException)
    {
        // 422 for a bad parameter OR A REFUSAL BY THE HOST, matching the Go agent's
        // writeError(StatusUnprocessableEntity). Measured on the real Windows host: asking to uninstall
        // FileAndStorage-Services made Windows answer "Storage Services cannot be removed" — a correct,
        // useful refusal that arrived at Bossman as an opaque 500 with an EMPTY body, because
        // InvalidOperationException was not in this list. A host that says no must have its reason carried to
        // whoever asked; a 500 says only that something broke here.
        return Results.Json(new { error = ex.Message }, statusCode: StatusCodes.Status422UnprocessableEntity);
    }
});

// The inventory document, cached: Bossman stores it as the host's `facts`, and `os_family` in there is what
// every family-dependent decision downstream reads. Until it existed this host was read as DEBIAN, because
// Bossman's family_of() ends in `return "debian"` for anything it cannot identify — one missing field, and a
// Windows Server gets offered apt packages by a catalogue lookup that believes it.
//
// Cached for an hour: it is near-static, and the feature count behind it starts a Windows PowerShell process.
Dictionary<string, object?>? inventoryCache = null;
var inventoryTaken = DateTimeOffset.MinValue;
var inventoryGate = new SemaphoreSlim(1, 1);

async Task<Dictionary<string, object?>> Inventory()
{
    if (inventoryCache is not null && DateTimeOffset.UtcNow - inventoryTaken < TimeSpan.FromHours(1))
    {
        return inventoryCache;
    }

    await inventoryGate.WaitAsync();
    try
    {
        if (inventoryCache is null || DateTimeOffset.UtcNow - inventoryTaken >= TimeSpan.FromHours(1))
        {
#if WINDOWS
            inventoryCache = AgenticMcp.Agent.Windows.WindowsInventory.Collect();
#else
            // The non-Windows build says what it is rather than claiming a family it is not: this binary is
            // the Windows agent, and running it on Linux is a development situation, not a supported host.
            inventoryCache = new Dictionary<string, object?>
            {
                ["os_family"] = "unknown",
                ["agent_platform"] = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
                ["inventory_note"] = "this is the Windows agent running on a non-Windows host (development); "
                                     + "no OS family is claimed",
            };
#endif
            inventoryTaken = DateTimeOffset.UtcNow;
        }
    }
    finally
    {
        inventoryGate.Release();
    }

    return inventoryCache!;
}

app.MapGet("/api/v1/hosts/overview", async () => Results.Json(new
{
    // One host and no satellites: this agent is a leaf. Proxy mode is a Go-agent feature this
    // implementation does not claim, and it says so by reporting itself rather than omitting the list.
    hosts = new[]
    {
        new
        {
            // `host`, NOT `name`, and this cost an afternoon: Bossman's _ingest_hosts_overview starts with
            // `host_name = host.get("host")` and CONTINUES when it is missing — so an entry keyed `name` was
            // skipped in silence, no facts were stored, and the host kept reading as Debian while the agent
            // served a perfectly good inventory. The Go agent's HostSnapshot has said `json:"host"` all along
            // (internal/server/hostoverview.go); one name for one thing, and the reader's name wins.
            host = name,
            // `mode` is part of the same contract: standalone means "a leaf, not relaying anyone". Absent
            // `parent` is what marks this as the agent's OWN entry rather than a satellite it relays.
            mode = "standalone",
            platform = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
            agent_version = ThisAssembly.Version,
            metrics = Array.Empty<object>(),
            inventory = await Inventory(),
        },
    },
}));

// ---- the collection loop --------------------------------------------------------------------------------
var collecting = app.Lifetime.ApplicationStopping;
_ = Task.Run(async () =>
{
    while (!collecting.IsCancellationRequested)
    {
        foreach (var collector in collectors)
        {
            // PER COLLECTOR. One collector throwing must not cost the pass its other collectors' readings —
            // on Windows that is the difference between "WMI is unhappy" and "this host reports nothing".
            try
            {
                var result = await collector.CollectAsync(collecting);
                store.Append(result.Samples);
                if (result.Absences.Count > 0)
                {
                    // Said out loud once per pass: a reading that did not happen is a fact, and a collector
                    // that logs nothing when it produced nothing is indistinguishable from a broken one.
                    // "readings from queries", not "produced/attempts" — one query over the volumes yields
                    // three readings each, so the two numbers are not a fraction and printing them as one
                    // read as "144/112".
                    log.LogInformation(
                        "collector {Collector}: {Produced} readings from {Attempts} queries, {Absent} absent: {First}",
                        collector.Name, result.Samples.Count, result.Attempts, result.Absences.Count,
                        result.Absences[0].Reason);
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                log.LogError(ex, "collector {Collector} failed", collector.Name);
            }
        }

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(30), collecting);
        }
        catch (OperationCanceledException)
        {
            return;
        }
    }
}, collecting);

log.LogInformation("agent {Name} listening on https://{Listen}, write gate {Gate}, {Pins} pinned key(s)",
    name, listen, writeEnabled ? "OPEN" : "closed", pins.Count);
log.LogInformation("firewall: {Note}", firewallNote);
if (AgenticMcp.Agent.Modules.PowerShellModule.ModuleDirectory is null)
{
    // Named, at startup: a runspace without its module tree still evaluates expressions, so it LOOKS like a
    // working PowerShell right up to the first Get-Date. Measured once through Bossman, which is how it was
    // found at all.
    log.LogWarning("PowerShell modules not found next to this executable: the `powershell` module can run "
                   // No braces around unix|win: the logger reads those as a placeholder name (CA2017).
                   + "language but almost no cmdlets. Expected runtimes/<unix-or-win>/lib/*/Modules under {Base}",
        AppContext.BaseDirectory);
}
else
{
    log.LogInformation("PowerShell modules: {Path}", AgenticMcp.Agent.Modules.PowerShellModule.ModuleDirectory);
}

if (pins.Count == 0)
{
    // A named state, not a silence: an agent with no pin answers /healthz and refuses nothing, which looks
    // identical to a working one until the first poll arrives.
    log.LogWarning("no pinned key: this agent will accept ANY client certificate. Enrol it against Bossman "
                   + "(BOSSMAN_URL) or drop its public key into {Path}", pinPath);
}
if (tokenWasGenerated)
{
    // Printed once, because a generated secret nobody was told is a secret nobody can use.
    log.LogInformation("generated bearer token (set AGENT_TOKEN to keep it across restarts): {Token}", token);
}

// THE LISTENER PROVES ITSELF, once, against its own port.
//
// Kestrel binding successfully is not the same as Kestrel being able to serve: on Windows a certificate
// whose key it cannot use starts and binds and logs "listening", then kills every connection at the
// handshake — a state invisible from the host and indistinguishable from a network fault on the server. So
// the agent asks itself for /healthz over TLS and says what happened. It does not exit on failure: a broken
// listener that says so is still better than one that lies, and the operator may be mid-diagnosis.
_ = Task.Run(async () =>
{
    await Task.Delay(TimeSpan.FromSeconds(2), collecting);
    var probeHost = listen.StartsWith("0.0.0.0", StringComparison.Ordinal) ? "127.0.0.1" : listen.Split(':')[0];
    using var handler = new HttpClientHandler
    {
        // Its own self-signed certificate — the pin is what authorises the CALLER, and this call is the
        // agent asking itself.
        ServerCertificateCustomValidationCallback = (_, _, _, _) => true,
    };
    using var probe = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    try
    {
        var reply = await probe.GetAsync($"https://{probeHost}:{listenPort}/healthz", collecting);
        log.LogInformation("self-probe: HTTPS on {Host}:{Port} answered {Status}", probeHost, listenPort,
            (int)reply.StatusCode);
    }
    catch (Exception ex)
    {
        log.LogError("self-probe FAILED: this agent is listening on {Host}:{Port} but cannot serve TLS to "
                     + "itself — {Error}. Bossman will report it as unreachable. On Windows this is usually "
                     + "the server certificate's key storage (see TlsAuth.KeyStorageFlags).",
            probeHost, listenPort, ex.Message);
    }
}, collecting);

await app.RunAsync();

internal static class ThisAssembly
{
    public static string Version =>
        typeof(ThisAssembly).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
}
