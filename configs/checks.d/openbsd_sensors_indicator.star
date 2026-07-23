def main(ctx, params):
    STATE_MAP = {
        "0": "UNKNOWN",
        "1": "OK",
        "2": "WARN",
        "3": "CRIT"
    }

    TYPE_MAP = {
        "0": "temp",
        "1": "fan",
        "2": "voltage",
        "9": "indicator",
        "13": "drive",
        "21": "powersupply"
    }

    def get_item_name(name, used):
        idx = 0
        new_name = name
        while new_name in used:
            new_name = name + "/" + str(idx)
            idx += 1
        return new_name

    def parse_snmp_output(lines):
        section = {}
        used = set()
        for i in range(0, len(lines), 5):
            if i + 4 >= len(lines):
                continue
            ok = True
            parts = []
            for j in range(5):
                line = lines[i + j].strip()
                if line.find(":") == -1:
                    ok = False
                    break
                val = line.split(":", 1)[1].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                parts.append(val)
            if not ok or len(parts) != 5:
                continue
            descr, sensortype, value, unit, state = parts
            if sensortype not in TYPE_MAP:
                continue
            if sensortype == "0" and value == "-273.15":
                continue
            if sensortype in ["1", "2"] and value == "0":
                continue
            if not (value.replace(".", "", 1).isdigit() or (value.startswith("-") and value[1:].replace(".", "", 1).isdigit())):
                value_converted = value
            else:
                value_converted = float(value)
            item_name = get_item_name(descr, used)
            used.add(item_name)
            section[item_name] = {
                "state": STATE_MAP.get(state, "UNKNOWN"),
                "value": value_converted,
                "unit": unit,
                "type": TYPE_MAP[sensortype]
            }
        return section

    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + ".2", base_oid + ".3", base_oid + ".5", base_oid + ".6", base_oid + ".7"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        if len(lines) % 5 != 0:
            return {
                "changed": False,
                "msg": "SNMP output malformed: expected multiples of 5 lines",
                "data": {"discovery": []}
            }
        section = parse_snmp_output(lines)
        items = []
        for item_name, data in section.items():
            if data["type"] == "indicator":
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d indicators" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid + ".2", base_oid + ".3", base_oid + ".5", base_oid + ".6", base_oid + ".7"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) % 5 != 0:
        return {
            "changed": False,
            "msg": "SNMP output malformed: expected multiples of 5 lines",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    section = parse_snmp_output(lines)
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "sensor item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": "Status: " + str(data["value"]),
        "data": {
            "state": data["state"],
            "metrics": {},
            "details": ""
        }
    }