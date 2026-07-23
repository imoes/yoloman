def main(ctx, params):
    # Determine mode: discovery vs check
    if params.get("_discover"):
        # Discovery: run SNMP query to gather NTLS section data
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.12383.3.1.2"
        ], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse snmpwalk output into section dict
        section = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full, value_raw = parts
            # Extract last OID component (e.g., .1.3.6.1.4.1.12383.3.1.2.1 -> 1)
            oid_idx = oid_full.rsplit(".", 1)[-1]
            value = value_raw.strip()
            # Convert numeric fields to int where appropriate
            if oid_idx in ["2", "3", "4", "5"]:
                section[oid_idx] = int(value) if value.isdigit() else 0
            else:
                section[oid_idx] = value

        # If section not populated, no data found
        if not section:
            return {"changed": False, "msg": "no NTLS data found", "data": {"discovery": []}}

        # Discovery yields services for successful/failed connection rate
        discovery = [
            {"item": "successful", "params": {}, "metrics": ["connections_rate"]},
            {"item": "failed", "params": {}, "metrics": ["connections_rate"]}
        ]
        return {"changed": False, "msg": "discovered 2 items", "data": {"discovery": discovery}}

    # Check mode: handle one item
    item = params.get("item", "")
    if item != "successful" and item != "failed":
        return {"changed": False, "msg": "unsupported item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Run SNMP query to gather fresh NTLS data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.12383.3.1.2"
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpwalk output into section dict (same as discovery)
    section = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full, value_raw = parts
        oid_idx = oid_full.rsplit(".", 1)[-1]
        value = value_raw.strip()
        if oid_idx in ["2", "3", "4", "5"]:
            section[oid_idx] = int(value) if value.isdigit() else 0
        else:
            section[oid_idx] = value

    # If section not populated, item not found
    if not section:
        return {"changed": False, "msg": "no NTLS data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map item to data field
    if item == "successful":
        value = section.get("4", 0)
    else:  # failed
        value = section.get("5", 0)

    # Simulate rate calculation: for Starlark, we use current value directly (no persisted rate store)
    # This mirrors the behavior when agent data is fresh and no time delta is applied.
    rate = float(value)

    # Since we cannot persist state between runs in Starlark, we report current value as rate
    # (a real-time rate would require state persistence across runs — not feasible here.
    #  In production, one would use agent caching or a more advanced mechanism.)
    summary = "%f connections/s" % rate
    state = "OK"
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"connections_rate": rate}, "details": ""}}