# Map fan states: OID value -> (Checkmk State, description)
# 1=UNKNOWN, 2=OK, 3=CRIT
_FAN_STATE_MAP = {
    "1": ("UNKNOWN", "Reported Unknown"),
    "2": ("OK", "Running"),
    "3": ("CRIT", "Down"),
}

def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # Discovery mode: enumerate all fan items
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2272.1.4.7.1.1.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}

        # Parse snmpwalk output: ".1.3.6.1.4.1.2272.1.4.7.1.1.2.<i> = INTEGER: <value>"
        out = []
        for line in res.stdout.splitlines():
            # Split on '=' and get value part
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            value_part = parts[1].strip()
            # Extract integer value (e.g. "INTEGER: 2" -> "2")
            if value_part.startswith("INTEGER: "):
                fan_value = value_part[11:].strip()
                # Use index (item) as position in list
                idx = str(len(out))
                out.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d fans" % len(out),
                "data": {"discovery": out}}

    # Check mode: single item
    item = params.get("item", "")
    # Fetch fan state OID: .1.3.6.1.4.1.2272.1.4.7.1.1.2.<item>
    base_oid = ".1.3.6.1.4.1.2272.1.4.7.1.1.2." + item
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "fan item %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpget: "<oid> = INTEGER: <value>"
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) < 2:
        return {"changed": False, "msg": "malformed snmpget output for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_part = parts[1].strip()
    if not value_part.startswith("INTEGER: "):
        return {"changed": False, "msg": "non-integer value for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fan_value = value_part[11:].strip()
    state_tuple = _FAN_STATE_MAP.get(fan_value)
    if state_tuple == None:
        return {"changed": False, "msg": "unknown fan state value: " + fan_value,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, text = state_tuple
    return {"changed": False, "msg": text,
            "data": {"state": state, "metrics": {}, "details": ""}}
