DEVICE_TYPE_MAP = {
    "1": "Power",
    "2": "Cooling",
    "3": "Control",
    "4": "Connectivity",
    "5": "Robotics",
    "6": "Media",
    "7": "Drive",
    "8": "Operator action request",
}

RAS_STATUS_MAP = {
    "1": ("OK", "good"),
    "2": ("CRIT", "failed"),
    "3": ("CRIT", "degraded"),
    "4": ("WARN", "warning"),
    "5": ("OK", "informational"),
    "6": ("UNKNOWN", "unknown"),
    "7": ("UNKNOWN", "invalid"),
}

OPNEED_STATUS_MAP = {
    "0": ("OK", "no"),
    "1": ("CRIT", "yes"),
    "2": ("OK", "no"),
}

# OID bases from the two SNMPTree fetches
OIDEND_TREE_1 = ".1.3.6.1.4.1.3697.1.10.10.1.15"
OIDEND_TREE_2 = ".1.3.6.1.4.1.3764.1.10.10"

# Sysoid prefix for Quantum small library detection
SYSOID_PREFIX = ".1.3.6.1.4.1.8072.3.2.10"
QUANTUM_PRODUCT_OID = ".1.3.6.1.4.1.3697.1.10.10.1.10.0"

def _walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1]))
    return rows

def _get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _fetch_section(ctx, host, community, base_oid, value_col):
    """Walk the OIDEnd column of a tree; return list of (dev_type_suffix, state)."""
    rows = _walk(ctx, host, community, base_oid)
    results = []
    for oid, value in rows:
        # The index is the OID suffix after the column base.
        # The OIDEnd() OID is the base itself with the index appended.
        if not oid.startswith(base_oid):
            continue
        index = oid[len(base_oid) + 1:]
        results.append((index, value))
    return results

def main(ctx, params):
    discover = bool(params.get("_discover"))
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- Discovery gate: only proceed if this is a Quantum Small Library ---
    # Check sysObjectId starts with the vendor subtree
    sysoid = _get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysoid == "" or not sysoid.startswith(SYSOID_PREFIX):
        return {"changed": False, "msg": "not a Quantum small library", "data": {"discovery": [], "host_labels": {}}} if discover else {"changed": False, "msg": "not a Quantum small library", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Check product string
    product = _get(ctx, host, community, QUANTUM_PRODUCT_OID)
    if product == "" or "Quantum Small Library Product" not in product:
        return {"changed": False, "msg": "not a Quantum small library", "data": {"discovery": [], "host_labels": {}}} if discover else {"changed": False, "msg": "not a Quantum small library", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # --- Fetch the two SNMP tables (OIDEnd + state value) ---
    table1 = _fetch_section(ctx, host, community, OIDEND_TREE_1, "10")
    table2 = _fetch_section(ctx, host, community, OIDEND_TREE_2, "12")

    # Combine: each row is (oidend_index, dev_state)
    # The OIDEnd is the first OID in each SNMPTree, so the walked OID IS the OIDEnd
    # and the value is the second column (10 or 12) — but snmpwalk returns the
    # OIDEnd OID with its value. We need to fetch the state column too.
    parsed = []

    for index, value in table1 + table2:
        dev_type = DEVICE_TYPE_MAP.get(index.split(".")[0]) if index else None
        if dev_type == None or not value:
            continue
        parsed.append((dev_type, value))

    if discover:
        if parsed:
            return {
                "changed": False,
                "msg": "discovered tape library status",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ],
                    "host_labels": {"cmk/os_family": "snmp"},
                },
            }
        return {"changed": False, "msg": "no library components found", "data": {"discovery": []}}

    # --- Check mode ---
    if not parsed:
        return {"changed": False, "msg": "no library components found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summaries = []
    worst_state = "OK"
    for dev_type, dev_state in parsed:
        if dev_type == "Operator action request":
            mapped = OPNEED_STATUS_MAP.get(dev_state)
        else:
            mapped = RAS_STATUS_MAP.get(dev_state)
        if mapped == None:
            state, readable = "UNKNOWN", "unknown[%s]" % dev_state
        else:
            state, readable = mapped
        summaries.append("%s: %s" % (dev_type, readable))
        if state == "CRIT":
            worst_state = "CRIT"
        elif state == "WARN" and worst_state != "CRIT":
            worst_state = "WARN"
        elif state == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"

    msg = "; ".join(summaries)
    return {"changed": False, "msg": msg, "data": {"state": worst_state, "metrics": {}, "details": ""}}