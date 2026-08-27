using System.Xml.Linq;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_gpresult</c> — the RESULTANT set of policy: which Group Policy Objects actually apply to this
/// host, which were denied and why.
///
/// <para><b>WE DO NOT MANAGE GROUP POLICY.</b> Authoring GPOs stays with Windows (GPMC, Active Directory) —
/// that is the operator's decision and it is the right one: a second authority writing GPOs would be two
/// systems declaring the same thing, and the domain would win every argument anyway.</para>
///
/// <para><b>But the RESULT belongs in the host's state document</b>, and its place there is precise: it is
/// neither our desired state nor the host's observed state. It is a FOREIGN AUTHORITY'S INTENT — what the
/// domain wants this machine to be. That distinction is the whole value:</para>
///
/// <list type="bullet">
///   <item>our desired state = what WE declared</item>
///   <item>gpresult = what AD declared for this host, which we do not control</item>
///   <item>observed state = what is actually true right now</item>
/// </list>
///
/// <para>Where the first two touch the same setting, the GPO wins on the host and our convergence will fight
/// it on every pass — forever, silently, with the operator watching a value revert and no explanation
/// anywhere. Recording the foreign intent is what turns that mystery into a named conflict.</para>
///
/// <para>READ-ONLY (<c>Writes = false</c>): available even with the write gate closed, because knowing which
/// policy governs a host is not a change to it.</para>
///
/// <para>MEASURED on bossman-wintest: <c>gpresult /X</c> answers in 1.8 s with 48 kB of XML. The element
/// names are PARTLY LOCALISED — this host's extension sections are called
/// "Gruppenrichtlinieninfrastruktur" and "Richtlinien der lokalen Gruppe" — so the parser reads only the
/// schema-stable elements (<c>GPO</c>, <c>Name</c>, <c>Path</c>, <c>Link</c>, <c>SOM</c>, <c>IsValid</c>,
/// <c>AccessDenied</c>, <c>FilterAllowed</c>) and never a display name. A parser keyed on German element
/// names would break on an English host and vice versa.</para>
/// </summary>
public sealed class GroupPolicyModule : IModule
{
    private static readonly XNamespace Rsop = "http://www.microsoft.com/GroupPolicy/Rsop";

    public string Name => "windows_gpresult";

