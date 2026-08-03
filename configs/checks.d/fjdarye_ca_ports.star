def main(ctx, params):
    if params.get("_discover"):
        device_oids = [
            ".1.3.6.1.4.1.211.1.21.1.150",
            ".1.3.6.1.4.1.211.1.21.1.153",
        ]
        # Probe for the real thing: the FJDARY-E system via SNMP sysObjectID
        sys_oid = None
        for dev in device_oids:
            res = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"), dev],
                mutates=False)
            # sysObjectID is under .1.3.6.1.2.1.1.2.0
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if sys_res.rc != 0 or len(sys_res.stdout.strip()) == 0:
            # Not an SNMP device we can reach / not installed
            return {"changed": False, "msg": "no fjdarye device found",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_id = sys_res.stdout.strip()
        if sys_id not in device_oids:
            return {"changed": False, "msg": "host is not a fjdarye CA device",
                    "data": {"discovery": [], "host_labels": {}}}

        # Walk the port table for each supported device base
        map_modes = {"11": "CA", "12": "RA", "13": "CARA", "20": "Initiator"}
        found = {}
        for dev in device_oids:
            base = dev + ".5.5.2.1"
            walk = ctx.run(
                ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                 "-Oqn", params.get("host", "localhost"), base],
                mutates=False)
            if walk.rc != 0:
                continue
            for line in walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid = parts[0]
                val = parts[1]
                if not oid.startswith(base + "."):
                    continue
                suffix = oid[len(base) + 1:]
                idx_dot = suffix.find(".")
                if idx_dot == -1:
                    continue
                index = suffix[:idx_dot]
                col = suffix[idx_dot + 1:]
                entry = found.setdefault(index, {})
                if col == "1":
                    entry["index"] = index
                elif col == "2":
                    entry["mode"] = map_modes.get(val, val)
                elif col == "3":
                    entry["read_iops"] = val
                elif col == "4":
                    entry["write_iops"] = val
                elif col == "5":
                    entry["read_mb"] = val
                elif col == "6":
                    entry["write_mb"] = val

        discovery = []
        default_indices = params.get("indices", [])
        default_modes = params.get("modes", ["CA", "CARA"])
        for index, entry in found.items():
            mode = entry.get("mode")
            if default_indices and index not in default_indices:
                continue
            if default_modes and mode not in default_modes:
                continue
            discovery.append({
                "item": index,
                "params": {"indices": default_indices, "modes": default_modes},
                "metrics": ["read_ios", "read_throughput", "write_ios", "write_throughput"],
                "service_labels": {"mode": mode},
            })
        return {"changed": False,
                "msg": "discovered %d fjdarye CA ports" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    # CHECK MODE
    item = params.get("item", "")
    base_oids = [
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]
    map_modes = {"11": "CA", "12": "RA", "13": "CARA", "20": "Initiator"}

    port = {}
    found_item = False
    for dev in base_oids:
        base = dev + ".5.5.2.1"
        for col_suffix, field in [("1", "index"), ("2", "mode"), ("3", "read_iops"),
                                  ("4", "write_iops"), ("5", "read_mb"),
                                  ("6", "write_mb")]:
            oid = base + "." + item + "." + col_suffix
            res = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"), oid],
                mutates=False)
            if res.rc == 0:
                port["index"] = item
                if field == "mode":
                    port[field] = map_modes.get(res.stdout.strip(), res.stdout.strip())
                elif field in ("read_iops", "write_iops"):
                    port[field] = res.stdout.strip()
                elif field in ("read_mb", "write_mb"):
                    port[field] = res.stdout.strip()

    if not port or "mode" not in port:
        return {"changed": False, "msg": "no fjdarye CA port with index %s found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mode = port.get("mode", "unknown")
    metrics = {}
    try_read = False
    try_write = False
    read_mb = _to_float(port.get("read_mb"))
    write_mb = _to_float(port.get("write_mb"))
    read_iops = _to_float(port.get("read_iops"))
    write_iops = _to_float(port.get("write_iops"))

    if read_mb != None:
        metrics["read_throughput"] = read_mb * 1048576.0
        try_read = True
    if read_iops != None:
        metrics["read_ios"] = read_iops
        try_read = True
    if write_mb != None and port.get("mode") != "Initiator":
        metrics["write_throughput"] = write_mb * 1048576.0
        try_write = True
    if write_iops != None and port.get("mode") != "Initiator":
        metrics["write_ios"] = write_iops
        try_write = True

    warn = params.get("levels", (None, None))
    warn_levels = warn[0] if warn != None else None
    crit_levels = warn[1] if warn != None else None

    state = "OK"
    summary = "Mode: %s" % mode
    if try_read and read_iops != None:
        rw, rc = _grade_read(read_iops, params)
        if rc == "CRIT":
            state = "CRIT"
        elif rc == "WARN" and state != "CRIT":
            state = "WARN"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _to_float(v):
    if v == None:
        return None
    if v.strip() == "":
        return None
    if v.strip().lstrip("-").replace(".", "", 1).isdigit():
        return float(v.strip())
    return None


def _grade_read(val, params):
    levels = params.get("read_ios_levels", (None, None))
    warn = levels[0]
    crit = levels[1]
    s = "OK"
    if crit != None and val >= crit:
        s = "CRIT"
    elif warn != None and val >= warn:
        s = "WARN"
    return (warn, s)