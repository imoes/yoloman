using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// The JSON shapes Bossman already speaks. Every name here is copied from the Go agent's own structs —
/// <c>internal/server/metrics.go</c> (MetricPoint, MetricsDumpOutput), <c>internal/enroll/enroll.go</c>
/// (Request, Response) — because this agent is a second implementation of ONE contract, not a second
/// contract. A field renamed here is a field Bossman silently stops reading.
/// </summary>
public sealed record MetricPoint(
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("value")] double Value,
    [property: JsonPropertyName("labels")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyDictionary<string, string>? Labels);

/// <summary>GET /api/v1/metrics — every metric in one reply, the shape the poller pulls.</summary>
public sealed record MetricsDump(
    [property: JsonPropertyName("metrics")] IReadOnlyDictionary<string, IReadOnlyList<MetricPoint>> Metrics);

/// <summary>GET /api/v1/metrics/{metric}.</summary>
public sealed record MetricsQueryResult(
    [property: JsonPropertyName("points")] IReadOnlyList<MetricPoint> Points);

/// <summary>
/// One entry of GET /api/v1/tools.
///
/// <para><c>Supported</c> and <c>UnsupportedReason</c> are the Windows agent's addition to the shape, and
/// they are the whole point of the listing: a module Windows cannot implement is listed as unsupported WITH
/// a reason rather than omitted. An omission is indistinguishable from an old agent that never had the
/// module — the operator and the LLM both need "no, and here is why", which is a state; "nothing" is not.
/// Bossman ignores unknown fields, so adding them costs the Go agent nothing.</para>
/// </summary>
public sealed record ToolInfo(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("input_schema")] IReadOnlyDictionary<string, object> InputSchema,
    [property: JsonPropertyName("writes")] bool Writes,
    [property: JsonPropertyName("supported")] bool Supported = true,
    [property: JsonPropertyName("unsupported_reason")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? UnsupportedReason = null);

public sealed record ToolsResponse(
    [property: JsonPropertyName("tools")] IReadOnlyList<ToolInfo> Tools);

/// <summary>POST /api/v1/enroll, as this agent sends it (internal/enroll/enroll.go's Request).</summary>
public sealed record EnrollRequest(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("address")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Address,
    [property: JsonPropertyName("enroll_secret")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? EnrollSecret);

/// <summary>Bossman's reply to a successful enrolment.</summary>
public sealed record EnrollResponse(
    [property: JsonPropertyName("bossman_public_key")] string? BossmanPublicKey,
    [property: JsonPropertyName("agent_id")] string? AgentId);
