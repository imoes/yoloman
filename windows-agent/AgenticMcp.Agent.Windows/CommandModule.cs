using System.Diagnostics;
using System.Text;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// Run an executable with an argument list — the fleet's <c>command</c> module, field for field
/// (<c>argv</c> / <c>cmd</c> / <c>chdir</c> / <c>env</c> in, <c>{cmd, rc, stdout, stderr}</c> out).
///
/// <para>NO SHELL, on purpose and unlike the name suggests: the process is started directly with its argument
/// list, so a path with a space, an argument with a quote and a value with an ampersand mean what they say. The
/// Go module makes the same choice. Anything that genuinely needs shell semantics — a pipeline, a redirect,
/// an environment expansion — is asking for the <c>powershell</c> module, which is where those belong and
/// where they are visible as such.</para>
///
/// <para>IT LIVES IN THE WINDOWS PROJECT although nothing in it needs Windows, because it is the WINDOWS
/// IMPLEMENTATION of a name the Go agent already answers on Linux — and registering a second cross-platform
/// `command` in the shared module set would put two implementations of one name in one process on the dev
/// host, which is the one thing the registry must never allow.</para>
///
/// <para>ONE DELIBERATE DIFFERENCE FROM LINUX, and it must not be smoothed over: `cmd` (a single string) is
/// split on whitespace there, which on Windows would break every second real command, because the paths have
/// spaces (`C:\Program Files\…`). It is accepted for compatibility and refused with that reason when the
/// string contains a quote or looks like a quoted path — `argv` is unambiguous and costs the caller one pair
/// of brackets.</para>
///
/// <para>`changed: true` ALWAYS, matching the Go module: this module cannot know what the command did, and a
/// module that guessed would be the one place in the system where `changed` is a hopeful assumption rather
/// than a measurement. A caller who knows better states it in the runbook.</para>
/// </summary>
public sealed class CommandModule : IModule
{
    public string Name => "command";

    public string Description =>
        "Run one executable with an argument list (`argv: [\"ipconfig\", \"/all\"]`), without a shell — no "
        + "pipelines, redirects or expansion; use the `powershell` module for those. Optional `chdir` and "
        + "`env`. Returns {cmd, rc, stdout, stderr} and always reports changed:true, because it cannot know "
        + "what the command did. `timeout_seconds` bounds the run (default 300).";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["argv"] = new Dictionary<string, object>
            {
                ["type"] = "array",
                ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "The executable and its arguments, unsplit and unquoted. Preferred.",
            },
            ["cmd"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "A single command line, split on whitespace. Accepted for compatibility with "
                                  + "the Linux module; on Windows prefer argv, because paths contain spaces.",
            },
            ["chdir"] = new Dictionary<string, object>
            {
                ["type"] = "string", ["description"] = "Working directory for the process.",
            },
            ["env"] = new Dictionary<string, object>
            {
                ["type"] = "object",
                ["description"] = "Extra environment variables for the child process.",
            },
            ["timeout_seconds"] = new Dictionary<string, object>
            {
                ["type"] = "number", ["description"] = "How long to wait before killing the process. Default 300.",
            },
            ["dry_run"] = new Dictionary<string, object>
            {
                ["type"] = "boolean", ["description"] = "Report the command that would run, and run nothing.",
            },
        },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        var argv = UserModule.AsStringList(parameters.GetValueOrDefault("argv"));
        var cmd = parameters.GetValueOrDefault("cmd") as string;
        if (argv.Count > 0 == !string.IsNullOrWhiteSpace(cmd))
        {
            throw new ArgumentException("command: exactly one of cmd or argv must be given.");
        }
        if (argv.Count == 0)
        {
            if (cmd!.Contains('"') || cmd.Contains('\''))
            {
                throw new ArgumentException(
                    "cmd: contains quotes, which this module would split on whitespace and get wrong. Pass "
                    + "`argv` as a list instead — on Windows a command line with quotes almost always means a "
                    + "path with spaces, and splitting it silently produces a different command.");
            }
            argv = cmd.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (argv.Count == 0)
            {
                throw new ArgumentException("cmd: must not be empty.");
            }
        }

        var line = string.Join(" ", argv);
        if (dryRun || parameters.GetValueOrDefault("dry_run") is true)
        {
            return new ModuleResult(true, "skipped (dry run)",
                new Dictionary<string, object?> { ["cmd"] = line });
        }

        var timeout = parameters.GetValueOrDefault("timeout_seconds") switch
        {
            double seconds when seconds > 0 => TimeSpan.FromSeconds(seconds),
            _ => TimeSpan.FromMinutes(5),
        };

        var psi = new ProcessStartInfo(argv[0])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in argv.Skip(1))
        {
            psi.ArgumentList.Add(argument);
        }
        if (parameters.GetValueOrDefault("chdir") is string chdir && chdir.Length > 0)
        {
            psi.WorkingDirectory = chdir;
        }
        if (parameters.GetValueOrDefault("env") is System.Text.Json.JsonElement env
            && env.ValueKind == System.Text.Json.JsonValueKind.Object)
        {
            foreach (var entry in env.EnumerateObject())
            {
                psi.Environment[entry.Name] = entry.Value.ValueKind == System.Text.Json.JsonValueKind.String
                    ? entry.Value.GetString() ?? ""
                    : entry.Value.ToString();
            }
        }

        using var process = Process.Start(psi)
                            // The executable's own name in the message: "the system cannot find the file
                            // specified" without saying which file is the least useful error Windows has.
                            ?? throw new FileNotFoundException($"could not start {argv[0]}");
        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(deadline.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Exited between the timeout and the kill.
            }
            // A TIMEOUT SAYS WHAT IT DOES NOT KNOW. The process was killed here, but a command that runs for
            // five minutes has usually done something, and reporting "failed" would state more than we
            // measured.
            throw new TimeoutException(
                $"{argv[0]} did not finish within {timeout.TotalSeconds:0}s and was killed. Whatever it had "
                + "already done to this host has been done; re-read the state before retrying, and pass a "
                + "longer timeout_seconds for a command that is expected to take minutes.");
        }

        return new ModuleResult(true, "executed", new Dictionary<string, object?>
        {
            ["cmd"] = line,
            ["rc"] = process.ExitCode,
            ["stdout"] = await stdout,
            ["stderr"] = await stderr,
        });
    }
}
