using System.ServiceProcess;
using AgenticMcp.Agent.Core;
using Microsoft.Win32;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>service</c> — a Windows service's run state and start mode. THE SAME NAME as the Linux module, because
/// it is the same concept: <c>state: started</c> starts a service on either platform, and
/// <c>enabled: true</c> makes it come back after a reboot.
///
/// <para>That identity is why <c>systemd</c> is listed as unsupported on this host and points here instead. A
/// unit file is not a service; the thing both platforms genuinely share is "a named background program with a
/// run state and a start mode", and that is what this module is.</para>
///
/// <para>TWO PROPERTIES, ONE MODULE, deliberately: run state and start mode are independent — a stopped
/// service can be set to start automatically, and a running one can be disabled — so both are reported and
/// each is only touched when asked for. Collapsing them into one "enabled and running" flag would make the
/// four real combinations unreachable.</para>
///
/// <para>UNVERIFIED: written and compiling, never run. There is no Windows host in this project yet.</para>
/// </summary>
public sealed class ServiceModule : IModule
{
    public string Name => "service";

    public string Description =>
        "Ensure a Windows service is in a declared run state and start mode. `name` is the service name (not "
        + "the display name); `state` is started, stopped or restarted; `enabled` is auto, manual or "
        + "disabled (true/false are accepted as auto/disabled). An ansible.windows.win_service task, a Chef "
        + "`windows_service` resource, a Puppet `service` type or a DSC Service block translate to a call "
        + "here — and so does a `service` task written for a Linux host, which is the point of the shared "
        + "name. Idempotent: the current state and start mode are read first, and each is only changed when "
        + "it differs. Returns both, before and after.";

    /// <summary>
    /// Start-mode values as the SERVICE CONTROL MANAGER stores them, in
    /// HKLM\SYSTEM\CurrentControlSet\Services\&lt;name&gt;\Start. ServiceController can read a start type but
    /// not set one, and `sc config` is a process this module would have to parse — the registry value is what
    /// sc config writes, so it is written directly and the mapping is stated rather than remembered.
    /// </summary>
    private static readonly Dictionary<string, int> StartValues = new(StringComparer.OrdinalIgnoreCase)
    {
        ["boot"] = 0, ["system"] = 1, ["auto"] = 2, ["manual"] = 3, ["disabled"] = 4,
    };

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The service name, e.g. \"Spooler\" — not the display name.",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "started", "stopped", "restarted" },
                ["description"] = "Leave unset to only change the start mode.",
            },
            ["enabled"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "auto", "manual", "disabled" },
                ["description"] = "The start mode. true/false are accepted as auto/disabled. Leave unset to "
                                  + "only change the run state.",
            },
            ["timeout_seconds"] = new Dictionary<string, object>
            {
                ["type"] = "number",
                ["default"] = 60,
                ["description"] = "How long to wait for a start or stop to complete.",
            },
        },
        ["required"] = new[] { "name" },
    };

    public bool Writes => true;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var name = Str(parameters, "name") ?? throw new ArgumentException("name: must not be empty");
        var wantedState = Str(parameters, "state");
        var wantedMode = NormaliseMode(Str(parameters, "enabled"));
        if (wantedState is null && wantedMode is null)
        {
            // Neither asked for is not "do nothing quietly": the caller believes they requested something.
            throw new ArgumentException("one of state or enabled is required");
        }

        if (wantedState is not null and not "started" and not "stopped" and not "restarted")
        {
            throw new ArgumentException(
                $"state: must be started, stopped or restarted, got \"{wantedState}\"");
        }

        var timeout = TimeSpan.FromSeconds(Num(parameters, "timeout_seconds") ?? 60);

        using var controller = new ServiceController(name);
        string statusBefore;
        try
        {
            statusBefore = controller.Status.ToString();
        }
        catch (InvalidOperationException ex)
        {
            // The service does not exist. Named, because "not installed" and "installed but stopped" are
            // different facts and a caller acts differently on each.
            throw new ArgumentException($"name: no service called \"{name}\" on this host", ex);
        }

        var modeBefore = ReadStartMode(name);
        var data = new Dictionary<string, object?>
        {
            ["name"] = name,
            ["state_before"] = statusBefore,
            ["enabled_before"] = modeBefore,
            ["dry_run"] = dryRun,
        };
        var changes = new List<string>();

        // START MODE FIRST. If the caller wants a service disabled AND stopped, doing it in this order means
        // a service that restarts itself between the two steps cannot come back enabled.
        if (wantedMode is not null && !string.Equals(modeBefore, wantedMode, StringComparison.OrdinalIgnoreCase))
        {
            changes.Add($"start mode {modeBefore} -> {wantedMode}");
            if (!dryRun)
            {
                WriteStartMode(name, StartValues[wantedMode]);
            }
        }

        var running = statusBefore is "Running" or "StartPending";
        switch (wantedState)
        {
            case "started" when !running:
                changes.Add("started");
                if (!dryRun)
                {
                    controller.Start();
                    controller.WaitForStatus(ServiceControllerStatus.Running, timeout);
                }

                break;
            case "stopped" when running:
                changes.Add("stopped");
                if (!dryRun)
                {
                    controller.Stop();
                    controller.WaitForStatus(ServiceControllerStatus.Stopped, timeout);
                }

                break;
            case "restarted":
                // ALWAYS a change, and honestly so: restarting is the operation, not a state to converge on.
                changes.Add("restarted");
                if (!dryRun)
                {
                    if (running)
                    {
                        controller.Stop();
                        controller.WaitForStatus(ServiceControllerStatus.Stopped, timeout);
                    }

                    controller.Start();
                    controller.WaitForStatus(ServiceControllerStatus.Running, timeout);
                }

                break;
        }

        if (!dryRun)
        {
            controller.Refresh();
            data["state_after"] = controller.Status.ToString();
            data["enabled_after"] = ReadStartMode(name);
        }

        if (changes.Count == 0)
        {
            return Task.FromResult(new ModuleResult(false, "already in the requested state", data));
        }

        data["changes"] = changes;
        return Task.FromResult(new ModuleResult(true,
            (dryRun ? "would change: " : "") + string.Join("; ", changes), data));
    }

    /// <summary>true/false are accepted as auto/disabled — the Linux module's spelling, so a shared task works.</summary>
    private static string? NormaliseMode(string? raw)
    {
        if (raw is null)
        {
            return null;
        }

        var mode = raw.Trim();
        if (bool.TryParse(mode, out var flag))
        {
            return flag ? "auto" : "disabled";
        }

        if (!StartValues.ContainsKey(mode))
        {
            throw new ArgumentException(
                $"enabled: must be auto, manual, disabled or a boolean, got \"{raw}\"");
        }

        return mode.ToLowerInvariant();
    }

    private static string? ReadStartMode(string name)
    {
        using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{name}");
        if (key?.GetValue("Start") is not int value)
        {
            return null;
        }

        return StartValues.FirstOrDefault(kv => kv.Value == value).Key ?? value.ToString();
    }

    private static void WriteStartMode(string name, int value)
    {
        using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{name}",
                            writable: true)
                        ?? throw new IOException($"cannot open the service key for {name}");
        key.SetValue("Start", value, RegistryValueKind.DWord);
    }

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;

    private static double? Num(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) && v is not null
        && double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : null;
}
