namespace AgenticMcp.Agent.Core;

/// <summary>What every module returns — the Go agent's <c>modules.Result</c>, field for field.</summary>
public sealed record ModuleResult(
    bool Changed,
    string? Msg = null,
    object? Data = null,
    IReadOnlyDictionary<string, int>? DataSource = null)
{
    public static ModuleResult Unchanged(string? msg = null) => new(false, msg);
}

/// <summary>
/// The module protocol, ported member for member from <c>internal/modules/module.go</c>: Name, Description,
/// InputSchema, Writes, Run(params, dryRun). Five members, one contract, two implementations — the same
/// relationship <c>docs/resource-protocol.md</c> describes for ConfigResource and TemplateResource.
/// </summary>
public interface IModule
{
    /// <summary>
    /// The ansible.builtin-style name. THE SAME NAME MEANS THE SAME THING on both platforms, or it gets a
    /// different name: <c>service</c> starts a service either way, while Windows' Task Scheduler is
    /// <c>scheduled_task</c> and not <c>cron</c>, because "a schedule expressed in five fields" and "a task
    /// with triggers, principals and conditions" are not one concept wearing two coats.
    /// </summary>
    string Name { get; }

    /// <summary>
    /// Written for a reader who has no other documentation — including an LLM translating an Ansible task,
    /// a Chef resource or a PowerShell DSC block into a call to this module.
    /// </summary>
    string Description { get; }

    IReadOnlyDictionary<string, object> InputSchema { get; }

    /// <summary>Whether this module can mutate the host. Writing modules are only registered when the write
    /// gate is open, exactly as on the Go side.</summary>
    bool Writes { get; }

    /// <summary>
    /// When <paramref name="dryRun"/> is true the module must report what WOULD change without changing it.
    /// A module that cannot preview must refuse rather than act — "would have" reported after the fact is
    /// the one answer a dry run may never give.
    /// </summary>
    Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct);
}

/// <summary>
/// A module this platform does not have, PRESENT IN THE LISTING with the reason it is absent.
///
/// <para>This type exists because of the excluded-middle rule (A ∨ ¬A): if <c>apt</c> were simply missing
/// from a Windows host's <c>GET /api/v1/tools</c>, an operator and an orchestrator could not tell "this host
/// cannot do that" from "this agent is too old to say". Both need a classified answer. Running it is an
/// error that names the platform, so a plan written against the wrong OS fails with the reason rather than
/// with a 404.</para>
/// </summary>
public sealed class UnsupportedModule(string name, string reason, string? instead = null) : IModule
{
    public string Name { get; } = name;

    public string Reason { get; } = reason;

    /// <summary>The module that DOES do this here, when there is one — the other half of a useful refusal.</summary>
    public string? Instead { get; } = instead;

    public string Description =>
        $"Not available on this platform: {Reason}." + (Instead is null ? "" : $" Use `{Instead}` instead.");

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>(),
    };

    public bool Writes => false;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct) =>
        throw new PlatformNotSupportedException(Description);
}

/// <summary>
/// The module registry. Holds the supported modules and the named refusals side by side, because
/// <c>GET /api/v1/tools</c> has to answer for both.
/// </summary>
public sealed class ModuleRegistry
{
    private readonly Dictionary<string, IModule> _modules = new(StringComparer.Ordinal);

    /// <summary>Whether writing modules may be registered at all — the write gate, same as the Go agent's.</summary>
    public bool WriteEnabled { get; }

    public ModuleRegistry(bool writeEnabled) => WriteEnabled = writeEnabled;

    /// <summary>
    /// Registers a module, or REFUSES it by name when it writes and the gate is closed. The refusal is
    /// itself recorded as an unsupported entry, so a closed gate is visible in the listing instead of
    /// looking like a module that was never built.
    /// </summary>
    public ModuleRegistry Add(IModule module)
    {
        if (module.Writes && !WriteEnabled)
        {
            _modules[module.Name] = new UnsupportedModule(module.Name,
                "this agent's write gate is closed, so no module that changes the host is offered");
            return this;
        }

        _modules[module.Name] = module;
        return this;
    }

    public IModule? Find(string name) => _modules.GetValueOrDefault(name);

    public ToolsResponse Describe() => new(_modules.Values
        .OrderBy(m => m.Name, StringComparer.Ordinal)
        .Select(m => m is UnsupportedModule u
            ? new ToolInfo(u.Name, u.Description, u.InputSchema, false, Supported: false,
                UnsupportedReason: u.Reason)
            : new ToolInfo(m.Name, m.Description, m.InputSchema, m.Writes))
        .ToList());
}
