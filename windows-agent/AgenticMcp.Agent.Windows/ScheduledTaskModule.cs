using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// WINDOWS' SCHEDULED TASKS, read completely and written declaratively — <c>scheduled_task</c>.
///
/// <para>NOT CALLED `cron`, and the module registry says why in its own listing: a cron entry is five fields
/// and a command, a scheduled task is a set of TRIGGERS, a PRINCIPAL to run as, CONDITIONS (on battery, only
/// when idle, only when a network is available) and SETTINGS (restart on failure, stop after a timeout). One
/// name for both would promise a translation that does not exist, so the Linux `cron` module stays Linux and
/// this answers here.</para>
///
/// <para>THE READ IS COMPLETE, THE WRITE IS A SUBSET, and the gap is stated rather than hidden. Listing
/// returns every task with its triggers, principal, last result and next run — including the several hundred
/// tasks Windows itself ships under \\Microsoft\\Windows, because "which tasks exist on this host" has to be
/// answerable in full. Creating one supports the four schedules that cover what a fleet actually schedules
/// (once, daily, hourly-ish interval, at startup, at logon); anything richer is REFUSED with a sentence
/// naming what to use instead, because a module that silently created a task with a trigger the caller did
/// not ask for would be worse than one that says no.</para>
///
/// <para>`last_result` IS WINDOWS' OWN CODE and it is not a boolean: 0 is success, 267009 means "still
/// running", 267011 "has not run yet", 0x41303 "never started". A module that mapped those onto ok/failed
/// would report a task that has never run as broken.</para>
/// </summary>
public sealed class ScheduledTaskModule : IModule
{
    public string Name => "scheduled_task";

    public string Description =>
        "Windows scheduled tasks. Without `name`: list every task with its triggers, the account it runs as, "
        + "its last result code and next run time. With `name`: ensure it is present or absent, enabled or "
        + "disabled — `command` (+ optional `arguments`, `working_directory`), `schedule` one of once, daily, "
        + "interval, startup, logon, plus `start_time` (HH:mm) or `interval_minutes`, `run_as` and "
        + "`run_level`. Idempotent: the task is read and compared first. `dry_run: true` returns the plan. "
        + "Richer triggers and conditions are refused with a message rather than approximated. This is NOT "
        + "`cron`: a scheduled task has triggers, a principal, conditions and settings, and one name for both "
        + "would promise a translation that does not exist.";

