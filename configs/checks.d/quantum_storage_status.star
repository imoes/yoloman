def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: check if this is a Quantum storage device
        # by fetching the qVendorID OID (base + "4.0")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.4.1.2036.2.1.1.4.0"],
            mutates=False,
        )
        if res.rc != 0:
            # Not a Quantum device or SNMP not available - empty discovery
            return {"changed": False, "msg": "discovered 0 Quantum storage devices",
                    "data": {"discovery": []}}
        # Single-service check: one item with empty name
        map_states = params.get("map_states", {
            "unavailable": 2,
            "available": 0,
            "online": 0,
            "offline": 2,
            "going online": 1,
            "state not available": 3,
        })
        return {"changed": False, "msg": "discovered 1 Quantum storage device",
                "data": {"discovery": [
                    {"item": "", "params": {"map_states": map_states},
                     "metrics": []},
                ]}}

    # Check mode - fetch the storage info via SNMP
    base_oid = ".1.3.6.1.4.1.2036.2.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch all required OIDs: qVendorID(4), qProdId(5), qProdRev(6), qState(7), qSerialNumber(12)
    vendor_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".4.0"],
        mutates=False,
    )
    if vendor_res.rc != 0:
        return {"changed": False,
                "msg": "no Quantum storage device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    prod_res = ctx.run(
        ["snnpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".5.0"],
        mutates=False,
    )
    rev_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".6.0"],
        mutates=False,
    )
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".7.0"],
        mutates=False,
    )
    serial_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".12.0"],
        mutates=False,
    )

    if state_res.rc != 0:
        return {"changed": False, "msg": "failed to fetch Quantum storage state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_val = state_res.stdout.strip()

    _QUANTUM_DEVICE_STATE = {
        "1": "Unavailable",
        "2": "Available",
        "3": "Online",
        "4": "Offline",
        "5": "Going online",
        "6": "State not available",
    }

    state_txt = _QUANTUM_DEVICE_STATE.get(state_val, "Unknown [%s]" % state_val)

    map_states = params.get("map_states", {
        "unavailable": 2,
        "available": 0,
        "online": 0,
        "offline": 2,
        "going online": 1,
        "state not available": 3,
    })

    state_num = map_states.get(state_txt, 3)

    # Map State numbers to Checkmk states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    if state_num == 0:
        verdict = "OK"
    elif state_num == 1:
        verdict = "WARN"
    elif state_num == 2:
        verdict = "CRIT"
    else:
        verdict = "UNKNOWN"

    details = "Manufacturer: %s\nProduct: %s\nRevision: %s\nSerial: %s" % (
        vendor_res.stdout.strip(),
        prod_res.stdout.strip(),
        rev_res.stdout.strip(),
        serial_res.stdout.strip(),
    )

    return {"changed": False, "msg": state_txt,
            "data": {"state": verdict, "metrics": {}, "details": details}}