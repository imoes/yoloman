# Translated Checkmk check: adva_fsp_current (Power Supply current)
# SNMP-based check for ADVA Fiber Service Platform F7 power supplies.

def _to_float(s):
    s = s.strip()
    if s == "" or s == None:
        return 0.0
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    if s.startswith("+"):
        s = s[1:]
    if s == "":
        return 0.0
    dot_seen = False
    for ch in s:
        if ch >= "0" and ch <= "9":
            continue
        if ch == ".":
            if dot_seen:
                return 0.0
            dot_seen = True
            continue
        return 0.0
    val = 0.0
    dot_pos = -1
    for i in range(len(s)):
        if s[i] == ".":
            dot_pos = i
    if dot_pos == -1:
        for ch in s:
            val = val * 10 + (ord(ch) - ord("0"))
        return val if not neg else -val
    int_part = s[:dot_pos]
    frac_part = s[dot_pos + 1:]
    for ch in int_part:
        val = val * 10 + (ord(ch) - ord("0"))
    f = 0.0
    for ch in frac_part:
        f = f * 10 + (ord(ch) - ord("0"))
    for _ in range(len(frac_part)):
        f = f / 10.0
    val = val + f
    return val if not neg else -val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- Detection: this check only applies to ADVA FSP devices ---
    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.1.0",
    ], mutates=False)
    if sys_descr.rc != 0:
        if not params.get("_discover"):
            return {"changed": False, "msg": "SNMP unavailable for " + host,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "device not reachable",
                "data": {"discovery": [], "host_labels": {}}}

    descr = sys_descr.stdout.strip()
    if "Fiber Service Platform F7" not in descr:
        if not params.get("_discover"):
            return {"changed": False, "msg": "not an ADVA FSP device",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "device not an ADVA FSP",
                "data": {"discovery": [], "host_labels": {}}}

    # --- Fetch the SNMP table columns by index ---
    cols = {
        "current": "1.11.2.4.2.2.1.1",
        "crit": "1.11.2.4.2.2.1.2",
        "power": "1.11.2.4.2.2.1.3",
        "name": "2.5.5.1.1.1",
        "index": "2.5.5.1.1.5",
    }
    raw = {}
    for cname in cols:
        r = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, ".1.3.6.1.4.1.2544." + cols[cname],
        ], mutates=False)
        col_data = {}
        if r.rc == 0:
            for line in r.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid = parts[0]
                val = parts[1]
                idx = oid[len(".1.3.6.1.4.1.2544." + cols[cname]) + 1:]
                col_data[idx] = val
        raw[cname] = col_data

    # --- Build SensorData for connected sensors (index_aid and power present) ---
    sensors = {}
    for idx in raw.get("power", {}):
        power_val = raw["power"].get(idx, "")
        index_aid = idx
        if not index_aid or not power_val:
            continue
        current_str = raw.get("current", {}).get(idx, "0")
        crit_str = raw.get("crit", {}).get(idx, "0")
        unit_name = raw.get("name", {}).get(idx, "")
        current = _to_float(current_str) / 1000.0
        crit = _to_float(crit_str) / 1000.0
        sensors[index_aid] = {"name": unit_name, "crit": crit, "current": current}

    # --- Discovery ---
    if params.get("_discover"):
        discovery = []
        for item in sorted(sensors.keys()):
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["current"],
            })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    # --- Check single item ---
    item = params.get("item", "")
    if item not in sensors:
        return {
            "changed": False,
            "msg": "no such power supply: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = sensors[item]
    current = sensor["current"]
    crit = sensor["crit"]

    state = "OK"
    if current >= crit and crit > 0:
        state = "CRIT"

    label = "[" + sensor["name"] + "]" if sensor["name"] else ""
    msg = label + " " + "%f A" % current

    return {
        "changed": False,
        "msg": msg.strip(),
        "data": {
            "state": state,
            "metrics": {"current": current},
            "details": "",
        },
    }