    private static readonly string[] Schedules = ["once", "daily", "interval", "startup", "logon"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = P("string", "Task name, optionally with its folder: \"Yoloman\\\\nightly-report\". "
                                   + "Omit to LIST every task on the host."),
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["description"] = "Whether the task should exist. Default present.",
            },
            ["enabled"] = P("boolean", "Whether the task may fire. A DISABLED TASK STILL EXISTS, which is why "
                                       + "this is separate from state."),
            ["command"] = P("string", "The program to run. Required when creating a task."),
            ["arguments"] = P("string", "Arguments for the program, as one string (Windows passes it verbatim)."),
            ["working_directory"] = P("string", "Working directory for the action."),
            ["schedule"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Schedules,
                ["description"] = "once (at start_time today/tomorrow), daily (at start_time), interval "
                                  + "(every interval_minutes, indefinitely), startup (at boot), logon.",
            },
            ["start_time"] = P("string", "HH:mm, for `once` and `daily`."),
            ["interval_minutes"] = P("number", "For `interval`: how often it repeats."),
            ["run_as"] = P("string", "The account the task runs as. Default SYSTEM, which needs no stored "
                                     + "password; a named user would, and this module does not store one."),
            ["run_level"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "limited", "highest" },
                ["description"] = "highest = run with elevation. Default limited.",
            },
            ["description"] = P("string", "Free text shown in Task Scheduler."),
            ["dry_run"] = P("boolean", "Report what would change without applying it."),
        },
    };

    private static Dictionary<string, object> P(string type, string description) =>
        new() { ["type"] = type, ["description"] = description };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "scheduled_task manages the Windows task scheduler; on Linux a schedule is the `cron` module, "
                + "which is a different model and keeps its own name.");
        }

        var name = (parameters.GetValueOrDefault("name") as string ?? "").Trim();
        if (name.Length == 0)
        {
            return await ListAll(ct);
        }

        var state = (parameters.GetValueOrDefault("state") as string ?? "present").ToLowerInvariant();
        if (state is not ("present" or "absent"))
        {
            throw new ArgumentException($"state: {state} is not one of present, absent.");
        }

        dryRun = dryRun || parameters.GetValueOrDefault("dry_run") is true;
        var (folder, leaf) = Split(name);
        var current = await Read(folder, leaf, ct);

        if (state == "absent")
        {
            if (current is null)
            {
                return new ModuleResult(false, $"scheduled task {name} is already absent",
                    new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["existed"] = false });
            }
            if (dryRun)
            {
                return new ModuleResult(true, $"would remove scheduled task {name}",
                    new Dictionary<string, object?> { ["name"] = name, ["plan"] = "remove", ["before"] = current });
            }
            await WindowsPowerShellBridge.RunJson(
                $"Unregister-ScheduledTask -TaskName {UserModule.Quote(leaf)} "
                + $"-TaskPath {UserModule.Quote(folder)} -Confirm:$false -ErrorAction Stop",
                "@()", TimeSpan.FromMinutes(2), ct);
            if (await Read(folder, leaf, ct) is not null)
            {
                throw new InvalidOperationException(
                    $"Unregister-ScheduledTask reported success but {name} still exists on the host.");
            }
            return new ModuleResult(true, $"removed scheduled task {name}",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "absent", ["before"] = current });
        }

        return await EnsurePresent(name, folder, leaf, parameters, current, dryRun, ct);
    }

    /// <summary>"Yoloman\\nightly" → ("\\Yoloman\\", "nightly"); a bare name lives in the root folder.</summary>
    private static (string Folder, string Leaf) Split(string name)
    {
        var normalised = name.Replace('/', '\\').Trim('\\');
        var cut = normalised.LastIndexOf('\\');
        return cut < 0
            ? ("\\", normalised)
            : ("\\" + normalised[..cut] + "\\", normalised[(cut + 1)..]);
    }

    private static async Task<ModuleResult> ListAll(CancellationToken ct)
    {
        // Get-ScheduledTask gives the definition, Get-ScheduledTaskInfo the runtime facts (last/next run,
        // result code) — two cmdlets because Windows keeps them apart, and the answer needs both to be
        // useful. The Info call is per task and guarded: a task whose info cannot be read still belongs in
        // the list, with its definition and without invented runtime values.
        const string setup =
            "$out = New-Object System.Collections.ArrayList; "
            + "foreach ($t in Get-ScheduledTask) { "
            + "  $info = $null; try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName "
            + "    -TaskPath $t.TaskPath -ErrorAction Stop } catch { }; "
            + "  $triggers = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }); "
            + "  $actions = @($t.Actions | ForEach-Object { "
            + "    if ($_.Execute) { (($_.Execute) + ' ' + [string]$_.Arguments).Trim() } else { $_.ToString() } }); "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = $t.TaskName; path = $t.TaskPath; state = [string]$t.State; "
            + "    author = [string]$t.Author; description = [string]$t.Description; "
            + "    run_as = [string]$t.Principal.UserId; run_level = [string]$t.Principal.RunLevel; "
            + "    triggers = $triggers; actions = $actions; "
            + "    last_run = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString('o') } else { '' }; "
            + "    next_run = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('o') } else { '' }; "
            // [int64], NOT [int]: a task result is a DWORD, and Windows really does return values above
            // 2^31 — measured, the list died on "Der Wert 2147942402 kann nicht in den Typ System.Int32
            // konvertiert werden" (0x80070002, "file not found", from a task whose program is gone). One
            // task with an unlucky code took down the whole inventory, which is the failure mode this cast
            // exists to remove.
            + "    last_result = if ($info) { [int64]$info.LastTaskResult } else { $null }; "
            + "    missed_runs = if ($info) { [int64]$info.NumberOfMissedRuns } else { $null } }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(4), ct);

        var rows = new List<Dictionary<string, object?>>();
        foreach (var task in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var result = task.Long("last_result");
            rows.Add(new Dictionary<string, object?>
            {
                ["name"] = task.String("name"),
                ["path"] = task.String("path"),
                ["full_name"] = (task.String("path").TrimEnd('\\') + "\\" + task.String("name")).TrimStart('\\'),
                // Windows' own word: Ready | Running | Disabled | Queued | Unknown. Five, not two.
                ["state"] = task.String("state").ToLowerInvariant(),
                ["run_as"] = task.String("run_as"),
                ["run_level"] = task.String("run_level").ToLowerInvariant(),
                ["triggers"] = task.StringArray("triggers")
                    // The CIM class name is what Windows calls a trigger type; the prefix is noise.
                    .Select(t => t.Replace("MSFT_Task", "").Replace("Trigger", "").ToLowerInvariant())
                    .ToList(),
                ["actions"] = task.StringArray("actions"),
                ["last_run"] = task.String("last_run"),
                ["next_run"] = task.String("next_run"),
                ["last_result"] = result,
                // THE CODE EXPLAINED, not replaced. A boolean here would report a task that has never run
                // as broken, and 267009 ("still running") as a failure.
                ["last_result_meaning"] = Meaning(result),
                ["missed_runs"] = task.Long("missed_runs"),
                ["description"] = task.String("description"),
                ["author"] = task.String("author"),
            });
        }

        rows.Sort((a, b) => string.Compare((string?)a["full_name"], (string?)b["full_name"],
                                           StringComparison.OrdinalIgnoreCase));
        var ours = rows.Count(r => !((string?)r["path"] ?? "").StartsWith(@"\Microsoft\",
                                                                         StringComparison.OrdinalIgnoreCase));
        return new ModuleResult(false,
            $"{rows.Count} scheduled task(s), {ours} outside Windows' own \\Microsoft tree",
            new Dictionary<string, object?> { ["tasks"] = rows, ["count"] = rows.Count },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = rows.Count });
    }

    /// <summary>Windows' last-run codes, in words. The four that actually turn up.</summary>
    private static string Meaning(long? code) => code switch
    {
        null => "not reported",
        0 => "the last run succeeded",
        267009 => "still running",
        267011 => "has not run yet",
        267014 => "the last run was stopped by the user or by a timeout",
        2147943645 => "the service is not running or the task was never started",
        2147942402 => "the program the task runs was not found (0x80070002)",
        _ => $"the last run ended with code {code} (0x{code:X}) — Windows' own, not translated here",
    };

    private static async Task<Dictionary<string, object?>?> Read(string folder, string leaf,
                                                                CancellationToken ct)
    {
        var setup =
            "$out = @(); $t = Get-ScheduledTask -TaskName " + UserModule.Quote(leaf)
            + " -TaskPath " + UserModule.Quote(folder) + " -ErrorAction SilentlyContinue; "
            + "if ($t) { $out = @([pscustomobject]@{ "
            + "  name = $t.TaskName; path = $t.TaskPath; state = [string]$t.State; "
            + "  run_as = [string]$t.Principal.UserId; run_level = [string]$t.Principal.RunLevel; "
            + "  description = [string]$t.Description; "
            + "  actions = @($t.Actions | ForEach-Object { (($_.Execute) + ' ' + [string]$_.Arguments).Trim() }); "
            + "  triggers = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(2), ct);
        var found = answer.Items.FirstOrDefault();
        if (found.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return null;
        }
        return new Dictionary<string, object?>
        {
            ["name"] = found.String("name"),
            ["path"] = found.String("path"),
            ["state"] = found.String("state").ToLowerInvariant(),
            ["run_as"] = found.String("run_as"),
            ["run_level"] = found.String("run_level").ToLowerInvariant(),
            ["description"] = found.String("description"),
            ["actions"] = found.StringArray("actions"),
            ["triggers"] = found.StringArray("triggers"),
        };
    }

    private static async Task<ModuleResult> EnsurePresent(string name, string folder, string leaf,
        IReadOnlyDictionary<string, object?> parameters, Dictionary<string, object?>? current, bool dryRun,
        CancellationToken ct)
    {
        var command = parameters.GetValueOrDefault("command") as string;
        var arguments = parameters.GetValueOrDefault("arguments") as string ?? "";
        var workingDirectory = parameters.GetValueOrDefault("working_directory") as string;
        var schedule = (parameters.GetValueOrDefault("schedule") as string ?? "").ToLowerInvariant();
        var startTime = parameters.GetValueOrDefault("start_time") as string;
        var intervalMinutes = parameters.GetValueOrDefault("interval_minutes") as double?;
        var runAs = parameters.GetValueOrDefault("run_as") as string ?? "SYSTEM";
        var runLevel = (parameters.GetValueOrDefault("run_level") as string ?? "limited").ToLowerInvariant();
        var description = parameters.GetValueOrDefault("description") as string;
        var enabled = parameters.GetValueOrDefault("enabled") as bool?;

        if (current is null)
        {
            // Creating needs the two things a task cannot be invented without. Named together, because
            // learning about them one round trip at a time is the experience this check exists to prevent.
            var missing = new List<string>();
            if (string.IsNullOrWhiteSpace(command)) { missing.Add("command"); }
            if (schedule.Length == 0) { missing.Add("schedule"); }
            if (missing.Count > 0)
            {
                throw new ArgumentException(
                    $"{string.Join(" and ", missing)}: required to create a scheduled task. `schedule` is one "
                    + $"of {string.Join(", ", Schedules)}; once/daily also need `start_time` (HH:mm) and "
                    + "interval needs `interval_minutes`.");
            }
            if (!Schedules.Contains(schedule))
            {
                throw new ArgumentException(
                    $"schedule: {schedule} is not one of {string.Join(", ", Schedules)}. Richer triggers "
                    + "(weekly, monthly, on an event, on idle) are deliberately not approximated here — "
                    + "create such a task once in Task Scheduler and this module will report and enable or "
                    + "disable it, or use the `powershell` module where the full trigger surface is visible.");
            }
            if (schedule is "once" or "daily" && string.IsNullOrWhiteSpace(startTime))
            {
                throw new ArgumentException($"start_time: required for schedule {schedule} (HH:mm).");
            }
            if (schedule == "interval" && (intervalMinutes is null or <= 0))
            {
                throw new ArgumentException("interval_minutes: required for schedule interval, and must be > 0.");
            }
        }

        var wantedAction = $"{command} {arguments}".Trim();
        var steps = new List<string>();
        var changes = new Dictionary<string, object?>();

        if (current is null)
        {
            steps.Add("create");
            changes["create"] = new[] { null, name };
        }
        else
        {
            var haveActions = (List<string>)current["actions"]!;
            if (!string.IsNullOrWhiteSpace(command)
                && !haveActions.Any(a => string.Equals(a, wantedAction, StringComparison.OrdinalIgnoreCase)))
            {
                steps.Add("action");
                changes["action"] = new object?[] { haveActions.FirstOrDefault(), wantedAction };
            }
            if (enabled is not null)
            {
                var isEnabled = (string?)current["state"] != "disabled";
                if (isEnabled != enabled)
                {
                    steps.Add("enabled");
                    changes["enabled"] = new object?[] { isEnabled, enabled };
                }
            }
        }

        if (steps.Count == 0)
        {
            return new ModuleResult(false, $"scheduled task {name} is already as declared",
                new Dictionary<string, object?> { ["name"] = name, ["state"] = "present", ["current"] = current });
        }
        if (dryRun)
        {
            return new ModuleResult(true,
                $"would {(current is null ? "create" : "update")} scheduled task {name}: "
                + string.Join(", ", steps),
                new Dictionary<string, object?>
                {
                    ["name"] = name, ["plan"] = steps, ["changes"] = changes, ["before"] = current,
                });
        }

        var script = new List<string>();
        if (current is null || changes.ContainsKey("action"))
        {
            var action = $"$action = New-ScheduledTaskAction -Execute {UserModule.Quote(command!)}";
            if (!string.IsNullOrWhiteSpace(arguments)) { action += $" -Argument {UserModule.Quote(arguments)}"; }
            if (!string.IsNullOrWhiteSpace(workingDirectory))
            {
                action += $" -WorkingDirectory {UserModule.Quote(workingDirectory)}";
            }
            script.Add(action);

            script.Add(schedule switch
            {
                "once" => $"$trigger = New-ScheduledTaskTrigger -Once -At {UserModule.Quote(startTime!)}",
                "daily" => $"$trigger = New-ScheduledTaskTrigger -Daily -At {UserModule.Quote(startTime!)}",
                // Indefinitely, and the duration is explicit: -RepetitionInterval without -RepetitionDuration
                // silently repeats for one day only, which is the kind of default that turns a monitoring task
                // into a task that stopped yesterday.
                "interval" => "$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) "
                              + $"-RepetitionInterval (New-TimeSpan -Minutes {(int)intervalMinutes!}) "
                              + "-RepetitionDuration ([TimeSpan]::MaxValue)",
                "startup" => "$trigger = New-ScheduledTaskTrigger -AtStartup",
                _ => "$trigger = New-ScheduledTaskTrigger -AtLogon",
            });

            script.Add($"$principal = New-ScheduledTaskPrincipal -UserId {UserModule.Quote(runAs)} "
                       + $"-RunLevel {(runLevel == "highest" ? "Highest" : "Limited")} -LogonType ServiceAccount");
            var register = $"Register-ScheduledTask -TaskName {UserModule.Quote(leaf)} "
                           + $"-TaskPath {UserModule.Quote(folder)} -Action $action -Trigger $trigger "
                           + "-Principal $principal -Force -ErrorAction Stop";
            if (!string.IsNullOrWhiteSpace(description))
            {
                register += $" -Description {UserModule.Quote(description)}";
            }
            script.Add(register + " | Out-Null");
        }

        if (changes.ContainsKey("enabled"))
        {
            script.Add(enabled is true
                ? $"Enable-ScheduledTask -TaskName {UserModule.Quote(leaf)} -TaskPath {UserModule.Quote(folder)} | Out-Null"
                : $"Disable-ScheduledTask -TaskName {UserModule.Quote(leaf)} -TaskPath {UserModule.Quote(folder)} | Out-Null");
        }

        await WindowsPowerShellBridge.RunJson(string.Join("; ", UserModule.Announced(script)), "@()",
            TimeSpan.FromMinutes(3), ct);

        var after = await Read(folder, leaf, ct);
        if (after is null)
        {
            throw new InvalidOperationException(
                $"the task operations reported success but {name} does not exist on the host afterwards.");
        }
        return new ModuleResult(true,
            $"{(current is null ? "created" : "updated")} scheduled task {name}: {string.Join(", ", steps)}",
            new Dictionary<string, object?>
            {
                ["name"] = name, ["state"] = "present", ["applied"] = steps, ["changes"] = changes,
                ["before"] = current, ["after"] = after,
            });
    }
}
