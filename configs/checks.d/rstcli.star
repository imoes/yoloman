# ===== check plugin: cmk/plugins/intel/agent_based/rstcli.py =====
# Translated to a read-only Starlark check module for the yolo-man agent.
# Monitors Intel Rapid Storage Technology (RST) CLI volumes and member disks.
# The host data source is `rstcli` (the Intel RST command-line tool).

RSTCLI_BIN = "rstcli"


def _rstcli_sections(lines):
    """Reproduce parse_rstcli_sections: group rstcli stdout into sections.

    A line whose first token starts with "--" begins a new section header.
    Header tokens beginning with "--" are stripped of leading dashes and
    joined by ":" to form the section name. Subsequent rows accumulate into
    that section until the next header (or end of output).

    Returns a list of (section_name, rows) tuples in order.
    """
    sections = []
    current_name = None
    current_rows = None
    for line in lines:
        tokens = line.split()
        if len(tokens) == 0:
            continue
        if tokens[0].startswith("--"):
            if current_name != None:
                sections.append((current_name, current_rows))
            cleaned = []
            for t in tokens:
                cleaned.append(t.lstrip("-").rstrip())
            current_name = ":".join([c for c in cleaned if c != ""]).strip()
            current_rows = []
        else:
            if current_name == None:
                continue
            if len(tokens) < 2:
                continue
            current_rows.append(tokens)
    if current_name != None:
        sections.append((current_name, current_rows))
    return sections


def _parse_volumes(rows):
    """Reproduce parse_rstcli_volumes: rows -> {volume_name: {field: value}}."""
    volumes = {}
    current = None
    for row in rows:
        if row[0] == "Name":
            name = row[1].strip()
            current = {}
            volumes[name] = current
        else:
            if current == None:
                continue
            current[row[0]] = row[1].strip()
    return volumes


def _parse_disks(rows):
    """Reproduce parse_rstcli_disks: rows -> list of {field: value} dicts."""
    disks = []
    current = None
    for row in rows:
        if row[0] == "ID":
            current = {}
            disks.append(current)
        if current != None:
            current[row[0]] = row[1].strip()
    return disks


def _parse_rstcli(string_table):
    """Reproduce parse_rstcli: full stdout lines -> section volumes dict."""
    sections = _rstcli_sections(string_table)
    volumes = {}
    for name, rows in sections:
        if name == "VOLUME INFORMATION":
            volumes.update(_parse_volumes(rows))
        elif name.startswith("DISKS IN VOLUME"):
            volume_name = name.split(":")[1].strip() if ":" in name else ""
            if volume_name in volumes:
                volumes[volume_name]["Disks"] = _parse_disks(rows)
    return volumes


def _vol_summary(volume):
    """Build the Checkmk-style summary line for a volume."""
    raid_level = volume.get("Raid Level", "")
    num_disks = volume.get("Num Disks", "")
    size = volume.get("Size", "")
    state = volume.get("State", "")
    nd = int(num_disks) if str(num_disks).isdigit() else 0
    return "RAID %s, %d disks (%s), state %s" % (raid_level, nd, size, state)


def _disk_summary(disk, volume_name):
    """Build the Checkmk-style summary line for a member disk."""
    state = disk.get("State", "")
    size = disk.get("Size", "")
    dtype = disk.get("Disk Type", "")
    model = disk.get("Model", "")
    serial = disk.get("Serial Number", "")
    return "%s (unit: %s, size: %s, type: %s, model: %s, serial: %s)" % (
        state, volume_name, size, dtype, model, serial)


def _is_installed(ctx):
    """Probe for the real thing: the rstcli binary must be present."""
    res = ctx.run(["command", "-v", RSTCLI_BIN], mutates=False)
    return res.rc == 0


def _gather(ctx):
    """Run rstcli and return the parsed section, or None if unavailable."""
    if not _is_installed(ctx):
        return None
    res = ctx.run([RSTCLI_BIN, "--information"], mutates=False)
    if res.rc != 0:
        return None
    return _parse_rstcli(res.stdout.splitlines())


def main(ctx, params):
    """Main entry point: discovery when _discover is set, check otherwise."""
    item = params.get("item", "")
    section = _gather(ctx)

    if params.get("_discover"):
        if section == None:
            return {"changed": False, "msg": "rstcli not installed or unavailable",
                    "data": {"discovery": []}}
        vol_items = []
        for name in section:
            vol_items.append({
                "item": name,
                "params": {},
                "metrics": [],
            })
        disk_items = []
        for vname, vol in section.items():
            for disk in vol.get("Disks", []):
                did = disk.get("ID", "")
                if did == "":
                    continue
                disk_items.append({
                    "item": "%s/%s" % (vname, did),
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d volumes, %d disks" % (len(vol_items), len(disk_items)),
            "data": {"discovery": vol_items + disk_items},
        }

    # ---- CHECK MODE ----
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if section == None:
        return {"changed": False, "msg": "rstcli not installed or unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if "/" in item:
        volume_name, disk_id = item.rsplit("/", 1)
        vol = section.get(volume_name, {})
        disks = vol.get("Disks", [])
        found = None
        for disk in disks:
            if disk.get("ID", "") == disk_id:
                found = disk
                break
        if found == None:
            return {"changed": False, "msg": "disk not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        summary = _disk_summary(found, volume_name)
        state = "OK" if found.get("State", "") == "Normal" else "CRIT"
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {}, "details": ""}}
    else:
        vol = section.get(item)
        if vol == None:
            return {"changed": False, "msg": "volume not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        summary = _vol_summary(vol)
        state = "OK" if vol.get("State", "") == "Normal" else "UNKNOWN"
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {}, "details": ""}}