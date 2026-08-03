def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1"],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "host not an Alcatel AOS7 device",
                    "data": {"discovery": [], "host_labels": {}}}

        boards = ["CPMA", "CFMA", "CPMB", "CFMB", "CFMC", "CFMD",
                  "FTA", "FTB",
                  "NI1", "NI2", "NI3", "NI4", "NI5", "NI6", "NI7", "NI8"]
        values = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            raw = parts[1]
            base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1."
            suffix = oid_part[len(base_oid):]
            if not suffix.isdigit():
                continue
            i = int(suffix)
            if i >= 8 and i <= 23 and i - 8 < len(boards):
                board = boards[i - 8]
                cleaned = raw.split(":")[0].strip().strip('"')
                if cleaned != "" and cleaned.lstrip("-").isdigit():
                    v = int(cleaned)
                    if v != 0:
                        values[board] = v

        out = []
        for b in boards:
            if b in values:
                out.append({"item": b, "params": {"levels": (45.0, 50.0)},
                            "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d temperature boards" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/os_family": "network"}}}

    item = params.get("item", "")
    boards = ["CPMA", "CFMA", "CPMB", "CFMB", "CFMC", "CFMD",
              "FTA", "FTB",
              "NI1", "NI2", "NI3", "NI4", "NI5", "NI6", "NI7", "NI8"]

    if item not in boards:
        return {"changed": False, "msg": "unknown board item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = boards.index(item) + 8
    oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1.%d" % idx
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), oid],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "snmp not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "no temperature for board %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip().strip('"')
    if raw == "" or not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "cannot parse temperature for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = float(int(raw))
    levels = params.get("levels", (45.0, 50.0))
    warn = levels[0] if type(levels) == "list" or type(levels) == "tuple" else 45.0
    crit = levels[1] if type(levels) == "list" or type(levels) == "tuple" else 50.0

    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Temperature Board %s: %f C" % (item, reading),
            "data": {"state": state, "metrics": {"temperature": reading},
                     "details": ""}}