def _parse_snmp_table(res, base_oid):
    # Parse snmpwalk output into dict: ap_id -> {field: value}
    # Output format: ".1.3.6.1.4.1.2011.6.139.X.Y.Z.N = INTEGER: value"
    parsed = {}
    lines = res.stdout.splitlines()
    for line in lines:
        if not line or not "=" in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val = parts[1].strip()
        if not val.startswith("INTEGER:"):
            continue
        value_str = val[len("INTEGER:"):].strip()
        # Extract index from OID
        if not oid.startswith(base_oid):
            continue
        suffix = oid[len(base_oid):].lstrip(".")
        # Find last numeric component as index
        idx_str = suffix.rsplit(".", 1)[-1] if "." in suffix else suffix
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        if not idx in parsed:
            parsed[idx] = {}
        parsed[idx]["value"] = int(value_str)
    return parsed

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Fetch both SNMP trees
        res1 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
        ], mutates=False)
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
        ], mutates=False)
        # Parse AP IDs from the second tree (has the AP index)
        aps = []
        for line in res2.stdout.splitlines():
            if not line or not "=" in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            if not oid.startswith(".1.3.6.1.4.1.2011.6.139.16.1.2.1.3"):
                continue
            # OID format: .1.3.6.1.4.1.2011.6.139.16.1.2.1.3.<ap_id>
            ap_id = oid.rsplit(".", 1)[-1].strip()
            if ap_id.isdigit():
                aps.append(ap_id)
        discovery = []
        for ap_id in aps:
            discovery.append({
                "item": ap_id,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["mem_used_percent"]
            })
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    ap_id = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if type(levels) == "list" else 80.0
    crit = levels[1] if type(levels) == "list" else 90.0

    # Fetch both SNMP trees
    res1 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
    ], mutates=False)
    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
    ], mutates=False)

    # Parse AP data
    # Tree1: .1.3.6.1.4.1.2011.6.139.13.3.3.1
    # oids: 6 (status), 40 (mem), 41 (cpu), 43 (temp), 44 (con_users)
    tree1 = {}
    for line in res1.stdout.splitlines():
        if not line or not "=" in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val = parts[1].strip()
        if not val.startswith("INTEGER:"):
            continue
        value_str = val[len("INTEGER:"):].strip()
        if not oid.startswith(".1.3.6.1.4.1.2011.6.139.13.3.3.1."):
            continue
        suffix = oid[len(".1.3.6.1.4.1.2011.6.139.13.3.3.1."):].strip()
        if not "." in suffix:
            continue
        parts2 = suffix.split(".")
        if len(parts2) != 2:
            continue
        ap_idx = int(parts2[0])
        oid_idx = int(parts2[1])
        if not ap_idx in tree1:
            tree1[ap_idx] = {}
        tree1[ap_idx][oid_idx] = int(value_str)

    # Tree2: .1.3.6.1.4.1.2011.6.139.16.1.2.1
    # oids: 3 (ap_id), 6 (radio_state), 25 (ch_usage), 40 (users_online)
    tree2 = {}
    for line in res2.stdout.splitlines():
        if not line or not "=" in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val = parts[1].strip()
        if not val.startswith("INTEGER:"):
            continue
        value_str = val[len("INTEGER:"):].strip()
        if not oid.startswith(".1.3.6.1.4.1.2011.6.139.16.1.2.1."):
            continue
        suffix = oid[len(".1.3.6.1.4.1.2011.6.139.16.1.2.1."):].strip()
        if not "." in suffix:
            continue
        parts2 = suffix.split(".")
        if len(parts2) != 2:
            continue
        ap_idx = int(parts2[0])
        oid_idx = int(parts2[1])
        if not ap_idx in tree2:
            tree2[ap_idx] = {}
        tree2[ap_idx][oid_idx] = int(value_str)

    # Build AP map
    ap_map = {}
    for ap_idx in tree2:
        ap_id_val = str(tree2[ap_idx].get(3, ""))
        mem_val = tree1.get(ap_idx, {}).get(40, None)
        if ap_id_val == ap_id and mem_val != None:
            mem_used_percent = float(mem_val)
            state = "CRIT" if mem_used_percent >= crit else ("WARN" if mem_used_percent >= warn else "OK")
            return {
                "changed": False,
                "msg": "Memory: %d%%" % mem_used_percent,
                "data": {
                    "state": state,
                    "metrics": {"mem_used_percent": mem_used_percent},
                    "details": ""
                }
            }

    # Not found
    return {
        "changed": False,
        "msg": "AP %s not found" % ap_id,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }