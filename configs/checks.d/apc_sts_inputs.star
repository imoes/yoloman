def main(ctx, params):
    if params.get("_discover"):
        base1 = ".1.3.6.1.4.1.705.2.3.2.1"
        base2 = ".1.3.6.1.4.1.705.2.4.2.1"
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), base1 + ".2"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), base2 + ".2"], mutates=False)
        if res1.rc == 127 or res2.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if res1.rc != 0 or res2.rc != 0:
            return {"changed": False, "msg": "SNMP query failed",
                    "data": {"discovery": [], "host_labels": {}}}
        sysdesc = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                           "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysdesc.rc != 0:
            return {"changed": False, "msg": "SNMP not available",
                    "data": {"discovery": [], "host_labels": {}}}
        sysval = sysdesc.stdout.strip().strip('"')
        if not sysval.startswith(".1.3.6.1.4.1.705.2.2"):
            return {"changed": False, "msg": "Not an APC STS device",
                    "data": {"discovery": [], "host_labels": {}}}
        sources = {}
        for res, base in [(res1, base1), (res2, base2)]:
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts
                idx = oid[len(base) + 1:]
                src = "1" if base == base1 else "2"
                if src not in sources:
                    sources[src] = {}
                if idx not in sources[src]:
                    sources[src][idx] = {}
                if oid.endswith(".2"):
                    sources[src][idx]["voltage"] = val
                elif oid.endswith(".3"):
                    sources[src][idx]["current"] = val
                elif oid.endswith(".4"):
                    sources[src][idx]["power"] = val
        discovery = []
        for src in sorted(sources.keys()):
            for phs in sorted(sources[src].keys(), key=lambda x: int(x)):
                item = "Source %s Phase %s" % (src, phs)
                discovery.append({"item": item, "params": {}, "metrics": ["voltage", "current", "power"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}
    item = params.get("item", "")
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                    "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.705.2.3.2.1.2"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                    "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.705.2.4.2.1.2"], mutates=False)
    if res1.rc != 0 or res2.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    base1 = ".1.3.6.1.4.1.705.2.3.2.1"
    base2 = ".1.3.6.1.4.1.705.2.4.2.1"
    idx = item.split("Phase ")[1] if "Phase " in item else ""
    src = item.split("Source ")[1].split(" ")[0] if "Source " in item else ""
    if src == "1":
        base = base1
        res_v = res1
    else:
        base = base2
        res_v = res2
    voltage = None
    current = None
    power = None
    for res in [res_v, ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                                "-Oqn", params.get("host", "localhost"), base + ".3"], mutates=False),
                ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-Oqn", params.get("host", "localhost"), base + ".4"], mutates=False)]:
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            oididx = oid[len(base) + 1:]
            suffix = oid[len(base):]
            if oididx == idx and suffix == ".2":
                voltage = int(val) / 10.0
            elif oididx == idx and suffix == ".3":
                current = int(val) / 10.0
            elif oididx == idx and suffix == ".4":
                power = int(val)
    if voltage == None and current == None and power == None:
        return {"changed": False, "msg": "Input %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = {}
    if voltage != None:
        metrics["voltage"] = voltage
    if current != None:
        metrics["current"] = current
    if power != None:
        metrics["power"] = power
    msg = "Input %s: %s" % (item, "voltage=%s current=%s power=%s" %
                           (_fmt(voltage), _fmt(current), _fmt(power)))
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": ""}}

def _fmt(v):
    if v == None:
        return "n/a"
    return str(v)