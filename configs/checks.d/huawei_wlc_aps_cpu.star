# Constants and mappings (module-level, as required)
_AP_STATE_MAP = {
    "1": {"label": "Idle", "state": "CRIT"},
    "2": {"label": "Auto find", "state": "WARN"},
    "3": {"label": "Type not match", "state": "CRIT"},
    "4": {"label": "Fault", "state": "CRIT"},
    "5": {"label": "Config", "state": "CRIT"},
    "6": {"label": "Config failed", "state": "CRIT"},
    "7": {"label": "Download", "state": "WARN"},
    "8": {"label": "Normal", "state": "OK"},
    "9": {"label": "Committing", "state": "CRIT"},
    "10": {"label": "Commit failed", "state": "CRIT"},
    "11": {"label": "Standy", "state": "WARN"},
    "12": {"label": "Version mismatch", "state": "CRIT"},
    "13": {"label": "Name conflicted", "state": "CRIT"},
    "14": {"label": "Invalid", "state": "CRIT"},
    "15": {"label": "Country code mismatch", "state": "CRIT"},
}
_AP_UNKNOWN_LABEL = "not available"
_AP_UNKNOWN_STATE = "UNKNOWN"

_RADIO_STATE_MAP = {"1": "up", "2": "down"}
_RADIO_UNKNOWN_STATE = "not available"


def _get_ap_state(status):
    entry = _AP_STATE_MAP.get(status)
    if entry == None:
        return _AP_UNKNOWN_STATE, _AP_UNKNOWN_LABEL
    return entry["state"], entry["label"]


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Detect device type via SNMP sysObjectID
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            fail("snmpget failed: " + res.stderr)
        oid = ""
        lines = res.stdout.splitlines()
        if len(lines) > 0:
            parts = lines[0].strip().split(" = ")
            if len(parts) >= 2:
                oid = parts[1].strip()
        if ".1.3.6.1.4.1.2011.2.240.17" not in oid:
            return {"changed": False, "msg": "device not a Huawei WLC (wrong sysObjectID)",
                    "data": {"discovery": []}}

        # Fetch AP section data via SNMP
        base1 = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
        base2 = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
        # We'll use snmpwalk to get all rows
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), base1 + ".6"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), base2 + ".3"], mutates=False)

        if res1.rc != 0 or res2.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse AP IDs from res2 walk output (we need them to pair with res1)
        ap_ids = []
        for line in res2.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            val = parts[1].strip()
            # OID value format: STRING: "<ap_id>" or Gauge32: <ap_id>
            # Strip quotes if present
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            ap_ids.append(val)

        # Build discovery list: one Service per AP (item is AP id)
        items = []
        for i in range(len(ap_ids)):
            ap_id = ap_ids[i]
            if ap_id == "" or ap_id == "0":
                continue
            items.append({"item": ap_id, "params": {"levels": [80.0, 90.0]},
                          "metrics": ["cpu_percent"]})

        return {"changed": False, "msg": "discovered %d APs" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch data via SNMP
    base1 = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
    base2 = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
    # Get AP status (idx 6) and CPU (idx 41) from first table
    # Get radio info from second table (idx 3 = apID, idx 41 = cpu is not there)
    # Instead: get .6 (apStatus) and .41 (cpu) from first tree, and pair by index

    # We'll fetch just the specific OIDs for this item
    # Since snmpwalk is easier to parse and we don't know index ahead, walk the relevant OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                   base1 + ".6"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed for apStatus",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ap_status_oid = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        if val_part.startswith('STRING:'):
            val = val_part[7:].strip().strip('"')
            if val == item:
                # Extract index from OID: base + ".6" + index suffix
                # OID format: .1.3.6.1.4.1.2011.6.139.13.3.3.1.6.<index>
                suffix = oid_part[len(base1 + ".6."):]
                ap_status_oid = suffix
                break

    if ap_status_oid == "":
        return {"changed": False, "msg": "AP not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Now fetch CPU percent for this index
    cpu_oid = base1 + ".41." + ap_status_oid
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, cpu_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpget failed for cpu",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_val = "0"
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        val_part = parts[1].strip()
        if val_part.startswith("INTEGER:"):
            cpu_val = val_part[8:].strip()
        elif val_part.startswith("Gauge32:"):
            cpu_val = val_part[8:].strip()

    # Guard for invalid cpu_val
    if cpu_val.isdigit() or (cpu_val.startswith("-") and cpu_val[1:].isdigit()):
        cpu_percent = float(cpu_val)
    else:
        return {"changed": False, "msg": "cpu value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch AP status for state summary
    status_oid = base1 + ".6." + ap_status_oid
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpget failed for status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_val = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        val_part = parts[1].strip()
        if val_part.startswith("INTEGER:"):
            status_val = val_part[8:].strip()
            break

    ap_state, ap_label = _get_ap_state(status_val)

    # Apply levels
    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0] if len(levels) >= 1 else 80.0
    crit = levels[1] if len(levels) >= 2 else 90.0

    state = "OK"
    if cpu_percent >= crit:
        state = "CRIT"
    elif cpu_percent >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "%s: %f%% (status: %s)" % (item, cpu_percent, ap_label),
            "data": {"state": state, "metrics": {"cpu_percent": cpu_percent}, "details": ""}}