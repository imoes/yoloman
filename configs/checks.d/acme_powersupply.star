def main(ctx, params):
    # Discovery mode: enumerate power supplies via SNMP
    if params.get("_discover"):
        # Walk description OID to get item names and indices
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.9148.3.3.1.5.1.1.3"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk on description OID failed: " + res.stderr)

        # Parse description OIDs: extract index and description
        section = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            if "STRING:" in parts[2]:
                oid_full = parts[0]
                idx = oid_full.rsplit(".", 1)[-1]
                descr = " ".join(parts[3:]).strip('"')
                section[descr] = idx

        # Walk state OID to get states for each index
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.9148.3.3.1.5.1.1.4"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk on state OID failed: " + res.stderr)

        state_by_idx = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            oid_full = parts[0]
            if ".1.3.6.1.4.1.9148.3.3.1.5.1.1.4." in oid_full:
                idx = oid_full.rsplit(".", 1)[-1]
                state_val = parts[-1].strip()
                if state_val.startswith("INTEGER:"):
                    state_val = state_val.split(":")[1].strip()
                state_by_idx[idx] = state_val

        # Combine description -> state
        final_section = {}
        for descr, idx in section.items():
            state = state_by_idx.get(idx)
            if state == None:
                continue
            final_section[descr] = state

        # Discovery: exclude state "7" (not present)
        out = []
        for descr, state in final_section.items():
            if state != "7":
                out.append({"item": descr, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d power supplies" % len(out),
                "data": {"discovery": out}}

    # Check mode: verify one power supply item
    item = params.get("item", "")
    # Re-fetch section for the specific item
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9148.3.3.1.5.1.1.3"
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk on description OID failed: " + res.stderr)

    section = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        if "STRING:" in parts[2]:
            oid_full = parts[0]
            idx = oid_full.rsplit(".", 1)[-1]
            descr = " ".join(parts[3:]).strip('"')
            section[descr] = idx

    # Check if item exists
    idx = section.get(item)
    if idx == None:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch state for this index
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9148.3.3.1.5.1.1.4"
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk on state OID failed: " + res.stderr)

    state_val = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        oid_full = parts[0]
        if ".1.3.6.1.4.1.9148.3.3.1.5.1.1.4." in oid_full:
            found_idx = oid_full.rsplit(".", 1)[-1]
            if found_idx == idx:
                state_val = parts[-1].strip()
                if state_val.startswith("INTEGER:"):
                    state_val = state_val.split(":")[1].strip()
                break

    if state_val == None:
        return {"changed": False, "msg": "state not found for power supply: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map state to Checkmk state
    ACME_ENVIRONMENT_STATES = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown"),
    }

    dev_state_str, dev_state_readable = ACME_ENVIRONMENT_STATES.get(
        state_val, ("CRIT", "unknown")
    )
    state = dev_state_str
    return {"changed": False, "msg": "Status: %s" % dev_state_readable,
            "data": {"state": state, "metrics": {}, "details": ""}}
