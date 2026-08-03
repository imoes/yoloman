def _snmp_get_oid(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_walk_oid(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        lines.append((sp[0], sp[1]))
    return lines

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect: sysObjectID must be one of the supported Fujitsu devices
    sysoid = _snmp_get_oid(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sysoid == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "no SNMP response / not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "SNMP not available; expander not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    supported_oids = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
        ".1.3.6.1.4.1.211.1.21.1.50",
    ]
    if sysoid not in supported_oids:
        if params.get("_discover"):
            return {"changed": False, "msg": "not a supported Fujitsu device",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "not a supported Fujitsu storage device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Fetch expander tables: base.2.8.2.1, columns 1 (Index) and 3 (Status)
        discovery = []
        for base in supported_oids:
            col_oid = base + ".2.8.2.1"
            rows = _snmp_walk_oid(ctx, community, host, col_oid)
            if not rows:
                continue
            # Build index -> status map from column 3; index from column 1
            values_by_index = {}
            for (row_oid, row_val) in rows:
                suffix = row_oid[len(col_oid) + 1:]
                parts = suffix.split(".")
                if len(parts) < 1:
                    continue
                # last component is the column id (1=index, 3=status)
                if len(parts) >= 2:
                    col_id = parts[-1]
                    idx = ".".join(parts[:-1])
                else:
                    col_id = parts[0]
                    idx = ""
                if idx not in values_by_index:
                    values_by_index[idx] = {}
                values_by_index[idx][col_id] = row_val
            for idx in values_by_index:
                cols = values_by_index[idx]
                status = cols.get("3", "")
                # Only inventory if status != "4" (Invalid)
                if status != "4":
                    discovery.append({
                        "item": idx,
                        "params": {"levels": (3, 4)},
                        "metrics": ["status"],
                    })
        return {"changed": False,
                "msg": "discovered %d expanders" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "linux"}}}

    # Check mode for one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no expander item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Locate the status for this index across all supported bases
    status_val = None
    for base in supported_oids:
        col_oid = base + ".2.8.2.1"
        # Query column 3 (status) for this specific index
        target = col_oid + ".3." + item
        val = _snmp_get_oid(ctx, community, host, target)
        if val != None and val != "":
            status_val = val
            break

    status_map = {
        "1": ("OK", "Normal"),
        "2": ("CRIT", "Alarm"),
        "3": ("WARN", "Warning"),
        "4": ("CRIT", "Invalid"),
        "5": ("CRIT", "Maintenance"),
        "6": ("CRIT", "Undefined"),
    }

    if status_val == None:
        return {"changed": False, "msg": "expander " + item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mapped = status_map.get(status_val, ("UNKNOWN", "Unknown"))
    state_label = mapped[0]
    summary = mapped[1]

    metric_value = 0
    if state_label == "OK":
        metric_value = 1
    elif state_label == "WARN":
        metric_value = 2
    elif state_label == "CRIT":
        metric_value = 3
    else:
        metric_value = 0

    return {"changed": False, "msg": "Expander " + item + " " + summary,
            "data": {"state": state_label, "metrics": {"status": metric_value}, "details": summary}}