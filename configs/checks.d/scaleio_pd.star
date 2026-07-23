UNIT_TO_MB = {
    "Bytes": 0.00000095367431640625,
    "KB": 0.0009765625,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1048576.0,
}

def _parse_sections(stdout):
    section = {}
    current_id = ""
    for line in stdout.splitlines():
        tokens = line.split()
        if len(tokens) == 0:
            continue
        if tokens[0] == "PROTECTION_DOMAIN" and len(tokens) >= 2:
            current_id = tokens[1].replace(":", "")
            if current_id not in section:
                section[current_id] = {}
        elif current_id != "" and current_id in section and len(tokens) >= 2:
            section[current_id][tokens[0]] = tokens[1:]
    return section

def main(ctx, params):
    mdm_ip = params.get("mdm_ip", "")
    if mdm_ip != "":
        cmd = ["scli", "--mdm_ip", mdm_ip, "--query_all_protection_domains", "--approve_certificate"]
    else:
        cmd = ["scli", "--query_all_protection_domains"]

    if params.get("_discover"):
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "scli failed: " + res.stderr,
                    "data": {"discovery": []}}
        section = _parse_sections(res.stdout)
        items = []
        for domain_id in section:
            items.append({
                "item": domain_id,
                "params": {"warn": 80.0, "crit": 90.0},
                "metrics": ["used_percent", "total_mb", "used_mb", "free_mb"],
            })
        return {"changed": False, "msg": "discovered %d protection domains" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "scli failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_sections(res.stdout)
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "protection domain not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    max_cap = data.get("MAX_CAPACITY_IN_KB")
    unused_cap = data.get("UNUSED_CAPACITY_IN_KB")

    if max_cap == None or len(max_cap) < 4:
        return {"changed": False, "msg": "missing MAX_CAPACITY_IN_KB for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if unused_cap == None or len(unused_cap) < 4:
        return {"changed": False, "msg": "missing UNUSED_CAPACITY_IN_KB for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Format: ["65.5", "TB", "(67059", "GB)"] — use the parenthetical integer value
    unit = max_cap[3].rstrip(")")
    if unit not in UNIT_TO_MB:
        return {"changed": False, "msg": "unknown unit: " + unit,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mb = float(int(max_cap[2].strip("("))) * UNIT_TO_MB[unit]
    free_mb = float(int(unused_cap[2].strip("("))) * UNIT_TO_MB[unit]

    if total_mb == 0:
        return {"changed": False, "msg": "total capacity is zero for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_mb = total_mb - free_mb
    used_pct = 100.0 * used_mb / total_mb

    name_data = data.get("NAME")
    name_str = name_data[0] if (name_data != None and len(name_data) > 0) else item

    pd_state_data = data.get("STATE")
    pd_state_raw = pd_state_data[0] if (pd_state_data != None and len(pd_state_data) > 0) else ""
    pd_state_short = pd_state_raw.replace("PROTECTION_DOMAIN_", "")

    state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")
    if pd_state_short != "ACTIVE" and pd_state_short != "":
        state = "CRIT"

    total_gb = total_mb / 1024.0
    used_gb = used_mb / 1024.0

    msg = "Name: %s, Used: %f GB/%f GB (%f%%)" % (name_str, used_gb, total_gb, used_pct)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_pct,
                "total_mb": total_mb,
                "used_mb": used_mb,
                "free_mb": free_mb,
            },
            "details": "State: %s" % pd_state_short,
        },
    }