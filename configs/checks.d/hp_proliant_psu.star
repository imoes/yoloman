# Module-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.232.6.2.9.3.1"
SNMP_OIDS = ["1", "2", "3", "4", "7", "8"]
CONDITION_MAP = {
    "1": ("UNKNOWN", 'State: "other"'),
    "2": ("OK", 'State: "ok"'),
    "3": ("CRIT", 'State: "degraded"'),
    "4": ("CRIT", 'State: "failed"'),
}

def _snmpwalk(ctx, community, host):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        SNMP_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout

def _parse_snmp_output(stdout, params):
    """Parse SNMP output and return items with PSU data."""
    entries = {}  # index -> {"1": chassis, "2": bay, "3": present, "4": condition, "7": used, "8": max_}

    for line in stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split(" = STRING: ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip().strip('"')
        if value == "":
            continue

        # Extract index after base OID
        suffix = oid[len(SNMP_BASE_OID):].lstrip(".")
        if not suffix.isdigit():
            continue
        index = int(suffix)
        if index not in entries:
            entries[index] = {}
        entries[index][suffix] = value

    # Now build items
    items = []
    total_used = 0
    total_max = 0
    count = 0

    for idx, entry in entries.items():
        chassis = entry.get("1", "")
        bay = entry.get("2", "")
        present = entry.get("3", "")
        cond = entry.get("4", "")
        used_str = entry.get("7", "0")
        max_str = entry.get("8", "0")

        # Guard against non-integer values instead of try/except
        used = int(used_str) if used_str.isdigit() else 0
        max_ = int(max_str) if max_str.isdigit() else 0

        # Skip if not present (3) or max is 0
        if present != "3" or max_ == 0:
            continue

        item_name = "%s/%s" % (chassis, bay)
        items.append({
            "item": item_name,
            "chassis": chassis,
            "bay": bay,
            "condition": cond,
            "used": used,
            "max_": max_
        })
        total_used += used
        total_max += max_
        count += 1

    # Add total item
    if count > 0:
        items.append({
            "item": "Total",
            "chassis": "",
            "bay": "",
            "condition": "",
            "used": total_used,
            "max_": total_max
        })

    return items

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        stdout = _snmpwalk(ctx, community, host)
        if stdout == None:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        items = _parse_snmp_output(stdout, params)
        discovery = []
        for item in items:
            discovery.append({
                "item": item["item"],
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["power_usage", "power_usage_percentage"]
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    stdout = _snmpwalk(ctx, community, host)
    if stdout == None:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    items = _parse_snmp_output(stdout, params)

    # Find the requested item
    found_item = None
    for entry in items:
        if entry["item"] == item:
            found_item = entry
            break

    if found_item == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Process item
    psu = found_item
    state = "OK"
    summary_parts = []

    if item != "Total":
        # chassis/bay item
        summary_parts.append("Chassis %s/Bay %s" % (psu["chassis"], psu["bay"]))
        cond = psu["condition"]
        if cond in CONDITION_MAP:
            cond_state, cond_msg = CONDITION_MAP[cond]
            state = cond_state
            summary_parts.append(cond_msg)
        else:
            summary_parts.append("State: unknown (%s)" % cond)

    summary_parts.append("Usage: %d/%d Watts" % (psu["used"], psu["max_"]))

    # Calculate percentage
    used = float(psu["used"])
    max_ = float(psu["max_"])
    percent = used * 100.0 / max_ if max_ != 0 else 0.0

    # Apply thresholds
    warn, crit = params.get("levels", (80.0, 90.0))
    if percent >= crit:
        state = "CRIT"
    elif percent >= warn:
        if state == "OK":
            state = "WARN"

    metrics = {
        "power_usage": int(used),
        "power_usage_percentage": int(percent) if percent == float(int(percent)) else percent
    }

    summary = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }