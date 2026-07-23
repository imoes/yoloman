# Constants (top-level, no imports)
DEFAULT_LOWER_WARN = 3000
DEFAULT_LOWER_CRIT = 2800

def _saveint(i):
    # Guard-based replacement: return 0 for non-digit strings
    return int(i) if i.isdigit() else 0

def _discover_fans(section):
    out = []
    for row in section:
        if len(row) < 3:
            continue
        presence, state, name = row
        name = name.lstrip()
        if name.startswith("FAN") and presence != "6" and (_saveint(state) > 0 or "Power" == "FAN"):
            sensor_id = name.split("#")[-1]
            out.append([sensor_id, name, state])
    return out

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}

        raw = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_str = parts[0].strip()
            val_str = parts[1].strip()
            oid_parts = oid_str.split(".")
            if len(oid_parts) < 15:
                continue
            idx_str = oid_parts[-1]
            col_str = oid_parts[-2]
            if not idx_str.isdigit() or not col_str.isdigit():
                continue
            col = int(col_str)
            idx = int(idx_str)
            if idx not in raw:
                raw[idx] = {}
            if val_str.startswith("INTEGER:"):
                val = val_str[len("INTEGER:"):].strip()
            elif val_str.startswith("STRING:"):
                val = val_str[len("STRING:"):].strip().strip('"')
            else:
                val = val_str
            raw[idx]["presence" if col == 3 else ("state" if col == 4 else "name")] = val

        section = []
        for idx in sorted(raw.keys()):
            row = raw[idx]
            presence = row.get("presence", "0")
            state = row.get("state", "0")
            name = row.get("name", "")
            section.append([presence, state, name])

        fans = _discover_fans(section)
        out = []
        for fan in fans:
            sensor_id, name, state = fan
            out.append({
                "item": sensor_id,
                "params": {"lower": [DEFAULT_LOWER_WARN, DEFAULT_LOWER_CRIT]},
                "metrics": ["speed"]
            })
        return {"changed": False, "msg": "discovered %d FANs" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == None:
        item = ""

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_str = parts[0].strip()
        val_str = parts[1].strip()
        oid_parts = oid_str.split(".")
        if len(oid_parts) < 15:
            continue
        idx_str = oid_parts[-1]
        col_str = oid_parts[-2]
        if not idx_str.isdigit() or not col_str.isdigit():
            continue
        col = int(col_str)
        idx = int(idx_str)
        if idx not in raw:
            raw[idx] = {}
        if val_str.startswith("INTEGER:"):
            val = val_str[len("INTEGER:"):].strip()
        elif val_str.startswith("STRING:"):
            val = val_str[len("STRING:"):].strip().strip('"')
        else:
            val = val_str
        raw[idx]["presence" if col == 3 else ("state" if col == 4 else "name")] = val

    section = []
    for idx in sorted(raw.keys()):
        row = raw[idx]
        presence = row.get("presence", "0")
        state = row.get("state", "0")
        name = row.get("name", "")
        section.append([presence, state, name])

    fans = _discover_fans(section)
    found = False
    for sensor_id, name, value in fans:
        if item == sensor_id:
            found = True
            speed = _saveint(value)
            lower = params.get("lower", [DEFAULT_LOWER_WARN, DEFAULT_LOWER_CRIT])
            warn = lower[0] if isinstance(lower, list) else DEFAULT_LOWER_WARN
            crit = lower[1] if isinstance(lower, list) else DEFAULT_LOWER_CRIT
            if speed <= crit:
                state = "CRIT"
                summary = "Error: speed %d RPM below critical threshold %d RPM" % (speed, crit)
            elif speed <= warn:
                state = "WARN"
                summary = "Warning: speed %d RPM below warning threshold %d RPM" % (speed, warn)
            else:
                state = "OK"
                summary = "OK: speed %d RPM" % speed
            metrics = {"speed": speed}
            return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": ""}}

    if not found:
        return {"changed": False, "msg": "FAN %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
