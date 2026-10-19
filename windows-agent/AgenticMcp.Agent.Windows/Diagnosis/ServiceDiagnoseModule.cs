using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// <c>service_diagnose</c> — why does this Windows service not start? Returns a Diagnosis document (the contract
/// configs/schemas/diagnosis.schema.json, the same shape the Linux agent's module of the same name returns).
///
/// <para>READ-ONLY and deterministic: it reads the service control manager and the event log, applies the rules of
/// configs/diagnosis_rules.json and changes nothing. Remedies in the result are data for Bossman to propose, never
/// executed here. Offered with the write gate closed — asking why something fails must never need the right to
/// change it.</para>
/// </summary>
public sealed class ServiceDiagnoseModule : IModule
{
    // The incident ring (docs/etw-ringbuffer-plan.md), filled by the ETW session. Null when no ring is wired (tests,
    // or a build without the collector); then the diagnosis simply has no past-incident history.
    private readonly IncidentRing? _incidents;

    public ServiceDiagnoseModule(IncidentRing? incidents = null) => _incidents = incidents;

    public string Name => "service_diagnose";

    public string Description =>
        "Explain why a Windows service does not start. Returns a Diagnosis: EVIDENCE (each measurement with a stable id — " +
        "scm:config:<name>, scm:status:<name>, evt:System:<event id>:<record id>, file:stat:<image>), FINDINGS (a rule from " +
        "configs/diagnosis_rules.json, a claim, a certainty Proven/Likely/Unknown, the evidence ids it rests on), a timeline " +
        "and named gaps. Deterministic and read-only: no model is involved and nothing is changed. A service that is not " +
        "running always gets a finding — svc.unexplained (Unknown, naming what could not be measured) when no rule matches. " +
        "Rules: no such service, disabled, image missing, unquoted image path, account missing, logon failed (disabled, " +
        "locked, expired, wrong password), log-on-as-a-service right missing, failed dependency (the deepest broken link, " +
        "load-order groups resolved), timeout, crash (with the application error), the service's own exit code, stopped " +
        "cleanly. Events are read by id and EventData, never by the (localized) message text.\n\n" +
        "Parameters: name (the service's key name, e.g. \"Spooler\"), include_snapshot (also return what the rules saw).\n\n" +
        "Cross-tool equivalents:\n" +
        "- Ansible: none — win_service reports state, not cause.\n" +
        "- DSC: none; a Service resource converges a state, it does not explain a failure.";

    public IReadOnlyDictionary<string, object> InputSchema { get; } = new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object> { ["type"] = "string", ["description"] = "The service's key name, e.g. \"Spooler\"." },
            ["include_snapshot"] = new Dictionary<string, object> { ["type"] = "boolean", ["default"] = false, ["description"] = "Also return the snapshot the rules evaluated." },
        },
        ["required"] = new[] { "name" },
    };

    public bool Writes => false;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var name = (parameters.TryGetValue("name", out var n) ? Convert.ToString(n) : null)?.Trim() ?? "";
        if (name.Length == 0 || name.IndexOfAny(['\\', '/', '"']) >= 0)
            throw new ArgumentException($"service_diagnose: '{name}' is not a service name");
        var withSnapshot = parameters.TryGetValue("include_snapshot", out var w) && w switch
        {
            bool b => b,
            string s => bool.TryParse(s, out var parsed) && parsed,
            System.Text.Json.JsonElement je => je.ValueKind == System.Text.Json.JsonValueKind.True,
            _ => false,
        };
        var snap = ScmCollector.Collect(name, DateTime.UtcNow);
        // Past incidents for THIS image — filtered by image, not pid: a service that crashed and restarted ran under a
        // different pid, so the dead invocation is found by its executable, newest first, a few at most.
        if (_incidents is not null && snap.Image?.Path is { Length: > 0 } image)
            snap.RecentIncidents = _incidents.Recent(image: image).Take(10).ToList();
        var doc = WindowsRules.Diagnose(snap, Guid.NewGuid().ToString("N"), Environment.MachineName);
        var data = new Dictionary<string, object?> { ["diagnosis"] = doc };
        if (withSnapshot) data["snapshot"] = snap;
        return Task.FromResult(new ModuleResult(false, doc.Summary, data,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = 1 }));
    }
}
