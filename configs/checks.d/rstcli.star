def main(ctx, params):
    # Discover mode: enumerate RAID volumes and their disks
    if params.get("_discover"):
        res = ctx.run(["rstcli", "-ld", "-pd"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 volumes",
                    "data": {"discovery": []}}

        volumes = _parse_rstcli(res.stdout)
        discovery = []

        # Discover volumes
        for vol_name in volumes:
            discovery.append({
                "item": vol_name,
                "params": {},
                "metrics": []
            })

        # Discover disks (volume/diskID)
        for vol_name in volumes:
            disks = volumes[vol_name].get("Disks", [])
            for disk in disks:
                disk_id = disk.get("ID", "")
                if disk_id:
                    discovery.append({
                        "item": vol_name + "/" + disk_id,
                        "params": {},
                        "metrics": []
                    })

        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: single item (volume or disk)
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "missing item parameter",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["rstcli", "-ld", "-pd"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "unable to retrieve rstcli data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_rstcli(res.stdout)
    if item.find("/") >= 0:
        # Disk check: volume/diskID
        parts = item.rsplit("/", 1)
        if len(parts) != 2:
            return {"changed": False, "msg": "invalid disk item format: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        vol_name, disk_id = parts
        disks = section.get(vol_name, {}).get("Disks", [])
        disk_state = "UNKNOWN"
        infotext = "Disk not found"
        for disk in disks:
            if disk.get("ID") == disk_id:
                state_str = disk.get("State", "Unknown")
                disk_state = "CRIT" if state_str not in _rstcli_states else _rstcli_states[state_str]
                size = disk.get("Size", "")
                dtype = disk.get("Disk Type", "")
                model = disk.get("Model", "")
                serial = disk.get("Serial Number", "")
                infotext = "%s (unit: %s, size: %s, type: %s, model: %s, serial: %s)" % (
                    state_str, vol_name, size, dtype, model, serial)
                break
        return {"changed": False, "msg": infotext,
                "data": {"state": disk_state, "metrics": {}, "details": ""}}
    else:
        # Volume check
        volume = section.get(item)
        if not volume:
            return {"changed": False, "msg": "volume not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state_str = volume.get("State", "Unknown")
        state = "CRIT" if state_str not in _rstcli_states else _rstcli_states[state_str]
        raid_level = volume.get("Raid Level", "")
        num_disks = volume.get("Num Disks", "")
        size = volume.get("Size", "")
        summary = "RAID %s, %s disks (%s), state %s" % (
            raid_level, num_disks, size, state_str)
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {}, "details": ""}}


# Parse rstcli -ld -pd output into structured section
def _parse_rstcli(output):
    lines = output.splitlines()
    volumes = {}
    current_section = None
    current_volume = None
    current_disk = None

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("--"):
            if current_section != None:
                # End previous section if any
                pass
            current_section = ":".join(stripped.strip("-").strip()).strip()
            if current_section == "VOLUME INFORMATION":
                current_volume = None
                current_disk = None
            elif current_section.startswith("DISKS IN VOLUME"):
                vol_name = current_section.split(":")[1].strip() if ":" in current_section else ""
                if vol_name and vol_name not in volumes:
                    volumes[vol_name] = {}
                current_volume = volumes.get(vol_name)
                current_disk = None
            else:
                current_volume = None
                current_disk = None
        elif not stripped or stripped == "0":
            continue
        else:
            fields = stripped.split(None, 1)
            if len(fields) < 2:
                continue
            key, value = fields[0], fields[1].strip()
            if key == "Name" and current_section == "VOLUME INFORMATION":
                current_volume = {}
                volumes[value] = current_volume
                current_disk = None
            elif key == "ID" and current_section and current_section.startswith("DISKS IN VOLUME"):
                current_disk = {}
                if current_volume != None:
                    if "Disks" not in current_volume:
                        current_volume["Disks"] = []
                    current_volume["Disks"].append(current_disk)
            elif current_volume != None and current_disk != None:
                current_disk[key] = value
            elif current_volume != None:
                current_volume[key] = value

    return volumes


# State mapping: only "Normal" -> OK per the source; everything else -> CRIT
_rstcli_states = {
    "Normal": "OK",
}