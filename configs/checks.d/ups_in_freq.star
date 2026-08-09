def main(ctx, params):
    base_oid = ".1.3.6.1.2.1.33.1.3.3.1.2"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not found", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            raw = line[sp + 1:]
            suffix = oid[len(base_oid) + 1:]
            if not suffix:
                continue
            if raw in ("", "NOSUCHOBJECT", "NOSUCHINSTANCE", "ENDOFMIBVIEW"):
                continue
            freq = int(raw) / 10.0 if raw.lstrip("-").isdigit() else 0
            if freq > 0:
                out.append({
                    "item": suffix,
                    "params": {"levels_lower": params.get("levels_lower", (45, 40))},
                    "metrics": ["in_freq"],
                })
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + "." + item],
        mutates=False,
    )
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "phase %s: no data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if not raw or raw in ("NOSUCHOBJECT", "NOSUCHINSTANCE", "ENDOFMIBVIEW"):
        return {
            "changed": False,
            "msg": "phase %s: no frequency data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if raw.lstrip("-").isdigit():
        freq = int(raw) / 10.0
    else:
        return {
            "changed": False,
            "msg": "phase %s: unparseable value %s" % (item, raw),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    warn, crit = params.get("levels_lower", (45, 40))
    if freq < crit:
        state = "CRIT"
    elif freq < warn:
        state = "WARN"
    else:
        state = "OK"

    infotext = "%f Hz" % freq
    if state != "OK":
        infotext += " (warn/crit below %f Hz/%f Hz)" % (warn, crit)

    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": state, "metrics": {"in_freq": freq}, "details": ""},
    }