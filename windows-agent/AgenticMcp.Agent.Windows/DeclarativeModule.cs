using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// THE SKELETON EVERY DECLARATIVE MODULE HERE REPEATS, written once.
///
/// <para>MEASURED before writing this: eight Windows modules, 379–554 lines each, and every one of them
/// contains the same seven steps — resolve `dry_run` from either the argument or the parameters, READ the
/// current state, COMPARE field by field into a list of steps, return `changed: false` when the list is empty,
/// return the plan when it is a dry run, APPLY, RE-READ, and report `{applied, changes, before, after}`. The
/// bodies differ completely; the shape does not.</para>
///
/// <para>WHY THIS IS NOT THE CODE GENERATOR THE PLAN ASKED FOR. Milestone 6 said to declare thin modules in a
/// table and generate them, because "40 hand-written near-identical modules is 40 chances to spell `state`
/// differently". The instinct is right and the mechanism is wrong, and the eight modules are the evidence:
/// not one of them turned out to be a thin shell over a cmdlet. Each needed a Windows-specific fact that a
/// generator would not have known — a task result that overflows <c>[int]</c>, principals that are localised,
/// a CIDR Windows rewrites into a netmask, a repetition that lasts one day without an explicit duration, two
/// bulk queries instead of one per row. Generated modules would be uniform AND wrong, which is worse than
/// hand-written and right. So what is shared is the SKELETON, tested once, and each module keeps its own
/// knowledge of the thing it manages.</para>
///
/// <para>WHAT A SUBCLASS OWES: <see cref="ReadAsync"/> (null when absent), <see cref="CompareAsync"/> (the
/// steps and their before/after), <see cref="BuildScript"/> (the PowerShell that applies them) and, when the
/// module reads rather than declares, its own override of <see cref="RunAsync"/>. Everything else — the
/// wording, the verification, the shape of the answer — comes from here, so two modules cannot disagree about
/// what "already as declared" means.</para>
///
/// <para>STILL TO DO, stated rather than left implicit: the eight existing modules predate this base and have
/// not been migrated onto it. Each of them is verified against a real host, and rewriting a working,
/// host-tested module without the host in front of me is a regression risk taken for tidiness. They migrate
/// one at a time, each with its verification re-run — not in one sweep.</para>
/// </summary>
public abstract class DeclarativeModule : IModule
{
    public abstract string Name { get; }
    public abstract string Description { get; }
    public abstract IReadOnlyDictionary<string, object> InputSchema { get; }
    public virtual bool Writes => true;

    /// <summary>What this module calls the thing it manages, for the messages: "time zone", "share", "rule".</summary>
    protected abstract string Noun { get; }

    /// <summary>The states this module accepts. `present`/`absent` for most; a module whose object always
    /// exists (a setting rather than a thing) declares only what it can be.</summary>
    protected virtual string[] States => ["present", "absent"];

    /// <summary>The current state of the target, or null when it does not exist. The ONE place a module says
    /// what "is" means for it.</summary>
    protected abstract Task<Dictionary<string, object?>?> ReadAsync(
        IReadOnlyDictionary<string, object?> parameters, CancellationToken ct);

    /// <summary>
    /// What differs between `current` and what the parameters declare: a step name per difference, and the
    /// before/after under the same name in `changes`. An empty list means already correct — which is why this
    /// returns the list rather than a boolean: the steps ARE the plan, and the plan is what a dry run shows.
    /// </summary>
    protected abstract Task<(List<string> Steps, Dictionary<string, object?> Changes)> CompareAsync(
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current,
        CancellationToken ct);

    /// <summary>The PowerShell statements that apply those steps, in order. Wrapped in step markers and run
    /// through the 5.1 bridge by the caller, so a failure halfway through says what had already been done.</summary>
    protected abstract List<string> BuildScript(IReadOnlyDictionary<string, object?> parameters,
        Dictionary<string, object?>? current, List<string> steps, Dictionary<string, object?> changes);

    /// <summary>Secrets the script needs, passed to the child shell's ENVIRONMENT rather than its command
    /// line. Empty for most modules.</summary>
    protected virtual Dictionary<string, string> Secrets(IReadOnlyDictionary<string, object?> parameters) => [];

    /// <summary>How long the apply may take. Overridden by modules that install things.</summary>
    protected virtual TimeSpan ApplyTimeout => TimeSpan.FromMinutes(3);

    /// <summary>A short name for the target, for the messages. Defaults to the `name` parameter.</summary>
    protected virtual string Target(IReadOnlyDictionary<string, object?> parameters) =>
        parameters.GetValueOrDefault("name") as string ?? Noun;

    public virtual async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters,
                                                     bool dryRun, CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException($"{Name} manages a Windows facility.");
        }

        // BOTH SOURCES OF dry_run, because callers use both: the plan engine passes the argument, a runbook
        // and the console put it in the parameters, and a module that honoured only one of them would apply a
        // change somebody asked to preview.
        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;

        var state = (parameters.GetValueOrDefault("state") as string ?? States[0]).ToLowerInvariant();
        if (!States.Contains(state))
        {
            throw new ArgumentException($"state: {state} is not one of {string.Join(", ", States)}.");
        }

        var target = Target(parameters);
        var current = await ReadAsync(parameters, ct);
        var (steps, changes) = await CompareAsync(parameters, current, ct);

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"{Noun} {target} is already as declared",
                new Dictionary<string, object?> { ["target"] = target, ["current"] = current });
        }

        if (dryRun)
        {
            return new ModuleResult(true, $"would change {Noun} {target}: {string.Join(", ", steps)}",
                new Dictionary<string, object?>
                {
                    ["target"] = target, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = BuildScript(parameters, current, steps, changes);
        if (script.Count > 0)
        {
            await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
                ApplyTimeout, ct, Secrets(parameters));
        }

        // THE STATE IS THE EVIDENCE, not the exit code — the rule windows_capability was fixed with, here by
        // construction so no module can forget it. A re-read that still differs is a failure, however happily
        // the shell exited.
        var after = await ReadAsync(parameters, ct);
        var (remaining, _) = await CompareAsync(parameters, after, ct);
        if (remaining.Count > 0)
        {
            throw new InvalidOperationException(
                $"{Name} reported success but the host still differs on: {string.Join(", ", remaining)}. "
                + $"Before: {Describe(current)}; after: {Describe(after)}.");
        }

        return new ModuleResult(true, $"changed {Noun} {target}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["target"] = target, ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }

    private static string Describe(Dictionary<string, object?>? state) =>
        state is null ? "(absent)" : string.Join(", ", state.Select(kv => $"{kv.Key}={kv.Value}"));

    /// <summary>A schema property, since every subclass writes these.</summary>
    protected static Dictionary<string, object> Prop(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    /// <summary>An enum-valued schema property.</summary>
    protected static Dictionary<string, object> Choice(string description, params string[] values) =>
        new() { ["type"] = "string", ["enum"] = values, ["description"] = description };

    /// <summary>The `dry_run` property, spelled the same way in every module that has one.</summary>
    protected static Dictionary<string, object> DryRunProp() =>
        Prop("boolean", "Report what would change without applying it.");
}
