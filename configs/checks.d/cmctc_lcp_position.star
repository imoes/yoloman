# ===== translated check: cmk.cmctc_lcp_position =====
# Sensor type: position (no levels, returns raw percentage position value)
# SNMP OIDs: base .1.3.6.1.4.1.2606.4.2.{tree}, oids: 5.2.1.1-8, 7.2.1.2

_MAP_STATUS = {
    "1": ["not available", 3],
    "2": ["lost", 2],
    "3": ["changed", 1],
    "4": ["ok", 0],
    "5": ["off", 2],
    "6": ["on", 0],
    "7": ["warning", 1],
    "8": ["too low", 2],
    "9": ["too high", 2],
    "10": ["error", 2],
}

def _round(x):
    # Starlark has no round() - implement simple rounding
    if x >= 0:
        return int(x + 0.5) if (x - int(x)) >= 0.5 else int(x)
    else:
        return int(x - 0.5) if (x - int(x)) <= -0.5 else int(x)

def _build_section(snmp_data):
    """Build section dict from parsed SNMP data"""
    # cmctc_lcp sensors map ( typeid -> (item_prefix, type_) )
    sensors_map = {
        "32": [None, "position"],
    }
    section = {}
    for tree, block in zip(["3", "4", "5", "6"], snmp_data):
        for entry in block:
            # Expected layout: [index, typeid, status, reading, high, low, warn, description]
            if len(entry) < 8:
                continue
            idx, typeid, status, reading, high, low, warn, desc = entry
            if typeid not in sensors_map:
                continue
            prefix, stype = sensors_map[typeid]
            item = prefix + " - " + tree + "." + idx if prefix else tree + "." + idx
            section[item] = {
                "status": status,
                "reading": float(reading),
                "high": float(high),
                "low": float(low),
                "warn": float(warn),
                "description": desc,
                "type_": stype,
            }
    return section

def _discover(section):
    out = []
    for item, sensor in section.items():
        if sensor["type_"] == "position":
            out.append({"item": item, "params": {}, "metrics": ["position"]})
    return out

def _check(item, params, section):
    # Checkmk default: no params (no user-defined thresholds for position)
    if item not in section:
        return {
            "changed": False,
            "msg": "item not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sensor = section[item]
    status_str = str(sensor["status"])
    desc_text = sensor["description"]
    reading = _round(sensor["reading"])
    status_info, status_code = [0, 0]
    if status_str in _MAP_STATUS:
        status_info = _MAP_STATUS[status_str][0]
        status_code = _MAP_STATUS[status_str][1]
    else:
        status_info = "UNKNOWN"
        status_code = 3

    # Build infotext with description
    infotext = ""
    if desc_text:
        infotext = "[" + desc_text + "] "

    # Primary result: state and reading
    summary = infotext + str(reading)

    # Secondary result: extra info for status and levels
    extra_info = ""
    extra_state = 0
    if status_code != 0:
        extra_state = status_code
        extra_info = status_info

    state = "CRIT" if extra_state == 2 else ("WARN" if extra_state == 1 else "OK")
    return {
        "changed": False,
        "msg": summary + (" (" + extra_info + ")" if extra_info else ""),
        "data": {
            "state": state,
            "metrics": {"position": reading},
            "details": extra_info,
        },
    }

def main(ctx, params):
    if params.get("_discover"):
        # Gather data via snmpwalk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2606.4.2"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed",
                "data": {"discovery": []}
            }
        # Parse into per-tree blocks (4 trees: 3,4,5,6)
        lines = res.stdout.splitlines()
        trees = ["3", "4", "5", "6"]
        tree_blocks = {"3": [], "4": [], "5": [], "6": []}
        current_tree = None
        for line in lines:
            if "=" not in line:
                continue
            oid_part, val_part = line.rstrip().rsplit("=", 1)
            # Extract tree from OID prefix
            oid_tokens = oid_part.strip().split(".")
            if len(oid_tokens) < 1:
                continue
            base_oid = ".".join(oid_tokens[:-1])
            tree = None
            for t in trees:
                if base_oid.startswith(".1.3.6.1.4.1.2606.4.2." + t):
                    tree = t
                    break
            if not tree:
                continue
            # Parse value line (TYPE: value, ...)
            parts = val_part.strip().split()
            if len(parts) < 2:
                continue
            val = parts[1].strip()
            # Extract index from OID
            index = oid_tokens[-1]
            tree_blocks[tree].append([index, val])

        # Group into full rows (8 columns) per tree
        # Each row is: index, typeid, status, reading, high, low, warn, description
        # snmpwalk gives interleaved OIDs; we need to group by index
        # Map OID suffix to list of (oid_idx, value)
        oid_map = {}
        for tree in trees:
            for entry in tree_blocks[tree]:
                idx, val = entry
                key = tree + "." + idx
                oid_map.setdefault(key, []).append(val)

        # Reconstruct rows: for each key, get 8 values in order
        snmp_data = []
        for tree in trees:
            block = []
            for key, values in sorted(oid_map.items()):
                if not key.startswith(tree + "."):
                    continue
                # We need 8 values per entry
                if len(values) == 8:
                    block.append(values)
            if block:
                snmp_data.append(block)

        section = _build_section(snmp_data)
        discovery = _discover(section)
        return {
            "changed": False,
            "msg": "discovered " + str(len(discovery)) + " items",
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    # Gather data same as discovery (no caching in Starlark)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2606.4.2"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    lines = res.stdout.splitlines()
    tree_blocks = {"3": [], "4": [], "5": [], "6": []}
    for line in lines:
        if "=" not in line:
            continue
        oid_part, val_part = line.rstrip().rsplit("=", 1)
        oid_tokens = oid_part.strip().split(".")
        if len(oid_tokens) < 1:
            continue
        base_oid = ".".join(oid_tokens[:-1])
        tree = None
        for t in ["3", "4", "5", "6"]:
            if base_oid.startswith(".1.3.6.1.4.1.2606.4.2." + t):
                tree = t
                break
        if not tree:
            continue
        parts = val_part.strip().split()
        if len(parts) < 2:
            continue
        val = parts[1].strip()
        index = oid_tokens[-1]
        tree_blocks[tree].append([index, val])

    # Group into rows (same logic as discovery)
    oid_map = {}
    for tree in ["3", "4", "5", "6"]:
        for entry in tree_blocks[tree]:
            idx, val = entry
            key = tree + "." + idx
            oid_map.setdefault(key, []).append(val)

    snmp_data = []
    for tree in ["3", "4", "5", "6"]:
        block = []
        for key, values in sorted(oid_map.items()):
            if not key.startswith(tree + "."):
                continue
            if len(values) == 8:
                block.append(values)
        if block:
            snmp_data.append(block)

    section = _build_section(snmp_data)
    return _check(item, params, section)
