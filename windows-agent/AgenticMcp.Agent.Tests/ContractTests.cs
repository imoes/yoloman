using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The contract with Bossman, asserted on the WIRE and not on the C# types.
///
/// A field renamed here is a field Bossman silently stops reading — there is no compiler between the two
/// implementations, so these tests are the only thing standing where a shared type would be.
/// </summary>
public class WireContractTests
{
    private static string Json(object value) => JsonSerializer.Serialize(value);

    [Fact]
    public void MetricPointSpellsItsFieldsTheWayTheGoAgentDoes()
    {
        var json = Json(new MetricPoint("2026-08-26T10:00:00Z", 42.5, new Dictionary<string, string>
        {
            ["core"] = "0",
        }));

        Assert.Equal("""{"timestamp":"2026-08-26T10:00:00Z","value":42.5,"labels":{"core":"0"}}""", json);
    }

    [Fact]
    public void AMetricWithoutLabelsOmitsTheKeyRatherThanSendingNull()
    {
        // Go's `omitempty` drops the key. A literal null is a different document, and the poller's
        // `point.get("labels") or {}` would cope — but "coping" is not agreement.
        Assert.Equal("""{"timestamp":"2026-08-26T10:00:00Z","value":1}""",
            Json(new MetricPoint("2026-08-26T10:00:00Z", 1, null)));
    }

    [Fact]
    public void TheDumpIsKeyedByMetricName()
    {
        var store = new MetricStore();
        var at = DateTimeOffset.Parse("2026-08-26T10:00:00Z");
        store.Append([new MetricSample("cpu_percent", 12, at, null, "Win32_PerfFormattedData_PerfOS_Processor")]);

        Assert.Equal("""{"metrics":{"cpu_percent":[{"timestamp":"2026-08-26T10:00:00Z","value":12}]}}""",
            Json(store.Dump(at.AddMinutes(-1), at.AddMinutes(1))));
    }

    [Fact]
    public void EnrolmentSendsNameTokenAndAddress()
    {
        Assert.Equal("""{"name":"win-test","token":"t0ken","address":"10.0.0.5:8051"}""",
            Json(new EnrollRequest("win-test", "t0ken", "10.0.0.5:8051", null)));
    }

    [Fact]
    public void TimestampsAreRfc3339WithoutFractionalSeconds()
    {
        // "o" would emit seven fractional digits: valid ISO 8601, parsed fine by Python, and not the format
        // every other timestamp in this fleet has. Two systems compare these as strings often enough.
        var at = new DateTimeOffset(2026, 8, 26, 12, 0, 0, 123, TimeSpan.FromHours(2));
        Assert.Equal("2026-08-26T10:00:00Z", MetricStore.Rfc3339(at));
    }
}

public class MetricStoreTests
{
    private static readonly DateTimeOffset Noon = DateTimeOffset.Parse("2026-08-26T12:00:00Z");

    [Fact]
    public void LabelOrderDoesNotSplitASeries()
    {
        // {a,b} and {b,a} are ONE series. Unsorted keys would split it, and the split would look like two
        // different cores, mounts or interfaces — a wrong answer that reads as a plausible one.
        var first = MetricStore.SeriesKey("net_bytes", new Dictionary<string, string> { ["iface"] = "eth0", ["dir"] = "rx" });
        var second = MetricStore.SeriesKey("net_bytes", new Dictionary<string, string> { ["dir"] = "rx", ["iface"] = "eth0" });
        Assert.Equal(first, second);
    }

    [Fact]
    public void DifferentLabelsAreDifferentSeries()
    {
        var store = new MetricStore();
        store.Append([
            new MetricSample("cpu_percent", 10, Noon, new Dictionary<string, string> { ["core"] = "0" }),
            new MetricSample("cpu_percent", 90, Noon, new Dictionary<string, string> { ["core"] = "1" }),
        ]);

        var points = store.Dump(Noon.AddMinutes(-1), Noon.AddMinutes(1)).Metrics["cpu_percent"];
        Assert.Equal(2, points.Count);
        Assert.Equal([10, 90], points.Select(p => p.Value).Order().ToArray());
    }

