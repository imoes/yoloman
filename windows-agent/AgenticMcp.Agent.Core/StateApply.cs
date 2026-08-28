using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// The document-loop contract: <c>POST /api/v1/state/apply</c>, field for field as the Go agent's
/// <c>internal/state</c> declares it.
///
/// <para>This is the path a real config change takes, and the reason it exists instead of an ad-hoc module
/// call: what goes through here is diffable, versioned and roll-backable, and Bossman records it as the
/// host's DECLARED state. A tool call changes a host; this declares what the host should be.</para>
///
/// <para>Names copied from Go (<c>type</c>, <c>path</c>, <c>format</c>, <c>values</c>, <c>action</c>,
/// <c>changed_count</c>) — a renamed field here is a field Bossman stops reading, and there is no compiler
/// between the two implementations.</para>
/// </summary>
public sealed record StateResource(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("format")] string? Format,
    [property: JsonPropertyName("values")] Dictionary<string, System.Text.Json.JsonElement>? Values);

public sealed record StateDocument(
    [property: JsonPropertyName("resources")] List<StateResource>? Resources,
    [property: JsonPropertyName("dry_run")] bool DryRun);

/// <summary>
/// What happened to one resource. <c>action</c> is <c>create | update | noop</c> — the same three words the
/// Go agent uses, so a diff view does not need to know which agent answered.
/// </summary>
public sealed record ResourceChange(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("action")] string Action,
    [property: JsonPropertyName("changed")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    Dictionary<string, object?[]>? Changed,
    [property: JsonPropertyName("error")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Error);

public sealed record StateApplyResult(
    [property: JsonPropertyName("changes")] List<ResourceChange> Changes,
    [property: JsonPropertyName("changed_count")] int ChangedCount,
    [property: JsonPropertyName("dry_run")] bool DryRun);
