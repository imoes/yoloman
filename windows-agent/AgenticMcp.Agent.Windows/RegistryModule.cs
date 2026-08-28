using AgenticMcp.Agent.Core;
using Microsoft.Win32;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>registry</c> — a registry value as desired state. A NEW name, not a Linux module's, because the
/// registry has no counterpart there: this is the reverse of the <c>supported: false</c> listing, and on a
/// Linux host this module is the one that would be listed as unavailable.
///
/// <para>THE REGISTRY IS A CONFIG FILE THAT IS NOT A FILE, which is why it needs its own module rather than
/// being reached through <c>copy</c> or a template. It is typed (a DWORD is not the string "1"), it is
/// hierarchical, and a value's absence differs from a value set to empty — three distinctions a file-shaped
/// module would flatten.</para>
///
/// <para>UNVERIFIED: written and compiling, never run. There is no Windows host in this project yet, and
/// nothing here should be read as measured. The parameters and the semantics are the ones
/// <c>ansible.windows.win_regedit</c> established, so a task written for that translates directly.</para>
/// </summary>
public sealed class RegistryModule : IModule
{
    public string Name => "registry";

    public string Description =>
        "Ensure a Windows registry value is in a declared state. `path` is the key (HKLM:\\SOFTWARE\\..., or "
        + "the long form HKEY_LOCAL_MACHINE\\...), `name` the value inside it (omit for the key's default "
        + "value), `data` the content and `type` one of string, expand_string, dword, qword, multi_string, "
        + "binary. `state: absent` removes the value, or the whole key when no `name` is given. An "
        + "ansible.windows.win_regedit task, a Chef `registry_key` resource, a Puppet `registry_value` or a "
        + "DSC Registry block translate to a call here. Idempotent: the current value is read and compared "
        + "BY TYPE AND CONTENT first, and an already-correct value reports changed:false with what it holds.";

