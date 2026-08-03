def main(ctx, params):
    # Avaya chassis temperature check (SNMP) — read-only translation.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "Chassis")

    if params.get("_discover"):
        # Probe that this is really an Avaya device via the sysObjectID.
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0 or ".1.3.6.1.4.1.2272" not in sysid.stdout:
            return {"changed": False, "msg": "not an Avaya chassis", "data": {"discovery": []}}
        # The single temperature sensor lives at .1.3.6.1.4.1.2272.1.100.1.2
        temp = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.4.1.2272.1.100.1.2"],
            mutates=False,
        )
        if temp.rc != 0 or temp.stdout.strip() == "":
            return {"changed": False, "msg": "no Avaya chassis temperature found", "data": {"discovery": []}}
        levels = params.get("levels", (55.0, 60.0))
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "Chassis",
                        "params": {"levels": list(levels)},
                        "metrics": ["temperature"],
                    }
                ]
            },
        }

    # Check mode: read the chassis temperature.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.4.1.2272.1.100.1.2"],
        mutates=False,
    )
    raw = res.stdout.strip()
    if res.rc != 0 or raw == "":
        return {
            "changed": False,
            "msg": "no Avaya chassis temperature found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # snmpget -Oqv already gives the bare value; guard against non-numeric.
    if not raw.isdigit() and not (raw.startswith("-") and raw[1:].isdigit()):
        return {
            "changed": False,
            "msg": "temperature value not numeric: %s" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    value = float(raw)

    levels = params.get("levels", (55.0, 60.0))
    warn = levels[0] if len(levels) > 0 else 55.0
    crit = levels[1] if len(levels) > 1 else 60.0

    # temperature check_temperature uses upper levels: warn at <=, crit at <=.
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature %s, %s C" % (item, str(value)),
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": "warn=%s crit=%s" % (str(warn), str(crit)),
        },
    }