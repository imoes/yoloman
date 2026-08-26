using System.Management.Automation;
using System.Management.Automation.Runspaces;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// Runs PowerShell — the Windows counterpart of the Go agent's <c>shell</c> module, and the substrate the
/// ported modules are written on.
///
/// <para>IN-PROCESS, in a hosted runspace, not <c>powershell.exe</c> per call. That is the whole reason this
/// is a module and not a shell escape: the runspace keeps PowerShell's streams SEPARATE (output, error,
/// warning, information), so a caller learns that a script warned without having to find the warning inside
/// a merged stdout, and the output stays a list of objects with their type names rather than text that has
/// to be parsed back.</para>
///
/// <para>DRY RUN IS NOT A SKIP HERE, when it can be avoided. The Go <c>shell</c> module reports
/// "skipped (dry run)" because there is nothing else an arbitrary command line can honestly offer.
/// PowerShell has a real preview — <c>$WhatIfPreference</c> — but only for cmdlets that implement it, and
/// nothing can tell from the outside whether a script consists only of those. So the caller asserts it with
/// <c>whatif</c>, and:</para>
/// <list type="bullet">
///   <item>with <c>whatif: true</c> the script RUNS under <c>$WhatIfPreference = $true</c>, and what comes
///   back is PowerShell's own "What if:" output — a real preview.</item>
///   <item>without it, a dry run skips and says exactly why, naming the parameter that would change the
///   answer. Reporting "would have" after the fact is the one thing a dry run may never do.</item>
/// </list>
///
/// <para>The <c>changed</c> flag follows the Go <c>shell</c> module rather than inventing a rule: an
/// arbitrary script is assumed to have changed something, because the module cannot know and the safe
/// assumption for a converge report is the loud one. A script that knows better should be a module.</para>
/// </summary>
public sealed class PowerShellModule : IModule
{
    /// <summary>Ceiling for a single call. A script that hangs must not hold the agent's action plane.</summary>
    private const int DefaultTimeoutSeconds = 300;

    /// <summary>
    /// Where PowerShell's own modules live, or null if they were not found.
    ///
    /// <para>A HOSTED RUNSPACE DOES NOT FIND THEM BY ITSELF, and that cost a full end-to-end run to notice:
    /// through Bossman, `Get-Date` came back as "The term 'Get-Date' is not recognized". Microsoft.PowerShell
    /// .SDK ships Utility, Management, Security and the rest under
    /// <c>runtimes/{unix|win}/lib/netX/Modules</c> next to the app, and nothing sets PSModulePath to point
    /// there — so the runspace had the LANGUAGE and almost no cmdlets. It looked like a working PowerShell,
    /// which is why the unit tests passed: the test assembly's own output directory happened to contain that
    /// folder, so the tests were green for a reason the agent did not share.
    ///
    /// Resolved once, reported in every result as `module_path`, and warned about at startup when missing —
    /// a runspace that can only do arithmetic must not look like one that can manage a host.</para>
    /// </summary>
    public static string? ModuleDirectory { get; } = ResolveModuleDirectory();

    private static string? ResolveModuleDirectory()
    {
        // "unix" or "win": the SDK lays its modules out per runtime, and the ones for the other platform are
        // present but wrong (the win tree carries CIM/WSMan cmdlets that cannot load on Linux).
        var runtime = OperatingSystem.IsWindows() ? "win" : "unix";
        var root = Path.Combine(AppContext.BaseDirectory, "runtimes", runtime, "lib");
        if (!Directory.Exists(root))
        {
            return null;
        }

        // The SDK targets net9.0 while this agent targets net10.0 — the framework rolls forward, but the
        // DIRECTORY NAME is the SDK's, so it is discovered rather than assumed.
        return Directory.EnumerateDirectories(root)
            .Select(d => Path.Combine(d, "Modules"))
            .FirstOrDefault(Directory.Exists);
    }

    public string Name => "powershell";

