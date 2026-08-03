def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ".1.3.6.1.2.1.1.2.0"
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"), sys_oid,
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            if res.rc == 127:
                return {"changed": False, "msg": "snmpget not installed",
                        "data": {"discovery": []}}
            return {"changed": False, "msg": "device not detected (no sysObjectID)",
                    "data": {"discovery": []}}
        sys_oid_val = res.stdout.strip()
        if not sys_oid_val.startswith(".1.3.6.1.4.1.476.1.42"):
            return {"changed": False, "msg": "not a Liebert device",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        labels_oid = base + ".10.1.2.1"
        values_oid = base + ".20.1.2.1"
        labels_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"), labels_oid,
        ], mutates=False)
        if labels_res.rc != 0 or not labels_res.stdout:
            return {"changed": False, "msg": "no Liebert system data",
                    "data": {"discovery": []}}

        values_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"), values_oid,
        ], mutates=False)
        if values_res.rc != 0:
            values_res = None

        label_map = {}
        for line in labels_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            if not oid.startswith(labels_oid + "."):
                continue
            suffix = oid[len(labels_oid) + 1:]
            label_map[suffix] = val.strip().strip('"')

        value_map = {}
        if values_res:
            for line in values_res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts
                if not oid.startswith(values_oid + "."):
                    continue
                suffix = oid[len(values_oid) + 1:]
                value_map[suffix] = val.strip().strip('"')

        section = {}
        for suffix, label in label_map.items():
            if not label:
                continue
            val = value_map.get(suffix, "")
            section[label] = val if val else ""

        model = section.get("System Model Number")
        if model:
            return {"changed": False, "msg": "discovered 1 Liebert system",
                    "data": {"discovery": [
                        {"item": model, "params": {},
                         "metrics": []},
                    ]}}

        return {"changed": False, "msg": "no Liebert system model found",
                "data": {"discovery": []}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    labels_oid = base + ".10.1.2.1"
    values_oid = base + ".20.1.2.1"

    labels_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"), labels_oid,
    ], mutates=False)
    if labels_res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if labels_res.rc != 0 or not labels_res.stdout:
        return {"changed": False, "msg": "no Liebert system data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"), values_oid,
    ], mutates=False)

    label_map = {}
    for line in labels_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts
        if not oid.startswith(labels_oid + "."):
            continue
        suffix = oid[len(labels_oid) + 1:]
        label_map[suffix] = val.strip().strip('"')

    value_map = {}
    if values_res and values_res.rc == 0 and values_res.stdout:
        for line in values_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            if not oid.startswith(values_oid + "."):
                continue
            suffix = oid[len(values_oid) + 1:]
            value_map[suffix] = val.strip().strip('"')

    section = {}
    for suffix, label in label_map.items():
        if not label:
            continue
        val = value_map.get(suffix, "")
        section[label] = val if val else ""

    model = section.get("System Model Number")
    if not model:
        return {"changed": False, "msg": "no Liebert system found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item and item != model:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    details = []
    for key in sorted(section.keys()):
        value = section[key]
        if key == "System Status" and "Normal Operation" not in value:
            state = "CRIT"
            details.append(key + ": " + value)
        else:
            details.append(key + ": " + value)

    return {"changed": False, "msg": "\n".join(details),
            "data": {"state": state, "metrics": {}, "details": ""}}