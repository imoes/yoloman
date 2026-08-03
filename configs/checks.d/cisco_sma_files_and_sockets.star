# Checkmk check: cisco_sma_files_and_sockets
# Translated to read-only Starlark for the yolo-man agent.
# Monitors: count of open files/sockets on a Cisco SMA device (SNMP scalar OID .1.3.6.1.4.1.15497.1.1.1.19)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = ".1.3.6.1.4.1.15497.1.1.1.19"

    # Default thresholds from checkmk source
    levels_upper = params.get("levels_upper_open_files_and_sockets", (5500, 6000))
    levels_lower = params.get("levels_lower_open_files_and_sockets", None)

    warn_upper = levels_upper[0] if type(levels_upper) in ("list", "tuple") else 5500
    crit_upper = levels_upper[1] if type(levels_upper) in ("list", "tuple") else 6000
    warn_lower = levels_lower[0] if (type(levels_lower) in ("list", "tuple") and len(levels_lower) > 0) else None
    crit_lower = levels_lower[1] if (type(levels_lower) in ("list", "tuple") and len(levels_lower) > 1) else None

    if params.get("_discover"):
        # Discovery: probe the real device by fetching the OID.
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget not installed", "data": {"discovery": []}}
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "no Cisco SMA detected", "data": {"discovery": []}}
        # The device answered: this is a single-service check, item ""
        entry = {
            "item": "",
            "params": {
                "levels_upper_open_files_and_sockets": (5500, 6000),
                "levels_lower_open_files_and_sockets": None,
            },
            "metrics": ["cisco_sma_files_and_sockets"],
            "service_labels": {},
        }
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [entry]}}

    # Check mode (single service, item "" )
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not installed on agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpget binary not found"},
        }
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no Cisco SMA detected on host " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpget failed rc=%d" % res.rc},
        }

    raw = res.stdout.strip()
    if raw == "":
        return {
            "changed": False,
            "msg": "no data from device " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "empty SNMP response"},
        }

    #snmpget -Oqv returns only the value (a bare integer for this OID)
    if not raw.lstrip("-").isdigit():
        return {
            "changed": False,
            "msg": "non-numeric value from device: " + raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "value parse error"},
        }

    value = int(raw.lstrip("-"))

    # Grade: upper levels -> WARN if >= warn, CRIT if >= crit
    #        lower levels -> WARN if <= warn, CRIT if <= crit
    state = "OK"
    if warn_upper != None:
        if value >= crit_upper:
            state = "CRIT"
        elif value >= warn_upper:
            state = "WARN"
    if state == "OK" and warn_lower != None:
        if value <= crit_lower:
            state = "CRIT"
        elif value <= warn_lower:
            state = "WARN"

    return {
        "changed": False,
        "msg": "Open: %d" % value,
        "data": {
            "state": state,
            "metrics": {"cisco_sma_files_and_sockets": value},
            "details": "Open files and sockets: %d" % value,
        },
    }