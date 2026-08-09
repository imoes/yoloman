# hp_msa_fan.star - Checkmk HP MSA fan check translated to Starlark

# State numeric maps (converted from Checkmk source)
HP_MSA_STATE_MAP = {
    "0": ("OK", "up"),
    "1": ("CRIT", "error"),
    "2": ("WARN", "off"),
    "3": ("UNKNOWN", "missing"),
}

HP_MSA_HEALTH_STATE_MAP = {
    "0": ("OK", "OK"),
    "1": ("WARN", "degraded"),
    "2": ("CRIT", "fault"),
    "3": ("CRIT", "N/A"),
    "4": ("UNKNOWN", "unknown"),
}


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    fans = _gather_fans(ctx, host, community)
    if len(fans) == 0:
        return {"changed": False, "msg": "discovered 0 fans", "data": {"discovery": []}}
    discovery = []
    for f in fans:
        discovery.append({"item": f["item"], "params": {}, "metrics": ["speed"]})
    return {"changed": False, "msg": "discovered %d fans" % len(discovery), "data": {"discovery": discovery}}


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    fans = _gather_fans(ctx, host, community)
    if len(fans) == 0:
        return {"changed": False, "msg": "no HP MSA fans found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fan_data = None
    for f in fans:
        if f["item"] == item:
            fan_data = f
            break
    if fan_data == None:
        return {"changed": False, "msg": "no such fan: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    speed = int(fan_data.get("speed", "0"))
    status_num = fan_data.get("status-numeric", "3")
    health_num = fan_data.get("health-numeric", "4")
    health_reason = fan_data.get("health-reason", "")
    fan_state, fan_state_readable = HP_MSA_STATE_MAP.get(status_num, ("UNKNOWN", "unknown"))
    fan_health_state, fan_health_state_readable = HP_MSA_HEALTH_STATE_MAP.get(health_num, ("UNKNOWN", "unknown"))
    msg = "Status: %s, speed: %d RPM" % (fan_state_readable, speed)
    if fan_state != "OK":
        msg2 = "health: %s (%s)" % (fan_health_state_readable, health_reason) if fan_health_state != "OK" and health_reason else ""
        details = msg2 if msg2 else ""
        return {"changed": False, "msg": msg, "data": {"state": fan_state, "metrics": {"speed": speed}, "details": details}}
    if fan_health_state != "OK" and health_reason:
        msg_full = msg + "; health: %s (%s)" % (fan_health_state_readable, health_reason)
        return {"changed": False, "msg": msg_full, "data": {"state": fan_health_state, "metrics": {"speed": speed}, "details": ""}}
    return {"changed": False, "msg": msg, "data": {"state": "OK", "metrics": {"speed": speed}, "details": ""}}


def _gather_fans(ctx, host, community):
    # HP MSA storage arrays expose fan data via SNMP
    # The fans are in a table with columns for name, status, speed, health, etc.
    # We use snmpwalk with -Oqn for clean numeric OID output
    base_oid = "1.3.6.1.4.1.25578.1.1.1.1"  # HP MSA enterprise MIB fan table base
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return []
    fans = {}
    # Parse the snmpwalk output: each line is "<OID>.<index> <value>"
    for line in res.stdout.splitlines():
        if " " not in line:
            continue
        parts = line.split(" ", 1)
        oid_full = parts[0]
        value = parts[1]
        # Extract index (suffix after base_oid)
        if not oid_full.startswith(base_oid):
            continue
        index = oid_full[len(base_oid) + 1:]
        # Determine column from OID suffix
        suffix = oid_full[len(base_oid) + 1 + len(index) + 1:] if "." in oid_full[len(base_oid) + 1:] else ""
        # Parse column number from the OID
        col_parts = oid_full[len(base_oid) + 1:].split(".")
        if len(col_parts) < 2:
            continue
        col_num = col_parts[-2] if len(col_parts) >= 2 else ""
        key = col_parts[0] if len(col_parts) >= 1 else ""
        # Map column numbers to fields (based on HP MSA MIB structure)
        col_field = _COLUMN_MAP.get(col_num, None)
        if col_field == None:
            continue
        if key not in fans:
            fans[key] = {"item": "fan_%s" % key}
        fans[key][col_field] = value
    result = []
    for k in sorted(fans.keys()):
        f = fans[k]
        if "status-numeric" in f and "speed" in f and "health-numeric" in f:
            result.append(f)
    return result


_COLUMN_MAP = {
    "1": "durable-id",
    "2": "name",
    "3": "location",
    "4": "status",
    "5": "status-numeric",
    "6": "speed",
    "7": "position",
    "8": "position-numeric",
    "9": "serial-number",
    "10": "fw-revision",
    "11": "hw-revision",
    "12": "health",
    "13": "health-numeric",
    "14": "health-reason",
    "15": "health-recommendation",
}