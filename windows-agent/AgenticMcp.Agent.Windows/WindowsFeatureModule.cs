using System.Text.Json;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_feature</c> — Windows Server roles, role services and features as desired state.
/// Ansible's <c>win_feature</c>, on the ServerManager cmdlets (<c>Get/Install/Uninstall-WindowsFeature</c>).
///
/// <para>THREE THINGS HERE ARE NOT BOOLEANS, and each was measured on a real Server 2022 rather than assumed
/// (see docs/windows-management.md §1):</para>
/// <list type="bullet">
///   <item><c>install_state</c> is WINDOWS' OWN WORD, lower-cased and passed through — never mapped onto an
///   enum of ours. Read from the host: <c>Available, Installed, UninstallPending, InstallPending, NotPresent,
///   Removed, Unknown</c> — SEVEN, where the design had named three. `Removed` means the payload was deleted
///   from the image so installing needs a source (two features on the test host are in that state today), and
///   `UninstallPending` appeared on the first real uninstall, while a restart was outstanding. Passing the
///   string through is why that fourth value reached the API intact instead of being coerced to the nearest
///   one we knew about.</item>
///   <item><c>restart_needed</c> is <c>yes | no | maybe</c>. `Maybe` is Windows' own answer, and both `true`
///   and `false` would be a lie about it.</item>
///   <item><c>feature_type</c> is <c>Role | Role Service | Feature</c> — 20/90/155 on that host. It is DATA
///   ABOUT THE TARGET and never this catalogue's own `kind`, which already means something else here: see
///   the identity finding in the design.</item>
/// </list>
///
/// <para>AND THE PLAN IS WINDOWS' OWN. <c>-WhatIf</c> answers with the full FeatureResult: asking for
/// `Web-Server -IncludeManagementTools` reports FIFTEEN features and a restart verdict. That is a better dry
/// run than the Linux side gets from apt, so the preview is the system's answer and not a rendering of our
/// intent — and an operator who ticks one box sees the other fourteen before Apply.</para>
/// </summary>
public sealed class WindowsFeatureModule : IModule
{
    /// <summary>A feature install can take minutes; a preview is seconds. One ceiling for both, generous.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(20);

    public string Name => "windows_feature";

    public string Description =>
        "Ensure Windows Server roles, role services and features are installed or absent. `name` is one "
        + "feature or a list of them (the ServerManager names, e.g. Web-Server, DNS, AD-Domain-Services); "
        + "`state` is present, absent or absent_with_payload (which deletes the feature files, so a later "
        + "install needs a source); `include_management_tools` adds the role's consoles; `include_sub_features` "
        + "adds everything under it; `source` points at an installation source for a feature whose payload was "
        + "removed. An ansible.windows.win_feature task translates directly. "
        + "READS FIRST, ALWAYS: the reply carries `install_state` (available|installed|removed), "
        + "`feature_type` (Role|Role Service|Feature) and, for a change, the FULL list of features Windows "
        + "says it would touch plus `restart_needed` (yes|no|maybe) — a dry run returns exactly that and "
        + "changes nothing. Idempotent: a feature already in the requested state reports changed:false.";

