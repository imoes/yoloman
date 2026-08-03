# Checkmk check: hyperv_vm_vhd_dynamic  ->  read-only Starlark check module
# Hyper-V VM Disk [item]  (dynamic / differencing VHDs)
#
# Data source: Checkmk's Hyper-V agent section `hyperv_vm_vhd`.
# On our host there is no Checkmk agent, so we obtain the same data via the
# real source the Checkmk plugin reads: Hyper-V PowerShell WMI.

def _parse_hyperv(string_table):
    """Mirror of cmk.plugins.hyperv_cluster.lib.parse_hyperv."""
    datatypes = {
        "vhd": "vhd.Name",
        "nic": "nic.name",
        "checkpoints": "checkpoint.name",
        "cluster.number_of_nodes": "cluster.node.name",
        "cluster.number_of_csv": "cluster.csv.name",
        "cluster.number_of_disks": "cluster.disk.name",
        "cluster.number_of_vms": "cluster.vm.name",
        "cluster.number_of_roles": "cluster.role.name",
        "cluster.number_of_networks": "cluster.network.name",
    }
    parsed = {}
    if len(string_table) == 0:
        return parsed
    datatype = datatypes.get(string_table[0][0])
    element = ""
    start = False
    counter = 1
    for line in string_table:
        first = line[0]
        if first == datatype:
            if start:
                counter = counter + 1
            else:
                start = True
            if datatype == "nic.name":
                element = " ".join(line[1:]) + " " + str(counter)
            else:
                element = " ".join(line[1:])
            parsed[element] = {}
        elif start:
            element_data = parsed.setdefault(element, {})
            element_data[first] = " ".join(line[1:])
    return parsed

def _basename(path):
    """Return the last component of a Windows-style path."""
    idx = path.rfind("\\")
    if idx >= 0:
        return path[idx + 1:]
    idx = path.rfind("/")
    if idx >= 0:
        return path[idx + 1:]
    return path

def _parse_hyperv_vm_vhd(string_table):
    """Mirror of parse_hyperv_vm_vhd from the check plugin."""
    raw = _parse_hyperv(string_table)
    out = {}
    for key, values in raw.items():
        vhd_path = values.get("vhd.Path")
        vhd_type = values.get("vhd.Type")
        if vhd_path == None or vhd_type == None:
            continue
        if vhd_type not in ("Dynamic", "Differencing", "Fixed"):
            continue
        disk_size = values.get("vhd.DiskSize")
        file_size = values.get("vhd.FileSize")
        if disk_size == None or file_size == None:
            continue
        try_disk = disk_size.strip()
        try_file = file_size.strip()
        if not try_disk.isdigit() or not try_file.isdigit():
            continue
        ctype = values.get("vhd.controller.Type")
        cnum = values.get("vhd.controller.Number")
        cloc = values.get("vhd.controller.Location")
        if ctype == None or cnum == None or cloc == None:
            continue
        item_key = "%s %s %s" % (ctype, cnum, cloc)
        out[item_key] = {
            "main_path_name": _basename(vhd_path),
            "disk_size": int(try_disk),
            "file_size": int(try_file),
            "type": vhd_type,
        }
    return out

def _gather_section(ctx):
    """Probe the real on-host source (Hyper-V) and emit a string_table.

    Returns [] when Hyper-V is absent so discovery is empty.
    """
    cmd = ";".join([
        "Import-Module Hyper-V -ErrorAction SilentlyContinue",
        "$v = Get-VHD -ErrorAction SilentlyContinue",
        "if (-not $v) { exit 0 }",
        "$out = @()",
        "foreach ($vh in $v) {",
        "  $p = 'vhd'",
        "  $out += ,@($p, 'vhd.Path', ($vh.Path))",
        "  $out += ,@($p, 'vhd.Name', ($vh.Name))",
        "  $out += ,@($p, 'vhd.Type', ($vh.VHDType.ToString()))",
        "  $out += ,@($p, 'vhd.DiskSize', ([string]($vh.Size)))",
        "  $out += ,@($p, 'vhd.FileSize', ([string]($vh.FileSize)))",
        "  $out += ,@($p, 'vhd.controller.Type', ([string]($vh.ControllerType)))",
        "  $out += ,@($p, 'vhd.controller.Number', ([string]($vh.ControllerNumber)))",
        "  $out += ,@($p, 'vhd.controller.Location', ([string]($vh.ControllerLocation)))",
        "}",
        "$out | ForEach-Object { $_.GetEnumerator() | ForEach-Object { echo ($_.Key + '|' + $_.Value) } }",
    ])
    r = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    if r.rc != 0 or not r.stdout:
        return []
    rows = []
    for ln in r.stdout.split("\n"):
        ln = ln.strip()
        if not ln or "|" not in ln:
            continue
        key, val = ln.split("|", 1)
        rows.append([key, val])
    return rows

def main(ctx, params):
    if params.get("_discover"):
        rows = _gather_section(ctx)
        section = _parse_hyperv_vm_vhd(rows)
        out = []
        for key, info in section.items():
            if info["type"] in ("Dynamic", "Differencing"):
                warn = params.get("warn", 80.0)
                crit = params.get("crit", 90.0)
                out.append({
                    "item": key,
                    "params": {"warn": warn, "crit": crit},
                    "metrics": ["file_size_percent", "file_size", "disk_size"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    rows = _gather_section(ctx)
    section = _parse_hyperv_vm_vhd(rows)
    if item not in section:
        return {
            "changed": False,
            "msg": "No information available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    info = section[item]
    disk_size = info["disk_size"]
    file_size = info["file_size"]
    if disk_size == 0:
        size_percent = 0.0
    else:
        size_percent = file_size / disk_size * 100.0

    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    if size_percent >= crit:
        state = "CRIT"
    elif size_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    summary = "Current disk size: %f%% %s of %d bytes - VHD type: %s" % (
        size_percent, str(file_size), disk_size, info["type"]
    )
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "file_size_percent": size_percent,
                "file_size": file_size,
                "disk_size": disk_size,
            },
            "details": "Disk name: " + info["main_path_name"],
        },
    }