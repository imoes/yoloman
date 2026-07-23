ACTION_MAPPING = {
    "0": ("Invalid action", "UNKNOWN"),
    "1": ("Action done", "OK"),
    "2": ("Out of service", "WARN"),
    "3": ("Back to service", "OK"),
    "4": ("Not applicable", "OK"),
}

STATUS_MAPPING = {
    "0": ("Invalid status", "UNKNOWN"),
    "1": ("Module doesn't exist", "OK"),
    "2": ("Module exists and ok", "OK"),
    "3": ("Module Ouf of service", "CRIT"),
    "4": ("Module Back to service start", "OK"),
    "5": ("Module mismatch", "CRIT"),
    "6": ("Module faulty", "CRIT"),
    "7": ("Not applicable", "OK"),
}


def _parse_module_fru(lines):
    data = {}
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 3:
            continue
        item = parts[0]
        action_idx = parts[1]
        status_idx = parts[2]
        action_name, action_state = ACTION_MAPPING.get(action_idx, ("Unknown action", "UNKNOWN"))
        status_name, status_state = STATUS_MAPPING.get(status_idx, ("Unknown status", "UNKNOWN"))
        data[item] = {"action": {"name": action_name, "state": action_state},
                      "status": {"name": status_name, "state": status_state}}
    return data


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse snmpwalk output: "<OID>.<end> = INTEGER: <value>"
        # We need to collect 3 OIDs per module:
        #   .1.3.6.1.4.1.5003.9.10.10.4.21.1.<end>.13 -> acSysModuleFRUaction
        #   .1.3.6.1.4.1.5003.9.10.10.4.21.1.<end>.14 -> acSysModuleFRUstatus
        #   The item itself is the OID end

        # First, gather all OID values
        oid_data = {}  # item -> {"13": action_val, "14": status_val}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Example: ".1.3.6.1.4.1.5003.9.10.10.4.21.1.1.13 = INTEGER: 1"
            if ".13 = INTEGER:" in line or ".14 = INTEGER:" in line:
                parts = line.split()
                if len(parts) < 5:
                    continue
                full_oid = parts[0].rstrip("=")
                value = parts[-1]
                # Extract item: part before .13 or .14
                base = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
                if full_oid.startswith(base + "."):
                    suffix = full_oid[len(base) + 1:]
                    if "." in suffix:
                        parts2 = suffix.split(".")
                        if len(parts2) >= 2:
                            item = parts2[0]
                            oid_type = parts2[-1]  # "13" or "14"
                            if item not in oid_data:
                                oid_data[item] = {}
                            oid_data[item][oid_type] = value

        # Now build discovery items
        items = []
        for item in sorted(oid_data.keys()):
            if "13" in oid_data[item] and "14" in oid_data[item]:
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d FRU modules" % len(items),
            "data": {"discovery": items}
        }

    # CHECK MODE
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.10.4.21.1." + item
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP fetch failed for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse for this specific item
    action_val = None
    status_val = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Look for .13 or .14 specifically for this item
        if ".13 = INTEGER:" in line:
            parts = line.split()
            if len(parts) >= 5:
                action_val = parts[-1]
        elif ".14 = INTEGER:" in line:
            parts = line.split()
            if len(parts) >= 5:
                status_val = parts[-1]

    if action_val == None or status_val == None:
        return {
            "changed": False,
            "msg": "missing data for FRU module " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    action_name, action_state = ACTION_MAPPING.get(action_val, ("Unknown action", "UNKNOWN"))
    status_name, status_state = STATUS_MAPPING.get(status_val, ("Unknown status", "UNKNOWN"))

    # Determine overall state (worst of action and status)
    overall_state = "OK"
    for s in [action_state, status_state]:
        if s == "CRIT":
            overall_state = "CRIT"
            break
        elif s == "WARN" and overall_state != "CRIT":
            overall_state = "WARN"
        elif s == "UNKNOWN" and overall_state == "OK":
            overall_state = "UNKNOWN"

    # Checkmk-style message: combine action and status summaries
    msg = "Action: " + action_name + ", Status: " + status_name

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {},
            "details": ""
        }
    }