    public string Description =>
        "Run a PowerShell script on this host, in-process in a hosted runspace, and return its output with "
        + "the streams kept separate. This is the Windows counterpart of the `shell` and `command` modules: "
        + "an Ansible `win_shell` task, a Chef `powershell_script` resource, a Puppet `exec` with a "
        + "PowerShell provider, or a Salt `cmd.run` with shell=powershell all translate to a call here. "
        + "Parameters: `script` (required, the code to run); `whatif` (assert that every cmdlet in the "
        + "script implements -WhatIf, which lets a dry run produce a REAL preview instead of a skip); "
        + "`timeout_seconds` (default 300); `working_directory` (where to run it). Returns `output` as a "
        + "list of {value, type} — the objects PowerShell produced, with their type names — plus `errors`, "
        + "`warnings`, `information` and `had_errors`. In dry-run mode without `whatif` the script is NOT "
        + "executed and the reply says so, naming `whatif` as the parameter that would change that.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["script"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The PowerShell code to run.",
            },
            ["whatif"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = false,
                ["description"] = "Assert that every cmdlet in the script implements -WhatIf. A dry run then "
                                  + "runs it under $WhatIfPreference and returns PowerShell's own preview "
                                  + "instead of skipping.",
            },
            ["timeout_seconds"] = new Dictionary<string, object>
            {
                ["type"] = "number",
                ["default"] = DefaultTimeoutSeconds,
                ["description"] = "Stop the script after this long.",
            },
            ["working_directory"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Directory to run in. Must exist; a missing one is an error, not a "
                                  + "silent fall back to the agent's own directory.",
            },
        },
        ["required"] = new[] { "script" },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var script = Str(parameters, "script")
                     ?? throw new ArgumentException("script: must not be empty");
        if (string.IsNullOrWhiteSpace(script))
        {
            throw new ArgumentException("script: must not be empty");
        }

        var whatIf = Bool(parameters, "whatif");
        var timeout = TimeSpan.FromSeconds(Num(parameters, "timeout_seconds") ?? DefaultTimeoutSeconds);
        var workingDirectory = Str(parameters, "working_directory");
        if (workingDirectory is not null && !Directory.Exists(workingDirectory))
        {
            // An error, not a fall back to wherever the agent happens to live: running the right script in
            // the wrong directory is the failure this parameter exists to prevent.
            throw new DirectoryNotFoundException($"working_directory: {workingDirectory} does not exist");
        }

        if (dryRun && !whatIf)
        {
            return new ModuleResult(Changed: false,
                Msg: "not run (dry run): an arbitrary script cannot be previewed. Pass whatif=true to assert "
                     + "that every cmdlet in it implements -WhatIf, and the dry run will execute it under "
                     + "$WhatIfPreference and return PowerShell's own preview.",
                Data: new Dictionary<string, object?>
                {
                    ["script"] = script,
                    ["previewable"] = false,
                });
        }

        var sessionState = InitialSessionState.CreateDefault2();
        if (ModuleDirectory is not null)
        {
            // Prepended, not replaced: a host may have its own module tree (a site's internal cmdlets), and
            // taking it away would be a surprise this module has no business causing.
            var existing = Environment.GetEnvironmentVariable("PSModulePath");
            sessionState.EnvironmentVariables.Add(new SessionStateVariableEntry("PSModulePath",
                string.IsNullOrEmpty(existing) ? ModuleDirectory : ModuleDirectory + Path.PathSeparator + existing,
                "PowerShell modules shipped with this agent, plus whatever the host already had"));
        }

        using var runspace = RunspaceFactory.CreateRunspace(sessionState);
        runspace.Open();
        using var shell = System.Management.Automation.PowerShell.Create();
        shell.Runspace = runspace;

        if (dryRun)
        {
            // The caller asserted every cmdlet supports it, so the preview is PowerShell's own.
            shell.AddScript("$WhatIfPreference = $true").Invoke();
            shell.Commands.Clear();
        }

        if (workingDirectory is not null)
        {
            shell.AddCommand("Set-Location").AddParameter("Path", workingDirectory).Invoke();
            shell.Commands.Clear();
        }

        shell.AddScript(script);

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        var output = new PSDataCollection<PSObject>();
        var timedOut = false;

        try
        {
            await using var registration = deadline.Token.Register(() =>
            {
                timedOut = !ct.IsCancellationRequested;
                // Stop, not Abort: a stopped pipeline still hands back the streams it filled, so a script
                // that ran for five minutes and then hung is not reported as having produced nothing.
                shell.BeginStop(null, null);
            });
            await shell.InvokeAsync<PSObject, PSObject>(null, output).WaitAsync(CancellationToken.None);
        }
        catch (PipelineStoppedException) when (timedOut || deadline.IsCancellationRequested)
        {
            // Expected: the registration above stopped it. Fall through to report what was collected.
        }

        var errors = shell.Streams.Error.Select(e => e.ToString()).ToList();
        var result = new Dictionary<string, object?>
        {
            ["script"] = script,
            // {value, type}: the type name is what makes this different from capturing stdout. A caller can
            // tell a System.IO.FileInfo from the string that happens to render the same way.
            ["output"] = output.Select(o => new Dictionary<string, object?>
            {
                ["value"] = o?.ToString(),
                ["type"] = o?.BaseObject?.GetType().FullName,
            }).ToList(),
            ["errors"] = errors,
            ["warnings"] = shell.Streams.Warning.Select(w => w.Message).ToList(),
            ["information"] = shell.Streams.Information.Select(i => i.MessageData?.ToString()).ToList(),
            ["had_errors"] = shell.HadErrors,
            ["what_if"] = dryRun && whatIf,
            ["timed_out"] = timedOut,
            // Reported every time: "Get-Date is not recognized" is unreadable without it, and null here is
            // the difference between a broken script and a runspace with no cmdlets.
            ["module_path"] = ModuleDirectory,
        };

        if (timedOut)
        {
            // A timeout is a failure with partial results, and both halves are reported: the streams filled
            // so far are in Data, and the caller is told the script did not finish.
            return new ModuleResult(Changed: true,
                Msg: $"stopped after {timeout.TotalSeconds:0}s: the script did not finish", Data: result,
                DataSource: new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = output.Count });
        }

        if (shell.HadErrors)
        {
            return new ModuleResult(Changed: true,
                Msg: "ran with errors: " + string.Join("; ", errors.Take(3)), Data: result,
                DataSource: new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = output.Count });
        }

        return new ModuleResult(
            // As in the Go shell module: an arbitrary script is assumed to have changed something, because
            // the module cannot know, and for a converge report the safe assumption is the loud one.
            Changed: !dryRun,
            Msg: dryRun ? "previewed under $WhatIfPreference" : "executed",
            Data: result,
            DataSource: new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = output.Count });
    }

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;

    private static bool Bool(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) && v switch
        {
            bool b => b,
            string s => bool.TryParse(s, out var parsed) && parsed,
            _ => false,
        };

    private static double? Num(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) && v is not null
        && double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : null;
}
