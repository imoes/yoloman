def _saveint(s):
    return int(s) if s != None and str(s).isdigit() else 0

def _convert(section, what):
    result = []
    for row in section:
        if len(row) < 3:
            continue
        presence = row[0]
        state = row[1]
        name = row[2].lstrip()
        state_int = _saveint(state)
        if name.startswith(what) and presence != "6" and (state_int > 0 or what == "Power"):
            sensor_id = name.split("#")[-1]
            result.append([sensor_id, name, state])
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    col_presence = base_oid + ".3"
    col_state = base_oid + ".4"
    col_name = base_oid + ".5"

    if params.get("_discover"):
        # Walk presence column to discover row indices
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_presence], mutates=False)
        if walk.rc != 0 and walk.rc != 127:
            return {"changed": False, "msg": "snmptable discovery failed", "data": {"discovery": []}}
        if walk.skipped:
            return {"changed": False, "msg": "would discover brocade temp sensors", "data": {"discovery": []}}

        indices = {}
        if walk.stdout:
            for line in walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(col_presence) + 1:]
                indices[idx] = parts[1]

        if not indices:
            return {"changed": False, "msg": "no brocade temp sensors found", "data": {"discovery": []}}

        discovery = []
        for idx in sorted(indices.keys()):
            # Query state and name by index
            state_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_state + "." + idx], mutates=False)
            name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_name + "." + idx], mutates=False)

            if state_res.rc != 0 or name_res.rc != 0:
                continue

            presence = indices[idx]
            state = state_res.stdout.strip()
            name = name_res.stdout.strip().lstrip()

            # Apply the same conversion logic as _brocade_sensor_convert with "SLOT"
            state_int = _saveint(state)
            if name.startswith("SLOT") and presence != "6" and state_int > 0:
                sensor_id = name.split(" ")[-1].split("#")[-1]
                # Actually, name could be "SLOT #0: TEMP #1", sensor_id = name.split("#")[-1] = "1"
                sensor_id = name.split("#")[-1]
                discovery.append({"item": sensor_id, "params": {"levels": (55.0, 60.0)}, "metrics": ["temperature"]})

        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    warn = params.get("levels", (55.0, 60.0))
    if type(warn) == "tuple":
        warn_val = warn[0]
        crit_val = warn[1]
    else:
        warn_val = 55.0
        crit_val = 60.0

    # Re-discover all SLOT sensors to find the matching item
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_presence], mutates=False)
    if walk.rc != 0 and walk.rc != 127:
        return {"changed": False, "msg": "no brocade temp sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if walk.skipped:
        return {"changed": False, "msg": "no brocade temp sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    indices = {}
    if walk.stdout:
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(col_presence) + 1:]
            indices[idx] = parts[1]

    if not indices:
        return {"changed": False, "msg": "no brocade temp sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = None
    for idx in sorted(indices.keys()):
        state_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_state + "." + idx], mutates=False)
        name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_name + "." + idx], mutates=False)
        if state_res.rc != 0 or name_res.rc != 0:
            continue

        presence = indices[idx]
        state = state_res.stdout.strip()
        name = name_res.stdout.strip().lstrip()

        state_int = _saveint(state)
        if name.startswith("SLOT") and presence != "6" and state_int > 0:
            sensor_id = name.split("#")[-1]
            if sensor_id == item:
                temperature = state_int
                break

    if temperature == None:
        return {"changed": False, "msg": "sensor not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "CRIT" if temperature >= crit_val else ("WARN" if temperature >= warn_val else "OK")
    return {"changed": False, "msg": "Temperature: %s C" % temperature, "data": {"state": state, "metrics": {"temperature": float(temperature)}, "details": ""}}