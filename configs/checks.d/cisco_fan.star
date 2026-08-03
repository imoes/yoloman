FAN_STATE_MAPPING = {
    "1": ("OK", "normal"),
    "2": ("WARN", "warning"),
    "3": ("CRIT", "critical"),
    "4": ("CRIT", "shutdown"),
    "5": ("UNKNOWN", "not present"),
    "6": ("CRIT", "not functioning"),
}


def cisco_sensor_item(description, sensor_id):
    if description == None or sensor_id == None or description == "None" or sensor_id == "None":
        return sensor_id if sensor_id != None else "unknown"
    splitted = [x.strip() for x in description.split(",")]
    if len(splitted) == 1:
        item = description
    elif "#" in splitted[-1] or "Power" in splitted[-1]:
        item = " ".join(splitted)
    elif splitted[-1].startswith("PS"):
        item = " ".join([splitted[0], splitted[-1].split(" ")[0]])
    elif len(splitted) >= 2 and splitted[-2].startswith("PS"):
        item = " ".join(splitted[:-2] + splitted[-2].split(" ")[:-1])
    elif len(splitted) >= 2 and splitted[-2].startswith("Status"):
        item = " ".join(splitted[:-2])
    else:
        item = " ".join(splitted[:-1]) if len(splitted) > 1 else " ".join(splitted)
    if item and item[-1].isdigit():
        final = item
    else:
        final = item + " " + sensor_id if item else sensor_id
    return final.replace("#", " ")


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item_filter = params.get("item", "")

    base_oid = ".1.3.6.1.4.1.9.9.13.1.4.1"
    col_desc = base_oid + ".2"
    col_state = base_oid + ".3"

    sys_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sys_descr.rc != 0 or "cisco" not in sys_descr.stdout.lower():
        if params.get("_discover"):
            return {"changed": False, "msg": "no Cisco device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Cisco device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_desc],
                  mutates=False)
    if res.rc != 0 or res.skipped:
        if params.get("_discover"):
            return {"changed": False, "msg": "no fan sensors found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no fan sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip().strip('"')
        idx = oid[len(col_desc) + 1:]
        if idx:
            rows.append((idx, val))

    if not rows:
        if params.get("_discover"):
            return {"changed": False, "msg": "no fan sensors found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no fan sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        discovery = []
        for idx, desc_val in rows:
            state_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 col_state + "." + idx],
                mutates=False,
            )
            dev_state = state_res.stdout.strip() if state_res.rc == 0 else "5"
            if dev_state in ["1", "2", "3", "4", "6"]:
                sensor_id = idx.split(".")[-1] if idx else "unknown"
                it = cisco_sensor_item(desc_val, sensor_id)
                discovery.append({"item": it, "params": {},
                                  "metrics": ["fan_status"]})
        return {"changed": False,
                "msg": "discovered %d fan sensors" % len(discovery),
                "data": {"discovery": discovery}}

    for idx, desc_val in rows:
        sensor_id = idx.split(".")[-1] if idx else "unknown"
        if cisco_sensor_item(desc_val, sensor_id) == item_filter:
            state_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 col_state + "." + idx],
                mutates=False,
            )
            dev_state = state_res.stdout.strip() if state_res.rc == 0 else "5"
            mapped = FAN_STATE_MAPPING.get(dev_state, ("UNKNOWN", "unknown[%s]" % dev_state))
            state_name, readable = mapped
            return {"changed": False,
                    "msg": "FAN %s: Status: %s" % (item_filter, readable),
                    "data": {"state": state_name,
                             "metrics": {"fan_status": 1 if state_name == "OK" else 0},
                             "details": ""}}

    return {"changed": False, "msg": "no such fan sensor: " + item_filter,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}