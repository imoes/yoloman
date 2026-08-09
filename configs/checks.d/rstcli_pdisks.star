def _split_sections(lines):
    """Split rstcli output into (section_name, rows) tuples."""
    sections = []
    current = None
    for line in lines:
        if line.startswith("--"):
            if current != None:
                sections.append(current)
            name = line.replace("-", "").strip()
            current = (name, [])
        elif len(line) < 2:
            continue
        else:
            if current == None:
                continue
            current[1].append(line)
    if current != None:
        sections.append(current)
    return sections

def _parse_volumes(rows):
    """Parse the VOLUME INFORMATION section into a dict of volume_name -> attrs."""
    volumes = {}
    current_volume = {}
    for row in rows:
        key = row[0]
        val = row[1].strip()
        if key == "Name":
            current_volume = {}
            volumes[val] = current_volume
        else:
            current_volume[key] = val
    return volumes

def _parse_disks(rows):
    """Parse a DISKS IN VOLUME section into a list of disk dicts."""
    disks = []
    current_disk = {}
    for row in rows:
        key = row[0]
        val = row[1].strip()
        if key == "ID":
            current_disk = {}
            disks.append(current_disk)
        current_disk[key] = val
    return disks

def _parse_rstcli_output(output):
    """Parse raw rstcli output into the section dict matching Checkmk's structure."""
    lines = output.splitlines()
    sections = _split_sections(lines)
    volumes = {}
    for section_name, rows in sections:
        if section_name == "VOLUME INFORMATION":
            volumes.update(_parse_volumes(rows))
        elif section_name.startswith("DISKS IN VOLUME"):
            vol_name = section_name.split(":")[1].strip()
            volumes[vol_name]["Disks"] = _parse_disks(rows)
    return volumes

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the rstcli binary
        res = ctx.run(["rstcli", "--help"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "rstcli not found", "data": {"discovery": []}}

        # Get volumes list
        res = ctx.run(["rstcli", "-I"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "rstcli no output", "data": {"discovery": []}}

        volumes = _parse_rstcli_output(res.stdout)
        if not volumes:
            return {"changed": False, "msg": "rstcli no volumes", "data": {"discovery": []}}

        discovery = []
        for vol_name, volume in volumes.items():
            disks = volume.get("Disks", [])
            for disk in disks:
                disk_id = disk.get("ID", "")
                if disk_id:
                    item = "%s/%s" % (vol_name, disk_id)
                    metric_names = []
                    discovery.append({"item": item, "params": {}, "metrics": metric_names})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Probe for the rstcli binary
    res = ctx.run(["rstcli", "--help"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "rstcli not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get full info
    res = ctx.run(["rstcli", "-I", "-J"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "rstcli no output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    volumes = _parse_rstcli_output(res.stdout)
    if not volumes:
        return {"changed": False, "msg": "no volumes found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # item is "volume_name/disk_id"
    parts = item.rsplit("/", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    volume_name = parts[0]
    disk_id = parts[1]

    volume = volumes.get(volume_name, {})
    disks = volume.get("Disks", [])

    rstcli_states = {"Normal": "OK"}

    for disk in disks:
        if disk.get("ID") == disk_id:
            state_str = disk.get("State", "")
            state = rstcli_states.get(state_str, "CRIT")
            infotext = "%s (unit: %s, size: %s, type: %s, model: %s, serial: %s)" % (
                state_str,
                volume_name,
                disk.get("Size", ""),
                disk.get("Disk Type", ""),
                disk.get("Model", ""),
                disk.get("Serial Number", ""),
            )
            return {
                "changed": False,
                "msg": infotext,
                "data": {"state": state, "metrics": {}, "details": ""},
            }

    return {"changed": False, "msg": "disk %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}