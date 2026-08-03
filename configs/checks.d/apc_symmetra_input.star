# Translated from Checkmk check: checkmk.apc_symmetra_input
# SNMP scalar voltage check for APC Symmetra input phase.

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.318.1.1.1.3.2.1.0"
    item = params.get("item", "")

    # --- Discovery mode ---
    if params.get("_discover"):
        # Detect APC device via sysObjectID prefix .1.3.6.1.4.1.318
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0:
            return {"changed": False, "msg": "device not reachable / not APC",
                    "data": {"discovery": []}}
        if not sysid.stdout.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not an APC device",
                    "data": {"discovery": []}}

        # Fetch the single scalar voltage value
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no input voltage data",
                    "data": {"discovery": []}}

        # One item always: "Input"
        return {
            "changed": False,
            "msg": "discovered 1 input phase",
            "data": {
                "discovery": [
                    {"item": "Input", "params": {"voltage_warn": 240.0, "voltage_crit": 250.0},
                     "metrics": ["voltage"]},
                ],
            },
        }

    # --- Check mode ---
    # Only one item exists
    if item and item != "Input":
        return {"changed": False, "msg": "no such phase: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "input voltage not available (rc=%d)" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    # Strip any leading type tag if -Oqv was insufficient
    if ":" in raw:
        raw = raw.split(": ", 1)[1] if ": " in raw else raw
    raw = raw.strip().strip('"')

    volt = 0.0
    if raw:
        parts = raw.split(".")
        if len(parts) == 1 and parts[0].lstrip("-").isdigit():
            volt = float(int(parts[0]))
        else:
            try_v = raw.replace(".", "", 1).lstrip("-")
            if try_v.isdigit():
                volt = float(raw)
            else:
                return {"changed": False, "msg": "cannot parse voltage value: " + raw,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = float(params.get("voltage_warn", 240.0))
    crit = float(params.get("voltage_crit", 250.0))

    state = "OK"
    if volt >= crit:
        state = "CRIT"
    elif volt >= warn:
        state = "WARN"

    msg = "Voltage: %f V" % volt
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"voltage": volt},
                     "details": msg}}