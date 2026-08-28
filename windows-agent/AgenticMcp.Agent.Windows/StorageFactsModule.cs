using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// THE HOST'S DISKS, in the shape the fleet's Storage screen reads (<c>block_devices.devices</c>, lsblk-style,
/// nested disk → partition) plus the two Linux volume managers named as absent rather than omitted.
///
/// <para>WHY lsblk's SHAPE: the Storage view renders a tree of {name, size, type, fstype, mountpoint} with
/// children. Windows answers the same questions with three cmdlets, so the mapping is a translation and not a
/// pretence:</para>
/// <list type="bullet">
/// <item>`type` is <c>disk</c> | <c>part</c>, exactly lsblk's words for exactly lsblk's two levels.</item>
/// <item>`size` is BYTES, like lsblk -b. Every Windows size here is already bytes, so nothing is rounded.</item>
/// <item>`mountpoint` is the drive letter with its colon (<c>C:</c>) or the mount path — Windows' own answer to
/// "where is this reachable". A partition with no letter and no mount path has an EMPTY mountpoint, which is
/// the same statement lsblk makes about an unmounted partition.</item>
/// <item>`fstype` is NTFS/ReFS/FAT32 as Windows reports it, lower-cased for the same reason lsblk lower-cases:
/// the screen groups by it.</item>
/// </list>
///
/// <para>LVM AND VDO ARE REPORTED AS UNAVAILABLE WITH A REASON, not left out. `available: false` plus "LVM is
/// a Linux volume manager; the Windows analogue is Storage Spaces" is a classified answer; an absent key is a
/// hole the screen would render as a spinner or as nothing, and the reader could not tell "this host has no
/// LVM" from "nobody asked". Storage Spaces itself is a real analogue and is NOT faked into the lvm block —
/// it will get its own key when the screen can show it, because a pool of physical disks with resiliency
/// settings is not a volume group.</para>
/// </summary>
public sealed class StorageFactsModule : IModule
{
    public string Name => "storage_facts";

