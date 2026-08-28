using System.Text.Json;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_capability</c> — the DISM side of "install a part of Windows": **capabilities** (RSAT tools,
/// OpenSSH, language features) and **optional features** (SMB1, Telnet client, .NET 3.5).
///
/// <para>WHY THIS IS NOT <c>windows_feature</c>, and why merging them would be the identity error this
/// project keeps finding: they are three different inventories with three different verbs, and Windows itself
/// keeps them apart.</para>
///
/// <list type="bullet">
///   <item><c>Get-WindowsFeature</c> (ServerManager) — 265 Server roles/role services/features. Server only.</item>
///   <item><c>Get-WindowsCapability</c> (DISM) — the on-demand payloads: RSAT, OpenSSH, fonts, languages.
///   States: <c>Installed</c>, <c>NotPresent</c>, <c>Staged</c>, <c>Removed</c>, <c>InstallPending</c>.</item>
///   <item><c>Get-WindowsOptionalFeature</c> (DISM) — the classic "Turn Windows features on or off" list.
///   States: <c>Enabled</c>, <c>Disabled</c>, <c>DisabledWithPayloadRemoved</c>, and the two Pending ones.</item>
/// </list>
///
/// <para>One module for the two DISM inventories, because they share the verb (<c>Add-</c>/<c>Remove-</c>)
/// and the payload problem; <c>kind</c> says which. A single module over all three would have to pretend that
/// a Server role and a language pack are the same kind of thing, and its `state` would mean something
/// different depending on an argument — which is exactly what the excluded-middle rule is about.</para>
///
/// <para><b>THE PAYLOAD IS THE POINT.</b> <c>DisabledWithPayloadRemoved</c> and <c>Removed</c> mean the bits
/// are not on the disk: enabling then needs a <c>source</c> (a mounted ISO's <c>sources\\sxs</c>, or WSUS
/// reached through <c>-LimitAccess</c>-free Windows Update). Two features on the test host are already in that
/// state. A module reporting a boolean "enabled" would say Disabled and let the operator discover the missing
/// source from a failure — so the state travels verbatim, as it does in windows_feature.</para>
/// </summary>
public sealed class WindowsCapabilityModule : IModule
{
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(30);

    private static readonly string[] Kinds = ["capability", "optional_feature"];

    public string Name => "windows_capability";

    public string Description =>
        "Install or remove a Windows CAPABILITY (DISM on-demand payload: RSAT tools, OpenSSH, language "
        + "features) or an OPTIONAL FEATURE (the classic 'Turn Windows features on or off' list: SMB1, "
        + "Telnet client, .NET 3.5). `kind` is capability or optional_feature — they are separate "
        + "inventories with separate cmdlets, which is why one module carries both but never merges them "
        + "with windows_feature's Server roles. `name` is the DISM name (e.g. Rsat.ActiveDirectory."
        + "DS-LDS.Tools~~~~0.0.1.0, or SMB1Protocol). `state` is present or absent. `source` points at "
        + "installation media, and is REQUIRED when the payload has been removed — the reply reports that "
        + "state verbatim (Removed / DisabledWithPayloadRemoved) rather than as a boolean, because 'disabled' "
        + "and 'the bits are gone' need different actions. Ansible's win_capability and win_optional_feature "
        + "both translate here.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The DISM name. Capabilities carry a version suffix (…~~~~0.0.1.0); "
                                  + "optional features do not (SMB1Protocol, TelnetClient, NetFx3).",
            },
            ["kind"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Kinds,
                ["default"] = "capability",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["default"] = "present",
            },
            ["source"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Installation source for a removed payload, e.g. D:\\sources\\sxs.",
            },
        },
        ["required"] = new[] { "name" },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var name = Str(parameters, "name") ?? throw new ArgumentException("name: must not be empty");
        var kind = Str(parameters, "kind") ?? "capability";
        if (!Kinds.Contains(kind))
        {
            throw new ArgumentException($"kind: must be one of {string.Join(", ", Kinds)}, got \"{kind}\"");
        }

        var state = Str(parameters, "state") ?? "present";
        if (state is not ("present" or "absent"))
        {
            throw new ArgumentException($"state: must be present or absent, got \"{state}\"");
        }

        var source = Str(parameters, "source");
        var wantPresent = state == "present";

        // ---- OBSERVE ------------------------------------------------------------------------------------
        var before = await Read(kind, name, ct);
        if (before is null)
        {
            // A DISM name this host does not know is an error that NAMES it: capabilities carry a version
            // suffix and a name without one simply does not resolve, which is the commonest mistake here.
            throw new ArgumentException(
                $"name: \"{name}\" is not in this host's "
                + $"{(kind == "capability" ? "Get-WindowsCapability" : "Get-WindowsOptionalFeature")} list. "
                + "Capabilities need their full name including the version suffix (…~~~~0.0.1.0) — and note "
                + "that on Windows SERVER the RSAT tools are windows_feature entries (RSAT-AD-Tools), not "
                + "DISM capabilities: this host's 316 capabilities are languages, fonts and the like, with no "
                + "Rsat.* among them at all. Measured, not assumed.");
        }

        var data = new Dictionary<string, object?>
        {
            ["name"] = name,
            ["kind"] = kind,
            // VERBATIM, never mapped: Installed | NotPresent | Staged | Removed | InstallPending for a
            // capability, Enabled | Disabled | DisabledWithPayloadRemoved | *Pending for a feature. The
            // module does not own this vocabulary — see the class remarks.
            ["state_before"] = before,
            ["dry_run"] = dryRun,
            ["shell"] = WindowsPowerShellBridge.ShellName,
        };

        var isPresent = before is "Installed" or "Enabled";
        var payloadGone = before is "Removed" or "DisabledWithPayloadRemoved";
        data["payload_removed"] = payloadGone;

        if (isPresent == wantPresent)
        {
            return new ModuleResult(false,
                wantPresent ? $"already present ({before})" : $"already absent ({before})", data);
        }

        if (wantPresent && payloadGone && string.IsNullOrWhiteSpace(source))
        {
            // REFUSED BEFORE TRYING, with the reason. DISM's own error for this is generic and arrives
            // minutes later; the state already says what is wrong, so saying it now is strictly better.
            throw new ArgumentException(
                $"\"{name}\" is {before}: its payload has been removed from this image, so installing it "
                + "needs `source` (a mounted ISO's sources\\sxs, or Windows Update). Nothing was attempted.");
        }

        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(wantPresent ? "install" : "remove")} — currently {before}", data);
        }

        // ---- APPLY --------------------------------------------------------------------------------------
        var (setup, expression) = Command(kind, name, wantPresent, source);
        var answer = await WindowsPowerShellBridge.RunJson(setup, expression, Timeout, ct);
        var restart = "Unknown";
        foreach (var item in answer.Items)
        {
            if (item.TryGetProperty("RestartNeeded", out var r))
            {
                restart = r.ValueKind == JsonValueKind.True ? "Yes"
                    : r.ValueKind == JsonValueKind.False ? "No"
                    : r.GetString() ?? "Unknown";
            }
        }

        data["restart_needed"] = restart;
        data["state_after"] = await Read(kind, name, ct);
        if (!string.IsNullOrWhiteSpace(answer.Preamble))
        {
            data["output"] = answer.Preamble;
        }

        // THE STATE IS THE EVIDENCE, the cmdlet's silence is only a claim. `package` has had this guard from
        // the start and this module shipped without it — and the very first run reported "installed" for a
        // capability whose state was still NotPresent. A converge that reports green and drifts back on the
        // next pass is worse than one that fails.
        var after = (string?)data["state_after"];
        var nowPresent = after is "Installed" or "Enabled";
        if (nowPresent != wantPresent && !PendingRestartState(after))
        {
            throw new InvalidOperationException(
                $"the command reported no error but \"{name}\" is still {after ?? "unknown"} "
                + $"(wanted {(wantPresent ? "present" : "absent")}) — the claim and the evidence disagree, so "
                + "nothing is reported as done.");
        }

        var pending = restart is "Yes" or "True";
        return new ModuleResult(true,
            $"{(wantPresent ? "installed" : "removed")} — now {data["state_after"]}"
            + (pending ? " — awaiting-restart (DISM says a restart is needed)" : ""),
            data);
    }

    /// <summary>
    /// The states that mean "the work is done, a restart has to happen first" — a legitimate outcome where
    /// the post-apply check must not fail.
    /// </summary>
    private static bool PendingRestartState(string? state) =>
        state is "InstallPending" or "UninstallPending" or "EnablePending" or "DisablePending";

    /// <summary>
    /// The current state word, or null when this host does not know the name.
    ///
    /// <para>EXISTENCE IS DECIDED BY THE LIST, and it took two wrong attempts to get here. Measured:</para>
    /// <list type="bullet">
    ///   <item><c>Get-WindowsCapability -Online -Name "Totally.Made.Up.Name"</c> returns an OBJECT with
    ///   <c>State: NotPresent</c> — so state alone cannot tell "never heard of it" from "available but not
    ///   installed".</item>
    ///   <item>The echoed <c>Name</c> cannot either: with <c>-Name</c> it comes back EMPTY for a real
    ///   capability too. The first fix keyed on that and refused every valid name.</item>
    ///   <item>The full list is <b>316 entries in 0.5 s</b> (optional features: 324 in 3.1 s), which is cheap
    ///   enough to be the answer. There the <c>Name</c> is populated, so a lookup distinguishes the two.</item>
    /// </list>
    /// </summary>
    private static async Task<string?> Read(string kind, string name, CancellationToken ct)
    {
        var escaped = name.Replace("'", "''");
        var (setup, expression) = kind == "capability"
            ? ($"$x = Get-WindowsCapability -Online | Where-Object Name -eq '{escaped}'",
                "[pscustomobject]@{ State = [string]$x.State; Echoed = [string]$x.Name }")
            : ($"$x = Get-WindowsOptionalFeature -Online | Where-Object FeatureName -eq '{escaped}'",
                "[pscustomobject]@{ State = [string]$x.State; Echoed = [string]$x.FeatureName }");

        var answer = await WindowsPowerShellBridge.RunJson(setup, expression, TimeSpan.FromMinutes(5), ct);
        foreach (var item in answer.Items)
        {
            var echoed = item.TryGetProperty("Echoed", out var e) ? e.GetString() : null;
            if (string.IsNullOrWhiteSpace(echoed))
            {
                return null; // not in this host's list — see the remarks
            }

            if (item.TryGetProperty("State", out var st))
            {
                var value = st.GetString();
                return string.IsNullOrWhiteSpace(value) ? null : value;
            }
        }

        return null;
    }

    private static (string Setup, string Expression) Command(string kind, string name, bool install,
        string? source)
    {
        var escaped = name.Replace("'", "''");
        // -NoRestart everywhere, always: a reboot is never implicit, least of all inside a converge run. The
        // module reports awaiting-restart and the operator decides when.
        if (kind == "capability")
        {
            // NO -NoRestart HERE. Add-WindowsCapability does not have that parameter — measured, it raises
            // "Es wurde kein Parameter gefunden, der dem Parameternamen NoRestart entspricht", and before the
            // bridge learned to fail on a terminating error this module reported the resulting nothing as
            // "installed". The optional-feature cmdlets below DO take it, which is exactly the kind of
            // difference that has to be written down rather than assumed away.
            var setup = install
                ? $"$r = Add-WindowsCapability -Online -Name '{escaped}' -ErrorAction Stop"
                  + (string.IsNullOrWhiteSpace(source) ? "" : $" -Source '{source.Replace("'", "''")}'")
                : $"$r = Remove-WindowsCapability -Online -Name '{escaped}' -ErrorAction Stop";
            return (setup, "[pscustomobject]@{ RestartNeeded = [string]$r.RestartNeeded }");
        }

        var featureSetup = install
            ? $"$r = Enable-WindowsOptionalFeature -Online -FeatureName '{escaped}' -NoRestart -ErrorAction Stop"
              + (string.IsNullOrWhiteSpace(source) ? "" : $" -Source '{source.Replace("'", "''")}' -LimitAccess")
            : $"$r = Disable-WindowsOptionalFeature -Online -FeatureName '{escaped}' -NoRestart -ErrorAction Stop";
        return (featureSetup, "[pscustomobject]@{ RestartNeeded = [string]$r.RestartNeeded }");
    }

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;
}
