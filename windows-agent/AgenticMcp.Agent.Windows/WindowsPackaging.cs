using System.Diagnostics;
using Microsoft.Win32;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// Which package providers this host HAS, and how to drive each one.
///
/// <para>Split out of <see cref="PackageModule"/> so the capability list has one owner: the module asks it
/// what is available, the inventory reports the same list, and Bossman can therefore check a plan against a
/// host BEFORE running it instead of discovering a missing tool from a failure. Two answers to
/// "does this host have winget" is the identity defect this file exists to avoid.</para>
///
/// <para>Measured on a fresh Windows Server 2022: <c>msi</c>, <c>installer</c>, <c>packagemanagement</c> and
/// <c>appx</c> are present; <c>winget</c>, <c>choco</c> and <c>scoop</c> are NOT. winget ships with
/// Windows 11 and Server 2025.</para>
/// </summary>
public static class WindowsPackaging
{
    /// <summary>The providers usable on this host, in a stable order.</summary>
    public static List<string> AvailableProviders()
    {
        var available = new List<string>();
        if (!OperatingSystem.IsWindows())
        {
            return available;
        }

        // msi and installer need no third-party tool: msiexec is part of Windows, and "installer" means
        // running the file the recipe points at.
        if (File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "msiexec.exe")))
        {
            available.Add("msi");
        }

        available.Add("installer");

        if (HasCommand("Get-Package"))
        {
            available.Add("packagemanagement");
        }

        if (HasCommand("Get-AppxPackage"))
        {
            available.Add("appx");
        }

        foreach (var (exe, provider) in new[] { ("winget.exe", "winget"), ("choco.exe", "choco") })
        {
            if (OnPath(exe))
            {
                available.Add(provider);
            }
        }

        return available;
    }

    private static bool OnPath(string executable) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "")
        .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
        .Any(dir =>
        {
            try
            {
                return File.Exists(Path.Combine(dir.Trim(), executable));
            }
            catch (ArgumentException)
            {
                return false; // a PATH entry with invalid characters is not a directory
            }
        });

    private static bool HasCommand(string name)
    {
        try
        {
            var answer = WindowsPowerShellBridge.RunJson(
                $"$c = Get-Command {name} -ErrorAction SilentlyContinue",
                "[pscustomobject]@{ Found = [bool]$c }",
                TimeSpan.FromSeconds(60), CancellationToken.None).GetAwaiter().GetResult();
            return answer.Items.Any(i => i.TryGetProperty("Found", out var f)
                                         && f.ValueKind == System.Text.Json.JsonValueKind.True);
        }
        catch (Exception)
        {
            // A provider we cannot confirm is a provider we do not claim. Reporting it as present and
            // failing later is the worse answer.
            return false;
        }
    }

    /// <summary>Is an MSI ProductCode installed? Read from the registry, never from Win32_Product.</summary>
    public static bool MsiProductInstalled(string productCode)
    {
        if (!OperatingSystem.IsWindows() || string.IsNullOrWhiteSpace(productCode))
        {
            return false;
        }

        // WIN32_PRODUCT IS NOT USED, and that is a correctness decision rather than a performance one:
        // enumerating it triggers an MSI self-repair of every installed package — a WRITE disguised as a
        // read. The Uninstall keys are where msiexec records what it installed, on both bitnesses.
        var code = productCode.Trim();
        foreach (var root in new[]
                 {
                     @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                     @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                 })
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"{root}\{code}");
            if (key is not null)
            {
                return true;
            }
        }

        return false;
    }

    public sealed record Run(string Command, int ExitCode, string Output);

    /// <summary>Runs the provider's install or remove command and returns its exit code and output.</summary>
    public static async Task<Run> Execute(string provider, bool install, string name, string? path,
        string arguments, int[] successCodes, CancellationToken ct)
    {
        switch (provider)
        {
            case "msi":
            {
                // /qn quiet, /norestart because A REBOOT IS NEVER IMPLICIT — the module reports
                // awaiting-restart and the operator decides when. Without it msiexec may restart the host
                // under a converge run, which is the least acceptable surprise in this whole system.
                var verb = install ? "/i" : "/x";
                var args = $"{verb} \"{path ?? name}\" /qn /norestart"
                           + (string.IsNullOrWhiteSpace(arguments) ? "" : " " + arguments);
                return await Process("msiexec.exe", args, ct);
            }

            case "installer":
            {
                if (!install)
                {
                    // Removal goes through what the product itself recorded — the UninstallString in the
                    // registry — because a vendor's uninstaller is the only thing that knows how.
                    var uninstall = UninstallString(name)
                                    ?? throw new InvalidOperationException(
                                        $"no UninstallString recorded for \"{name}\" — nothing to run. Give an "
                                        + "explicit path plus arguments if the product does not register one.");
                    return await Shell(uninstall + " " + arguments, ct);
                }

                var file = path ?? throw new ArgumentException("provider installer needs path or source_url");
                // .bat/.cmd through cmd, .ps1 through the PowerShell bridge, an .exe directly: the file's own
                // kind decides, because "run this installer" means three different things.
                return Path.GetExtension(file).ToLowerInvariant() switch
                {
                    ".bat" or ".cmd" => await Process("cmd.exe", $"/c \"{file}\" {arguments}", ct),
                    ".ps1" => await Bridge($"& '{file.Replace("'", "''")}' {arguments}", ct),
                    _ => await Process(file, arguments, ct),
                };
            }

            case "packagemanagement":
                return await Bridge(install
                    ? $"Install-Package -Name '{Escape(name)}' -Force -ErrorAction Stop | Out-Null; exit 0"
                    : $"Uninstall-Package -Name '{Escape(name)}' -Force -ErrorAction Stop | Out-Null; exit 0", ct);

            case "winget":
                return await Process("winget.exe", install
                    ? $"install --id {name} --silent --accept-package-agreements --accept-source-agreements"
                    : $"uninstall --id {name} --silent", ct);

            case "choco":
                return await Process("choco.exe", install ? $"install {name} -y" : $"uninstall {name} -y", ct);

            case "appx":
                return await Bridge(install
                    ? $"Add-AppxPackage -Path '{Escape(path ?? name)}' -ErrorAction Stop; exit 0"
                    : $"Get-AppxPackage '{Escape(name)}' | Remove-AppxPackage -ErrorAction Stop; exit 0", ct);

            default:
                throw new ArgumentException($"provider: {provider} has no execution path");
        }
    }

    private static string? UninstallString(string displayName)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        foreach (var root in new[]
                 {
                     @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                     @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                 })
        {
            using var parent = Registry.LocalMachine.OpenSubKey(root);
            if (parent is null)
            {
                continue;
            }

            foreach (var child in parent.GetSubKeyNames())
            {
                using var entry = parent.OpenSubKey(child);
                if (entry?.GetValue("DisplayName")?.ToString() == displayName)
                {
                    return entry.GetValue("UninstallString")?.ToString();
                }
            }
        }

        return null;
    }

    private static Task<Run> Bridge(string script, CancellationToken ct) =>
        Task.Run(async () =>
        {
            try
            {
                var output = await WindowsPowerShellBridge.Run(script, TimeSpan.FromMinutes(30), ct);
                return new Run($"powershell: {script}", 0, output.Trim());
            }
            catch (InvalidOperationException ex)
            {
                // The bridge raises on a non-zero exit; the message carries the shell's error stream. Mapped
                // back to a code so every provider answers in the same shape.
                return new Run($"powershell: {script}", 1, ex.Message);
            }
        }, ct);

    private static Task<Run> Shell(string commandLine, CancellationToken ct) =>
        Process("cmd.exe", "/c " + commandLine, ct);

    private static async Task<Run> Process(string executable, string arguments, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(executable)
        {
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = System.Diagnostics.Process.Start(psi)
                            ?? throw new InvalidOperationException($"could not start {executable}");
        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(30));
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
                // already gone
            }

            throw new TimeoutException($"{executable} did not finish within 30 minutes");
        }

        var output = ((await stdout) + " " + (await stderr)).Replace("\r", " ").Replace("\n", " ").Trim();
        return new Run($"{executable} {arguments}", process.ExitCode,
            output.Length > 2000 ? output[..2000] : output);
    }

    private static string Escape(string value) => value.Replace("'", "''");
}