    public string Description =>
        "This Windows host's disks, partitions and volumes as a tree (disk → partition), with sizes in bytes, "
        + "filesystem type and drive letter — the same block_devices shape the Linux agent's lsblk-based "
        + "storage_facts returns, so one Storage view renders either host. LVM and VDO are reported as "
        + "unavailable with the reason rather than omitted. Read-only; changing partitions is not this module.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>(),
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
                                             CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "storage_facts (this implementation) reads Windows' Storage cmdlets; on Linux the Go agent's "
                + "lsblk implementation answers the same name.");
        }

        // ONE PowerShell call for all three cmdlets, because each one costs a process start and the screen
        // needs them together anyway. Volumes are matched to partitions by drive letter — the only link
        // Get-Partition and Get-Volume reliably share on both MBR and GPT disks.
        const string setup =
            "$out = New-Object System.Collections.ArrayList; "
            + "$vols = @{}; foreach ($v in Get-Volume) { if ($v.DriveLetter) { $vols[[string]$v.DriveLetter] = $v } }; "
            + "foreach ($d in Get-Disk) { "
            + "  $parts = New-Object System.Collections.ArrayList; "
            + "  foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) { "
            + "    $letter = if ($p.DriveLetter) { [string]$p.DriveLetter } else { '' }; "
            + "    $v = if ($letter -and $vols.ContainsKey($letter)) { $vols[$letter] } else { $null }; "
            + "    [void]$parts.Add([pscustomobject]@{ "
            + "      name = 'Disk' + $d.Number + 'Partition' + $p.PartitionNumber; size = [long]$p.Size; "
            + "      mountpoint = if ($letter) { $letter + ':' } elseif ($p.AccessPaths) { [string]$p.AccessPaths[0] } else { '' }; "
            + "      fstype = if ($v) { [string]$v.FileSystemType } else { '' }; "
            + "      label = if ($v) { [string]$v.FileSystemLabel } else { '' }; "
            + "      free = if ($v) { [long]$v.SizeRemaining } else { $null }; "
            + "      part_type = [string]$p.Type; is_boot = [bool]$p.IsBoot; is_system = [bool]$p.IsSystem }) }; "
            + "  [void]$out.Add([pscustomobject]@{ "
            + "    name = 'Disk' + $d.Number; size = [long]$d.Size; model = [string]$d.FriendlyName; "
            + "    serial = [string]$d.SerialNumber; bus = [string]$d.BusType; "
            + "    partition_style = [string]$d.PartitionStyle; health = [string]$d.HealthStatus; "
            + "    operational_status = [string]$d.OperationalStatus; is_readonly = [bool]$d.IsReadOnly; "
            + "    children = $parts }) }";
        var answer = await WindowsPowerShellBridge.RunJson(setup, "@($out)", TimeSpan.FromMinutes(3), ct);

        var devices = new List<Dictionary<string, object?>>();
        var partitionCount = 0;
        foreach (var disk in answer.Items)
        {
            ct.ThrowIfCancellationRequested();
            var children = new List<Dictionary<string, object?>>();
            if (disk.ValueKind == System.Text.Json.JsonValueKind.Object
                && disk.TryGetProperty("children", out var kids))
            {
                foreach (var part in kids.ValueKind == System.Text.Json.JsonValueKind.Array
                             ? kids.EnumerateArray()
                             : (kids.ValueKind == System.Text.Json.JsonValueKind.Object
                                 ? [kids]
                                 : Array.Empty<System.Text.Json.JsonElement>().AsEnumerable()))
                {
                    partitionCount++;
                    children.Add(new Dictionary<string, object?>
                    {
                        ["name"] = part.String("name"),
                        ["type"] = "part",
                        ["size"] = part.Long("size"),
                        ["fstype"] = part.String("fstype").ToLowerInvariant(),
                        ["mountpoint"] = part.String("mountpoint"),
                        ["label"] = part.String("label"),
                        // Windows' own extras, beside the lsblk fields rather than squeezed into them.
                        ["free_bytes"] = part.Long("free"),
                        ["part_type"] = part.String("part_type"),
                        ["is_boot"] = part.Bool("is_boot"),
                        ["is_system"] = part.Bool("is_system"),
                    });
                }
            }

            devices.Add(new Dictionary<string, object?>
            {
                ["name"] = disk.String("name"),
                ["type"] = "disk",
                ["size"] = disk.Long("size"),
                ["fstype"] = "",
                ["mountpoint"] = "",
                ["model"] = disk.String("model"),
                ["serial"] = disk.String("serial"),
                ["tran"] = disk.String("bus").ToLowerInvariant(),  // lsblk's name for the transport
                ["partition_style"] = disk.String("partition_style"),
                // HEALTH IS WINDOWS' OWN WORD (Healthy / Warning / Unhealthy) and passed through: a boolean
                // "ok" would erase the middle value, which is the one worth acting on before it is too late.
                ["health"] = disk.String("health"),
                ["operational_status"] = disk.String("operational_status"),
                ["is_readonly"] = disk.Bool("is_readonly"),
                ["children"] = children,
            });
        }

        var data = new Dictionary<string, object?>
        {
            ["block_devices"] = new Dictionary<string, object?>
            {
                ["available"] = true,
                ["devices"] = devices,
            },
            // NAMED AS ABSENT, with the reason and the analogue. An omitted key is a hole the screen cannot
            // tell from "not asked yet".
            ["lvm"] = new Dictionary<string, object?>
            {
                ["available"] = false,
                ["error"] = "LVM is a Linux volume manager and is not present on Windows. The analogue is "
                            + "Storage Spaces (pools with resiliency settings), which is a different model "
                            + "than volume groups and will get its own section rather than be reported here.",
            },
            ["vdo"] = new Dictionary<string, object?>
            {
                ["available"] = false,
                ["error"] = "VDO is a Linux device-mapper target and is not present on Windows. NTFS/ReFS "
                            + "compression and dedup are per-volume features, not a device layer.",
            },
        };

        return new ModuleResult(false,
            $"{devices.Count} disk(s), {partitionCount} partition(s)",
            data,
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = devices.Count });
    }
}
