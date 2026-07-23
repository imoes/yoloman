def _parse_hyperv_vhd(string_table_lines):
    """Parse agent section 'hyperv_vm_vhd' into dict keyed by controller location string."""
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
    if len(string_table_lines) == 0:
        return parsed

    section_name = string_table_lines[0][0] if len(string_table_lines[0]) > 0 else ""
    datatype = datatypes.get(section_name)
    if datatype == None:
        return parsed

    element = ""
    start = False
    counter = 1
    for line in string_table_lines:
        if len(line) == 0:
            continue
        if line[0] == datatype:
            if start:
                counter += 1
            else:
                start = True

            if datatype == "nic.name":
                element = " ".join(line[1:]) + " " + str(counter)
            else:
                element = " ".join(line[1:])

            parsed[element] = {}
        elif start:
            if len(line) < 2:
                continue
            element_data = parsed.setdefault(element, {})
            element_data[line[0]] = " ".join(line[1:])

    return parsed


def _parse_vhd_section(string_table_lines):
    """Parse raw section into VHD info dict for FIXED type disks only."""
    raw = _parse_hyperv_vhd(string_table_lines)
    vhd_section = {}
    for key, values in raw.items():
        vhd_type = values.get("vhd.Type")
        if vhd_type == "Fixed":
            vhd_path = values.get("vhd.Path")
            if vhd_path != None and vhd_type != None:
                controller_key = (
                    values.get("vhd.controller.Type", "")
                    + " "
                    + values.get("vhd.controller.Number", "")
                    + " "
                    + values.get("vhd.controller.Location", "")
                )
                disk_size_str = values.get("vhd.DiskSize", "0")
                file_size_str = values.get("vhd.FileSize", "0")
                disk_size = int(disk_size_str) if disk_size_str.isdigit() else 0
                file_size = int(file_size_str) if file_size_str.isdigit() else 0
                # Extract filename from Windows path
                path_parts = vhd_path.split("\\")
                main_path_name = ""
                for p in path_parts:
                    if len(p.strip()) > 0:
                        main_path_name = p

                vhd_section[controller_key] = {
                    "main_path_name": main_path_name,
                    "disk_size": disk_size,
                    "file_size": file_size,
                    "type": "Fixed",
                }
    return vhd_section


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["wmic", "path", "Win32_VirtualHardDisk", "get", "Caption,Path,DiskSize,FileSize,Type", "/format:csv"],
            mutates=False
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "Failed to query VHD info via WMI",
                "data": {"discovery": []}
            }

        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {
                "changed": False,
                "msg": "No VHD data returned",
                "data": {"discovery": []}
            }

        section = []
        for line in lines[1:]:
            parts = line.split(",")
            if len(parts) < 5:
                continue

            path = parts[1]
            disk_size_str = parts[2]
            file_size_str = parts[3]
            vhd_type = parts[4].strip()

            if vhd_type != "Fixed":
                continue

            disk_size = int(disk_size_str) if disk_size_str.isdigit() else 0
            file_size = int(file_size_str) if file_size_str.isdigit() else 0

            path_parts = path.split("\\")
            main_path_name = ""
            for p in path_parts:
                if len(p.strip()) > 0:
                    main_path_name = p

            item = main_path_name if len(main_path_name) > 0 else path

            section.append({
                "item": item,
                "params": {},
                "metrics": ["disk_size"]
            })

        return {
            "changed": False,
            "msg": "discovered %d fixed VHDs" % len(section),
            "data": {"discovery": section}
        }

    item = params.get("item", "")
    res = ctx.run(
        ["wmic", "path", "Win32_VirtualHardDisk", "get", "Caption,Path,DiskSize,FileSize,Type", "/format:csv"],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to query VHD info via WMI",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "No VHD data returned",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    vhd_section = {}
    for line in lines[1:]:
        parts = line.split(",")
        if len(parts) < 5:
            continue

        path = parts[1]
        disk_size_str = parts[2]
        file_size_str = parts[3]
        vhd_type = parts[4].strip()

        if vhd_type != "Fixed":
            continue

        disk_size = int(disk_size_str) if disk_size_str.isdigit() else 0
        file_size = int(file_size_str) if file_size_str.isdigit() else 0

        path_parts = path.split("\\")
        main_path_name = ""
        for p in path_parts:
            if len(p.strip()) > 0:
                main_path_name = p

        vhd_section[main_path_name] = {
            "main_path_name": main_path_name,
            "disk_size": disk_size,
            "file_size": file_size,
            "type": "Fixed",
        }

    if item not in vhd_section:
        return {
            "changed": False,
            "msg": "No information available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    info = vhd_section[item]
    disk_name = info["main_path_name"]
    disk_size = info["disk_size"]
    vhd_type = info["type"]

    return {
        "changed": False,
        "msg": "Disk name: %s, Maximum disk size: %s, VHD type: %s" % (
            disk_name,
            str(disk_size),
            vhd_type
        ),
        "data": {
            "state": "OK",
            "metrics": {"disk_size": disk_size},
            "details": "",
        },
    }