using System.Text.Json;
using System.Text.Json.Nodes;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The diagnosis contract (configs/schemas/diagnosis.schema.json) from the C# side: the same golden documents the
/// Go and the Python tests read, the same catalogue, the same refusals. There is no compiler between the three
/// implementations — these tests are where a shared type would be.
/// </summary>
public class DiagnosisContractTests
{
    private static string RepoConfigs()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "configs", "schemas")))
            dir = dir.Parent;
        return dir is null ? throw new DirectoryNotFoundException("repo configs/ not found above the test binary")
            : Path.Combine(dir.FullName, "configs");
    }

    public static IEnumerable<object[]> Goldens() =>
        Directory.GetFiles(Path.Combine(RepoConfigs(), "schemas", "diagnosis.examples"), "*.json")
            .Order().Select(f => new object[] { Path.GetFileName(f) });

    private static string Golden(string name) =>
        File.ReadAllText(Path.Combine(RepoConfigs(), "schemas", "diagnosis.examples", name));

    [Fact]
    public void ThereAreGoldensForBothPlatformsAndTheGapCase()
    {
        var names = Goldens().Select(g => (string)g[0]).ToList();
        Assert.Contains("windows-logon-right.json", names);
        Assert.Contains("windows-dependency.json", names);
        Assert.Contains("linux-203-exec.json", names);
        Assert.Contains("unknown-gap.json", names);
    }

    [Theory]
    [MemberData(nameof(Goldens))]
    public void AGoldenRoundTripsThroughTheModelWithoutLosingAField(string name)
    {
        var json = Golden(name);
        var opts = new JsonSerializerOptions { UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow };
        var doc = JsonSerializer.Deserialize<DiagnosisDocument>(json, opts)!;
        var again = JsonSerializer.Serialize(doc);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(json), JsonNode.Parse(again)),
            $"{name}: the C# model does not reproduce the document:\n{again}");
    }

    [Theory]
    [MemberData(nameof(Goldens))]
    public void AGoldenHoldsTheContract(string name)
    {
        var doc = JsonSerializer.Deserialize<DiagnosisDocument>(Golden(name))!;
        Assert.Empty(Validator.Validate(doc));
    }

    [Fact]
    public void TheEmbeddedCatalogueIsTheRepoCatalogue()
    {
        var repo = File.ReadAllBytes(Path.Combine(RepoConfigs(), "diagnosis_rules.json"));
        Assert.True(repo.SequenceEqual(Catalogue.RawBytes()),
            "AgenticMcp.Agent.Diagnosis/rules.json differs from configs/diagnosis_rules.json — copy it");
    }

    private static Builder NewProbe() =>
        new("t1", "bossman-wintest", "windows", new Target { Name = "yoloman-probe", DisplayName = "yoloman probe" },
            new DateTime(2026, 10, 17, 14, 0, 0, DateTimeKind.Utc));

    private static Evidence Status(string id = "scm:status:yoloman-probe") =>
        new() { Id = id, Source = "QueryServiceStatusEx", Fact = "yoloman-probe is stopped.", Raw = new JsonObject() };

    [Theory]
    [InlineData("no evidence", "svc.image_missing", "Proven", "", "without evidence")]
    [InlineData("dangling", "svc.image_missing", "Proven", "scm:status:other", "not recorded")]
    [InlineData("unknown gap", "svc.unexplained", "Unknown", "scm:status:yoloman-probe", "Unknown must name")]
    [InlineData("over-certain", "svc.image_path_unquoted", "Proven", "scm:status:yoloman-probe", "exceeds the rule's maximum Likely")]
    [InlineData("other platform", "svc.oom_killed", "Proven", "scm:status:yoloman-probe", "does not apply to platform windows")]
    [InlineData("unknown rule", "svc.guessed", "Likely", "scm:status:yoloman-probe", "not in the catalogue")]
    public void TheBuilderRefusesWhatTheContractForbids(string _, string rule, string certainty, string evidence, string want)
    {
        var b = NewProbe();
        b.Evidence(Status());
        var why = b.Find(new Finding
        {
            RuleId = rule, Certainty = certainty, Claim = "x",
            EvidenceIds = evidence == "" ? [] : [evidence],
        });
        Assert.NotNull(why);
        Assert.Contains(want, why);
        Assert.Throws<DiagnosisContractException>(() => b.Build(Diagnosis.Status.Stopped));
    }

    [Fact]
    public void APrecedentAloneIsNoCause()
    {
        var b = NewProbe();
        var id = b.Evidence(Status());
        var why = b.Find(new Finding
        {
            RuleId = "svc.disabled", Certainty = Certainty.Proven, Claim = "x", EvidenceIds = [id],
            Precedent = new Precedent { EvidenceId = id, Change = "c", Observed = DateTime.UtcNow },
        });
        Assert.Contains("correlation, not a cause", why);
    }

    [Fact]
    public void AStoppedServiceWithoutFindingDoesNotBuild_UnexplainedDoes()
    {
        var b = NewProbe();
        b.Evidence(Status());
        var ex = Assert.Throws<DiagnosisContractException>(() => b.Build(Diagnosis.Status.Stopped));
        Assert.Contains(ex.Problems, p => p.Contains("svc.unexplained"));

        var b2 = NewProbe();
        var id = b2.Evidence(Status());
        Assert.Null(b2.Unexplained([id], "no event since the log rolled over"));
        var doc = b2.Build(Diagnosis.Status.Stopped);
        Assert.Equal(Certainty.Unknown, doc.Findings[0].Certainty);
    }

    [Fact]
    public void FindingsAreOrderedByTheCatalogueAndTheSummaryIsTheLeadingClaim()
    {
        var b = NewProbe();
        var id = b.Evidence(Status());
        b.Find(new Finding { RuleId = "svc.exits_immediately", Certainty = Certainty.Proven, Claim = "exits", EvidenceIds = [id] });
        b.Find(new Finding { RuleId = "svc.dependency_failed", Certainty = Certainty.Proven, Claim = "dependency", EvidenceIds = [id] });
        var doc = b.Build(Diagnosis.Status.Stopped);
        Assert.Equal("svc.dependency_failed", doc.Findings[0].RuleId);
        Assert.Equal("dependency", doc.Summary);
    }

    [Fact]
    public void WhatTheBuilderWritesReadsBackAsTheSameDocument()
    {
        var b = NewProbe();
        var id = b.Evidence(new Evidence
        {
            Id = "evt:System:7000:1", Source = "EventLog/System", Observed = new DateTime(2026, 10, 17, 13, 59, 0, DateTimeKind.Utc),
            Fact = "event 7000", Raw = JsonNode.Parse("""{"event_id":7000}"""),
        });
        b.Find(new Finding { RuleId = "svc.image_missing", Certainty = Certainty.Proven, Claim = "missing", EvidenceIds = [id] });
        var json = JsonSerializer.Serialize(b.Build(Diagnosis.Status.Stopped));
        Assert.Contains("\"observed\":\"2026-10-17T13:59:00Z\"", json);
        Assert.Contains("\"precedent\":null", json);
        Assert.Contains("\"display_name\":\"yoloman probe\"", json);
        Assert.Empty(Validator.Validate(JsonSerializer.Deserialize<DiagnosisDocument>(json)!));
    }
}
