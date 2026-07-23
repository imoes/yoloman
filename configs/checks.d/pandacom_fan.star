def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3652.3.2.3.1"

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid + ".2"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        fan_items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            if value.startswith("INTEGER: "):
                value = value[9:]
            if value.startswith("Gauge32: "):
                value = value[9:]
            # Extract fan number from OID
            if oid.startswith(base_oid + ".2."):
                fan_nr = oid[len(base_oid) + 3:]
                if value not in ["0", "5"]:
                    fan_items.append({"item": fan_nr, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d fans" % len(fan_items),
            "data": {"discovery": fan_items}
        }

    # Check mode
    item = params.get("item", "")
    if item == None:
        item = ""

    # Build OID for specific fan
    fan_oid = base_oid + ".2." + item
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        fan_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "no data for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "cannot parse response for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value = parts[1].strip()
    if value.startswith("INTEGER: "):
        value = value[9:]
    if value.startswith("Gauge32: "):
        value = value[9:]

    map_fan_state = {
        "0": ("UNKNOWN", "not available"),
        "1": ("OK", "on"),
        "2": ("CRIT", "off"),
        "3": ("OK", "pass"),
        "4": ("CRIT", "fail"),
        "5": ("UNKNOWN", "not installed"),
        "6": ("OK", "auto"),
    }

    state_name = map_fan_state.get(value, ("UNKNOWN", "unknown state"))[0]
    state_readable = map_fan_state.get(value, ("UNKNOWN", "unknown state"))[1]

    return {
        "changed": False,
        "msg": "Operational status: " + state_readable,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }