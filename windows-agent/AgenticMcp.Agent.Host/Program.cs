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
builder.Services.AddSingleton<IMetricCollector>(new RuntimeMetricCollector());

var app = builder.Build();
var log = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("agent");
var store = app.Services.GetRequiredService<MetricStore>();
var collector = app.Services.GetRequiredService<IMetricCollector>();

// The module registry. Every Linux-only module is LISTED with the reason it cannot work here — see
// UnsupportedModule for why an omission would be the wrong answer.
var modules = new ModuleRegistry(writeEnabled)
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

app.MapGet("/api/v1/hosts/overview", () => Results.Json(new
{
    // One host and no satellites: this agent is a leaf. Proxy mode is a Go-agent feature this
    // implementation does not claim, and it says so by reporting itself rather than omitting the list.
    hosts = new[]
    {
        new
        {
            name,
            platform = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
            agent_version = ThisAssembly.Version,
            metrics = Array.Empty<object>(),
        },
    },
}));

// ---- the collection loop --------------------------------------------------------------------------------
var collecting = app.Lifetime.ApplicationStopping;
_ = Task.Run(async () =>
{
    while (!collecting.IsCancellationRequested)
    {
        try
        {
            var result = await collector.CollectAsync(collecting);
            store.Append(result.Samples);
            if (result.Absences.Count > 0)
            {
                // Said out loud once per pass: a reading that did not happen is a fact, and a collector that
                // logs nothing when it produces nothing is indistinguishable from one that is broken.
                // "readings from queries", not "produced/attempts": one query over the volumes yields three readings per
                // volume, so the two numbers are not a fraction and printing them as one read as 144/112.
                log.LogInformation("collector {Collector}: {Produced} readings from {Attempts} queries, {Absent} absent: {First}",
                    collector.Name, result.Samples.Count, result.Attempts, result.Absences.Count,
                    result.Absences[0].Reason);
            }
        }
        catch (OperationCanceledException)
        {
            break;
        }
        catch (Exception ex)
        {
            log.LogError(ex, "collection pass failed");
        }

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(30), collecting);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}, collecting);

log.LogInformation("agent {Name} listening on https://{Listen}, write gate {Gate}, {Pins} pinned key(s)",
    name, listen, writeEnabled ? "OPEN" : "closed", pins.Count);
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

await app.RunAsync();

internal static class ThisAssembly
{
    public static string Version =>
        typeof(ThisAssembly).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
}
