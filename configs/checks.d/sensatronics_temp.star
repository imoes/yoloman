def main(ctx, params):
    if params.get("_discover"):
        sysoid = ".1.3.6.1.4.1.16174.1.1.1"
        sysodesc = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if sysodesc.rc != 0 or sysodesc.stdout.strip() != sysoid:
            return {"changed": False, "msg": "sensatronics device not found",
                    "data": {"discovery": []}}
        sensors = {}
        for table in range(16):
            res = ctx.run([
                "snmpwalk", "-v2c",
                "-c", params.get("community", "public"),
                "-Oqn",
                params.get("host", "localhost"),
                sysoid + ".3." + str(table),
            ], mutates=False)
            if res.rc != 0:
                continue
            name = None
            value = None
            for line in res.stdout.splitlines():
                p = line.find(" ")
                if p < 0:
                    continue
                oid = line[:p]
                suffix = oid[len(sysoid + ".3." + str(table)) + 1:]
                v = line[p + 1:]
                if suffix == "1.0":
                    name = v.strip().strip('"')
                elif suffix == "2.0":
                    value = v.strip()
            if name != None and value != None:
                sensors[name] = float(value) if _is_num(value) else value
        out = []
        for name in sensors:
            out.append({"item": name,
                        "params": {"levels": (23.0, 25.0)},
                        "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out,
                         "host_labels": {"cmk/os_family": "sensatronics"}}}
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqn",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.16174.1.1.1.3.0",
    ], mutates=False)
    reading = None
    if res.rc == 0:
        for line in res.stdout.splitlines():
            p = line.find(" ")
            if p < 0:
                continue
            oid = line[:p]
            suffix = oid[len(".1.3.6.1.4.1.16174.1.1.1.3.0") + 1:]
            v = line[p + 1:]
            if suffix == "1.0":
                name = v.strip().strip('"')
                if name == item:
                    pass
            elif suffix == "2.0":
                if name == item:
                    reading = float(v.strip()) if _is_num(v.strip()) else None
    if reading == None:
        return {"changed": False,
                "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (23.0, 25.0))
    warn = levels[0] if len(levels) > 0 else 23.0
    crit = levels[1] if len(levels) > 1 else 25.0
    state = "OK"
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "Temperature %s: %f C" % (item, reading),
            "data": {"state": state,
                     "metrics": {"temperature": reading},
                     "details": "warn=%f crit=%f" % (warn, crit)}}

def _is_num(s):
    if s == None or s == "":
        return False
    neg = False
    i = 0
    if s[0] == "-":
        neg = True
        i = 1
    elif s[0] == "+":
        i = 1
    digits = False
    dot = False
    # BY INDEX: a Starlark string is NOT iterable, so `for c in s[i:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_c in range(i, len(s)):
        c = s[_i_c]
        if c >= "0" and c <= "9":
            digits = True
        elif c == "." and not dot:
            dot = True
        else:
            return False
    return digits