    public string Description =>
        "Report which Group Policy Objects apply to this host and which were denied, with the reason — the "
        + "resultant set of policy, from `gpresult /X`. This system does NOT author or manage GPOs (Windows "
        + "keeps that), but the RESULT is recorded as a foreign authority's intent: where a GPO and our own "
        + "declared config touch the same setting, the GPO wins on the host and a convergence run would fight "
        + "it forever. Returns applied GPOs (name, GUID, scope, link order, version), denied GPOs WITH the "
        + "reason (access denied, security filtering, disabled link, empty), the scope of management, whether "
        + "a slow link was detected, and when policy was last read. `scope` selects computer, user or both. "
        + "Read-only: knowing which policy governs a host is not a change to it.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["scope"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "computer", "user", "both" },
                ["default"] = "computer",
                ["description"] = "Computer policy is the one that governs a server. User policy applies to "
                                  + "whoever is signed in, which on a server is usually nobody.",
            },
            ["include_xml"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = false,
                ["description"] = "Also return the raw gpresult XML (48 kB on a workgroup host, more in a "
                                  + "domain). Off by default: the parsed summary is what a decision reads, "
                                  + "and the extension sections are localised so nothing generic can be made "
                                  + "of them here.",
            },
        },
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var scope = Str(parameters, "scope") ?? "computer";
        if (scope is not ("computer" or "user" or "both"))
        {
            throw new ArgumentException($"scope: must be computer, user or both, got \"{scope}\"");
        }

        var includeXml = parameters.TryGetValue("include_xml", out var raw)
                         && (raw is true || (raw is string s
                             && string.Equals(s, "true", StringComparison.OrdinalIgnoreCase)));

        // /X to a temp file, then read it: gpresult has no stdout XML mode, and /F overwrites without asking.
        // Base64 across the bridge so 48 kB of XML with umlauts survives the console code page intact.
        // THE PATH GOES IN A VARIABLE, quoted once. `& gpresult /X $env:TEMP\file` parses fine in ARGUMENT
        // mode and `[IO.File]::ReadAllText($env:TEMP\file)` does not — expression mode reads the backslash as
        // an operator and the whole script fails to parse. One quoted assignment serves both.
        const string setup = "$p = \"$env:TEMP\\agentic-gpresult.xml\"; "
                             + "& gpresult /X $p /F | Out-Null; "
                             + "$xml = [IO.File]::ReadAllText($p); "
                             + "Remove-Item $p -ErrorAction SilentlyContinue";
        var expression = "[pscustomobject]@{ "
                         + "Xml = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml)) }";

        var answer = await WindowsPowerShellBridge.RunJson(setup, expression, TimeSpan.FromMinutes(5), ct);
        var encoded = answer.Items
            .Select(i => i.TryGetProperty("Xml", out var x) ? x.GetString() : null)
            .FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
        if (encoded is null)
        {
            throw new InvalidOperationException(
                "gpresult produced no XML. On a host where no policy has ever been applied it still writes a "
                + "document, so an empty answer means the command failed rather than that nothing applies.");
        }

        var xml = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
        var document = XDocument.Parse(xml);
        var root = document.Root ?? throw new InvalidOperationException("gpresult XML has no root");

        var data = new Dictionary<string, object?>
        {
            ["read_at"] = root.Element(Rsop + "ReadTime")?.Value,
            ["scope"] = scope,
            ["shell"] = WindowsPowerShellBridge.ShellName,
            // SAID PLAINLY IN EVERY REPLY: this is somebody else's declaration. Without it the section reads
            // as something this system set, which is the one misunderstanding that matters here.
            ["authority"] = "windows-group-policy",
            ["managed_by_us"] = false,
        };

        var sections = new List<string>();
        if (scope is "computer" or "both")
        {
            sections.Add("ComputerResults");
        }

        if (scope is "user" or "both")
        {
            sections.Add("UserResults");
        }

        var applied = new List<Dictionary<string, object?>>();
        var denied = new List<Dictionary<string, object?>>();
        foreach (var section in sections)
        {
            var results = root.Element(Rsop + section);
            if (results is null)
            {
                continue;
            }

            data[$"{section.ToLowerInvariant()}_name"] = results.Element(Rsop + "Name")?.Value;
            data[$"{section.ToLowerInvariant()}_domain"] = results.Element(Rsop + "Domain")?.Value;
            // SOM is the scope of management — the OU/site/domain chain this host sits in. It is what makes a
            // GPO's presence explicable rather than magic.
            data[$"{section.ToLowerInvariant()}_som"] = results.Element(Rsop + "SOM")?.Value;
            data[$"{section.ToLowerInvariant()}_slow_link"] = results.Element(Rsop + "SlowLink")?.Value;

            foreach (var gpo in results.Elements(Rsop + "GPO"))
            {
                var link = gpo.Element(Rsop + "Link");
                var entry = new Dictionary<string, object?>
                {
                    ["scope"] = section == "ComputerResults" ? "computer" : "user",
                    ["name"] = gpo.Element(Rsop + "Name")?.Value,
                    // The GUID, because a GPO's display NAME is editable and localised (this host's local
                    // policy object is called "Richtlinien der lokalen Gruppe") while the identifier is not.
                    ["id"] = gpo.Element(Rsop + "Path")?.Element(Rsop + "Identifier")?.Value,
                    ["enabled"] = gpo.Element(Rsop + "Enabled")?.Value,
                    ["valid"] = gpo.Element(Rsop + "IsValid")?.Value,
                    ["filter_allowed"] = gpo.Element(Rsop + "FilterAllowed")?.Value,
                    ["access_denied"] = gpo.Element(Rsop + "AccessDenied")?.Value,
                    ["version_ad"] = gpo.Element(Rsop + "VersionDirectory")?.Value,
                    ["version_sysvol"] = gpo.Element(Rsop + "VersionSysvol")?.Value,
                    ["som_path"] = link?.Element(Rsop + "SOMPath")?.Value,
                    ["link_order"] = link?.Element(Rsop + "LinkOrder")?.Value,
                    ["applied_order"] = link?.Element(Rsop + "AppliedOrder")?.Value,
                    ["no_override"] = link?.Element(Rsop + "NoOverride")?.Value,
                };

                // WHY IT DID NOT APPLY, named. gpresult states the three causes separately, and an operator
                // asking "why is my GPO not working" is asking exactly which of them it was.
                var reasons = new List<string>();
                if (entry["access_denied"] as string == "true")
                {
                    reasons.Add("access denied (the computer object cannot read the GPO)");
                }

                if (entry["filter_allowed"] as string == "false")
                {
                    reasons.Add("security filtering excludes this host");
                }

                if (entry["enabled"] as string == "false")
                {
                    reasons.Add("the link is disabled");
                }

                if (entry["valid"] as string == "false")
                {
                    reasons.Add("the GPO is not valid (missing or unreadable in SYSVOL)");
                }

                if (reasons.Count > 0)
                {
                    entry["denied_because"] = reasons;
                    denied.Add(entry);
                }
                else
                {
                    applied.Add(entry);
                }
            }
        }

        data["applied"] = applied;
        // DENIED GPOs ARE REPORTED, not filtered away. "The policy is not in the applied list" and "the
        // policy was refused for this host, here is why" are different facts, and only the second one can be
        // acted on — the whole reason this module exists rather than a grep of the applied names.
        data["denied"] = denied;
        data["applied_count"] = applied.Count;
        data["denied_count"] = denied.Count;
        if (includeXml)
        {
            data["xml"] = xml;
        }

        var domain = data.GetValueOrDefault("computerresults_domain") as string;
        return new ModuleResult(false,
            $"{applied.Count} GPO(s) applied, {denied.Count} denied"
            + (string.IsNullOrWhiteSpace(domain) ? "" : $" (domain {domain})")
            + " — declared by Windows Group Policy, not by this system",
            data,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = applied.Count + denied.Count });
    }

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;
}
