using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Diagnosis;

/// <summary>One entry of the rule catalogue (configs/diagnosis_rules.json).</summary>
public sealed class Rule
{
    [JsonPropertyName("order")] public int Order { get; set; }
    [JsonPropertyName("platforms")] public List<string> Platforms { get; set; } = [];
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("certainty")] public string Certainty { get; set; } = "";
    [JsonPropertyName("remedy_kinds")] public List<string> RemedyKinds { get; set; } = [];
}

public static class Catalogue
{
    private static readonly Lazy<IReadOnlyDictionary<string, Rule>> Rules = new(Load);

    /// <summary>The embedded catalogue, byte-identical to configs/diagnosis_rules.json (a test keeps it so).</summary>
    public static IReadOnlyDictionary<string, Rule> All => Rules.Value;

    public static byte[] RawBytes()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("diagnosis_rules.json")
                      ?? throw new InvalidOperationException("diagnosis: the rule catalogue is not embedded");
        using var m = new MemoryStream();
        s.CopyTo(m);
        return m.ToArray();
    }

    private static IReadOnlyDictionary<string, Rule> Load()
    {
        using var doc = JsonDocument.Parse(RawBytes());
        return doc.RootElement.GetProperty("rules").Deserialize<Dictionary<string, Rule>>()
               ?? throw new InvalidOperationException("diagnosis: empty rule catalogue");
    }
}

/// <summary>Raised by <see cref="Builder.Build"/> when anything was refused on the way — the document would not hold.</summary>
public sealed class DiagnosisContractException(IReadOnlyList<string> problems)
    : Exception("diagnosis: contract violations: " + string.Join("; ", problems))
{
    public IReadOnlyList<string> Problems { get; } = problems;
}

/// <summary>
/// Assembles a diagnosis and refuses anything the contract forbids at the moment it is added — the twin of the Go
/// builder (internal/diagnosis/builder.go), so a rule that tries to claim without evidence fails in its own test.
/// </summary>
public sealed class Builder
{
    private readonly DiagnosisDocument _d;
    private readonly IReadOnlyDictionary<string, Rule> _rules = Catalogue.All;
    private readonly HashSet<string> _ids = [];
    private readonly List<string> _refused = [];
    private readonly List<(string Id, string What, DateTime At, bool HostWide)> _changes = [];

    /// <summary>
    /// How far back a change may lie and still be offered as a finding's precedent. An older change stays on the
    /// timeline; after a week nearly everything on a host has changed once. Same window as the Go agent.
    /// </summary>
    public static readonly TimeSpan PrecedentWindow = TimeSpan.FromDays(7);

    public Builder(string id, string host, string platform, Target target, DateTime collectedAt)
    {
        if (platform is not ("windows" or "linux")) throw new ArgumentException($"diagnosis: unknown platform {platform}");
        _d = new DiagnosisDocument
        {
            DiagnosisId = id, Host = host, Platform = platform, Target = target, CollectedAt = Second(collectedAt),
        };
    }

    /// <summary>
    /// The locator part of an evidence id with whitespace percent-encoded: ids are whitespace-free by contract, and a
    /// Windows path is "C:\Program Files\…". Same rule as the Go agent's diagnosis.Key.
    /// </summary>
    public static string Key(string locator) => System.Text.RegularExpressions.Regex.Replace(locator, @"\s", m => "%" + ((int)m.Value[0]).ToString("X2"));

    public static DateTime Second(DateTime t)
    {
        var u = t.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(t, DateTimeKind.Utc) : t.ToUniversalTime();
        return new DateTime(u.Ticks - u.Ticks % TimeSpan.TicksPerSecond, DateTimeKind.Utc);
    }

    /// <summary>Records one measurement; a second evidence with the same id is refused.</summary>
    public string Evidence(Evidence e)
    {
        if (string.IsNullOrEmpty(e.Id) || !e.Id.Contains(':') || string.IsNullOrEmpty(e.Source) || string.IsNullOrEmpty(e.Fact))
        {
            _refused.Add($"evidence {e.Id}: id (source:locator), source and fact are required");
            return e.Id;
        }
        if (!_ids.Add(e.Id))
        {
            _refused.Add($"evidence {e.Id} recorded twice");
            return e.Id;
        }
        if (e.Observed is { } o) e.Observed = Second(o);
        _d.Evidence.Add(e);
        return e.Id;
    }

    public bool Has(string id) => _ids.Contains(id);

    /// <summary>Adds a finding, or refuses it; returns the reason, null when accepted.</summary>
    public string? Find(Finding f)
    {
        var why = Check(f);
        if (why is not null)
        {
            _refused.Add(why);
            return why;
        }
        if (f.Precedent is { } p) p.Observed = Second(p.Observed);
        _d.Findings.Add(f);
        return null;
    }

    public string? Unexplained(List<string> evidenceIds, string gap) => Find(new Finding
    {
        RuleId = "svc.unexplained", Certainty = Diagnosis.Certainty.Unknown, EvidenceIds = evidenceIds, Gap = gap,
        Claim = $"{_d.Target.Name} is not running and no rule explains why.",
    });