    private static readonly Dictionary<string, RegistryValueKind> Kinds = new(StringComparer.OrdinalIgnoreCase)
    {
        ["string"] = RegistryValueKind.String,
        ["expand_string"] = RegistryValueKind.ExpandString,
        ["dword"] = RegistryValueKind.DWord,
        ["qword"] = RegistryValueKind.QWord,
        ["multi_string"] = RegistryValueKind.MultiString,
        ["binary"] = RegistryValueKind.Binary,
    };

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["path"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = @"The key, e.g. HKLM:\SOFTWARE\Contoso\Agent.",
            },
            ["name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The value's name. Omit for the key's default value.",
            },
            ["data"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The content to set. For multi_string, newline-separated; for binary, hex.",
            },
            ["type"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Kinds.Keys.ToArray(),
                ["default"] = "string",
                ["description"] = "The value's type. A DWORD is not the string \"1\".",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["default"] = "present",
            },
        },
        ["required"] = new[] { "path" },
    };

    public bool Writes => true;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var rawPath = Str(parameters, "path") ?? throw new ArgumentException("path: must not be empty");
        var (hive, subKey) = SplitHive(rawPath);
        var name = Str(parameters, "name");
        var state = Str(parameters, "state") ?? "present";
        var typeName = Str(parameters, "type") ?? "string";
        if (!Kinds.TryGetValue(typeName, out var kind))
        {
            throw new ArgumentException(
                $"type: must be one of {string.Join(", ", Kinds.Keys)}, got \"{typeName}\"");
        }

        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Default);

        if (state == "absent")
        {
            return Task.FromResult(Absent(baseKey, subKey, name, dryRun));
        }

        var data = Str(parameters, "data")
                   ?? throw new ArgumentException("data: required unless state is absent");
        var wanted = Convert_(data, kind);

        using var existing = baseKey.OpenSubKey(subKey, writable: false);
        var current = existing?.GetValue(name ?? "");
        var currentKind = existing is null ? (RegistryValueKind?)null
            : name is null ? existing.GetValueKind("") : SafeKind(existing, name);

        // BY TYPE AND CONTENT. A DWORD 1 and the string "1" render the same and are not the same value; a
        // comparison on the rendered text would report "already correct" for a value the daemon reads
        // differently.
        if (current is not null && currentKind == kind && Same(current, wanted))
        {
            return Task.FromResult(new ModuleResult(false, "already set", new Dictionary<string, object?>
            {
                ["path"] = rawPath,
                ["name"] = name,
                ["type"] = typeName,
                ["value"] = Render(current),
            }));
        }

        var result = new Dictionary<string, object?>
        {
            ["path"] = rawPath,
            ["name"] = name,
            ["type"] = typeName,
            ["value_before"] = current is null ? null : Render(current),
            ["value"] = Render(wanted),
            ["dry_run"] = dryRun,
        };

        if (dryRun)
        {
            return Task.FromResult(new ModuleResult(true,
                current is null ? "would create the value" : "would change the value", result));
        }

        using var writable = baseKey.CreateSubKey(subKey, writable: true)
                             ?? throw new IOException($"cannot create or open {rawPath}");
        writable.SetValue(name ?? "", wanted, kind);
        return Task.FromResult(new ModuleResult(true,
            current is null ? "value created" : "value changed", result));
    }

    private static ModuleResult Absent(RegistryKey baseKey, string subKey, string? name, bool dryRun)
    {
        using var existing = baseKey.OpenSubKey(subKey, writable: false);
        if (existing is null)
        {
            return new ModuleResult(false, "the key does not exist");
        }

        // A NAME MAKES THE DIFFERENCE between deleting one value and deleting a whole subtree, so it is not
        // optional by accident: without `name` this removes the key AND everything under it, and the message
        // says which of the two happened.
        if (name is null)
        {
            if (!dryRun)
            {
                baseKey.DeleteSubKeyTree(subKey, throwOnMissingSubKey: false);
            }

            return new ModuleResult(true, dryRun ? "would remove the key and everything under it"
                : "key removed (with everything under it)");
        }

        if (existing.GetValue(name) is null)
        {
            return new ModuleResult(false, "the value does not exist");
        }

        if (!dryRun)
        {
            using var writable = baseKey.OpenSubKey(subKey, writable: true)!;
            writable.DeleteValue(name, throwOnMissingValue: false);
        }

        return new ModuleResult(true, dryRun ? "would remove the value" : "value removed",
            new Dictionary<string, object?> { ["name"] = name });
    }

    /// <summary>
    /// Splits "HKLM:\SOFTWARE\X" or "HKEY_LOCAL_MACHINE\SOFTWARE\X" into hive and sub-key.
    /// Both spellings, because PowerShell writes the first and every piece of documentation the second.
    /// </summary>
    internal static (RegistryHive Hive, string SubKey) SplitHive(string path)
    {
        var normalised = path.Replace('/', '\\').TrimStart('\\');
        var cut = normalised.IndexOfAny([':', '\\']);
        var head = (cut < 0 ? normalised : normalised[..cut]).ToUpperInvariant();
        var rest = cut < 0 ? "" : normalised[(cut + 1)..].TrimStart(':', '\\');

        var hive = head switch
        {
            "HKLM" or "HKEY_LOCAL_MACHINE" => RegistryHive.LocalMachine,
            "HKCU" or "HKEY_CURRENT_USER" => RegistryHive.CurrentUser,
            "HKCR" or "HKEY_CLASSES_ROOT" => RegistryHive.ClassesRoot,
            "HKU" or "HKEY_USERS" => RegistryHive.Users,
            "HKCC" or "HKEY_CURRENT_CONFIG" => RegistryHive.CurrentConfig,
            _ => throw new ArgumentException(
                $"path: unknown hive \"{head}\". Use HKLM, HKCU, HKCR, HKU or HKCC (or their long names)."),
        };
        if (rest.Length == 0)
        {
            // Refusing the bare hive is not pedantry: `state: absent` on it would mean deleting the hive.
            throw new ArgumentException("path: a hive alone is not a key; name a sub-key under it");
        }

        return (hive, rest);
    }

    private static object Convert_(string data, RegistryValueKind kind) => kind switch
    {
        RegistryValueKind.DWord => int.Parse(data, System.Globalization.CultureInfo.InvariantCulture),
        RegistryValueKind.QWord => long.Parse(data, System.Globalization.CultureInfo.InvariantCulture),
        RegistryValueKind.MultiString => data.Split('\n').Select(l => l.TrimEnd('\r')).ToArray(),
        RegistryValueKind.Binary => Convert.FromHexString(data.Replace(" ", "").Replace(":", "")),
        _ => data,
    };

    private static bool Same(object current, object wanted) => (current, wanted) switch
    {
        (byte[] a, byte[] b) => a.SequenceEqual(b),
        (string[] a, string[] b) => a.SequenceEqual(b, StringComparer.Ordinal),
        _ => Equals(current, wanted),
    };

    private static string Render(object value) => value switch
    {
        byte[] bytes => Convert.ToHexString(bytes),
        string[] lines => string.Join("\n", lines),
        _ => value.ToString() ?? "",
    };

    private static RegistryValueKind? SafeKind(RegistryKey key, string name)
    {
        try
        {
            return key.GetValueKind(name);
        }
        catch (IOException)
        {
            // The value vanished between the read and the kind lookup. Reported as "no kind" rather than
            // crashing: the comparison above then treats it as a change, which is the safe direction.
            return null;
        }
    }

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;
}
