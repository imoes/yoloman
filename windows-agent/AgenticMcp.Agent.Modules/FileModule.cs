using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// <c>file</c> — a path in a declared state. The same module name and the same parameter names as
/// <c>ansible.builtin.file</c> and the Go agent's own <c>file</c>, because the same name must mean the same
/// thing on both platforms or it would need a different name.
///
/// <para>IDEMPOTENT, and that is the whole content of the module: <c>changed</c> is false when the path is
/// already in the requested state, which is what makes a converge report readable. A module that reported
/// "changed" every run would make drift invisible by drowning it.</para>
///
/// <para>WHAT IS NOT HERE, deliberately. <c>mode</c>, <c>owner</c> and <c>group</c> are POSIX concepts; a
/// Windows ACL is not a mode bit, and quietly accepting <c>mode: "0644"</c> would be the equivalence error
/// this project's identity rule exists to prevent. They are rejected by name with that reason, and ACLs get
/// their own parameters when they are implemented — a different concept under a different name.</para>
/// </summary>
public sealed class FileModule : IModule
{
    public string Name => "file";

    public string Description =>
        "Ensure a path is in a declared state on this host. `state: file` (the default) requires it to exist "
        + "as a file and creates an empty one if it does not; `state: directory` creates the directory and "
        + "its parents; `state: absent` removes it (a directory recursively); `state: touch` updates the "
        + "modification time, creating the file if needed. An ansible.builtin.file task, a Chef `directory`/"
        + "`file` resource, a Puppet `file` type or a Salt `file.managed` state translate to a call here. "
        + "Idempotent: `changed` is false when the path is already as requested. POSIX-only parameters "
        + "(mode, owner, group) are REJECTED with a reason rather than ignored — a Windows ACL is not a mode "
        + "bit, and pretending otherwise would silently do nothing.";

    /// <summary>The four states, exhaustive and named — there is no fifth, and no implicit default beyond `file`.</summary>
    private static readonly string[] States = ["file", "directory", "absent", "touch"];

    /// <summary>POSIX parameters that have no meaning here. Refused by name; see the class remarks.</summary>
    private static readonly string[] PosixOnly = ["mode", "owner", "group", "selevel", "serole", "setype"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["path"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The path to act on.",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = States,
                ["default"] = "file",
                ["description"] = "file | directory | absent | touch",
            },
        },
        ["required"] = new[] { "path" },
    };

    public bool Writes => true;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var path = Params.Str(parameters, "path");
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("path: must not be empty");
        }

        foreach (var posix in PosixOnly)
        {
            if (parameters.ContainsKey(posix))
            {
                // Refused, not ignored. Silently dropping `mode: "0600"` would report success for a file that
                // is readable by everyone — the worst kind of wrong answer, because it looks like the right one.
                throw new ArgumentException(
                    $"{posix}: POSIX-only and not implemented on this platform. A Windows ACL is not a mode "
                    + "bit; use the `acl` module when it lands rather than a permission this agent would "
                    + "silently drop.");
            }
        }

        var state = Params.Str(parameters, "state") ?? "file";
        if (!States.Contains(state))
        {
            throw new ArgumentException(
                $"state: must be one of {string.Join(", ", States)}, got {state.r()}");
        }

        var fileExists = File.Exists(path);
        var dirExists = Directory.Exists(path);

        return Task.FromResult(state switch
        {
            "absent" => Absent(path, fileExists, dirExists, dryRun),
            "directory" => Directory_(path, fileExists, dirExists, dryRun),
            "touch" => Touch(path, fileExists, dirExists, dryRun),
            _ => FileState(path, fileExists, dirExists, dryRun),
        });
    }

    private static ModuleResult Absent(string path, bool fileExists, bool dirExists, bool dryRun)
    {
        if (!fileExists && !dirExists)
        {
            return Unchanged(path, "absent", "already absent");
        }

        if (!dryRun)
        {
            if (dirExists)
            {
                Directory.Delete(path, recursive: true);
            }
            else
            {
                File.Delete(path);
            }
        }

        return Changed(path, "absent", dryRun,
            dirExists ? "directory removed (recursively)" : "file removed", dryRun);
    }

    private static ModuleResult Directory_(string path, bool fileExists, bool dirExists, bool dryRun)
    {
        if (dirExists)
        {
            return Unchanged(path, "directory", "already a directory");
        }

        if (fileExists)
        {
            // A conflict, not a silent replacement: deleting a file to put a directory in its place is a data
            // loss the caller did not ask for. `state: absent` first says it out loud.
            throw new IOException($"{path} exists and is a file; refusing to replace it with a directory. "
                                  + "Remove it explicitly with state: absent first.");
        }

        if (!dryRun)
        {
            Directory.CreateDirectory(path);
        }

        return Changed(path, "directory", dryRun, "directory created (with parents)", dryRun);
    }

    private static ModuleResult Touch(string path, bool fileExists, bool dirExists, bool dryRun)
    {
        if (dirExists)
        {
            throw new IOException($"{path} is a directory; touch applies to files");
        }

        if (!dryRun)
        {
            if (fileExists)
            {
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
            }
            else
            {
                CreateParent(path);
                File.WriteAllBytes(path, []);
            }
        }

        // ALWAYS changed, and this is the one state where that is honest: touch's purpose IS to move the
        // modification time, so there is no "already touched".
        return Changed(path, "touch", dryRun, fileExists ? "mtime updated" : "empty file created", dryRun);
    }

    private static ModuleResult FileState(string path, bool fileExists, bool dirExists, bool dryRun)
    {
        if (dirExists)
        {
            throw new IOException($"{path} is a directory; refusing to replace it with a file");
        }

        if (fileExists)
        {
            return Unchanged(path, "file", "already a file");
        }

        if (!dryRun)
        {
            CreateParent(path);
            File.WriteAllBytes(path, []);
        }

        return Changed(path, "file", dryRun, "empty file created", dryRun);
    }

    private static void CreateParent(string path)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(parent) && !Directory.Exists(parent))
        {
            Directory.CreateDirectory(parent);
        }
    }

    private static ModuleResult Unchanged(string path, string state, string why) =>
        new(false, why, new Dictionary<string, object?> { ["path"] = path, ["state"] = state });

    private static ModuleResult Changed(string path, string state, bool dryRun, string what, bool preview) =>
        new(true, preview ? $"would change: {what}" : what,
            new Dictionary<string, object?>
            {
                ["path"] = path,
                ["state"] = state,
                ["dry_run"] = dryRun,
            });
}

/// <summary>Parameter reading, shared by the modules so one spelling of "missing" serves all of them.</summary>
internal static class Params
{
    internal static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;

    internal static bool Bool(IReadOnlyDictionary<string, object?> p, string key, bool fallback = false) =>
        p.TryGetValue(key, out var v)
            ? v switch
            {
                bool b => b,
                string s => bool.TryParse(s, out var parsed) ? parsed : fallback,
                _ => fallback,
            }
            : fallback;

    /// <summary>A tiny helper so an error message can quote a value the way the rest of the fleet does.</summary>
    internal static string r(this string? value) => value is null ? "null" : $"\"{value}\"";
}
