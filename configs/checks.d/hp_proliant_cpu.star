def _sanitize_item(item):
    return item.replace("\x00", "\\x00")

def main(ctx, params):
    if params.get("_discover"):
        # Verify this is an HPE ProLiant / StoreEasy / Synergy system via the product name OID.
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.232.2.2.4.2.0"],
            mutates=False,
        )
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "not an HPE ProLiant/StoreEasy/Synergy system",
                    "data": {"discovery": []}}
        product = res.stdout.strip().strip('"').lower()
        is_hpe = False
        for kw in ("proliant", "storeeasy", "synergy"):
            if kw in product:
                is_hpe = True
                break
        if not is_hpe:
            return {"changed": False, "msg": "not an HPE ProLiant/StoreEasy/Synergy system",
                    "data": {"discovery": []}}

        # Walk the CPU status table: base .1.3.6.1.4.1.232.1.2.2.1.1, columns 1,2,3,6.
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-On", params.get("host", "localhost"),
             ".1.3.6.1.4.1.232.1.2.2.1.1.1"],
            mutates=False,
        )
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "no HPE ProLiant CPU entries found",
                    "data": {"discovery": []}}

        rows = {}
        col_base = ".1.3.6.1.4.1.232.1.2.2.1.1"
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(col_base) + 1:]
            if idx not in rows:
                rows[idx] = {}
            rows[idx]["1"] = val

        res2 = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-On", params.get("host", "localhost"),
             col_base + ".2"],
            mutates=False,
        )
        if res2.stdout != "":
            for line in res2.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                idx = oid[len(col_base) + 1:]
                if idx in rows:
                    rows[idx]["2"] = val

        res3 = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-On", params.get("host", "localhost"),
             col_base + ".3"],
            mutates=False,
        )
        if res3.stdout != "":
            for line in res3.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                idx = oid[len(col_base) + 1:]
                if idx in rows:
                    rows[idx]["3"] = val

        res6 = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-On", params.get("host", "localhost"),
             col_base + ".6"],
            mutates=False,
        )
        if res6.stdout != "":
            for line in res6.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                idx = oid[len(col_base) + 1:]
                if idx in rows:
                    rows[idx]["6"] = val

        out = []
        for idx in sorted(rows.keys()):
            r = rows[idx]
            if "1" not in r or "2" not in r or "3" not in r or "6" not in r:
                continue
            name = _sanitize_item(r["3"])
            out.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d HPE ProLiant CPU entries" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE
    item = params.get("item", "")

    # Product-name detection
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.232.2.2.4.2.0"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "not an HPE ProLiant/StoreEasy/Synergy system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get the index for this item by walking column 3 (name)
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-On", params.get("host", "localhost"),
         ".1.3.6.1.4.1.232.1.2.2.1.1.3"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no CPU data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    col_base = ".1.3.6.1.4.1.232.1.2.2.1.1"
    target_idx = None
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip().strip('"')
        idx = oid[len(col_base) + 1:]
        if _sanitize_item(val) == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "no CPU entry found for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_map = {
        "1": "unknown",
        "2": "ok",
        "3": "degraded",
        "4": "failed",
        "5": "disabled",
    }
    state_map = {
        "unknown": "UNKNOWN",
        "other": "UNKNOWN",
        "ok": "OK",
        "degraded": "CRIT",
        "failed": "CRIT",
        "disabled": "WARN",
    }

    def _get(oid_suffix):
        r = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             col_base + "." + oid_suffix + "." + target_idx],
            mutates=False,
        )
        if r.rc != 0:
            return ""
        return r.stdout.strip()

    index_v = _get("1")
    slot = _get("2")
    name = _get("3")
    status_str = _get("6")

    if status_str == "":
        return {"changed": False, "msg": "no CPU status found for index " + str(target_idx),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    snmp_status = status_map.get(status_str, "unknown")
    state = state_map.get(snmp_status, "UNKNOWN")
    summary = 'CPU%s "%s" in slot %s is in state "%s"' % (index_v, name, slot, snmp_status)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}