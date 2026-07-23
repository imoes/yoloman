# Module: hp_mcs_sensors_fan
# Read-only Starlark translation of Checkmk check: hp_mcs_sensors_fan
# Discovery: enumerate fan sensors (type in {9,10,11,26,27,28})
# Check: check one fan item with hw_fans ruleset (default lower=(1000,500))

_FAN_TYPES = [9, 10, 11, 26, 27, 28]

def _parse_snmp_table(ctx, community, host):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.232.167.2.4.5.2.1"
    ], mutates=False)
    lines = res.stdout.splitlines()
    raw = {}
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        if not "=" in line:
            continue
        idx_eq = line.find("=")
        oid = line[:idx_eq].strip()
        val = line[idx_eq+1:].strip()
        # Remove type prefix (e.g. "INTEGER: ", "STRING: ", etc.)
        if val.startswith("INTEGER: "):
            val = val[9:]
        elif val.startswith("STRING: "):
            val = val[8:]
            if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                val = val[1:-1]
        elif val.startswith("Gauge32: "):
            val = val[9:]
        elif val.startswith("Counter32: "):
            val = val[11:]
        parts = oid.split(".")
        if len(parts) > 0:
            idx_str = parts[-1]
            if idx_str.isdigit():
                raw[int(idx_str)] = val
    section = {}
    i = 1
    while i <= 10000:
        if not i in raw:
            i += 1
            continue
        if (i + 5) > 10000:
            break
        if not (i in raw and (i+1) in raw and (i+2) in raw and (i+3) in raw and (i+4) in raw and (i+5) in raw):
            i += 1
            continue
        t_str = raw[i]
        name = raw[i+1]
        status_str = raw[i+2]
        value_str = raw[i+3]
        high_str = raw[i+4]
        low_str = raw[i+5]
        # Convert values safely using guards
        t = int(t_str) if t_str.isdigit() else 0
        status = int(status_str) if status_str.isdigit() else 0
        value = float(value_str) if value_str.replace(".","").isdigit() else 0.0
        high = float(high_str) if high_str.replace(".","").isdigit() else 0.0
        low = float(low_str) if low_str.replace(".","").isdigit() else 0.0
        section[str(i)] = {
            "type": t,
            "name": name,
            "status": status,
            "value": value,
            "high": high,
            "low": low,
        }
        i += 7
    return section

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        section = _parse_snmp_table(ctx, community, host)
        items = []
        for key, entry in section.items():
            if entry["type"] in _FAN_TYPES:
                items.append({
                    "item": entry["name"],
                    "params": {"lower": [1000, 500]},
                    "metrics": ["speed"]
                })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    section = _parse_snmp_table(ctx, community, host)

    found = None
    for entry in section.values():
        if entry["name"] == item:
            found = entry
            break

    if found == None:
        return {
            "changed": False,
            "msg": "fan sensor not found: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    rpm = found["value"]
    status = found["status"]

    lower_warn = 1000.0
    lower_crit = 500.0
    lower_param = params.get("lower")
    if lower_param != None:
        if len(lower_param) >= 2:
            lower_str0 = str(lower_param[0])
            lower_str1 = str(lower_param[1])
            if lower_str0.replace(".","").isdigit():
                lower_warn = float(lower_str0)
            if lower_str1.replace(".","").isdigit():
                lower_crit = float(lower_str1)

    if status == 1:
        state = "OK"
    elif status == 2:
        state = "WARN"
    elif status == 3:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    if state == "OK":
        if rpm <= lower_crit:
            state = "CRIT"
        elif rpm <= lower_warn:
            state = "WARN"

    msg = "speed: %f RPM" % rpm

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"speed": rpm},
            "details": ""
        }
    }