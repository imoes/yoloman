# Module constants — status mapping
STATUS_MAP = {
    "1": ("OK", "on"),
    "2": ("WARN", "off"),
}

def main(ctx, params):
    if params.get("_discover"):
        # SNMP discovery: walk the base OID for apc_powerswitch
        base_oid = ".1.3.6.1.4.1.318.1.1.12.3.5.1.1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid,
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse lines: ".1.3.6.1.4.1.318.1.1.12.3.5.1.1.1.1 = INTEGER: 1"
        items = []
        lines = res.stdout.splitlines()
        # Build mapping: index -> (name, status)
        index_to_name = {}
        index_to_status = {}

        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_str, value_str = parts
            # Extract last OID component and value
            oid_parts = oid_str.rsplit(".", 1)
            if len(oid_parts) != 2:
                continue
            idx_oid_part = oid_parts[1]  # e.g., "1.1", "1.2", "1.4"
            # Map to index: only .1, .2, .4 matter — we use the base OID's last component as index
            # The section parses .1.3.6.1.4.1.318.1.1.12.3.5.1.1 + idx (like .1.1, .1.2, .1.4)
            # So the index is the common part after the base: use the last component of idx_oid_part
            # For simplicity: extract the last segment as index (e.g., "1" for .1.1)
            last_seg = idx_oid_part.rsplit(".", 1)[-1]
            if not last_seg.isdigit():
                continue
            # We need to separate .1 (index), .2 (name), .4 (status)
            base_idx = oid_parts[0].rsplit(".", 1)[-1] if "." in oid_parts[0] else "1"
            if oid_str.endswith(".1." + last_seg):
                index_to_name[last_seg] = value_str.split(": ", 1)[-1].strip()
            elif oid_str.endswith(".2." + last_seg):
                index_to_status[last_seg] = value_str.split(": ", 1)[-1].strip()

        # Collect items with status == "1"
        out = []
        for idx in index_to_status:
            if index_to_status.get(idx) == "1" and idx in index_to_name:
                out.append({
                    "item": idx,
                    "params": {"discovered_status": "1"},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d outlets" % len(out),
            "data": {"discovery": out}
        }

    # Normal check mode
    item = params.get("item", "")
    if item == None:
        item = ""

    # Reuse the same SNMP walk as in discovery
    base_oid = ".1.3.6.1.4.1.318.1.1.12.3.5.1.1"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid,
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse again to get specific item's status and name
    name = ""
    status = ""
    lines = res.stdout.splitlines()
    # Build mapping per index
    index_to_name = {}
    index_to_status = {}

    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_str, value_str = parts
        # Extract the index (last segment after base OID)
        # OID: base + ".1.<index>" or ".2.<index>" or ".4.<index>"
        if oid_str.startswith(base_oid + ".1."):
            idx = oid_str[len(base_oid) + 3:]  # e.g., "1"
            index_to_name[idx] = value_str.split(": ", 1)[-1].strip()
        elif oid_str.startswith(base_oid + ".2."):
            idx = oid_str[len(base_oid) + 3:]
            index_to_status[idx] = value_str.split(": ", 1)[-1].strip()

    # Find the specific item
    if item in index_to_status:
        status = index_to_status[item]
    else:
        return {
            "changed": False,
            "msg": "outlet not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if item in index_to_name:
        name = index_to_name[item]

    # Map status to state
    state_info = STATUS_MAP.get(status, ("UNKNOWN", "unknown (%s)" % status if status else "unknown"))
    state_str, state_readable = state_info

    return {
        "changed": False,
        "msg": "Port %s has status %s" % (name, state_readable),
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }
