using System.Diagnostics;
using System.Security.Cryptography;
using AgenticMcp.Agent.Core;
using Microsoft.Win32;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>package</c> — install or remove software on Windows, through an EXPLICIT provider.
///
/// <para>This is the half Linux gets from apt and Windows has no answer for. Two things make it work at all,
/// and both are stated rather than inferred:</para>
///
/// <para><b>The provider is never implicit.</b> Measured on a fresh Server 2022: <c>winget</c> is NOT there
/// (it ships with Windows 11 / Server 2025), and neither are choco or scoop. Present: msiexec, DISM,
/// PackageManagement (OneGet), Appx. A module that hid a provider preference would do different things on two
/// hosts and its failure on one of them would read as a broken package rather than a missing tool — so the
/// caller names the provider, the host reports which ones it HAS (WindowsInventory), and asking for one that
/// is absent is refused BY NAME.</para>
///
/// <para><b>The detection rule is mandatory.</b> Without it, "install" means "run the installer again": a
/// change on every pass, and a fleet that reports 400 changes a night reports nothing. A vendor's setup.exe
/// is not self-describing, so the three facts nobody can derive are declared once — the silent switches, the
/// detection rule, the uninstall path — and this module's whole idempotence is that rule.</para>
///
/// <para><c>success_codes</c> defaults to <c>[0, 3010]</c> because <b>3010 means "installed, reboot
/// required"</b>, and treating it as a failure is the commonest way a Windows rollout reports red on a
/// success. The reply says <c>awaiting-restart</c> instead.</para>
/// </summary>
public sealed class PackageModule : IModule
{
    public string Name => "package";

    private static readonly string[] Providers =
        ["msi", "installer", "packagemanagement", "winget", "choco", "appx"];

    private static readonly string[] Detections = ["registry", "msi_product", "file_version", "command"];

