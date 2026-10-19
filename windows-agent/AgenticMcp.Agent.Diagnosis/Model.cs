using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Diagnosis;

// The contract configs/schemas/diagnosis.schema.json as C# types — field for field the Go model
// (internal/diagnosis/model.go). Every key is always written, null included: the contract requires the keys, and a
// missing key is a different document. DiagnosisContractTests round-trips the golden documents through these types.

public static class Certainty
{
    public const string Proven = "Proven";
    public const string Likely = "Likely";
    public const string Unknown = "Unknown";

    internal static int Rank(string c) => c switch { Proven => 2, Likely => 1, Unknown => 0, _ => -1 };
}

public static class Status
{
    public const string Running = "running";
    public const string Stopped = "stopped";
    public const string Failed = "failed";
    public const string Starting = "starting";
    public const string NotFound = "not-found";
    public const string Unknown = "unknown";
    // The updates target's states: up-to-date (nothing pending) or behind (updates pending / a failure).
    public const string UpToDate = "up-to-date";
    public const string Behind = "behind";
}

public sealed class Target
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "service";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("display_name")] public string? DisplayName { get; set; }
}

public sealed class Evidence
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("source")] public string Source { get; set; } = "";
    [JsonPropertyName("observed")] public DateTime? Observed { get; set; }
    [JsonPropertyName("fact")] public string Fact { get; set; } = "";
    [JsonPropertyName("raw")] public JsonNode? Raw { get; set; }
}

public sealed class Precedent
{
    [JsonPropertyName("evidence_id")] public string EvidenceId { get; set; } = "";
    [JsonPropertyName("change")] public string Change { get; set; } = "";
    [JsonPropertyName("observed")] public DateTime Observed { get; set; }
    [JsonPropertyName("gap_seconds")] public long GapSeconds { get; set; }
}

public sealed class RemedyTarget
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("attribute")] public string? Attribute { get; set; }
}

public sealed class Rollback
{
    [JsonPropertyName("action")] public string Action { get; set; } = "";
    [JsonPropertyName("value")] public JsonNode? Value { get; set; }
}

public sealed class Verify
{
    [JsonPropertyName("rule_absent")] public string RuleAbsent { get; set; } = "";
    [JsonPropertyName("expect")] public JsonNode? Expect { get; set; }
}

public sealed class Remedy
{
    [JsonPropertyName("action")] public string Action { get; set; } = "";
    [JsonPropertyName("target")] public RemedyTarget Target { get; set; } = new();
    [JsonPropertyName("before")] public JsonNode? Before { get; set; }
    [JsonPropertyName("after")] public JsonNode? After { get; set; }
    [JsonPropertyName("rollback")] public Rollback Rollback { get; set; } = new();
    [JsonPropertyName("verify")] public Verify Verify { get; set; } = new();
}

public sealed class Finding
{
    [JsonPropertyName("rule_id")] public string RuleId { get; set; } = "";
    [JsonPropertyName("claim")] public string Claim { get; set; } = "";
    [JsonPropertyName("certainty")] public string Certainty { get; set; } = "";
    [JsonPropertyName("evidence_ids")] public List<string> EvidenceIds { get; set; } = [];
    [JsonPropertyName("precedent")] public Precedent? Precedent { get; set; }
    [JsonPropertyName("remedy")] public Remedy? Remedy { get; set; }
    [JsonPropertyName("gap")] public string? Gap { get; set; }
}

public sealed class TimelineEntry
{
    [JsonPropertyName("observed")] public DateTime Observed { get; set; }
    [JsonPropertyName("evidence_id")] public string EvidenceId { get; set; } = "";
}

public sealed class Gap
{
    [JsonPropertyName("what")] public string What { get; set; } = "";
    [JsonPropertyName("why")] public string Why { get; set; } = "";
}

public sealed class DiagnosisDocument
{
    public const string SchemaId = "yoloman.diagnosis/v1";

    [JsonPropertyName("schema")] public string Schema { get; set; } = SchemaId;
    [JsonPropertyName("diagnosis_id")] public string DiagnosisId { get; set; } = "";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("platform")] public string Platform { get; set; } = "";
    [JsonPropertyName("target")] public Target Target { get; set; } = new();
    [JsonPropertyName("collected_at")] public DateTime CollectedAt { get; set; }
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("evidence")] public List<Evidence> Evidence { get; set; } = [];
    [JsonPropertyName("findings")] public List<Finding> Findings { get; set; } = [];
    [JsonPropertyName("timeline")] public List<TimelineEntry> Timeline { get; set; } = [];
    [JsonPropertyName("gaps")] public List<Gap> Gaps { get; set; } = [];
}