    /// <summary>
    /// Offers a recorded evidence as a candidate precedent: what changed, and when. hostWide marks a change of the host
    /// (an update, a product install) rather than of the service itself or its dependencies (its key, its image).
    /// </summary>
    public void Change(string evidenceId, string what, DateTime at, bool hostWide)
    {
        if (!Has(evidenceId)) { _refused.Add($"change {evidenceId}: evidence was not recorded"); return; }
        _changes.Add((evidenceId, what, Second(at), hostWide));
    }

    /// <summary>
    /// Gives every finding without one the most recent change at or before failedAt within <see cref="PrecedentWindow"/>
    /// — a change of the target when there is one, otherwise of the host. Nothing changed in that window: no precedent.
    /// </summary>
    public void Precede(DateTime failedAt)
    {
        failedAt = Second(failedAt);
        (string Id, string What, DateTime At, bool HostWide)? Pick(bool hostWide)
        {
            (string Id, string What, DateTime At, bool HostWide)? best = null;
            foreach (var c in _changes)
                if (c.HostWide == hostWide && c.At <= failedAt && failedAt - c.At <= PrecedentWindow && (best is null || c.At > best.Value.At))
                    best = c;
            return best;
        }
        if ((Pick(false) ?? Pick(true)) is not { } ch) return;
        foreach (var f in _d.Findings)
        {
            if (f.Precedent is not null || (f.EvidenceIds.Count == 1 && f.EvidenceIds[0] == ch.Id)) continue;
            f.Precedent = new Precedent { EvidenceId = ch.Id, Change = ch.What, Observed = ch.At, GapSeconds = (long)(failedAt - ch.At).TotalSeconds };
        }
    }

    public void Gap(string what, string why) => _d.Gaps.Add(new Gap { What = what, Why = why });

    private string? Check(Finding f)
    {
        if (!_rules.TryGetValue(f.RuleId, out var rule)) return $"finding {f.RuleId}: rule is not in the catalogue";
        if (!rule.Platforms.Contains(_d.Platform)) return $"finding {f.RuleId}: rule does not apply to platform {_d.Platform}";
        if (string.IsNullOrEmpty(f.Claim)) return $"finding {f.RuleId}: a finding states its claim";
        if (f.EvidenceIds.Count == 0) return $"finding {f.RuleId}: a claim without evidence is not a finding";
        if (Diagnosis.Certainty.Rank(f.Certainty) < 0) return $"finding {f.RuleId}: unknown certainty {f.Certainty}";
        if (Diagnosis.Certainty.Rank(f.Certainty) > Diagnosis.Certainty.Rank(rule.Certainty))
            return $"finding {f.RuleId}: certainty {f.Certainty} exceeds the rule's maximum {rule.Certainty}";
        if (f.Certainty == Diagnosis.Certainty.Unknown && string.IsNullOrEmpty(f.Gap))
            return $"finding {f.RuleId}: Unknown must name what could not be measured";
        foreach (var id in f.EvidenceIds)
            if (!Has(id)) return $"finding {f.RuleId}: cites evidence that was not recorded: {id}";
        if (f.Precedent is { } p)
        {
            if (!Has(p.EvidenceId)) return $"finding {f.RuleId}: precedent cites evidence that was not recorded: {p.EvidenceId}";
            if (f.EvidenceIds.Count == 1 && f.EvidenceIds[0] == p.EvidenceId)
                return $"finding {f.RuleId}: the only evidence is the precedent — a preceding change is a correlation, not a cause";
        }
        if (f.Remedy is { } r && !rule.RemedyKinds.Contains(r.Target.Kind))
            return $"finding {f.RuleId}: remedy kind {r.Target.Kind} is not one the rule offers";
        return null;
    }

    /// <summary>Orders findings by the catalogue, derives timeline and summary, checks the whole document.</summary>
    public DiagnosisDocument Build(string status)
    {
        _d.Status = status;
        var ordered = _d.Findings.Select((f, i) => (f, i))
            .OrderBy(x => _rules[x.f.RuleId].Order).ThenBy(x => x.i).Select(x => x.f).ToList();
        _d.Findings = ordered;
        _d.Timeline = _d.Evidence.Where(e => e.Observed is not null).Select((e, i) => (e, i))
            .OrderBy(x => x.e.Observed).ThenBy(x => x.i)
            .Select(x => new TimelineEntry { Observed = x.e.Observed!.Value, EvidenceId = x.e.Id }).ToList();
        _d.Summary = _d.Findings.Count > 0 ? _d.Findings[0].Claim
            : status == Diagnosis.Status.Running ? $"{_d.Target.Name} is running." : $"{_d.Target.Name} is {status}.";
        var problems = _refused.Concat(Validator.Validate(_d)).ToList();
        if (problems.Count > 0) throw new DiagnosisContractException(problems);
        return _d;
    }
}