    [Fact]
    public void AQueryFiltersOnLabelsAsASuperset()
    {
        var store = new MetricStore();
        store.Append([
            new MetricSample("disk_usage", 55, Noon, new Dictionary<string, string> { ["mount"] = "C:", ["fs"] = "NTFS" }),
            new MetricSample("disk_usage", 12, Noon, new Dictionary<string, string> { ["mount"] = "D:", ["fs"] = "NTFS" }),
        ]);

        var got = store.Query("disk_usage", Noon.AddMinutes(-1), Noon.AddMinutes(1),
            new Dictionary<string, string> { ["mount"] = "C:" });

        Assert.Single(got.Points);
        Assert.Equal(55, got.Points[0].Value);
    }

    [Fact]
    public void AFilterNamingAnAbsentLabelMatchesNothing()
    {
        var store = new MetricStore();
        store.Append([new MetricSample("uptime", 3600, Noon)]);

        Assert.Empty(store.Query("uptime", Noon.AddMinutes(-1), Noon.AddMinutes(1),
            new Dictionary<string, string> { ["core"] = "0" }).Points);
    }

    [Fact]
    public void PointsOutsideTheRangeAreNotReturned()
    {
        var store = new MetricStore();
        store.Append([
            new MetricSample("cpu_percent", 1, Noon.AddHours(-2)),
            new MetricSample("cpu_percent", 2, Noon),
        ]);

        var got = store.Query("cpu_percent", Noon.AddMinutes(-30), Noon.AddMinutes(30));
        Assert.Single(got.Points);
        Assert.Equal(2, got.Points[0].Value);
    }

    [Fact]
    public void ASeriesIsBoundedAndKeepsTheNewestPoints()
    {
        var store = new MetricStore(perSeriesCapacity: 3);
        for (var i = 0; i < 10; i++)
        {
            store.Append([new MetricSample("cpu_percent", i, Noon.AddSeconds(i))]);
        }

        var values = store.Query("cpu_percent", Noon.AddHours(-1), Noon.AddHours(1))
            .Points.Select(p => p.Value).ToArray();
        Assert.Equal([7, 8, 9], values);
    }
}

public class ModuleRegistryTests
{
    private sealed class FakeModule(string name, bool writes) : IModule
    {
        public string Name { get; } = name;
        public string Description => "a test module";
        public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object> { ["type"] = "object" };
        public bool Writes { get; } = writes;

