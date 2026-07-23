def main(ctx, params):
    # Probe: run the real command the Checkmk agent plugin would run to get RST CLI data
    res = ctx.run(["rstcli", "-l", "-v"], mutates=False)
    if res.rc != 0:
        # If rstcli not found, behave like the Python plugin: return no discovery items
        if res.stdout.strip() == "rstcli not found" or "rstcli not found" in res.stderr:
            if params.get("_discover"):
                return {"changed": False, "msg": "discovered 0 volumes", "data": {"discovery": []}}
            return {"changed": False, "msg": "no data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # Unexpected error (command missing, permission, etc.) -> UNKNOWN for check mode
        if not params.get("_discover"):
            return {"changed": False, "msg": "command failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse rstcli output into the same section structure as the Python plugin
    # Format: sections separated by lines like "--VOLUME INFORMATION--" or "--DISKS IN VOLUME: Volume 0--"
    lines = res.stdout.splitlines()
    sections = {}
    current_section_name = None
    current_rows = []
    
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("--") and line.endswith("--"):
            # Save previous section if any
            if current_section_name != None:
                sections[current_section_name] = current_rows
            # Start new section: strip dashes and trim, e.g. "VOLUME INFORMATION" or "DISKS IN VOLUME: Volume 0"
            raw = line.strip("-").strip()
            current_section_name = raw
            current_rows = []
        elif line == "":
            # Skip blank lines
            pass
        elif current_section_name != None:
            # Parse key-value line: "Key: Value" or just "Key" (skip single-column lines like stray "0")
            parts = line.split(":", 1)
            if len(parts) >= 2:
                key = parts[0].strip()
                value = parts[1].strip()
                current_rows.append([key, value])
        i += 1
    # Save last section
    if current_section_name != None:
        sections[current_section_name] = current_rows

    # Build volumes dict: extract VOLUME INFORMATION rows and DISKS rows
    volumes = {}
    # First, parse VOLUME INFORMATION section if present
    if "VOLUME INFORMATION" in sections:
        volume_rows = sections["VOLUME INFORMATION"]
        current_volume = {}
        current_volume_name = ""
        for row in volume_rows:
            if row[0] == "Name":
                if current_volume_name:
                    volumes[current_volume_name] = current_volume
                current_volume = {}
                current_volume_name = row[1].strip()
                volumes[current_volume_name] = current_volume
            else:
                current_volume[row[0]] = row[1].strip()
        if current_volume_name:
            volumes[current_volume_name] = current_volume

    # Then, attach DISKS lists by scanning "DISKS IN VOLUME:*" sections
    for key, rows in sections.items():
        if key.startswith("DISKS IN VOLUME:"):
            vol_name = key.split(":", 1)[1].strip()
            if vol_name in volumes:
                current_disk = {}
                disks_list = []
                for r in rows:
                    if r[0] == "ID":
                        if current_disk:
                            disks_list.append(current_disk)
                        current_disk = {}
                    current_disk[r[0]] = r[1].strip()
                if current_disk:
                    disks_list.append(current_disk)
                volumes[vol_name]["Disks"] = disks_list

    # STATE MAPPING (same as Python plugin: only "Normal" -> OK; anything else -> CRIT)
    def _state_for(s):
        if s == "Normal":
            return "OK"
        return "CRIT"

    # DISCOVERY MODE: enumerate per-disk services
    if params.get("_discover"):
        items = []
        for vol_name, vol in volumes.items():
            disks = vol.get("Disks", [])
            for d in disks:
                item = "%s/%s" % (vol_name, d.get("ID", ""))
                items.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d RAID disks" % len(items), "data": {"discovery": items}}

    # CHECK MODE: one item = "volume_name/disk_id"
    item = params.get("item", "")
    if "/" not in item:
        return {"changed": False, "msg": "malformed item", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vol_name = item.rsplit("/", 1)[0]
    disk_id = item.rsplit("/", 1)[1]
    vol = volumes.get(vol_name)
    if vol == None:
        return {"changed": False, "msg": "volume not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    disks = vol.get("Disks", [])
    disk_found = None
    for d in disks:
        if d.get("ID") == disk_id:
            disk_found = d
            break

    if disk_found == None:
        return {"changed": False, "msg": "disk not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _state_for(disk_found.get("State", ""))
    size_str = disk_found.get("Size", "")
    disk_type = disk_found.get("Disk Type", "")
    model = disk_found.get("Model", "")
    serial = disk_found.get("Serial Number", "")

    infotext = "%s (unit: %s, size: %s, type: %s, model: %s, serial: %s)" % (
        disk_found.get("State", "unknown"),
        vol_name,
        size_str if size_str else "N/A",
        disk_type if disk_type else "N/A",
        model if model else "N/A",
        serial if serial else "N/A"
    )

    return {"changed": False, "msg": infotext, "data": {"state": state, "metrics": {}, "details": ""}}