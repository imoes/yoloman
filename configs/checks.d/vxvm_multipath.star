def _parse_line(line):
    # line is whitespace-separated: name status enc_type paths active_paths inactive_paths enclosure
    parts = line.split()
    if len(parts) < 7:
        return None
    name = parts[0]
    status = parts[1]
    # parts[2] = enc_type (ignored)
    paths = parts[3]
    active_paths = parts[4]
    inactive_paths = parts[5]
    enclosure = parts[6]
    if not (paths.lstrip("-").isdigit() and active_paths.lstrip("-").isdigit() and inactive_paths.lstrip("-").isdigit()):
        return None
    return {
        "name": name,
        "status": status,
        "paths": float(paths),
        "active_paths": float(active_paths),
        "inactive_paths": float(inactive_paths),
        "enclosure": enclosure,
    }

def _parse_section(content):
    out = {}
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        d = _parse_line(line)
        if d != None:
            out[d["name"]] = d
    return out

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real source: /etc/vx/tables/multipath or `vxvm list` output.
        # Checkmk's vxvm agent section is produced by a Checkmk special agent that
        # runs `vxvm list` / `vxdmp querysubpaths` under Veritas installation.
        # We reproduce the same data source: vxdmp querysubpaths-all (or vxvm).
        res = ctx.run(["vxdmp", "querysubpaths-all"], mutates=False)
        if res.rc != 0:
            # vxdmp not installed or not a VxVM host -> no items
            return {"changed": False, "msg": "no vxvm multipath data", "data": {"discovery": []}}
        content = res.stdout
        section = _parse_section(content)
        if len(section) == 0:
            return {"changed": False, "msg": "no vxvm multipath disks", "data": {"discovery": []}}
        discovery = []
        for name in section:
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["paths", "active_paths", "inactive_paths"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Re-gather data for the single item in check mode
    res = ctx.run(["vxdmp", "querysubpaths-all"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "vxvm multipath not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(res.stdout)
    disk = section.get(item)
    if disk == None:
        return {"changed": False, "msg": "no such multipath disk: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if disk["active_paths"] != disk["paths"] and disk["active_paths"] >= disk["paths"] / 2:
        state = "WARN"
    elif disk["inactive_paths"] > 0 and disk["inactive_paths"] > disk["paths"] / 2:
        state = "CRIT"

    summary = "Status: %s, (%d/%d) Paths to enclosure %s enabled" % (
        disk["status"], int(disk["active_paths"]), int(disk["paths"]), disk["enclosure"])
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {"paths": disk["paths"], "active_paths": disk["active_paths"], "inactive_paths": disk["inactive_paths"]}, "details": ""}}