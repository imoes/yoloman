PS_GET_VHDS = """$ErrorActionPreference = 'SilentlyContinue'
$out = @()
Get-VM | Get-VMHardDiskDrive | ForEach-Object {
    $drive = $_
    $vhd = Get-VHD -Path $drive.Path
    if ($vhd -ne $null) {
        $out += [PSCustomObject]@{
            controller_type     = $drive.ControllerType.ToString()
            controller_number   = [int]$drive.ControllerNumber
            controller_location = [int]$drive.ControllerLocation
            path                = $drive.Path
            vhd_type            = $vhd.VHDType.ToString()
            disk_size           = [long]$vhd.Size
            file_size           = [long]$vhd.FileSize
        }
    }
}
ConvertTo-Json -InputObject @($out) -Depth 2 -Compress"""

def _get_vhds(ctx):
    res = ctx.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", PS_GET_VHDS],
        mutates=False,
    )
    if res.rc != 0:
        return []
    raw = res.stdout.strip()
    if not raw or raw == "null" or raw == "[]":
        return []
    data = json.decode(raw)
    if type(data) == "dict":
        data = [data]
    return data

def _item_key(v):
    ct = v.get("controller_type", "")
    cn = v.get("controller_number", 0)
    cl = v.get("controller_location", 0)
    return "%s %s %s" % (ct, cn, cl)

def _fmt_bytes(n):
    n = float(n)
    if n >= 1073741824.0:
        return "%f GB" % (n / 1073741824.0)
    if n >= 1048576.0:
        return "%f MB" % (n / 1048576.0)
    if n >= 1024.0:
        return "%f KB" % (n / 1024.0)
    return "%d B" % int(n)

def main(ctx, params):
    if params.get("_discover"):
        vhds = _get_vhds(ctx)
        items = []
        for v in vhds:
            vhd_type = v.get("vhd_type", "")
            if vhd_type == "Dynamic" or vhd_type == "Differencing":
                items.append({
                    "item": _item_key(v),
                    "params": {"size_limit": ["absolute", ["no_levels", None]]},
                    "metrics": [
                        "hyperv_vhd_metrics_file_size",
                        "hyperv_vhd_metrics_disk_size",
                        "hyperv_vhd_metrics_file_size_percent",
                    ],
                })
        return {
            "changed": False,
            "msg": "discovered %d dynamic/differencing VHD(s)" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    vhds = _get_vhds(ctx)

    found = None
    for v in vhds:
        if _item_key(v) == item:
            found = v
            break

    if found == None:
        return {
            "changed": False,
            "msg": "No information available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    disk_size = int(found.get("disk_size", 0))
    file_size = int(found.get("file_size", 0))
    vhd_path = found.get("path", "")
    vhd_type = found.get("vhd_type", "")

    disk_name = vhd_path
    if "\\" in vhd_path:
        disk_name = vhd_path.rsplit("\\", 1)[-1]
    elif "/" in vhd_path:
        disk_name = vhd_path.rsplit("/", 1)[-1]

    if disk_size == 0:
        return {
            "changed": False,
            "msg": "Disk name: %s - disk_size is zero, cannot calculate usage" % disk_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    size_percent = float(file_size) / float(disk_size) * 100.0

    size_limit = params.get("size_limit", ["absolute", ["no_levels", None]])
    limit_type = size_limit[0]
    levels = size_limit[1]

    state = "OK"
    if levels[0] == "fixed":
        warn_level = float(levels[1][0])
        crit_level = float(levels[1][1])
        if limit_type == "relative":
            warn_abs = warn_level / 100.0 * float(disk_size)
            crit_abs = crit_level / 100.0 * float(disk_size)
        else:
            warn_abs = warn_level
            crit_abs = crit_level
        if float(file_size) >= crit_abs:
            state = "CRIT"
        elif float(file_size) >= warn_abs:
            state = "WARN"

    summary = "Disk name: %s, Current disk size: %f%% - %s of %s, VHD type: %s" % (
        disk_name,
        size_percent,
        _fmt_bytes(file_size),
        _fmt_bytes(disk_size),
        vhd_type,
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "hyperv_vhd_metrics_file_size": file_size,
                "hyperv_vhd_metrics_disk_size": disk_size,
                "hyperv_vhd_metrics_file_size_percent": size_percent,
            },
            "details": "",
        },
    }