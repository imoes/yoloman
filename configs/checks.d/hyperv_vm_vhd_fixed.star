def _parse_hyperv(string_table):
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
    if datatype == None:
        return parsed
    element = ""
    start = False
    counter = 1
    for line in string_table:
        if line[0] == datatype:
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
            element_data[line[0]] = " ".join(line[1:])
    return parsed

def _parse_vhd_string_table(string_table):
    raw = _parse_hyperv(string_table)
    result = {}
    for key, values in raw.items():
        vhd_path = values.get("vhd.Path")
        vhd_type = values.get("vhd.Type")
        if vhd_path == None or vhd_type == None:
            continue
        if vhd_type not in ("Fixed", "Dynamic", "Differencing"):
            continue
        disk_size_str = values.get("vhd.DiskSize", "0")
        file_size_str = values.get("vhd.FileSize", "0")
        disk_size = int(disk_size_str) if disk_size_str.isdigit() else 0
        file_size = int(file_size_str) if file_size_str.isdigit() else 0
        controller_type = values.get("vhd.controller.Type", "")
        controller_number = values.get("vhd.controller.Number", "")
        controller_location = values.get("vhd.controller.Location", "")
        item_key = controller_type + " " + controller_number + " " + controller_location
        result[item_key] = {
            "main_path": vhd_path,
            "disk_size": disk_size,
            "file_size": file_size,
            "type": vhd_type,
        }
    return result

def _gather_vhd_ps_script():
    p1 = "Get-VM | ForEach-Object { $vm = $_; "
    p2 = "Get-VMHardDiskDrive -VM $vm | ForEach-Object { "
    p3 = "$disk = $_; $path = $disk.Path; "
    p4 = "$vhd = Get-VHD -Path $path -ErrorAction SilentlyContinue; "
    p5 = "if ($vhd) { "
    p6 = "[PSCustomObject]@{ 'vhd.DiskSize' = $vhd.DiskSize; "
    p7 = "'vhd.FileSize' = $vhd.FileSize; "
    p8 = "'vhd.Path' = $vhd.Path; "
    p9 = "'vhd.Type' = $vhd.VHDType; "
    p10 = "'vhd.controller.Type' = $disk.ControllerType; "
    p11 = "'vhd.controller.Number' = $disk.ControllerNumber; "
    p12 = "'vhd.controller.Location' = $disk.ControllerLocation; "
    p13 = "'vhd.Name' = $vm.Name; } "
    p14 = "} } } | Out-String -Width 4096"
    return p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12 + p13 + p14

def _parse_ps_output(stdout):
    lines = stdout.splitlines()
    string_table = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("vhd.") or line.startswith("vhd.controller."):
            parts = line.split(" ", 1)
            key = parts[0]
            value = parts[1] if len(parts) > 1 else ""
            string_table.append([key, value])
    return string_table

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(
            ["pwsh", "-NoProfile", "-Command",
             "Get-Command Get-VM -ErrorAction Stop | Out-Null; $PSVersion"],
            mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "Hyper-V not available",
                    "data": {"discovery": [], "host_labels": {}}}
        ps_script = _gather_vhd_ps_script()
        res = ctx.run(
            ["pwsh", "-NoProfile", "-Command", ps_script],
            mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no VHD data retrieved",
                    "data": {"discovery": []}}
        string_table = _parse_ps_output(res.stdout)
        section = _parse_vhd_string_table(string_table)
        discovery = []
        for item_key, info in section.items():
            if info["type"] == "Fixed":
                discovery.append({
                    "item": item_key,
                    "params": {"warn": 80, "crit": 90},
                    "metrics": ["disk_size"],
                    "service_labels": {
                        "vhd_type": "Fixed",
                        "image": info["main_path"],
                    },
                })
        return {"changed": False, "msg": "discovered %d fixed VHDs" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/hyperv": "yes"}}}

    item = params.get("item", "")
    ps_script = _gather_vhd_ps_script()
    res = ctx.run(
        ["pwsh", "-NoProfile", "-Command", ps_script],
        mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no VHD data retrieved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    string_table = _parse_ps_output(res.stdout)
    section = _parse_vhd_string_table(string_table)
    if item not in section:
        return {"changed": False, "msg": "No information available for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    info = section[item]
    disk_size = info["disk_size"]
    main_path = info["main_path"]
    path_name = main_path.split("\\")[-1] if "\\" in main_path else main_path.split("/")[-1]
    return {"changed": False, "msg": "Disk name: %s | VHD type: Fixed" % path_name,
            "data": {"state": "OK", "metrics": {"disk_size": disk_size}, "details": ""}}