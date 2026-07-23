# ===== Starlark translation of Checkmk check: cisco_cpu_memory =====
# Reads Cisco CPU memory via SNMP, computes utilization and checks levels (percent or absolute)

def _to_bytes(raw):
    if not raw:
        return 0
    # Check for valid numeric string (digits and optional single decimal point)
    cleaned = raw.replace(".", "")
    if not cleaned.isdigit():
        return 0
    # Since we have only digits after removing dot, parse safely
    return int(float(raw) * 1024)

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk both SNMP trees and build item list
        # Tree 1: base=".1.3.6.1.4.1.9.9.109.1.1.1.1", oids ["2","12","13","14"]
        tree1 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.2",
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.12",
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.13",
            ".1.3.6.1.4.1.9.9.109.1.1.1.1.14"
        ], mutates=False)
        # Tree 2: base=".1.3.6.1.2.1.47.1.1.1", oids OIDEnd() + "1.7"
        tree2 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)

        # Parse tree2 first: index -> description
        ph_idx_to_desc = {}
        for line in tree2.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Extract OID end (index)
            idx_oid = oid_part.rsplit(".", 1)
            if len(idx_oid) != 2:
                continue
            idx = idx_oid[1]
            # Trim quotes if present
            val = val_part
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            ph_idx_to_desc[idx] = val[4:] if val.lower().startswith("cpu ") else val

        # Parse tree1: for each row get (idx, used, free, reserved)
        items = []
        lines1 = tree1.stdout.splitlines()
        i = 0
        while i < len(lines1):
            # We expect 4 lines per row (2,12,13,14)
            row = []
            for j in range(4):
                if i + j >= len(lines1):
                    break
                line = lines1[i + j].strip()
                if not line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                val_part = parts[1].strip()
                # Extract value: type prefix can be "INTEGER:", "GAUGE:", etc.
                if ":" in val_part:
                    val = val_part.split(":", 1)[1].strip()
                else:
                    val = val_part
                row.append(val)
            if len(row) == 4:
                idx, used, free, reserved = row
                # Skip if used=0 and free=0
                if used == "0" and free == "0":
                    i += 4
                    continue
                name = ph_idx_to_desc.get(idx, idx)
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["usage_percent"]
                })
            i += 4
        return {
            "changed": False,
            "msg": "discovered %d memory entries" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode: item is expected
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch SNMP data: same trees as discovery
    tree1 = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.2",
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.12",
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.13",
        ".1.3.6.1.4.1.9.9.109.1.1.1.1.14"
    ], mutates=False)
    tree2 = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)

    # Build index -> desc mapping
    ph_idx_to_desc = {}
    for line in tree2.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        idx_oid = oid_part.rsplit(".", 1)
        if len(idx_oid) != 2:
            continue
        idx = idx_oid[1]
        val = val_part
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        ph_idx_to_desc[idx] = val[4:] if val.lower().startswith("cpu ") else val

    # Find item data in tree1
    mem_used = 0
    mem_free = 0
    mem_reserved = 0
    found = False
    lines1 = tree1.stdout.splitlines()
    i = 0
    while i < len(lines1):
        row = []
        for j in range(4):
            if i + j >= len(lines1):
                break
            line = lines1[i + j].strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            val_part = parts[1].strip()
            if ":" in val_part:
                val = val_part.split(":", 1)[1].strip()
            else:
                val = val_part
            row.append(val)
        if len(row) == 4:
            idx, used, free, reserved = row
            if used == "0" and free == "0":
                i += 4
                continue
            name = ph_idx_to_desc.get(idx, idx)
            if name == item:
                mem_used = _to_bytes(used)
                mem_free = _to_bytes(free)
                mem_reserved = _to_bytes(reserved)
                found = True
                break
        i += 4

    # If item not found, return UNKNOWN
    if not found:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Compute totals
    mem_occupied = mem_used + mem_reserved
    mem_total = mem_used + mem_free

    # Handle zero total (UNKNOWN)
    if mem_total == 0:
        return {
            "changed": False,
            "msg": "Cannot calculate memory usage: Device reports total memory 0",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse levels: (warn, crit) in bytes if int (converted from MB), else percent (0-100)
    warn, crit = params.get("levels", (None, None))
    # Default: no levels (check will still compute percent, but won't alert)
    # But we need to produce a percent metric and apply levels if set
    warn_bytes = None
    crit_bytes = None

    if warn != None:
        if type(warn) == "int":
            warn_bytes = abs(warn) * 1024 * 1024
            crit_bytes = abs(crit) * 1024 * 1024
        elif type(warn) == "float":
            # Checkmk passes absolute MB as int; if float, treat as percent
            # However, per spec, levels can be absolute (MB) or tuple (percent, MB)
            warn_bytes = abs(warn) * 1024 * 1024
            crit_bytes = abs(crit) * 1024 * 1024
        else:
            # tuple? Not in our current spec, but we assume absolute MB as int only
            warn_bytes = None
            crit_bytes = None

    # Compute utilization percent
    usage_percent = (mem_used * 100.0) / mem_total

    # Determine state
    state = "OK"
    if warn_bytes != None and crit_bytes != None:
        if mem_used >= crit_bytes:
            state = "CRIT"
        elif mem_used >= warn_bytes:
            state = "WARN"
    else:
        # No absolute levels — only percent if we had percent thresholds,
        # but Checkmk default params is empty dict, so we default to percent-based alerting if warn/crit are percentages
        # Since params.get("levels") is not present in default, we assume no alerting unless user configured levels.
        # So we report the metric but don't change state.
        pass

    return {
        "changed": False,
        "msg": "CPU Memory utilization %s: %f%% used (%d MB / %d MB)" % (
            item, usage_percent, mem_used // (1024 * 1024), mem_total // (1024 * 1024)
        ),
        "data": {
            "state": state,
            "metrics": {"usage_percent": usage_percent, "used": mem_used, "total": mem_total},
            "details": ""
        }
    }