    public string Description =>
        "Install or remove software on this Windows host. `provider` is REQUIRED and explicit — msi (msiexec), "
        + "installer (any exe/bat/cmd/ps1 with its own switches), packagemanagement (Install-Package), winget, "
        + "choco or appx — because the same request must not mean different things on two hosts; ask for one "
        + "the host lacks and it is refused by name. `detect` is REQUIRED for state:present and is the whole "
        + "idempotence: registry (a value exists/equals), msi_product (a ProductCode), file_version (an "
        + "EXE/DLL's version) or command (a script whose exit code decides). `source` may carry a url plus "
        + "sha256, verified BEFORE execution. `success_codes` defaults to [0, 3010]: 3010 means installed and "
        + "a reboot is pending, which is a success. An ansible.windows.win_package task translates directly.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "What this package is called, for reporting and for the provider that needs "
                                  + "an id (packagemanagement, winget, choco, appx).",
            },
            ["provider"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Providers,
                ["description"] = "Required. See the module description for why there is no default.",
            },
            ["state"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = new[] { "present", "absent" },
                ["default"] = "present",
            },
            ["path"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "A local installer path (msi/installer). Mutually exclusive with source.url.",
            },
            ["source_url"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Where to fetch the installer from.",
            },
            ["source_sha256"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Checksum of the fetched installer, verified before it is executed. An "
                                  + "installer fetched over HTTP with no hash is remote code execution with "
                                  + "extra steps.",
            },
            ["arguments"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "The installer's own switches for INSTALLING, space-separated (e.g. "
                                  + "\"/S /v/qn\"). Not used when state is absent — see "
                                  + "uninstall_arguments.",
            },
            ["uninstall_arguments"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Switches appended to the product's own UninstallString when state is "
                                  + "absent. Separate from `arguments` because the two are different "
                                  + "commands: a recipe carrying /S for a silent install made the removal "
                                  + "run \"reg delete <key> /f /S\", which Windows refuses as invalid "
                                  + "syntax. Most products need nothing here.",
            },
            ["success_codes"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["default"] = "0,3010",
                ["description"] = "Exit codes that mean success. 3010 = installed, reboot pending.",
            },
            ["detect"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Detections,
                ["description"] = "Required for state:present. How to tell whether it is already installed.",
            },
            ["detect_key"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "registry: the key. msi_product: the ProductCode. file_version: the file. "
                                  + "command: the script.",
            },
            ["detect_name"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "registry: the value's name.",
            },
            ["detect_equals"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "registry/file_version: the value it must have. Omit to require only that "
                                  + "it exists — which is a WEAKER claim, and the reply says which was used.",
            },
        },
        ["required"] = new[] { "provider" },
    };

    public bool Writes => true;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var provider = (Str(parameters, "provider") ?? "").ToLowerInvariant();
        if (!Providers.Contains(provider))
        {
            throw new ArgumentException(
                $"provider: required, one of {string.Join(", ", Providers)} — there is no default on purpose "
                + "(see the module description)");
        }

        var available = WindowsPackaging.AvailableProviders();
        if (!available.Contains(provider))
        {
            // BY NAME, with what the host actually has. On a fresh Server 2022 `winget` is simply not there,
            // and "not installed" would be the wrong diagnosis for a package nobody tried to install.
            throw new ArgumentException(
                $"provider: this host has no {provider}. Available here: {string.Join(", ", available)}. "
                + "Bossman reports the same list as a host capability, so a plan can be checked before it runs.");
        }

        var name = Str(parameters, "name") ?? "";
        var state = Str(parameters, "state") ?? "present";
        var wantPresent = state == "present";

        // ---- DETECT, before anything else --------------------------------------------------------------
        var detect = Str(parameters, "detect");
        if (wantPresent && string.IsNullOrWhiteSpace(detect))
        {
            throw new ArgumentException(
                "detect: required for state:present. Without it, installing means running the installer again "
                + "on every pass — a change that is not a change, which is how a converge report becomes "
                + "unreadable. One of: " + string.Join(", ", Detections));
        }

        var installed = detect is null
            ? (bool?)null
            : await Detect(detect, parameters, ct);

        var data = new Dictionary<string, object?>
        {
            ["name"] = name,
            ["provider"] = provider,
            ["detect"] = detect,
            ["detected_installed"] = installed,
            ["dry_run"] = dryRun,
            ["providers_available"] = available,
        };

        if (installed == wantPresent)
        {
            return new ModuleResult(false, wantPresent ? "already installed" : "already absent", data);
        }

        if (dryRun)
        {
            return new ModuleResult(true,
                wantPresent ? "would install" : "would remove", data);
        }

        // ---- FETCH and VERIFY --------------------------------------------------------------------------
        var path = Str(parameters, "path");
        var url = Str(parameters, "source_url");
        if (wantPresent && provider is "msi" or "installer")
        {
            if (path is null && url is null)
            {
                throw new ArgumentException($"provider {provider} needs either path or source_url");
            }

            if (url is not null)
            {
                path = await Fetch(url, Str(parameters, "source_sha256"), data, ct);
            }

            if (!File.Exists(path))
            {
                throw new FileNotFoundException($"path: {path} does not exist on this host");
            }
        }

        var codes = ParseCodes(Str(parameters, "success_codes") ?? "0,3010");
        var arguments = Str(parameters, "arguments") ?? "";
        var uninstallArguments = Str(parameters, "uninstall_arguments") ?? "";
        var run = await WindowsPackaging.Execute(provider, wantPresent, name, path, arguments, codes, ct,
            uninstallArguments);
        data["command"] = run.Command;
        data["exit_code"] = run.ExitCode;
        data["output"] = run.Output;

        if (!codes.Contains(run.ExitCode))
        {
            throw new InvalidOperationException(
                $"{provider} exited {run.ExitCode} (accepted: {string.Join(", ", codes)}): {run.Output}");
        }

        // ---- RE-DETECT: the installer's exit code is a claim, the detection rule is the evidence --------
        if (detect is not null)
        {
            data["detected_after"] = await Detect(detect, parameters, ct);
            if ((bool?)data["detected_after"] != wantPresent)
            {
                // The installer said success and the rule disagrees. That is worth failing on: the
                // alternative is a converge that reports green and drifts back on the next pass.
                throw new InvalidOperationException(
                    $"{provider} exited {run.ExitCode} (a success code) but the detection rule still reports "
                    + $"{(wantPresent ? "not installed" : "installed")} — the installer's claim and the "
                    + "evidence disagree, so nothing is reported as done.");
            }
        }

        var rebootPending = run.ExitCode == 3010;
        data["awaiting_restart"] = rebootPending;
        return new ModuleResult(true,
            (wantPresent ? "installed" : "removed")
            + (rebootPending ? " — awaiting-restart (exit 3010: reboot pending)" : ""),
            data);
    }

    // ---------------------------------------------------------------------------------------------------
    private async Task<bool> Detect(string kind, IReadOnlyDictionary<string, object?> p, CancellationToken ct)
    {
        var key = Str(p, "detect_key") ?? "";
        var expected = Str(p, "detect_equals");
        switch (kind)
        {
            case "registry":
            {
                if (!OperatingSystem.IsWindows())
                {
                    return false;
                }

                var (hive, subKey) = RegistryModule.SplitHive(key);
                using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Default);
                using var opened = baseKey.OpenSubKey(subKey);
                if (opened is null)
                {
                    return false;
                }

                var valueName = Str(p, "detect_name");
                if (valueName is null)
                {
                    return true; // the KEY existing is the claim
                }

                var value = opened.GetValue(valueName);
                return value is not null
                       && (expected is null || string.Equals(value.ToString(), expected, StringComparison.Ordinal));
            }

            case "msi_product":
                return WindowsPackaging.MsiProductInstalled(key);

            case "file_version":
            {
                if (!File.Exists(key))
                {
                    return false;
                }

                if (expected is null)
                {
                    return true;
                }

                var info = FileVersionInfo.GetVersionInfo(key);
                return string.Equals(info.FileVersion, expected, StringComparison.Ordinal)
                       || string.Equals(info.ProductVersion, expected, StringComparison.Ordinal);
            }

            case "command":
            {
                // Exit 0 means installed. The last resort, for what nothing else fits — and it runs through
                // the Windows PowerShell bridge so it behaves like every other script this agent runs.
                try
                {
                    await WindowsPowerShellBridge.Run(key, TimeSpan.FromMinutes(2), ct);
                    return true;
                }
                catch (InvalidOperationException)
                {
                    return false;
                }
            }

            default:
                throw new ArgumentException(
                    $"detect: must be one of {string.Join(", ", Detections)}, got \"{kind}\"");
        }
    }

    /// <summary>Downloads the installer and verifies its checksum BEFORE it can be executed.</summary>
    private static async Task<string> Fetch(string url, string? sha256, Dictionary<string, object?> data,
        CancellationToken ct)
    {
        var directory = Path.Combine(Path.GetTempPath(), "agentic-packages");
        Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, Path.GetFileName(new Uri(url).LocalPath));

        // NOT `new HttpClient()`: that one uses HttpClient.DefaultProxy, which cannot read a CIDR entry in
        // NO_PROXY. Measured on the host — an installer at http://10.32.28.130:8099/… inside the bypass
        // list's own 10.32.0.0/16 was proxied anyway and came back 503, while curl.exe on the same host with
        // the same environment got 200. See ProxyPolicy for the whole measurement.
        using var http = ProxyPolicy.CreateFleetHttpClient(TimeSpan.FromMinutes(30));
        var bytes = await http.GetByteArrayAsync(url, ct);
        var actual = Convert.ToHexStringLower(SHA256.HashData(bytes));
        data["source_url"] = url;
        data["source_sha256"] = actual;

        if (!string.IsNullOrWhiteSpace(sha256))
        {
            if (!string.Equals(actual, sha256.Trim().ToLowerInvariant(), StringComparison.Ordinal))
            {
                // Refused before a single byte is executed. This is the whole reason the field exists.
                throw new InvalidOperationException(
                    $"source_sha256 mismatch: expected {sha256.Trim().ToLowerInvariant()}, got {actual}. "
                    + "The installer was NOT run.");
            }

            data["checksum_verified"] = true;
        }
        else
        {
            // An unverified download is not refused — an internal repository over HTTP is a real situation —
            // but it is REPORTED, with the hash it actually had, so the recipe can be pinned afterwards.
            data["checksum_verified"] = false;
            data["checksum_note"] = "no source_sha256 given; the installer ran unverified. Its actual hash is "
                                    + "in source_sha256 above — pin it in the recipe.";
        }

        await File.WriteAllBytesAsync(target, bytes, ct);
        return target;
    }

    private static int[] ParseCodes(string raw) =>
        raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(s => int.TryParse(s, out var n) ? n : -1)
            .Where(n => n >= 0)
            .DefaultIfEmpty(0)
            .ToArray();

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;
}
