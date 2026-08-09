def _state_for_status(status_name):
    mapping = {
        "invalid": "UNKNOWN",
        "normal": "OK",
        "out of range low": "CRIT",
        "out of range high": "CRIT",
        "alarm low": "CRIT",
        "alarm high": "CRIT",
    }
    return mapping.get(status_name, "UNKNOWN")


def _parse_hwg(rows):
    map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}
    map_dev_states = {
        "0": "invalid",
        "1": "normal",
        "2": "out of range low",
        "3": "out of range high",
        "4": "alarm low",
        "5": "alarm high",
    }
    parsed = {}
    for row in rows:
        if len(row) < 5:
            continue
        index = row[0]
        descr = row[1]
        sensorstatus = row[2]
        current = row[3]
        unit = row[4]
        status_name = map_dev_states.get(sensorstatus, "")
        is_humidity = int(sensorstatus) != 0 and map_units.get(unit, "") == "%"
        if is_humidity:
            parsed.setdefault(index, {
                "descr": descr,
                "humidity": float(current),
                "dev_status_name": status_name,
                "dev_status": sensorstatus,
            })
        else:
            tempval = None
            if current.lstrip("-").isdigit() or _is_float(current):
                tempval = float(current)
            parsed.setdefault(index, {
                "descr": descr,
                "dev_unit": map_units.get(unit),
                "temperature": tempval,
                "dev_status_name": status_name,
                "dev_status": sensorstatus,
            })
    return parsed


def _is_float(s):
    if s == None or s == "":
        return False
    stripped = s
    if stripped[0:1] in ("+", "-") and len(stripped) > 1:
        stripped = stripped[1:]
    if stripped.count(".") != 1:
        return False
    parts = stripped.split(".")
    return parts[0].isdigit() and parts[1].isdigit()


def _grade(temp, warn, crit):
    if temp == None:
        return "UNKNOWN"
    if temp >= crit:
        return "CRIT"
    if temp >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.21796.4.9.3.1"

    if params.get("_discover"):
        sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_res.rc != 0:
            return {"changed": False, "msg": "not reachable (rc=%d)" % sys_res.rc, "data": {"discovery": []}}
        if "STE2" not in sys_res.stdout:
            return {"changed": False, "msg": "not an STE2 device", "data": {"discovery": []}}

        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + ".1"], mutates=False)
        if walk_res.rc != 0 or walk_res.stdout == "":
            return {"changed": False, "msg": "no temperature sensors", "data": {"discovery": []}}

        indices = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            suffix = oid[len(base_oid + ".1"):]
            if len(suffix) > 0 and suffix[0] == ".":
                suffix = suffix[1:]
            if suffix == "":
                continue
            indices.append(suffix)

        if len(indices) == 0:
            return {"changed": False, "msg": "no temperature sensors", "data": {"discovery": []}}

        section = {}
        for idx in indices:
            col_vals = []
            oids_to_fetch = [base_oid + "." + oid_part + "." + idx for oid_part in ["1", "2", "3", "4", "7"]]
            for oid in oids_to_fetch:
                res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
                col_vals.append(res.stdout.strip() if res.rc == 0 else "")
            rows = [col_vals]
            section = _parse_hwg(rows)

        discovery = []
        for index, attrs in section.items():
            if attrs.get("temperature") != None and attrs.get("dev_status_name", "") not in ["invalid", ""]:
                discovery.append({"item": index, "params": {"levels": (30.0, 35.0)}, "metrics": ["temperature"]})

        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    indices_to_fetch = []
    if item == "":
        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + ".1"], mutates=False)
        if walk_res.rc != 0 or walk_res.stdout == "":
            return {"changed": False, "msg": "no temperature sensors", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            suffix = oid[len(base_oid + ".1") + 1:]
            indices_to_fetch.append(suffix)
    else:
        indices_to_fetch.append(item)

    found_item = None
    section = {}
    for idx in indices_to_fetch:
        col_vals = []
        for oid_part in ["1", "2", "3", "4", "7"]:
            oid = base_oid + "." + oid_part + "." + idx
            res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
            col_vals.append(res.stdout.strip() if res.rc == 0 else "")
        rows = [col_vals]
        parsed = _parse_hwg(rows)
        section.update(parsed)
        if item == "" and found_item == None:
            for k, v in parsed.items():
                if v.get("temperature") != None and v.get("dev_status_name", "") not in ["invalid", ""]:
                    found_item = k
                    break
        if item != "" and idx in parsed:
            found_item = idx

    if item != "":
        if item in section:
            found_item = item
        elif not section:
            found_item = None

    if found_item == None or found_item not in section:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section[found_item]
    temp = data.get("temperature")
    status_name = data.get("dev_status_name", "")
    state = _state_for_status(status_name)
    levels = params.get("levels", (30.0, 35.0))
    warn = levels[0] if len(levels) > 0 else 30.0
    crit = levels[1] if len(levels) > 1 else 35.0
    if temp != None:
        temp_state = _grade(temp, warn, crit)
        if temp_state == "CRIT":
            state = "CRIT"
        elif temp_state == "WARN" and state == "OK":
            state = "WARN"
    metrics = {}
    if temp != None:
        metrics["temperature"] = temp
    else:
        metrics["temperature"] = 0
    msg = "Description: " + data.get("descr", "") + ", Status: " + status_name
    if temp != None:
        msg = msg + ", Temperature: " + str(temp) + (data.get("dev_unit") or "c")
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": msg}}