        public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
            CancellationToken ct) => Task.FromResult(ModuleResult.Unchanged("ran"));
    }

    [Fact]
    public void ALinuxOnlyModuleIsListedWithItsReasonRatherThanOmitted()
    {
        // The excluded-middle rule: an omission is indistinguishable from an agent too old to have the
        // module. "No, because Windows has no apt" is a state an operator and an LLM can both act on.
        var registry = new ModuleRegistry(writeEnabled: true)
            .Add(new UnsupportedModule("apt", "Windows has no APT package database", instead: "winget"));

        var apt = registry.Describe().Tools.Single(t => t.Name == "apt");
        Assert.False(apt.Supported);
        Assert.Equal("Windows has no APT package database", apt.UnsupportedReason);
        Assert.Contains("winget", apt.Description);
    }

    [Fact]
    public async Task RunningAnUnsupportedModuleFailsWithTheReasonNotWithANotFound()
    {
        var module = new UnsupportedModule("systemd", "Windows services are managed by the service manager",
            instead: "service");
        var ex = await Assert.ThrowsAsync<PlatformNotSupportedException>(() =>
            module.RunAsync(new Dictionary<string, object?>(), dryRun: true, CancellationToken.None));
        Assert.Contains("Windows services are managed", ex.Message);
    }

    [Fact]
    public void AClosedWriteGateTurnsAWritingModuleIntoANamedRefusal()
    {
        // Not "the module vanishes": the listing has to say WHY it cannot be called, or a closed gate looks
        // exactly like a module that was never built.
        var registry = new ModuleRegistry(writeEnabled: false).Add(new FakeModule("file", writes: true));

        var file = registry.Describe().Tools.Single(t => t.Name == "file");
        Assert.False(file.Supported);
        Assert.Contains("write gate is closed", file.UnsupportedReason);
    }

    [Fact]
    public void AReadOnlyModuleIsOfferedEvenWithTheGateClosed()
    {
        var registry = new ModuleRegistry(writeEnabled: false).Add(new FakeModule("stat", writes: false));
        Assert.True(registry.Describe().Tools.Single(t => t.Name == "stat").Supported);
    }

    [Fact]
    public void TheListingIsOrderedSoTwoIdenticalAgentsAnswerIdentically()
    {
        var registry = new ModuleRegistry(writeEnabled: true)
            .Add(new FakeModule("stat", false))
            .Add(new FakeModule("copy", false))
            .Add(new FakeModule("find", false));

        Assert.Equal(["copy", "find", "stat"], registry.Describe().Tools.Select(t => t.Name).ToArray());
    }
}

public class TimeBoundTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-08-26T12:00:00Z");

    [Fact]
    public void AnEmptyBoundTakesTheDefault()
    {
        Assert.True(Endpoints.TryParseTimeBound("", Now, TimeSpan.FromHours(-1), out var got, out _));
        Assert.Equal(Now.AddHours(-1), got);
    }

    [Theory]
    [InlineData("1h", -1)]
    [InlineData("24h", -24)]
    public void ARelativeDurationMeansThatLongBeforeNow(string raw, int hours)
    {
        Assert.True(Endpoints.TryParseTimeBound(raw, Now, TimeSpan.Zero, out var got, out _));
        Assert.Equal(Now.AddHours(hours), got);
    }

    [Fact]
    public void AnAbsoluteTimestampIsTakenAsGiven()
    {
        // The poller sends its cursor this way; the relative form is what a hand-driven curl sends. An agent
        // that understood only one would work in exactly one of the two situations it is used in.
        Assert.True(Endpoints.TryParseTimeBound("2026-08-26T09:30:00Z", Now, TimeSpan.Zero, out var got, out _));
        Assert.Equal(DateTimeOffset.Parse("2026-08-26T09:30:00Z"), got);
    }

    [Fact]
    public void NonsenseIsRejectedWithAReason()
    {
        Assert.False(Endpoints.TryParseTimeBound("yesterday", Now, TimeSpan.Zero, out _, out var error));
        Assert.Contains("yesterday", error);
    }

    [Fact]
    public void LabelFiltersAreReadFromTheLabelDotPrefix()
    {
        var got = Endpoints.LabelFilter([
            new("label.mount", "C:"),
            new("from", "1h"),
            new("label.fs", "NTFS"),
        ]);

        Assert.Equal(new Dictionary<string, string> { ["mount"] = "C:", ["fs"] = "NTFS" }, got);
    }
}

