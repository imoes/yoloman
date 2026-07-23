def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2606.4.2"
        trees = ["3", "4", "5", "6"]
        status_items = []
        for tree in trees:
            oid_prefix = base_oid + "." + tree + ".5.2.1"
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                oid_prefix
            ], mutates=False)
            lines = res.stdout.splitlines()
            entries = []
            for line in lines:
                line = line.strip()
                if line == "":
                    continue
                parts = line.split(" = ")
                if len(parts) != 2:
                    continue
                oid_part, value_part = parts
                suffix = oid_part.rsplit(".", 1)
                if len(suffix) != 2:
                    continue
                try_idx_str = suffix[1]
                idx = int(try_idx_str) if try_idx_str.isdigit() else 0
                val_parts = value_part.split(": ")
                if len(val_parts) < 2:
                    continue
                val_str = ": ".join(val_parts[1:]).strip()
                entries.append((idx, val_str))
            sensors_by_idx = {}
            for i, val in entries:
                if i not in sensors_by_idx:
                    sensors_by_idx[i] = []
                sensors_by_idx[i].append(val)
            for i, fields in sensors_by_idx.items():
                if len(fields) < 7:
                    continue
                typeid, status, reading, high, low, warn, description = fields[:7]
                sensor_spec = _CMCTC_LCP_SENSORS.get(typeid)
                if sensor_spec == None:
                    continue
                if sensor_spec[1] != "status":
                    continue
                item = "%s - %s.%s" % (sensor_spec[0], tree, i) if sensor_spec[0] != None else "%s.%s" % (tree, i)
                status_items.append({
                    "item": item,
                    "params": {},
                    "metrics": ["status"]
                })
        return {"changed": False, "msg": "discovered %d status sensors" % len(status_items),
                "data": {"discovery": status_items}}

    item = params.get("item", "")
    tree_part = item
    if " - " in item:
        tree_part = item.rsplit(" - ", 1)[1]
    parts_tree = tree_part.split(".")
    if len(parts_tree) != 2:
        return {
            "changed": False,
            "msg": "sensor item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    tree = parts_tree[0]
    idx_str = parts_tree[1]
    idx = int(idx_str) if idx_str.isdigit() else 0
    base_oid = ".1.3.6.1.4.1.2606.4.2"
    oid_prefix = base_oid + "." + tree + ".5.2.1"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        oid_prefix
    ], mutates=False)
    lines = res.stdout.splitlines()
    entries = []
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        suffix = oid_part.rsplit(".", 1)
        if len(suffix) != 2:
            continue
        try_idx_str = suffix[1]
        i = int(try_idx_str) if try_idx_str.isdigit() else 0
        val_parts = value_part.split(": ")
        if len(val_parts) < 2:
            continue
        val_str = ": ".join(val_parts[1:]).strip()
        entries.append((i, val_str))
    sensors_by_idx = {}
    for i, val in entries:
        if i not in sensors_by_idx:
            sensors_by_idx[i] = []
        sensors_by_idx[i].append(val)
    target = sensors_by_idx.get(idx)
    if target == None or len(target) < 7:
        return {
            "changed": False,
            "msg": "sensor item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    typeid, status, reading, high, low, warn, description = target[:7]
    map_sensor_state = {
        "1": ("UNKNOWN", "not available"),
        "2": ("CRIT", "lost"),
        "3": ("WARN", "changed"),
        "4": ("OK", "ok"),
        "5": ("CRIT", "off"),
        "6": ("OK", "on"),
        "7": ("WARN", "warning"),
        "8": ("CRIT", "too low"),
        "9": ("CRIT", "too high"),
        "10": ("CRIT", "error"),
    }
    status_int = int(status) if status.isdigit() else 1
    state_text, extra_info = map_sensor_state.get(str(status_int), ("UNKNOWN", "unknown status"))
    infotext = ""
    if description != "" and description != None:
        infotext = "[%s] " % description
    reading_int = int(float(reading)) if reading.isdigit() or (reading.find(".") != -1 and reading.replace(".", "").replace("-", "").isdigit()) else 0
    unit = ""
    msg = "%s%d%s" % (infotext, reading_int, unit)
    if extra_info != "":
        msg = "%s (%s)" % (msg, extra_info)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_text,
            "metrics": {"status": reading_int},
            "details": ""
        }
    }


_CMCTC_LCP_SENSORS = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}