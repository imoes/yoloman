def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2011.5.25.31.1.1.10.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}

        items = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid_str = oid_part.strip()
            value_str = value_part.strip()
            parts = oid_str.rsplit(".", 1)
            if len(parts) != 2:
                continue
            base_oid, sub_oid = parts
            if sub_oid not in ("5", "6"):
                continue
            index = base_oid.split(".")[-1]
            value_part_str = value_str.split(":")[-1].strip()
            if not value_part_str.isdigit() and (not value_part_str.startswith("-") and value_part_str[1:].isdigit()):
                continue
            val = int(value_part_str)
            if sub_oid == "5":
                items.setdefault(index, {})["speed"] = val
            elif sub_oid == "6":
                items.setdefault(index, {})["present"] = val

        discovery = []
        for idx, data in items.items():
            if data.get("present") == 1:
                discovery.append({"item": idx, "params": {}, "metrics": ["fan_perc"]})
        return {"changed": False, "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2011.5.25.31.1.1.10." + item + ".5",
        ".1.3.6.1.4.1.2011.5.25.31.1.1.10." + item + ".6"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpget failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fan_speed = None
    fan_present = 0
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        value_str = value_part.strip()
        parts = value_str.split(":", 1)
        if len(parts) != 2:
            continue
        value_part_str = parts[-1].strip()
        if not value_part_str.isdigit() and (not value_part_str.startswith("-") and value_part_str[1:].isdigit()):
            continue
        val = int(value_part_str)
        if oid_part.strip().endswith(".5"):
            fan_speed = val
        elif oid_part.strip().endswith(".6"):
            fan_present = val

    if fan_present != 1:
        return {"changed": False, "msg": "fan %s not present" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if fan_speed == None:
        return {"changed": False, "msg": "could not read fan speed for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("levels", (None, None))
    crit = params.get("levels_lower", (None, None))

    state = "OK"
    details = []
    metrics = {"fan_perc": fan_speed}

    if warn[0] != None and fan_speed >= warn[0]:
        state = "WARN"
        details.append("Fan speed %f%% >= warning threshold %f%%" % (fan_speed, warn[0]))
    if crit[0] != None and fan_speed >= crit[0]:
        state = "CRIT"
        details.append("Fan speed %f%% >= critical threshold %f%%" % (fan_speed, crit[0]))

    if warn[1] != None and fan_speed <= warn[1]:
        state = "WARN" if state != "CRIT" else state
        details.append("Fan speed %f%% <= warning threshold %f%%" % (fan_speed, warn[1]))
    if crit[1] != None and fan_speed <= crit[1]:
        state = "CRIT"
        details.append("Fan speed %f%% <= critical threshold %f%%" % (fan_speed, crit[1]))

    msg = "Fan %s speed %f%%" % (item, fan_speed)
    if len(details) > 0:
        msg += " - " + "; ".join(details)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}