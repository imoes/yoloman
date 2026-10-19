using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Diagnosis;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>update_diagnose</c> — why is this host behind on updates, or why did an update fail? Returns a Diagnosis document
/// (the shared contract configs/schemas/diagnosis.schema.json, target kind "updates"), the same shape service_diagnose
/// returns.
///
/// <para>READ-ONLY and deterministic: it reads the SAME windows_update_facts data (the Windows Update Agent COM API,
/// no new measurement) and applies the `upd.` rules of configs/diagnosis_rules.json — a failed install with its
/// HRESULT, a pending reboot that blocks installs, a WSUS that did not answer, how far behind the host is. Remedies in
/// the result are data for Bossman to propose, never run here. Offered with the write gate closed.</para>
/// </summary>
public sealed class UpdateDiagnoseModule : IModule
{
    public string Name => "update_diagnose";

    public string Description =>
        "Explain why a host is behind on updates or why an update failed. Returns a Diagnosis (the same contract as " +
        "service_diagnose, target kind \"updates\"): EVIDENCE from windows_update_facts (the last search, the pending " +
        "list, the update history with ResultCode and HRESULT in Windows' own words, a pending reboot), FINDINGS (a " +
        "rule from configs/diagnosis_rules.json — upd.install_failed, upd.reboot_pending, upd.wsus_unreachable, " +
        "upd.behind, upd.up_to_date — a claim, a certainty, the evidence ids), a timeline and named gaps. Deterministic " +
        "and read-only: no model, nothing changed.\n\n" +
        "Parameters: include_snapshot (also return the snapshot the rules saw).\n\n" +
        "Cross-tool equivalents:\n- Ansible: none — win_updates reports/installs, it does not explain.\n" +
        "- PowerShell: PSWindowsUpdate reports pending updates; it does not diagnose a failure.";

    public IReadOnlyDictionary<string, object> InputSchema { get; } = new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["include_snapshot"] = new Dictionary<string, object> { ["type"] = "boolean", ["default"] = false, ["description"] = "Also return the snapshot the rules evaluated." },
        },
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("update_diagnose asks the Windows Update Agent; on Linux the Go agent's module of the same name answers from apt/dnf.");
        var withSnapshot = parameters.TryGetValue("include_snapshot", out var w) && w switch
        {
            bool b => b,
            string s => bool.TryParse(s, out var parsed) && parsed,
            System.Text.Json.JsonElement je => je.ValueKind == System.Text.Json.JsonValueKind.True,
            _ => false,
        };
        // The SAME read-only collection windows_update_facts does — a search against the Windows Update Agent.
        var answer = await WindowsPowerShellBridge.RunJson(WindowsUpdateFactsModule.Setup, WindowsUpdateFactsModule.Expression, TimeSpan.FromMinutes(10), ct);
        var facts = WindowsUpdateFacts.Interpret(answer.Items.FirstOrDefault());
        var host = Environment.MachineName;
        var snap = UpdateRules.FromFacts(facts, host, DateTime.UtcNow);
        var doc = UpdateRules.Diagnose(snap, Guid.NewGuid().ToString("N"), host);
        var data = new Dictionary<string, object?> { ["diagnosis"] = doc };
        if (withSnapshot) data["snapshot"] = snap;
        return new ModuleResult(false, doc.Summary, data,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = 1 });
    }
}