    private static readonly string[] States = ["present", "absent", "absent_with_payload"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "One feature name, or several separated by commas. ServerManager names, "
                                  + "not display names — `Web-Server`, not `Web Server (IIS)`.",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = States,
                ["default"] = "present",
                ["description"] = "present | absent | absent_with_payload. The third one deletes the feature "
                                  + "files (Uninstall-WindowsFeature -Remove): the state becomes `removed` "
                                  + "and a later install needs `source`.",
            },
            ["include_management_tools"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = false,
                ["description"] = "Add the role's management consoles. `Web-Server` alone gives no IIS "
                                  + "manager, which is the commonest surprise on a fresh install.",
            },
            ["include_sub_features"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = false,
                ["description"] = "Add everything beneath the named feature.",
            },
            ["source"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Installation source (a mounted ISO's sources\\sxs, or a WSUS path) — "
                                  + "required only for a feature whose payload was removed.",
            },
        },
        ["required"] = new[] { "name" },
    };

    /// <summary>True: it installs software. The write gate decides whether it is offered at all.</summary>
    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var raw = Str(parameters, "name") ?? throw new ArgumentException("name: must not be empty");
        var names = raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (names.Length == 0)
        {
            throw new ArgumentException("name: must not be empty");
        }

        var state = Str(parameters, "state") ?? "present";
        if (!States.Contains(state))
        {
            throw new ArgumentException($"state: must be one of {string.Join(", ", States)}, got \"{state}\"");
        }

        var source = Str(parameters, "source");
        var withTools = Bool(parameters, "include_management_tools");
        var withSubs = Bool(parameters, "include_sub_features");

        // ---- OBSERVE, first and always ------------------------------------------------------------------
        var before = await Inventory(names, ct);
        var unknown = names.Where(n => !before.ContainsKey(n)).ToList();
        if (unknown.Count > 0)
        {
            // A feature name Windows does not know is an error that NAMES it: "no such feature" and "not
            // installed" are different facts, and a typo in a role definition must not read as drift.
            throw new ArgumentException(
                $"name: this host's Get-WindowsFeature does not know {string.Join(", ", unknown)}. "
                + "Use the ServerManager Name, not the DisplayName.");
        }

        var wantInstalled = state == "present";
        // ONLY THE ONES THAT NEED IT. Passing a feature that is already in the requested state to
        // Install/Uninstall-WindowsFeature is not harmless: Windows runs its prerequisite check over
        // everything named, so one untouchable feature in the list fails the whole call. Measured — a request
        // naming three features, one of them already absent, was refused for a fourth reason entirely.
        var pending = before.Values.Where(f => wantInstalled
            ? !f.Installed
            : f.Installed || (state == "absent_with_payload" && f.InstallState != "Removed"))
            .Select(f => f.Name).ToArray();
        var needChange = pending.Length > 0;

        var data = new Dictionary<string, object?>
        {
            ["features"] = before.Values.Select(f => f.ToDictionary()).ToList(),
            ["state"] = state,
            ["dry_run"] = dryRun,
            // The bridge is named in every reply: nobody debugging a feature install should have to discover
            // from a stack trace that these commands ran in a different shell than `powershell` does.
            ["shell"] = WindowsPowerShellBridge.ShellName,
        };

        if (!needChange)
        {
            return new ModuleResult(false,
                wantInstalled ? "already installed" : "already absent", data);
        }

        // ---- PLAN — and the plan is Windows' own -------------------------------------------------------
        // -WhatIf reports every feature it would touch and whether a restart is needed. Run for BOTH the dry
        // run and the real apply, because an operator (or an approval gate) reading "would install 15
        // features" and then getting those 15 is the same statement twice, while getting them without having
        // seen the list is a change nobody consented to.
        var plan = await Preview(pending, state, withTools, withSubs, source, ct);
        data["acting_on"] = pending;
        data["plan"] = plan.Features;
        data["restart_needed"] = plan.RestartNeeded;
        data["plan_source"] = "Install-WindowsFeature -WhatIf";
        data["plan_narrative"] = plan.Narrative;

        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(wantInstalled ? "install" : "remove")} {plan.Features.Count} feature(s); "
                + $"restart needed: {plan.RestartNeeded}", data);
        }

        // ---- APPLY --------------------------------------------------------------------------------------
        var applied = await Apply(pending, state, withTools, withSubs, source, ct);
        data["result"] = applied.Features;
        data["restart_needed"] = applied.RestartNeeded;
        data["exit_code"] = applied.ExitCode;
        if (!applied.Success)
        {
            throw new InvalidOperationException(
                $"Windows refused the change (exit {applied.ExitCode}): {applied.Error}");
        }

        var after = await Inventory(names, ct);
        data["features_after"] = after.Values.Select(f => f.ToDictionary()).ToList();

        // AWAITING-RESTART IS A STATE, not a footnote. Between install and reboot Get-WindowsFeature says
        // Installed while the role's service does not exist — so the message says so rather than reporting a
        // clean success that the next check will contradict.
        var awaitingRestart = applied.RestartNeeded is "Yes" or "Maybe";
        return new ModuleResult(true,
            $"{(wantInstalled ? "installed" : "removed")} {applied.Features.Count} feature(s)"
            + (awaitingRestart
                ? $" — awaiting-restart (Windows says restart needed: {applied.RestartNeeded})"
                : ""),
            data);
    }

    // -------------------------------------------------------------------------------------------------
    private sealed record Feature(string Name, string DisplayName, string FeatureType, bool Installed,
        string InstallState)
    {
        public Dictionary<string, object?> ToDictionary() => new()
        {
            ["name"] = Name,
            ["display_name"] = DisplayName,
            // Windows' own word, lower-cased into our spelling: role | role_service | feature.
            ["feature_type"] = FeatureType.Replace(" ", "_").ToLowerInvariant(),
            ["installed"] = Installed,
            // available | installed | removed — the third one is why this is not a boolean.
            ["install_state"] = InstallState.ToLowerInvariant(),
        };
    }

    private async Task<Dictionary<string, Feature>> Inventory(string[] names, CancellationToken ct)
    {
        // ConvertTo-Json with -Compress and an explicit -Depth: PowerShell's default depth of 2 silently
        // truncates nested objects into the string "System.Object[]", which is a data loss that looks like
        // data. -AsArray so a single feature does not come back as a bare object.
        // EVERY ENUM CAST TO STRING. Measured: InstallState is Available=0, Installed=1, Removed=5 — JSON
        // carries the number, and reading it as an index would have mis-mapped Removed silently. Also
        // -ErrorAction SilentlyContinue: a name Windows does not know must come back as ABSENT FROM THE
        // RESULT, not as a failed command, so the caller can say which name it was.
        var expression = $"Get-WindowsFeature -Name {Quote(names)} -ErrorAction SilentlyContinue | "
                         + "Select-Object Name,DisplayName,"
                         + "@{n='FeatureType';e={[string]$_.FeatureType}},"
                         + "@{n='Installed';e={[bool]$_.Installed}},"
                         + "@{n='InstallState';e={[string]$_.InstallState}}";
        var found = new Dictionary<string, Feature>(StringComparer.OrdinalIgnoreCase);
        foreach (var element in (await Query("", expression, ct)).Items)
        {
            var name = element.TryGetProperty("Name", out var n) ? n.GetString() ?? "" : "";
            if (name.Length == 0)
            {
                continue;
            }

            found[name] = new Feature(name,
                element.TryGetProperty("DisplayName", out var d) ? d.GetString() ?? "" : "",
                element.TryGetProperty("FeatureType", out var t) ? t.GetString() ?? "" : "",
                element.TryGetProperty("Installed", out var i) && i.ValueKind == JsonValueKind.True,
                element.TryGetProperty("InstallState", out var s) ? s.GetString() ?? "" : "");
        }

        return found;
    }

    private sealed record Plan(List<Dictionary<string, object?>> Features, string RestartNeeded,
        bool Success, string ExitCode, string Error, string Narrative);

    private Task<Plan> Preview(string[] names, string state, bool tools, bool subs, string? source,
        CancellationToken ct) =>
        Run(names, state, tools, subs, source, whatIf: true, ct);

    private Task<Plan> Apply(string[] names, string state, bool tools, bool subs, string? source,
        CancellationToken ct) =>
        Run(names, state, tools, subs, source, whatIf: false, ct);

    private async Task<Plan> Run(string[] names, string state, bool tools, bool subs, string? source,
        bool whatIf, CancellationToken ct)
    {
        var command = state == "present"
            ? "Install-WindowsFeature"
            : "Uninstall-WindowsFeature";
        var arguments = new List<string> { $"-Name {Quote(names)}" };
        if (state == "present")
        {
            if (tools)
            {
                arguments.Add("-IncludeManagementTools");
            }

            if (subs)
            {
                arguments.Add("-IncludeAllSubFeature");
            }

            if (!string.IsNullOrWhiteSpace(source))
            {
                arguments.Add($"-Source '{source.Replace("'", "''")}'");
            }
        }
        else if (state == "absent_with_payload")
        {
            arguments.Add("-Remove");
        }

        if (whatIf)
        {
            arguments.Add("-WhatIf");
        }

        // -ErrorAction Stop so a refusal is an error rather than a warning nobody reads, and the whole
        // result object serialised: Success, ExitCode, RestartNeeded and the FeatureResult list are all part
        // of the answer an operator needs.
        // ExitCode and RestartNeeded are enums too — [string] on both, for the same reason as InstallState.
        var setup = $"$r = {command} {string.Join(' ', arguments)} -ErrorAction Stop";
        var expression = "[pscustomobject]@{ Success = [bool]$r.Success; ExitCode = [string]$r.ExitCode; "
                         + "RestartNeeded = [string]$r.RestartNeeded; "
                         + "FeatureResult = @($r.FeatureResult | Select-Object Id,Name,DisplayName,"
                         + "@{n='Skipped';e={[bool]$_.Skipped}}) }";
        var features = new List<Dictionary<string, object?>>();
        var restart = "Unknown";
        var success = true;
        var exit = "";
        var answer = await Query(setup, expression, ct);
        foreach (var element in answer.Items)
        {
            if (element.TryGetProperty("RestartNeeded", out var r))
            {
                restart = r.GetString() ?? "Unknown";
            }

            if (element.TryGetProperty("Success", out var s))
            {
                success = s.ValueKind != JsonValueKind.False;
            }

            if (element.TryGetProperty("ExitCode", out var e))
            {
                exit = e.GetString() ?? "";
            }

            if (!element.TryGetProperty("FeatureResult", out var list)
                || list.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var f in list.EnumerateArray())
            {
                features.Add(new Dictionary<string, object?>
                {
                    ["name"] = f.TryGetProperty("Name", out var fn) ? fn.GetString() : null,
                    ["display_name"] = f.TryGetProperty("DisplayName", out var fd) ? fd.GetString() : null,
                    ["skipped"] = f.TryGetProperty("Skipped", out var fs)
                                  && fs.ValueKind == JsonValueKind.True,
                });
            }
        }

        // A -WhatIf run reports its features through the WHAT-IF STREAM as well, and on some hosts the
        // FeatureResult of a preview comes back empty. An empty plan for a change we know is needed would
        // read as "nothing to do", so it is reported as unknown rather than as none.
        if (whatIf && features.Count == 0)
        {
            features.Add(new Dictionary<string, object?>
            {
                ["name"] = string.Join(", ", names),
                ["display_name"] = "(Windows returned no feature list for this preview)",
                ["skipped"] = false,
            });
        }

        // WINDOWS' OWN WORDS travel with the plan: the -WhatIf preamble reads "What if: Performing
        // installation for "[Webserver (IIS)] HTTP-Protokollierung"" and that is a better preview than any
        // rendering of ours. Kept rather than parsed — it is prose, and prose is what it is good at.
        return new Plan(features, restart, success, exit, success ? "" : $"exit {exit}", answer.Preamble);
    }

    /// <summary>
    /// Every ServerManager call goes through Windows PowerShell 5.1 — see WindowsPowerShellBridge for the
    /// measurement that made this necessary (PowerShell 7 cannot load the module at all).
    /// </summary>
    private static Task<WindowsPowerShellBridge.Answer> Query(string setup, string jsonExpression,
        CancellationToken ct) =>
        WindowsPowerShellBridge.RunJson(setup, jsonExpression, Timeout, ct);

    /// <summary>Feature names as a PowerShell array literal, single-quoted and escaped.</summary>
    private static string Quote(IEnumerable<string> names) =>
        string.Join(",", names.Select(n => $"'{n.Replace("'", "''")}'"));

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;

    private static bool Bool(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) && v switch
        {
            bool b => b,
            string s => bool.TryParse(s, out var parsed) && parsed,
            _ => false,
        };
}
