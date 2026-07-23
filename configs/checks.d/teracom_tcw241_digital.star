def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode: enumerate sensors 1-4
    if params.get("_discover"):
        # Fetch descriptions (base .1.3.6.1.4.1.38783.3.2.2.3, oids 1.0..4.0)
        res_desc = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.38783.3.2.2.3.1.0",
            ".1.3.6.1.4.1.38783.3.2.2.3.2.0",
            ".1.3.6.1.4.1.38783.3.2.2.3.3.0",
            ".1.3.6.1.4.1.38783.3.2.2.3.4.0"
        ], mutates=False)
        # Fetch states (base .1.3.6.1.4.1.38783.3.3.3, oids 1.0..4.0)
        res_state = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.38783.3.3.3.1.0",
            ".1.3.6.1.4.1.38783.3.3.3.2.0",
            ".1.3.6.1.4.1.38783.3.3.3.3.0",
            ".1.3.6.1.4.1.38783.3.3.3.4.0"
        ], mutates=False)

        if res_desc.rc != 0 or res_state.rc != 0:
            return {"changed": False, "msg": "SNMP probe failed"}

        # Parse snmpwalk output: each line format: "OID = STRING: value" or "OID = INTEGER: value"
        def parse_snmp_lines(res):
            out = []
            for line in res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                value_str = parts[1].strip()
                # Extract value after colon if present (for STRING/INTEGER prefixes)
                if ": " in value_str:
                    v = value_str.split(": ", 1)[1].strip().strip('"')
                else:
                    v = value_str.strip().strip('"')
                out.append(v)
            return out

        descriptions = parse_snmp_lines(res_desc)
        states = parse_snmp_lines(res_state)

        items = []
        for i in range(min(len(descriptions), len(states), 4)):
            idx = str(i + 1)
            desc = descriptions[i] if i < len(descriptions) else ""
            state_raw = states[i] if i < len(states) else ""
            sensor_state = "open" if state_raw == "1" else "closed"
            items.append({
                "item": idx,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d digital sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: validate the given item
    item = params.get("item", "")
    if not item.isdigit() or int(item) < 1 or int(item) > 4:
        return {
            "changed": False,
            "msg": "invalid sensor number: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch both OID trees for all sensors
    res_desc = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.38783.3.2.2.3.1.0",
        ".1.3.6.1.4.1.38783.3.2.2.3.2.0",
        ".1.3.6.1.4.1.38783.3.2.2.3.3.0",
        ".1.3.6.1.4.1.38783.3.2.2.3.4.0"
    ], mutates=False)
    res_state = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.38783.3.3.3.1.0",
        ".1.3.6.1.4.1.38783.3.3.3.2.0",
        ".1.3.6.1.4.1.38783.3.3.3.3.0",
        ".1.3.6.1.4.1.38783.3.3.3.4.0"
    ], mutates=False)

    if res_desc.rc != 0 or res_state.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP probe failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse lines
    descriptions = []
    states = []

    def parse_snmp_lines(res):
        out = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            value_str = parts[1].strip()
            if ": " in value_str:
                v = value_str.split(": ", 1)[1].strip().strip('"')
            else:
                v = value_str.strip().strip('"')
            out.append(v)
        return out

    descriptions = parse_snmp_lines(res_desc)
    states = parse_snmp_lines(res_state)

    idx = int(item) - 1
    if idx >= len(descriptions) or idx >= len(states):
        return {
            "changed": False,
            "msg": "sensor " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    desc = descriptions[idx] if idx < len(descriptions) else ""
    state_raw = states[idx] if idx < len(states) else ""
    state = "open" if state_raw == "1" else "closed"

    # Determine state: OK if open, CRIT if closed
    if state == "open":
        verdict = "OK"
    else:
        verdict = "CRIT"

    summary = "[{}] is {}".format(desc, state)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": verdict,
            "metrics": {},
            "details": ""
        }
    }