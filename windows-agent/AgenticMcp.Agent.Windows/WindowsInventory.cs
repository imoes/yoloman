using Microsoft.Management.Infrastructure;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// The host's inventory document — what <c>GET /api/v1/hosts/overview</c> carries as <c>inventory</c> and
/// Bossman stores as the agent's <c>facts</c>.
///
/// <para><b><c>os_family</c> is the load-bearing field</b>, and until this existed the whole fleet read this
/// host as Debian. Measured: Bossman's <c>family_of()</c> ends in <c>return "debian"</c> for anything it
/// cannot identify, and the C# agent's overview carried no inventory at all — so a Windows Server would have
/// been offered apt packages by a catalogue lookup that believed it. One missing field, and every
/// family-dependent decision downstream is wrong in the same direction.</para>
///
/// <para>Deliberately SMALL. This is not the Go agent's full hardware inventory; it is the handful of facts
/// something actually branches on, each from a named WMI class so its origin is reachable. A field nobody
/// reads is a field nobody notices going stale.</para>
/// </summary>
public static class WindowsInventory
{
    public static Dictionary<string, object?> Collect()
    {
        // THE FLEET'S OWN KEY NAMES, not new ones for the same ideas. The Go agent's inventory document
        // (internal/inventory/inventory.go) is `collected_at, system, board, bios, cpu, memory_mb, os, disks,
        // nics`, and Bossman's compiler copies exactly those keys into the desired-state document while both
        // family resolvers read `os.id` / `os.id_like`. The first version of this file invented `os_release`,
        // `cpu_count` and `memory_total_bytes` — one fact under two names, which is the identity rule broken
        // in the place where a Windows host and a Linux host are supposed to look like the same kind of thing.
        var inventory = new Dictionary<string, object?>
        {
            ["collected_at"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            // Read by both resolvers in preference to the os-release tokens. Without it this host was read as
            // DEBIAN, because Bossman's family_of() ends in `return "debian"` for anything unidentified.
            ["os_family"] = "windows",
        };

        if (!OperatingSystem.IsWindows())
        {
            return inventory;
        }

        try
        {
            using var session = CimSession.Create(null);
            foreach (var os in session.QueryInstances(@"root\cimv2", "WQL",
                         "SELECT Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime, "
                         + "TotalVisibleMemorySize FROM Win32_OperatingSystem"))
            {
                using (os)
                {
                    inventory["os"] = new Dictionary<string, object?>
                    {
                        // `id` is what both family resolvers tokenise. "windows" here and "windows" in the
                        // catalogue's `families` key are deliberately the same word.
                        ["id"] = "windows",
                        ["distribution"] = Text(os, "Caption"),
                        ["version"] = Text(os, "Version"),
                        ["pretty_name"] = Text(os, "Caption"),
                        // The build number is Windows' equivalent of a kernel version: the number an operator
                        // quotes when asking whether a fix is in.
                        ["kernel"] = Text(os, "BuildNumber"),
                        ["architecture"] = Text(os, "OSArchitecture"),
                    };
                    // memory_mb, in MB, because that is the unit the field's NAME promises. TotalVisibleMemory
                    // Size is in kilobytes — the same trap as the WMI collector's mem_total_bytes.
                    inventory["memory_mb"] = (long)(Num(os, "TotalVisibleMemorySize") / 1024);
                    inventory["last_boot"] = Stamp(os, "LastBootUpTime");
                }

                break;
            }

            foreach (var cs in session.QueryInstances(@"root\cimv2", "WQL",
                         "SELECT Name, Domain, Manufacturer, Model, NumberOfLogicalProcessors, "
                         + "NumberOfProcessors, PartOfDomain FROM Win32_ComputerSystem"))
            {
                using (cs)
                {
                    if (inventory["os"] is Dictionary<string, object?> osDict)
                    {
                        osDict["hostname"] = Text(cs, "Name");
                    }

                    inventory["system"] = new Dictionary<string, object?>
                    {
                        ["manufacturer"] = Text(cs, "Manufacturer"),
                        ["product_name"] = Text(cs, "Model"),
                        // DOMAIN MEMBERSHIP IS A FACT, not a detail: a domain member's users, policies and
                        // authority are not the host's, which is why the `user` module refuses domain accounts
                        // (docs/windows-management.md §7). Reported so a plan can be checked against it rather
                        // than discovering it from a failure.
                        ["domain"] = Text(cs, "Domain"),
                        ["part_of_domain"] = Flag(cs, "PartOfDomain"),
                    };
                    inventory["cpu"] = new Dictionary<string, object?>
                    {
                        ["sockets"] = (int)Num(cs, "NumberOfProcessors"),
                        ["threads"] = (int)Num(cs, "NumberOfLogicalProcessors"),
                    };
                }

                break;
            }

            foreach (var cpu in session.QueryInstances(@"root\cimv2", "WQL",
                         "SELECT Name, Manufacturer, NumberOfCores FROM Win32_Processor"))
            {
                using (cpu)
                {
                    if (inventory["cpu"] is Dictionary<string, object?> cpuDict)
                    {
                        cpuDict["model"] = Text(cpu, "Name");
                        cpuDict["vendor"] = Text(cpu, "Manufacturer");
                        cpuDict["cores"] = (int)Num(cpu, "NumberOfCores");
                    }
                }

                break;
            }

            // Roles and features, COUNTED rather than listed. The list belongs to windows_feature, which reads
            // it on demand; 265 entries in every overview payload would be the fleet-table mistake this
            // project already measured once (5.46 MB of relationships on every host page).
            inventory["windows_features_installed"] = InstalledFeatureCount();
            // WHICH PACKAGE PROVIDERS THIS HOST HAS. Reported as a fact so a plan can be checked against the
            // host BEFORE it runs: measured on a fresh Server 2022, winget is NOT present, and "install this
            // with winget" failing on the target reads as a broken package rather than a missing tool.
            inventory["package_providers"] = WindowsPackaging.AvailableProviders();
        }
        catch (Exception ex)
        {
            // NAMED, not swallowed. An inventory that silently loses os_family puts this host back to being
            // read as Debian — the exact failure this class exists to prevent — so the reason travels with the
            // document instead of leaving an empty one that looks like a Linux box.
            inventory["inventory_error"] = $"{ex.GetType().Name}: {ex.Message}";
        }

        return inventory;
    }

    /// <summary>
    /// How many roles/features are installed. Through the Windows PowerShell bridge, because
    /// <c>Get-WindowsFeature</c> lives in ServerManager, which PowerShell 7 cannot load — see
    /// <see cref="WindowsPowerShellBridge"/>.
    /// </summary>
    private static int? InstalledFeatureCount()
    {
        try
        {
            var answer = WindowsPowerShellBridge.RunJson(
                "$n = (Get-WindowsFeature | Where-Object Installed).Count",
                "[pscustomobject]@{ Count = [int]$n }",
                TimeSpan.FromMinutes(2), CancellationToken.None).GetAwaiter().GetResult();
            foreach (var item in answer.Items)
            {
                if (item.TryGetProperty("Count", out var c) && c.TryGetInt32(out var n))
                {
                    return n;
                }
            }
        }
        catch (Exception)
        {
            // A count is a nicety; os_family is not. Losing the former must never cost the latter, so this
            // one failure is the only swallowed exception here — and it returns null, which the document
            // shows as an absent count rather than as zero.
        }

        return null;
    }

    private static string? Text(CimInstance instance, string property) =>
        instance.CimInstanceProperties[property]?.Value?.ToString();

    private static double Num(CimInstance instance, string property)
    {
        var value = instance.CimInstanceProperties[property]?.Value;
        return value is null ? 0 : Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static bool Flag(CimInstance instance, string property) =>
        instance.CimInstanceProperties[property]?.Value is true;

    private static string? Stamp(CimInstance instance, string property) =>
        instance.CimInstanceProperties[property]?.Value is DateTime dt
            ? dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            : null;
}
