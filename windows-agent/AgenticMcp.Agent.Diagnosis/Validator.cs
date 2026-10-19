namespace AgenticMcp.Agent.Diagnosis;

/// <summary>
/// The document check of bossman/bossman/services/diagnosis_contract.py and internal/diagnosis/validate.go, in C#:
/// everything the JSON schema cannot express. Each violation is a sentence; an empty list means the document holds.
/// </summary>
public static class Validator
{
    public static List<string> Validate(DiagnosisDocument d)
    {
        var rules = Catalogue.All;
        var output = new List<string>();
        if (d.Schema != DiagnosisDocument.SchemaId) output.Add($"schema is {d.Schema}, want {DiagnosisDocument.SchemaId}");
        var ev = new Dictionary<string, Evidence>();
        foreach (var e in d.Evidence)
            if (!ev.TryAdd(e.Id, e)) output.Add($"evidence id {e.Id} is not unique");
        for (var i = 0; i < d.Findings.Count; i++)
        {
            var f = d.Findings[i];
            var where = $"findings/{i} ({f.RuleId})";
            if (!rules.TryGetValue(f.RuleId, out var rule))
            {
                output.Add(where + ": rule is not in configs/diagnosis_rules.json");
                continue;
            }
            if (!rule.Platforms.Contains(d.Platform)) output.Add($"{where}: rule does not apply to platform {d.Platform}");
            if (Certainty.Rank(f.Certainty) > Certainty.Rank(rule.Certainty))
                output.Add($"{where}: certainty {f.Certainty} exceeds the rule's maximum {rule.Certainty}");
            if (f.EvidenceIds.Count == 0) output.Add(where + ": a claim without evidence is not a finding");
            foreach (var id in f.EvidenceIds.Where(id => !ev.ContainsKey(id)))
                output.Add($"{where}: cites evidence that is not in the diagnosis: {id}");
            if (f.Certainty == Certainty.Unknown && string.IsNullOrEmpty(f.Gap))
                output.Add(where + ": Unknown must name what could not be measured");
            if (f.Precedent is { } p)
            {
                if (!ev.ContainsKey(p.EvidenceId))
                    output.Add($"{where}: precedent cites evidence that is not in the diagnosis: {p.EvidenceId}");
                if (f.EvidenceIds.Count == 1 && f.EvidenceIds[0] == p.EvidenceId)
                    output.Add(where + ": the only evidence is the precedent — a preceding change is a correlation, not a cause");
            }
            if (f.Remedy is { } r && !rule.RemedyKinds.Contains(r.Target.Kind))
                output.Add($"{where}: remedy kind {r.Target.Kind} is not one the rule offers");
        }
        switch (d.Status)
        {
            case Status.Stopped or Status.Failed or Status.NotFound or Status.Unknown or Status.Behind when d.Findings.Count == 0:
                output.Add($"status is {d.Status} but there is no finding — svc.unexplained / upd.unexplained (Unknown, with the gap) is the finding for 'no rule matched'");
                break;
            case Status.Running or Status.Starting or Status.Stopped or Status.Failed or Status.NotFound or Status.Unknown or Status.UpToDate or Status.Behind:
                break;
            default:
                output.Add($"status {d.Status} is not a contract status");
                break;
        }
        var timed = d.Evidence.Where(e => e.Observed is not null).Select(e => e.Id).Order().ToList();
        var listed = d.Timeline.Select(t => t.EvidenceId).Order().ToList();
        for (var i = 1; i < d.Timeline.Count; i++)
            if (d.Timeline[i].Observed < d.Timeline[i - 1].Observed) output.Add("timeline is not in time order");
        foreach (var t in d.Timeline)
            if (ev.TryGetValue(t.EvidenceId, out var e) && e.Observed is { } o && o != t.Observed)
                output.Add($"timeline entry {t.EvidenceId} has another time than its evidence");
        if (!timed.SequenceEqual(listed)) output.Add("timeline must list exactly the evidence that has an observed time");
        return output;
    }
}
