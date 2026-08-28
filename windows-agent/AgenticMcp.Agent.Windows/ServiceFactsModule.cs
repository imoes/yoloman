using System.Management;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// EVERY SERVICE ON THIS HOST, under the name Bossman already asks for (<c>service_facts</c>) and in a shape
/// the Services screen can render without knowing which agent answered.
///
/// <para>WHY IT EXISTS: Bossman's per-host Services panel calls `service_facts` and renders `data`. On a
/// Windows host the call 502'd, so the panel was empty — the same class of gap `package_facts` had, found the
/// same way (comparing every module Bossman calls against what this agent lists, after the result log showed
/// the first one).</para>
///
/// <para>THE FIELD NAMES ARE THE GO AGENT'S, deliberately, INCLUDING the systemd words: `unit`, `load`,
/// `active`, `sub`. That looks wrong for Windows until you look at the alternative — a Windows-shaped list
/// means the Services screen needs two renderers and every consumer has to branch on the OS. So the systemd
/// vocabulary is treated as the fleet's INTERFACE and Windows' own answer travels beside it under its own
/// names (`start_mode`, `status`, `pid`, `start_name`), never mapped away:
///   active  = running | stopped        (Windows State, lower-cased — one word, same question)
///   sub     = Windows' State verbatim  (Running, Stopped, StartPending, …)
///   load    = "loaded", always         (a Windows service exists in the SCM or it does not)
///   enabled = auto | manual | disabled (from StartMode — the closest true statement, not a boolean)
/// `enabled` is NOT a boolean here for the same reason `install_state` is not: Windows has Auto,
/// Auto (Delayed Start), Manual, Disabled and Boot/System, and "true" would erase four of them.</para>
/// </summary>
public sealed class ServiceFactsModule : IModule
{
    public string Name => "service_facts";

    public string Description =>
        "Every service registered with the Windows service control manager: name, display name, whether it is "
        + "running, its start mode, its PID and the account it runs as. Takes no parameters and returns them "
        + "all; filter client-side. The Windows counterpart of the Linux agent's systemd service_facts, with "
        + "the same field names (unit/name/load/active/sub/enabled) so one Services view renders either host, "
        + "plus Windows' own words (status, start_mode, pid, start_name) beside them. Read-only — starting and "
        + "stopping is the `service` module.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>(),
    };

    public bool Writes => false;

    /// <summary>StartMode → the fleet's `enabled` word. Windows' six start modes collapse to three states an
    /// operator acts on, and the untouched original stays in `start_mode` for anyone who needs the rest.</summary>
    private static string EnabledFrom(string? startMode) => (startMode ?? "").ToLowerInvariant() switch
    {
        "auto" => "auto",
        "manual" => "manual",
        "disabled" => "disabled",
        // Boot and System are driver start modes; naming them "auto" would be a small lie that a driver list
        // would then repeat. Passed through instead.
        "" => "unknown",
        var other => other,
    };

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                       CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "service_facts (this implementation) reads the Windows service control manager; on Linux the "
                + "Go agent's systemd implementation answers the same name.");
        }

        var services = new List<Dictionary<string, object?>>();
        // WMI rather than Get-Service: one query returns start mode, PID and the run-as account together,
        // which Get-Service does not, and it costs no PowerShell process. Measured on the test host: 240
        // services in ~0.4 s.
        using var searcher = new ManagementObjectSearcher(
            "SELECT Name, DisplayName, State, StartMode, ProcessId, StartName, PathName, Description "
            + "FROM Win32_Service");
        foreach (var row in searcher.Get())
        {
            ct.ThrowIfCancellationRequested();
            using var svc = (ManagementObject)row;
            var state = svc["State"] as string ?? "";
            var name = svc["Name"] as string ?? "";
            services.Add(new Dictionary<string, object?>
            {
                // The fleet's interface, spelled the systemd way so one view renders either host.
                ["unit"] = name,
                ["name"] = name,
                ["load"] = "loaded",
                ["active"] = state.Equals("Running", StringComparison.OrdinalIgnoreCase) ? "running" : "stopped",
                ["sub"] = state,
                ["enabled"] = EnabledFrom(svc["StartMode"] as string),
                // Windows' own answer, beside it rather than instead of it.
                ["display_name"] = svc["DisplayName"] as string,
                ["status"] = state,
                ["start_mode"] = svc["StartMode"] as string,
                ["pid"] = svc["ProcessId"] is uint pid && pid != 0 ? pid : null,
                ["start_name"] = svc["StartName"] as string,
                ["description"] = svc["Description"] as string,
            });
        }

        services.Sort((a, b) => string.Compare(a["name"] as string, b["name"] as string,
                                               StringComparison.OrdinalIgnoreCase));
        var running = services.Count(s => (string?)s["active"] == "running");
        return Task.FromResult(new ModuleResult(
            false,
            $"{services.Count} service(s), {running} running, {services.Count - running} stopped",
            services,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = services.Count }));
    }
}
