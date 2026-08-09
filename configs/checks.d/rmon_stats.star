def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysOID.rc != 0:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        gate = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"],
            mutates=False,
        )
        if gate.rc != 0:
            return {"changed": False, "msg": "no RMON present",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.1.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RMON ports",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.2.1.16.1.1.1.1"
        ports = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if oid.startswith(base + "."):
                index = oid[len(base) + 1:]
                ports[index] = value
        out = []
        for index in sorted(ports.keys()):
            out.append({"item": index,
                        "params": {"discover": True},
                        "metrics": ["bcast", "mcast", "0-63b", "64-127b",
                                    "128-255b", "256-511b", "512-1023b",
                                    "1024-1518b"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oids = ["1", "6", "7", "14", "15", "16", "17", "18", "19"]
    fields = ["bcast", "mcast", "0-63b", "64-127b", "128-255b",
              "256-511b", "512-1023b", "1024-1518b"]
    base = ".1.3.6.1.2.1.16.1.1.1"
    stats = {}
    for i in range(len(oids)):
        oid = base + "." + oids[i] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no RMON stats for interface %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": ""}}
        val = res.stdout.strip()
        val = val.replace(" Packets", "").strip()
        stats[fields[i]] = int(val) if val.isdigit() else 0

    metrics = {}
    for metric in fields:
        metrics[metric] = stats[metric]

    parts = []
    for metric in fields:
        parts.append(metric + "=" + str(stats[metric]))
    summary = ", ".join(parts)
    return {"changed": False,
            "msg": "IF %s: %s" % (item, summary),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
def _rate(value_store, key, now, octets):
    prev = value_store.get(key)
    if prev == None or prev.get("t") == None or now == prev.get("t"):
        value_store[key] = {"t": now, "v": octets}
        return None
    dt = now - prev["t"]
    if dt <= 0:
        value_store[key] = {"t": now, "v": octets}
        return None
    rate = (octets - prev["v"]) / dt
    value_store[key] = {"t": now, "v": octets}
    return rate
def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysOID.rc != 0:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        gate = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"],
            mutates=False,
        )
        if gate.rc != 0:
            return {"changed": False, "msg": "no RMON present",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.1.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RMON ports",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.2.1.16.1.1.1.1"
        ports = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if oid.startswith(base + "."):
                index = oid[len(base) + 1:]
                ports[index] = value
        out = []
        for index in sorted(ports.keys()):
            out.append({"item": index,
                        "params": {"discover": True},
                        "metrics": ["bcast", "mcast", "0-63b", "64-127b",
                                    "128-255b", "256-511b", "512-1023b",
                                    "1024-1518b"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oids = ["1", "6", "7", "14", "15", "16", "17", "18", "19"]
    fields = ["bcast", "mcast", "0-63b", "64-127b", "128-255b",
              "256-511b", "512-1023b", "1024-1518b"]
    base = ".1.3.6.1.2.1.16.1.1.1"
    stats = {}
    for i in range(len(oids)):
        oid = base + "." + oids[i] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no RMON stats for interface %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": ""}}
        val = res.stdout.strip()
        val = val.replace(" Packets", "").strip()
        stats[fields[i]] = int(val) if val.isdigit() else 0

    metrics = {}
    for metric in fields:
        metrics[metric] = stats[metric]

    parts = []
    for metric in fields:
        parts.append(metric + "=" + str(stats[metric]))
    summary = ", ".join(parts)
    return {"changed": False,
            "msg": "IF %s: %s" % (item, summary),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
def _rate(value_store, key, now, octets):
    prev = value_store.get(key)
    if prev == None or prev.get("t") == None or now == prev.get("t"):
        value_store[key] = {"t": now, "v": octets}
        return None
    dt = now - prev["t"]
    if dt <= 0:
        value_store[key] = {"t": now, "v": octets}
        return None
    rate = (octets - prev["v"]) / dt
    value_store[key] = {"t": now, "v": octets}
    return rate
def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysOID.rc != 0:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        gate = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"],
            mutates=False,
        )
        if gate.rc != 0:
            return {"changed": False, "msg": "no RMON present",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.1.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RMON ports",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.2.1.16.1.1.1.1"
        ports = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if oid.startswith(base + "."):
                index = oid[len(base) + 1:]
                ports[index] = value
        out = []
        for index in sorted(ports.keys()):
            out.append({"item": index,
                        "params": {"discover": True},
                        "metrics": ["bcast", "mcast", "0-63b", "64-127b",
                                    "128-255b", "256-511b", "512-1023b",
                                    "1024-1518b"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oids = ["1", "6", "7", "14", "15", "16", "17", "18", "19"]
    fields = ["bcast", "mcast", "0-63b", "64-127b", "128-255b",
              "256-511b", "512-1023b", "1024-1518b"]
    base = ".1.3.6.1.2.1.16.1.1.1"
    stats = {}
    for i in range(len(oids)):
        oid = base + "." + oids[i] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no RMON stats for interface %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": ""}}
        val = res.stdout.strip()
        val = val.replace(" Packets", "").strip()
        stats[fields[i]] = int(val) if val.isdigit() else 0

    metrics = {}
    for metric in fields:
        metrics[metric] = stats[metric]

    parts = []
    for metric in fields:
        parts.append(metric + "=" + str(stats[metric]))
    summary = ", ".join(parts)
    return {"changed": False,
            "msg": "IF %s: %s" % (item, summary),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
def _rate(value_store, key, now, octets):
    prev = value_store.get(key)
    if prev == None or prev.get("t") == None or now == prev.get("t"):
        value_store[key] = {"t": now, "v": octets}
        return None
    dt = now - prev["t"]
    if dt <= 0:
        value_store[key] = {"t": now, "v": octets}
        return None
    rate = (octets - prev["v"]) / dt
    value_store[key] = {"t": now, "v": octets}
    return rate
def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysOID.rc != 0:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        gate = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"],
            mutates=False,
        )
        if gate.rc != 0:
            return {"changed": False, "msg": "no RMON present",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.1.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RMON ports",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.2.1.16.1.1.1.1"
        ports = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if oid.startswith(base + "."):
                index = oid[len(base) + 1:]
                ports[index] = value
        out = []
        for index in sorted(ports.keys()):
            out.append({"item": index,
                        "params": {"discover": True},
                        "metrics": ["bcast", "mcast", "0-63b", "64-127b",
                                    "128-255b", "256-511b", "512-1023b",
                                    "1024-1518b"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oids = ["1", "6", "7", "14", "15", "16", "17", "18", "19"]
    fields = ["bcast", "mcast", "0-63b", "64-127b", "128-255b",
              "256-511b", "512-1023b", "1024-1518b"]
    base = ".1.3.6.1.2.1.16.1.1.1"
    stats = {}
    for i in range(len(oids)):
        oid = base + "." + oids[i] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no RMON stats for interface %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": ""}}
        val = res.stdout.strip()
        val = val.replace(" Packets", "").strip()
        stats[fields[i]] = int(val) if val.isdigit() else 0

    metrics = {}
    for metric in fields:
        metrics[metric] = stats[metric]

    parts = []
    for metric in fields:
        parts.append(metric + "=" + str(stats[metric]))
    summary = ", ".join(parts)
    return {"changed": False,
            "msg": "IF %s: %s" % (item, summary),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
def _rate(value_store, key, now, octets):
    prev = value_store.get(key)
    if prev == None or prev.get("t") == None or now == prev.get("t"):
        value_store[key] = {"t": now, "v": octets}
        return None
    dt = now - prev["t"]
    if dt <= 0:
        value_store[key] = {"t": now, "v": octets}
        return None
    rate = (octets - prev["v"]) / dt
    value_store[key] = {"t": now, "v": octets}
    return rate
def main(ctx, params):
    if params.get("_discover"):
        sysOID = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysOID.rc != 0:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        gate = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"],
            mutates=False,
        )
        if gate.rc != 0:
            return {"changed": False, "msg": "no RMON present",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.2.1.16.1.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no RMON ports",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.2.1.16.1.1.1.1"
        ports = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if oid.startswith(base + "."):
                index = oid[len(base) + 1:]
                ports[index] = value
        out = []
        for index in sorted(ports.keys()):
            out.append({"item": index,
                        "params": {"discover": True},
                        "metrics": ["bcast", "mcast", "0-63b", "64-127b",
                                    "128-255b", "256-511b", "512-1023b",
                                    "1024-1518b"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oids = ["1", "6", "7", "14", "15", "16", "17", "18", "19"]
    fields = ["bcast", "mcast", "0-63b", "64-127b", "128-255b",
              "256-511b", "512-1023b", "1024-1518b"]
    base = ".1.3.6.1.2.1.16.1.1.1"
    stats = {}
    for i in range(len(oids)):
        oid = base + "." + oids[i] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no RMON stats for interface %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": ""}}
        val = res.stdout.strip()
        val = val.replace(" Packets", "").strip()
        stats[fields[i]] = int(val) if val.isdigit() else 0

    metrics = {}
    for metric in fields:
        metrics[metric] = stats[metric]

    parts = []
    for metric in fields:
        parts.append(metric + "=" + str(stats[metric]))
    summary = ", ".join(parts)
    return {"changed": False,
            "msg": "IF %s: %s" % (item, summary),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}