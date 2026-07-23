JUNIPER_BASE_OID = ".1.3.6.1.4.1.2636.3.1.13.1"
JUNIPER_DESCR_OID = JUNIPER_BASE_OID + ".5.9"
JUNIPER_BUFFER_OID = JUNIPER_BASE_OID + ".11.9"
JUNIPER_SYSOID = ".1.3.6.1.2.1.1.2.0"
JUNIPER_SYSOID_PREFIX = ".1.3.6.1.4.1.2636.1.1.1"

def _extract_number(s):
    # Extract first numeric value from string (no try/except allowed)
    stripped = s.strip()
    tokens = stripped.split()
    for token in tokens:
        clean = token.rstrip(" %")
        # Check if numeric (integer or float)
        has_dot = clean.find(".") >= 0
        if clean.replace(".", "").isdigit() and (not has_dot or clean.count(".") == 1):
            # Only convert if it's a valid number
            return float(clean)
    return None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), JUNIPER_BUFFER_OID
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            # OID format: .1.3.6.1.4.1.2636.3.1.13.1.11.9.<index>.0.0
            oid_tokens = oid_part.strip().split(".")
            if len(oid_tokens) < 9:
                continue
            idx = oid_tokens[-3]
            if idx.isdigit():
                # Validate routing engine exists by checking descr OID
                descr_oid = "%s.%s.0.0" % (JUNIPER_DESCR_OID, idx)
                descr_res = ctx.run([
                    "snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-On", params.get("host", "localhost"), descr_oid
                ], mutates=False)
                if descr_res.rc == 0 and "=" in descr_res.stdout:
                    items.append({
                        "item": idx,
                        "params": {"levels": (80.0, 90.0)},
                        "metrics": ["mem_used_percent"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d routing engines" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    buffer_oid = "%s.%s.0.0" % (JUNIPER_BUFFER_OID, item)
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), buffer_oid
    ], mutates=False)

    if res.rc != 0 or "=" not in res.stdout:
        return {
            "changed": False,
            "msg": "routing engine %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse value: "OID = INTEGER: <value>" or "OID = gauge32: <value>"
    line = res.stdout.strip()
    val_part = line.split(" = ", 1)[-1] if " = " in line else ""
    val_str = val_part.split(": ", 1)[-1] if ": " in val_part else val_part

    val = _extract_number(val_str)
    if val == None:
        return {
            "changed": False,
            "msg": "could not parse memory value from routing engine %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Handle levels parameter
    warn_val = 80.0
    crit_val = 90.0
    levels = params.get("levels")
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn_val = float(levels[0])
        crit_val = float(levels[1])

    if val >= crit_val:
        state = "CRIT"
    elif val >= warn_val:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Used: %f%%" % val,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": val},
            "details": ""
        }
    }