public class TlsAuthTests
{
    private static (string Pem, X509Certificate2 Cert) MakeIdentity(string cn)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN={cn}", key, HashAlgorithmName.SHA256);
        var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddHours(-1), DateTimeOffset.UtcNow.AddYears(1));
        var pem = "-----BEGIN PUBLIC KEY-----\n"
                  + Convert.ToBase64String(cert.PublicKey.ExportSubjectPublicKeyInfo(), Base64FormattingOptions.InsertLineBreaks)
                  + "\n-----END PUBLIC KEY-----\n";
        return (pem, cert);
    }

    [Fact]
    public void ThePinnedKeyAuthorisesItsOwnCertificate()
    {
        var (pem, cert) = MakeIdentity("bossman");
        var pins = new[] { TlsAuth.LoadTrustedKeyPem("bossman", pem) };

        Assert.True(TlsAuth.MatchesAny(cert, pins, out var matched));
        Assert.Equal("bossman", matched!.Name);
    }

    [Fact]
    public void AnotherPartysCertificateIsRefused()
    {
        var (pem, _) = MakeIdentity("bossman");
        var (_, stranger) = MakeIdentity("someone-else");

        Assert.False(TlsAuth.MatchesAny(stranger, [TlsAuth.LoadTrustedKeyPem("bossman", pem)], out _));
    }

    [Fact]
    public void AReissuedCertificateAroundTHESAMEKEYStillMatches()
    {
        // The pin is the public key, not the certificate. Bossman may re-issue its cert — a longer validity,
        // a changed subject — around the same key, and pinning the cert would break a rotation that changed
        // nothing about the identity.
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var first = new CertificateRequest("CN=bossman", key, HashAlgorithmName.SHA256)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddHours(-1), DateTimeOffset.UtcNow.AddDays(1));
        var reissued = new CertificateRequest("CN=bossman-2", key, HashAlgorithmName.SHA256)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddHours(-1), DateTimeOffset.UtcNow.AddYears(5));

        var pem = "-----BEGIN PUBLIC KEY-----\n"
                  + Convert.ToBase64String(first.PublicKey.ExportSubjectPublicKeyInfo(), Base64FormattingOptions.InsertLineBreaks)
                  + "\n-----END PUBLIC KEY-----\n";

        Assert.True(TlsAuth.MatchesAny(reissued, [TlsAuth.LoadTrustedKeyPem("bossman", pem)], out _));
    }

    [Fact]
    public void AMalformedPinFailsAtLoadRatherThanOnTheFirstConnection()
    {
        // A bad pin has to be a startup error. Deferred, it becomes a permanent 403 with no explanation.
        Assert.Throws<FormatException>(() => TlsAuth.LoadTrustedKeyPem("bossman", "not a PEM file"));
        Assert.Throws<FormatException>(() => TlsAuth.LoadTrustedKeyPem("bossman",
            "-----BEGIN PUBLIC KEY-----\nZm9v\n-----END PUBLIC KEY-----\n"));
    }

    [Fact]
    public void AnRsaKeyIsAcceptedToo()
    {
        // The fleet's keys are whatever Bossman generated; the comparison is over raw SPKI bytes, so the
        // loader must not be the place that decides an algorithm family.
        using var rsa = RSA.Create(2048);
        var pem = "-----BEGIN PUBLIC KEY-----\n"
                  + Convert.ToBase64String(rsa.ExportSubjectPublicKeyInfo(), Base64FormattingOptions.InsertLineBreaks)
                  + "\n-----END PUBLIC KEY-----\n";

        Assert.Equal("bossman", TlsAuth.LoadTrustedKeyPem("bossman", pem).Name);
    }

    [Fact]
    public void TheServerCertificateIsCreatedOnceAndReused()
    {
        var dir = Path.Combine(Path.GetTempPath(), "agentic-tls-" + Guid.NewGuid().ToString("N"));
        try
        {
            var pfx = Path.Combine(dir, "agent-tls.pfx");
            using var first = TlsAuth.EnsureServerCertificate(pfx, "win-test");
            using var second = TlsAuth.EnsureServerCertificate(pfx, "win-test");

            Assert.Equal(first.Thumbprint, second.Thumbprint);
            Assert.Equal("CN=win-test", first.Subject);
            // Ten years: an expiry nobody renews is an outage scheduled for a date nobody remembers.
            Assert.True(first.NotAfter > DateTime.Now.AddYears(9));
        }
        finally
        {
            if (Directory.Exists(dir))
            {
                Directory.Delete(dir, true);
            }
        }
    }
}
