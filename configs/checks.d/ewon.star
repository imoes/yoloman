def main(ctx, params):
    # === Constants (module top-level) ===
    OXYREDUCT_TAG_MAP = {
        1: {"name": "alarms", "levels": (1, 2, -1, -1)},
        2: {"name": "incidents", "levels": (1, 2, -1, -1)},
        3: {"name": "shutdown messages", "levels": (1, 2, -1, -1)},
        4: {
            "flags": "00000????0000000",
            "flag_names": [
                "buzzer", "light test", "luminous field", "optical alarm",
                "accustic alarm", "", "", "", "", "warnings", "shutdown",
                "operation reports", "incident", "O2 high", "O2 low", "alarms",
            ],
        },
        5: {
            "flags": "00??????00**0101",
            "flag_names": [
                "recovery", "maintenance", "", "", "", "", "", "",
                "warnings", "incidents", "N2 to safe area",
                "N2 request from safe area", "N2 via outlet", "N2 via compressor",
                "N2-supply locked", "N2-supply open",
            ],
        },
        6: {"name": "O2 minimum", "levels": (16, 17, 14, 13), "scale": 0.01, "unit": "%", "perfvar": "o2_percentage", "condition_flag": (1, 15)},
        7: {
            "flags": "?????000??00000*",
            "flag_names": [
                "", "", "", "", "", "luminous field", "optical alarm",
                "acoustic alarm", "", "", "warnings", "operation report",
                "shutdown", "incidents", "alarm", "O2 Sensor",
            ],
        },
        8: {"name": "O2 minimum", "levels": (16, 17, 14, 13), "scale": 0.01, "unit": "%", "perfvar": "o2_percentage", "condition_flag": (1, 15)},
        9: {
            "flags": "?????000??00000*",
            "flag_names": [
                "", "", "", "", "", "luminous field", "optical alarm",
                "acoustic alarm", "", "", "warnings", "operation report",
                "shutdown", "incidents", "alarm", "O2 Sensor",
            ],
        },
        10: {"name": "O2 average", "levels_name": "o2_levels", "levels": (16, 17, 14, 13), "scale": 0.01, "unit": "%", "perfvar": "o2_percentage"},
        11: {"name": "O2 target", "scale": 0.01, "unit": "%"},
        12: {"name": "O2 for N2-in", "scale": 0.01, "unit": "%"},
        13: {"name": "O2 for N2-out", "scale": 0.01, "unit": "%"},
        14: {"name": "CO2 maximum", "levels": (1500, 2000, -1, -1), "unit": "ppm"},
        15: {
            "flags": "????++++????++++",
            "flag_names": [
                "", "", "", "", "air control shutdown", "air control closed",
                "air control open", "air control active", "", "", "", "",
                "valve shutdown", "valve closed", "valve open", "valve active",
            ],
        },
        16: {
            "flags": "????++++????++++",
            "flag_names": [
                "", "", "", "", "access shutdown", "access closed",
                "access open", "access active", "", "", "", "",
                "air circulation shutdown", "air circulation closed",
                "air circulation open", "air circulation active",
            ],
        },
        17: {
            "flags": "??00++++0?000001",
            "flag_names": [
                "O2 ref sensors working", "O2 ref sensors projected",
                "BMZ quick reduction", "key switch active", "mode BK3",
                "mode BK2", "mode BK1", "mode FB", "operation mode change",
                "", "warnings", "operation reports", "shutdown",
                "incidents", "alarm", "active",
            ],
        },
    }

    # === Discovery mode ===
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res_names = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.8284.2.1.3.1.11.1.16"
        ], mutates=False)

        res_values = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.8284.2.1.3.1.11.1.4"
        ], mutates=False)

        # Parse name mapping
        name_map = {}
        for line in res_names.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            oid_tokens = oid_part.strip().rsplit(".", 1)
            if len(oid_tokens) != 2:
                continue
            tagid_str = oid_tokens[1]
            value_tokens = value_part.split(": ", 1)
            if len(value_tokens) != 2:
                continue
            name_str = value_tokens[1].strip().strip('"')
            name_map[tagid_str] = name_str

        # Parse value mapping
        value_map = {}
        for line in res_values.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            oid_tokens = oid_part.strip().rsplit(".", 1)
            if len(oid_tokens) != 2:
                continue
            tagid_str = oid_tokens[1]
            value_tokens = value_part.split(": ", 1)
            if len(value_tokens) != 2:
                continue
            val_str = value_tokens[1].strip()
            val = float(val_str) if val_str.isdigit() or (val_str.find(".") != -1 and val_str.replace(".", "").replace("-", "").isdigit()) else 0.0
            value_map[tagid_str] = val

        # Aggregate by name
        section = {}
        for tagid_str, val in value_map.items():
            name = name_map.get(tagid_str, "")
            if name == "":
                continue
            section.setdefault(name, {})[int(tagid_str)] = val

        # Discovery
        discovered = []

        # Always discover "eWON Status"
        device = params.get("device", None)
        discovered.append({
            "item": "eWON Status",
            "params": {"device": device},
            "metrics": []
        })

        # Discover oxyreduct items
        if device == "oxyreduct":
            for name, area_info in section.items():
                tagids = area_info.keys()
                if len(tagids) == 0:
                    continue
                if min(tagids) < 10:
                    discovered.append({
                        "item": name,
                        "params": {"device": device},
                        "metrics": []
                    })
                else:
                    last_tagid = max(tagids)
                    flags = int(area_info[last_tagid])
                    if flags % 2 == 1:
                        discovered.append({
                            "item": name,
                            "params": {"device": device},
                            "metrics": []
                        })

        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovered),
            "data": {"discovery": discovered}
        }

    # === Check mode ===
    item = params.get("item", "")
    device = params.get("device", None)

    if item == "eWON Status":
        if device == None:
            return {
                "changed": False,
                "msg": "This device requires configuration. Please pick the device type.",
                "data": {"state": "WARN", "metrics": {}, "details": ""}
            }
        return {
            "changed": False,
            "msg": "Configured for " + str(device),
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    if device != "oxyreduct":
        return {
            "changed": False,
            "msg": "No messages",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.8284.2.1.3.1.11.1.16"
    ], mutates=False)

    res_values = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.8284.2.1.3.1.11.1.4"
    ], mutates=False)

    # Rebuild section
    name_map = {}
    for line in res_names.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_tokens = oid_part.strip().rsplit(".", 1)
        if len(oid_tokens) != 2:
            continue
        tagid_str = oid_tokens[1]
        value_tokens = value_part.split(": ", 1)
        if len(value_tokens) != 2:
            continue
        name_str = value_tokens[1].strip().strip('"')
        name_map[tagid_str] = name_str

    value_map = {}
    for line in res_values.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_tokens = oid_part.strip().rsplit(".", 1)
        if len(oid_tokens) != 2:
            continue
        tagid_str = oid_tokens[1]
        value_tokens = value_part.split(": ", 1)
        if len(value_tokens) != 2:
            continue
        val_str = value_tokens[1].strip()
        val = float(val_str) if val_str.isdigit() or (val_str.find(".") != -1 and val_str.replace(".", "").replace("-", "").isdigit()) else 0.0
        value_map[tagid_str] = val

    section = {}
    for tagid_str, val in value_map.items():
        name = name_map.get(tagid_str, "")
        if name == "":
            continue
        section.setdefault(name, {})[int(tagid_str)] = val

    data = section.get(item)

    if data == None or len(data) == 0:
        return {
            "changed": False,
            "msg": "No data for item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Process data using same logic as _check_oxyreduct
    results = []
    for tagid, value in data.items():
        ref_tagid = tagid
        if ref_tagid > 17:
            ref_tagid = ((ref_tagid - 18) % 8) + 10

        tag_params = OXYREDUCT_TAG_MAP.get(ref_tagid, {})

        # measure check
        if "name" in tag_params:
            if "condition_flag" in tag_params:
                condition_tagid = tagid + tag_params["condition_flag"][0]
                condition_val = data.get(condition_tagid, 0)
                if int(condition_val) & tag_params["condition_flag"][1] == 0:
                    continue

            value = value * float(tag_params.get("scale", 1.0))
            levels = tag_params.get("levels", (16, 17, 14, 13))

            unit_str = tag_params.get("unit", "")
            perfvar = tag_params.get("perfvar", "")
            name_str = tag_params["name"]

            upper_warn, upper_crit, lower_warn, lower_crit = levels
            state = "OK"

            if upper_warn != -1 and value >= float(upper_warn):
                state = "WARN"
            if upper_crit != -1 and value >= float(upper_crit):
                state = "CRIT"
            if lower_warn != -1 and value <= float(lower_warn):
                state = "WARN"
            if lower_crit != -1 and value <= float(lower_crit):
                state = "CRIT"

            if unit_str != "":
                msg = "%s %f %s" % (name_str, value, unit_str)
            else:
                msg = "%s %f" % (name_str, value)
            results.append((state, msg, perfvar, value))

        # bitmask check
        flags = tag_params.get("flags", "")
        if flags != "":
            val_int = int(value)
            bits = ""
            for i in range(16):
                bit_val = (val_int >> (15 - i)) & 1
                bits += str(bit_val)

            flag_names = tag_params.get("flag_names", [])
            for i in range(min(len(flags), len(flag_names))):
                flag_char = flags[i]
                name = flag_names[i]
                bit = bits[i]

                if flag_char == "1" and bit == "0":
                    results.append(("CRIT", name + " inactive", "", 0))
                elif flag_char == "0" and bit == "1":
                    results.append(("CRIT", name + " active", "", 0))
                elif flag_char == "*" or (flag_char == "+" and bit == "1"):
                    state_str = "active" if bit == "1" else "inactive"
                    results.append(("OK", name + " " + state_str, "", 0))

    # Aggregate results
    if len(results) == 0:
        state = "OK"
        msg = "No messages"
    else:
        state = "OK"
        for s, _, _, _ in results:
            if s == "CRIT":
                state = "CRIT"
                break
            if s == "WARN" and state != "CRIT":
                state = "WARN"

        msg = results[0][1]
        for i in range(1, len(results)):
            msg += "; " + results[i][1]

    metrics = {}
    for _, _, perfvar, val in results:
        if perfvar != "":
            metrics[perfvar] = val

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
