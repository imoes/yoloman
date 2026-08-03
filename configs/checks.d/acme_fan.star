ACME_ENVIRONMENT_STATES = {
    "1": (0, "initial"),
    "2": (0, "normal"),
    "3": (1, "minor"),
    "4": (1, "major"),
    "5": (2, "critical"),
    "6": (2, "shutdown"),
    "7": (2, "not present"),
    "8": (2, "not functioning"),
    "9": (2, "unknown"),
}

def parse_snmp_line(line):
    # snmpwalk -Oqn gives "<OID> <value>"
    parts = line.split(" ", 1)
    if len(parts) < 2:
        return None
    return (parts[0], parts[1].strip().strip('"'))

def strip_type_tag(value):
    # Strip type tag like "STRING: " or "INTEGER: " if present, and quotes
    if ": " in value:
        value = value.split(": ", 1)[1]
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        value = value[1:-1]
    return value

def discover_acme_fan(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.9148.3.3.1.4.1.1"
    descr_oid = base_oid + ".3"

    # Check if ACME device is present
    sys_oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_oid_res.rc != 0 or not sys_oid_res.stdout:
        return {"changed": False, "msg": "no ACME device found", "data": {"discovery": []}}
    sys_oid = sys_oid_res.stdout.strip().strip('"')
    if not sys_oid.startswith("1.3.6.1.4.1.9148"):
        return {"changed": False, "msg": "no ACME device found", "data": {"discovery": []}}

    # Walk the fan description column
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, descr_oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no ACME fans found", "data": {"discovery": []}}

    discovery = []
    for line in res.stdout.splitlines():
        parsed = parse_snmp_line(line)
        if parsed == None:
            continue
        oid, descr_value = parsed
        # Extract index: OID suffix after the column base
        index = oid[len(descr_oid) + 1:]
        if not index:
            continue

        # Get state for this fan
        state_oid = base_oid + ".5." + index
        state_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_oid], mutates=False)
        if state_res.rc != 0 or not state_res.stdout:
            continue
        state = strip_type_tag(state_res.stdout.strip())

        # Skip fans that are not present (state == "7")
        if state == "7":
            continue

        discovery.append({"item": descr_value, "params": {}, "metrics": []})

    return {"changed": False, "msg": "discovered %d fans" % len(discovery), "data": {"discovery": discovery}}

def check_acme_fan(ctx, params, item):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.9148.3.3.1.4.1.1"

    # Walk descriptions to find the index for this item
    descr_oid = base_oid + ".3"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, descr_oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no ACME fans found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_index = None
    for line in res.stdout.splitlines():
        parsed = parse_snmp_line(line)
        if parsed == None:
            continue
        oid, descr_value = parsed
        if descr_value == item:
            found_index = oid[len(descr_oid) + 1:]
            break

    if found_index == None:
        return {"changed": False, "msg": "fan not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get the fan state
    state_oid = base_oid + ".5." + found_index
    state_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_oid], mutates=False)
    if state_res.rc != 0 or not state_res.stdout:
        return {"changed": False, "msg": "cannot read fan state for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = strip_type_tag(state_res.stdout.strip())

    # Get the fan speed value
    value_oid = base_oid + ".4." + found_index
    value_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, value_oid], mutates=False)
    if value_res.rc != 0 or not value_res.stdout:
        value_str = ""
    else:
        value_str = strip_type_tag(value_res.stdout.strip())

    if state in ACME_ENVIRONMENT_STATES:
        dev_state_num, dev_state_readable = ACME_ENVIRONMENT_STATES[state]
        if dev_state_num == 0:
            state_str = "OK"
        elif dev_state_num == 1:
            state_str = "WARN"
        elif dev_state_num == 2:
            state_str = "CRIT"
        else:
            state_str = "UNKNOWN"
    else:
        dev_state_readable = "unknown"
        state_str = "UNKNOWN"

    return {"changed": False, "msg": "Status: " + dev_state_readable + ", Speed: " + value_str + "%", "data": {"state": state_str, "metrics": {}, "details": ""}}

def main(ctx, params):
    if params.get("_discover"):
        return discover_acme_fan(ctx, params)
    item = params.get("item", "")
    return check_acme_fan(ctx, params, item)