def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        detect = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.4.1.232.2.2.4.2.0",
        ], mutates=False)
        if detect.rc != 0 or detect.stdout.find("proliant") == -1:
            return {
                "changed": False,
                "msg": "device is not a ProLiant system",
                "data": {"discovery": []},
            }

        base = ".1.3.6.1.4.1.232.8.2.1.1"
        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, base + ".4",
        ], mutates=False)
        if walk.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed: " + walk.stderr,
                "data": {"discovery": []},
            }

        discovery = []
        for line in walk.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) < 2 or sp[1].strip() == "":
                continue
            oid = sp[0]
            idx = oid[len(base + ".4"):]
            if idx == "":
                continue

            cols = {}
            for oid_num in ["1", "2"]:
                g = ctx.run([
                    "snmpget", "-v2c", "-c", community, "-Oqv",
                    host, base + "." + oid_num + "." + idx,
                ], mutates=False)
                cols[oid_num] = g.stdout.strip()

            item = cols["1"] + "/" + cols["2"]
            discovery.append({"item": item, "params": {}, "metrics": []})

        verb = "would discover" if ctx.check_mode else "discovered"
        return {
            "changed": False,
            "msg": "%s %d drive boxes" % (verb, len(discovery)),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base = ".1.3.6.1.4.1.232.8.2.1.1"

    c_index, b_index = item.split("/")

    idx = None
    for cand_oid in [c_index, b_index]:
        for col_num in ["1", "2", "3", "4", "7", "8", "9", "10", "11", "17", "23"]:
            g = ctx.run([
                "snmpget", "-v2c", "-c", community, "-Oqv",
                host, base + "." + col_num + "." + cand_oid,
            ], mutates=False)
            if g.rc == 0:
                idx = cand_oid
                break
        if idx != None:
            break

    if idx == None:
        return {
            "changed": False,
            "msg": "no matching drive box index found for item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    oid_map = {
        "1": "_c_index",
        "2": "_b_index",
        "3": "ty",
        "4": "model",
        "7": "fan_status",
        "8": "cond",
        "9": "temp_status",
        "10": "sp_status",
        "11": "pwr_status",
        "17": "serial",
        "23": "loc",
    }

    values = {}
    for oid_num, col_name in oid_map.items():
        g = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, base + "." + oid_num + "." + idx,
        ], mutates=False)
        if g.rc != 0:
            values[col_name] = ""
        else:
            values[col_name] = g.stdout.strip()

    ty = values["ty"]
    model = values["model"]
    fan_status = values["fan_status"]
    cond = values["cond"]
    temp_status = values["temp_status"]
    sp_status = values["sp_status"]
    pwr_status = values["pwr_status"]
    serial = values["serial"]
    loc = values["loc"]

    hp_sts_drvbox_type_map = {
        "1": "other",
        "2": "ProLiant Storage System",
        "3": "ProLiant-2 Storage System",
        "4": "internal ProLiant-2 Storage System",
        "5": "proLiant2DuplexTop",
        "6": "proLiant2DuplexBottom",
        "7": "proLiant2InternalDuplexTop",
        "8": "proLiant2InternalDuplexBottom",
    }

    hp_sts_drvbox_cond_map = {
        "1": "UNKNOWN",
        "2": "OK",
        "3": "WARN",
        "4": "CRIT",
    }

    hp_sts_drvbox_fan_map = {
        "1": "UNKNOWN",
        "2": "OK",
        "3": "CRIT",
        "4": None,
        "5": "WARN",
    }

    hp_sts_drvbox_temp_map = {
        "1": "UNKNOWN",
        "2": "OK",
        "3": "WARN",
        "4": "CRIT",
        "5": None,
    }

    hp_sts_drvbox_sp_map = {
        "1": "UNKNOWN",
        "2": "OK",
        "3": "CRIT",
        "4": None,
    }

    hp_sts_drvbox_power_map = {
        "1": "UNKNOWN",
        "2": "OK",
        "3": "WARN",
        "4": "CRIT",
        "5": None,
    }

    worst_state = "OK"

    for val, label, map_ in [
        (fan_status, "Fan-Status", hp_sts_drvbox_fan_map),
        (cond, "Condition", hp_sts_drvbox_cond_map),
        (temp_status, "Temp-Status", hp_sts_drvbox_temp_map),
        (sp_status, "Sidepanel-Status", hp_sts_drvbox_sp_map),
        (pwr_status, "Power-Status", hp_sts_drvbox_power_map),
    ]:
        if val not in map_:
            continue
        st = map_[val]
        if st == None:
            continue
        if st == "CRIT":
            worst_state = "CRIT"
        elif st == "WARN" and worst_state != "CRIT":
            worst_state = "WARN"
        elif st == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"

    type_name = hp_sts_drvbox_type_map.get(ty, "unknown")
    summary = "%s: %s, Model: %s, Serial: %s, Location: %s" % (
        label, type_name, model, serial, loc,
    ) if False else "Drive Box %s" % item

    summary = "Type: %s, Model: %s, Serial: %s, Location: %s" % (
        type_name, model, serial, loc,
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst_state,
            "metrics": {},
            "details": "",
        },
    }