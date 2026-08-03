def _split_line(line):
    idx = line.find(" ")
    if idx == -1:
        return "", ""
    return line[:idx], line[idx + 1:]

def _get_suffix_oid(base, col, idx):
    return base + "." + col + "." + idx

def main(ctx, params):
    base = ".1.3.6.1.4.1.37954"
    oids = ["2.1.3.1", "3.1.2.1"]
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc != 0 or not sysoid_res.stdout.startswith(".1.3.6.1.4.1.332.11.6"):
        return {"changed": False, "msg": "Kentix device not detected",
                "data": {"discovery": []}}

    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + oids[0]],
        mutates=False,
    )
    if walk_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no kentix dewpoint data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = {}
    for line in walk_res.stdout.splitlines():
        oid, val = _split_line(line)
        if not oid or not val:
            continue
        idx = oid[len(base + "." + oids[0]):]
        if not idx:
            continue
        rows[idx] = {"lan": val}

    if not rows:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no kentix dewpoint data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    for idx in list(rows.keys()):
        r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             _get_suffix_oid(base, oids[1], idx)],
            mutates=False,
        )
        if r.rc == 0:
            rows[idx]["rack"] = r.stdout.strip()

    warn = params.get("warn", 28.0)
    crit = params.get("crit", 30.0)
    p = params.get("levels")
    w = warn
    c = crit
    if p and len(p) >= 2:
        w = p[0]
        c = p[1]

    if params.get("_discover"):
        discovery = []
        for idx in rows:
            vals = rows[idx]
            lan = vals.get("lan", "")
            rack = vals.get("rack", "")
            for sub, val in [("LAN", lan), ("Rack", rack)]:
                if val and val not in ("NOSUCHOBJECT", "NOSUCHINSTANCE"):
                    item = sub + "/" + idx
                    discovery.append({"item": item,
                                      "params": {"warn": w, "crit": c},
                                      "metrics": ["dewpoint"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    idx = item
    for sub in ["LAN", "Rack"]:
        prefix = sub + "/"
        if item.startswith(prefix):
            idx = item[len(prefix):]
            break

    vals = rows.get(idx, {})
    reading = None
    which = ""
    for sub, key in [("LAN", "lan"), ("Rack", "rack")]:
        v = vals.get(key, "")
        if v and v not in ("NOSUCHOBJECT", "NOSUCHINSTANCE"):
            reading = float(v) / 10.0
            which = sub
            break

    if reading == None:
        return {"changed": False,
                "msg": "no dewpoint reading for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if reading >= c:
        state = "CRIT"
    elif reading >= w:
        state = "WARN"

    metrics = {"dewpoint": reading}
    return {"changed": False,
            "msg": "%s %s: %f C" % (which, item, reading),
            "data": {"state": state, "metrics": metrics,
                     "details": "Dewpoint reading for " + item}}