HP_MSA_DEFAULT_PARAMS = {
    "read_throughput": {"warn": 0, "crit": 0},
    "write_throughput": {"warn": 0, "crit": 0},
}

def _parse_hp_msa_section(res):
    """Parse the output of an HP MSA disk query into a section-like dict."""
    section = {}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        name = f[0]
        read_str = f[1] if len(f) > 1 else "0"
        write_str = f[2] if len(f) > 2 else "0"
        read_val = float(read_str) if read_str.replace(".", "", 1).isdigit() else 0.0
        write_val = float(write_str) if write_str.replace(".", "", 1).isdigit() else 0.0
        section[name] = {
            "read_throughput": read_val,
            "write_throughput": write_val,
        }
    return section

def _grade_throughput(value, params, levels_key):
    """Grade a throughput value against warn/crit levels."""
    default_levels = HP_MSA_DEFAULT_PARAMS.get(levels_key, {})
    warn = params.get("warn", default_levels.get("warn", 0))
    crit = params.get("crit", default_levels.get("crit", 0))
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _check_disk_io(params, disk, item):
    """Check disk IO statistics for one disk."""
    metrics = {}
    states = []
    msg_parts = []

    for field in ["read_throughput", "write_throughput"]:
        value = disk.get(field, 0.0)
        if value != 0.0:
            metrics[field] = value
            field_params = params.get(field, {})
            st = _grade_throughput(value, field_params, field)
            states.append(st)
            msg_parts.append("%s: %f" % (field, value))

    if states:
        if "CRIT" in states:
            state = "CRIT"
        elif "WARN" in states:
            state = "WARN"
        else:
            state = "OK"
    else:
        state = "OK"

    msg = item + " " + ", ".join(msg_parts)
    return {"state": state, "metrics": metrics, "msg": msg, "details": ""}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        snmpwalk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                               host, ".1.3.6.1.4.1.23287.2.2.1"], mutates=False)

        if snmpwalk_res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not found",
                    "data": {"discovery": []}}

        if snmpwalk_res.rc != 0:
            return {"changed": False, "msg": "HP MSA not reachable",
                    "data": {"discovery": []}}

        section = _parse_hp_msa_section(snmpwalk_res)
        if len(section) == 0:
            return {"changed": False, "msg": "no HP MSA disks found",
                    "data": {"discovery": []}}

        discovery = []
        for name in sorted(section.keys()):
            disk = section[name]
            metrics = []
            if disk.get("read_throughput", 0.0) != 0.0:
                metrics.append("read_throughput")
            if disk.get("write_throughput", 0.0) != 0.0:
                metrics.append("write_throughput")
            entry = {
                "item": name,
                "params": {"read_throughput": {"warn": 0, "crit": 0},
                           "write_throughput": {"warn": 0, "crit": 0}},
                "metrics": metrics if metrics else ["read_throughput", "write_throughput"],
            }
            discovery.append(entry)

        return {"changed": False,
                "msg": "discovered %d HP MSA disks" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    snmpwalk_res = ctx.run(["snmpwalk", "-v2c", "-c", community,
                           "-Oqn", host,
                           ".1.3.6.1.4.1.23287.2.2.1"], mutates=False)

    if snmpwalk_res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if snmpwalk_res.rc != 0:
        return {"changed": False, "msg": "HP MSA array not reachable or SNMP failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_hp_msa_section(snmpwalk_res)
    if item == "SUMMARY":
        total_read = 0.0
        total_write = 0.0
        for name in section:
            total_read += section[name].get("read_throughput", 0.0)
            total_write += section[name].get("write_throughput", 0.0)
        disk = {"read_throughput": total_read, "write_throughput": total_write}
    else:
        disk = section.get(item)
        if disk == None:
            return {"changed": False,
                    "msg": "no such HP MSA disk: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    result = _check_disk_io(params, disk, item)
    return {"changed": False,
            "msg": result["msg"],
            "data": {"state": result["state"], "metrics": result["metrics"],
                     "details": result["details"]}}