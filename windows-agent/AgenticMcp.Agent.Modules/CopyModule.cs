using System.Security.Cryptography;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// <c>copy</c> — put content at a path, from a local file (<c>src</c>) or given inline (<c>content</c>).
/// Same name and same parameters as <c>ansible.builtin.copy</c> and the Go agent's <c>copy</c>.
///
/// <para>IDEMPOTENCE IS BY CONTENT, not by timestamp: the destination is hashed and left alone when it
/// already holds exactly these bytes. A mtime comparison would report a change for a file someone touched and
/// no change for one that was edited and back-dated — the second of those is the dangerous direction.</para>
///
/// <para>The hash is SHA-256 and it is REPORTED, before and after. That is the sufficient-reason rule applied
/// to a write: "changed: true" without saying from what to what is a claim nobody can check.</para>
/// </summary>
public sealed class CopyModule : IModule
{
    public string Name => "copy";

    public string Description =>
        "Write content to a path on this host, either from a local file (`src`) or given inline (`content`). "
        + "An ansible.builtin.copy task, a Chef `cookbook_file`/`file` with content, a Puppet `file` with "
        + "`content`, or a Salt `file.managed` translate to a call here. Idempotent BY CONTENT: the "
        + "destination is hashed, and a file that already holds exactly these bytes is reported as unchanged "
        + "with its checksum. `backup: true` keeps the previous content beside it with a timestamped suffix "
        + "and reports the path. Parent directories are created. POSIX-only parameters (mode, owner, group) "
        + "are REJECTED with a reason rather than silently dropped.";

    private static readonly string[] PosixOnly = ["mode", "owner", "group"];

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["dest"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Where to write.",
            },
            ["content"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The content to write. Mutually exclusive with `src`.",
            },
            ["src"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "A local file to copy from. Mutually exclusive with `content`.",
            },
            ["backup"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = false,
                ["description"] = "Keep the previous content beside the destination, with a timestamp, and "
                                  + "report where.",
            },
        },
        ["required"] = new[] { "dest" },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var dest = Params.Str(parameters, "dest");
        if (string.IsNullOrWhiteSpace(dest))
        {
            throw new ArgumentException("dest: must not be empty");
        }

        foreach (var posix in PosixOnly)
        {
            if (parameters.ContainsKey(posix))
            {
                throw new ArgumentException(
                    $"{posix}: POSIX-only and not implemented on this platform. A Windows ACL is not a mode "
                    + "bit; a dropped permission would be reported as success.");
            }
        }

        var src = Params.Str(parameters, "src");
        var content = Params.Str(parameters, "content");
        if (src is not null && content is not null)
        {
            // Both is not "src wins" — it is a caller who believes two different things about what should
            // land there, and guessing which would make the wrong one silent.
            throw new ArgumentException("src and content are mutually exclusive: pass exactly one");
        }

        byte[] wanted;
        if (src is not null)
        {
            if (!File.Exists(src))
            {
                throw new FileNotFoundException($"src: {src} does not exist on this host");
            }

            wanted = await File.ReadAllBytesAsync(src, ct);
        }
        else if (content is not null)
        {
            wanted = System.Text.Encoding.UTF8.GetBytes(content);
        }
        else
        {
            throw new ArgumentException("one of src or content is required");
        }

        var wantedHash = Sha256(wanted);
        var existed = File.Exists(dest);
        string? beforeHash = null;
        if (existed)
        {
            beforeHash = Sha256(await File.ReadAllBytesAsync(dest, ct));
            if (beforeHash == wantedHash)
            {
                // The whole point of hashing: an unchanged run says so, with the checksum that proves it.
                return new ModuleResult(false, "already has this content", new Dictionary<string, object?>
                {
                    ["dest"] = dest,
                    ["checksum"] = wantedHash,
                    ["size"] = wanted.Length,
                });
            }
        }

        var data = new Dictionary<string, object?>
        {
            ["dest"] = dest,
            ["checksum_before"] = beforeHash,
            ["checksum"] = wantedHash,
            ["size"] = wanted.Length,
            ["dry_run"] = dryRun,
        };

        if (dryRun)
        {
            // A real preview: both checksums are already known, so the caller learns exactly what would
            // change without anything being written.
            return new ModuleResult(true,
                existed ? "would replace the content" : "would create the file", data);
        }

        string? backupPath = null;
        if (existed && Params.Bool(parameters, "backup"))
        {
            // A fixed, sortable suffix rather than a random one: a directory of backups should read as a
            // history, and UTC because a host that moves timezone must not appear to have gone backwards.
            backupPath = $"{dest}.{DateTime.UtcNow:yyyyMMddTHHmmssZ}.bak";
            File.Copy(dest, backupPath, overwrite: true);
            data["backup"] = backupPath;
        }

        var parent = Path.GetDirectoryName(Path.GetFullPath(dest));
        if (!string.IsNullOrEmpty(parent) && !Directory.Exists(parent))
        {
            Directory.CreateDirectory(parent);
        }

        // Written to a temporary file beside the destination and moved into place: a reader never sees a
        // half-written config, and a crash mid-write leaves the old content rather than a truncated file.
        // Same reason the config catalogue's own writer does it (bossman/tools/_jsonio.py).
        var temporary = dest + ".agentic-tmp";
        await File.WriteAllBytesAsync(temporary, wanted, ct);
        File.Move(temporary, dest, overwrite: true);

        return new ModuleResult(true, existed ? "content replaced" : "file created", data);
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexStringLower(SHA256.HashData(bytes));
}
