def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.1271.2.3.1.2"
        col_name = base + ".2.1.1.2"
        col_tx = base + ".3.2.2.1.15"
        col_rx = base + ".3.2.2.1.13"

        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.rc != 0:
            return {"changed": False, "msg": "no Ciena device found", "data": {"discovery": []}}
        sysoid = sysoid_res.stdout.strip()

        is_ciena = sysoid.startswith(".1.3.6.1.4.1.1271.1.2.11") or sysoid.startswith(".1.3.6.1.4.1.6141.1.96")
        if not is_ciena:
            return {"changed": False, "msg": "no Ciena device found", "data": {"discovery": []}}

        desc_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if desc_res.rc != 0:
            return {"changed": False, "msg": "no Ciena device found", "data": {"discovery": []}}
        if "5171" not in desc_res.stdout:
            return {"changed": False, "msg": "no Ciena 5171 device found", "data": {"discovery": []}}

        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Osn", "-1", col_name],
            mutates=False,
        )
        if walk_res.rc != 0:
            return {"changed": False, "msg": "no routing instances found", "data": {"discovery": []}}

        tx_map = {}
        rx_map = {}
        tx_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Osn", "-1", col_tx],
            mutates=False,
        )
        if tx_walk.rc == 0:
            for line in tx_walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts[0], parts[1]
                idx = oid[len(col_tx) + 1:]
                tx_map[idx] = val

        rx_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Osn", "-1", col_rx],
            mutates=False,
        )
        if rx_walk.rc == 0:
            for line in rx_walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts[0], parts[1]
                idx = oid[len(col_rx) + 1:]
                rx_map[idx] = val

        out = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, name_val = parts[0], parts[1]
            idx = oid[len(col_name) + 1:]
            name = name_val.strip().strip('"')
            tx = tx_map.get(idx, "")
            rx = rx_map.get(idx, "")
            if tx and rx:
                entry = {
                    "item": name,
                    "params": {},
                    "metrics": ["if_out_octets", "if_in_octets"],
                }
                out.append(entry)

        return {
            "changed": False,
            "msg": "discovered %d routing instances" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    instance = _lookup_instance(ctx, host, community, item)
    if instance == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    tx = instance["transmitted"]
    rx = instance["received"]
    state = _grade_bandwidth(tx, params.get("tx_warn"), params.get("tx_crit"))
    rx_state = _grade_bandwidth(rx, params.get("rx_warn"), params.get("rx_crit"))
    final_state = _worst_state([state, rx_state])

    msg = "Transmitted: %s, Received: %s" % (_format_bw(tx), _format_bw(rx))
    details = "Routing instance: %s\nTransmitted: %d bytes/sec\nReceived: %d bytes/sec" % (item, tx, rx)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": {"if_out_octets": tx, "if_in_octets": rx},
            "details": details,
        },
    }


def _lookup_instance(ctx, host, community, item):
    base = ".1.3.6.1.4.1.1271.2.3.1.2"
    col_name = base + ".2.1.1.2"
    col_tx = base + ".3.2.2.1.15"
    col_rx = base + ".3.2.2.1.13"

    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc != 0:
        return None
    sysoid = sysoid_res.stdout.strip()
    is_ciena = sysoid.startswith(".1.3.6.1.4.1.1271.1.2.11") or sysoid.startswith(".1.3.6.1.4.1.6141.1.96")
    if not is_ciena:
        return None

    desc_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if desc_res.rc != 0:
        return None
    if "5171" not in desc_res.stdout:
        return None

    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Osn", "-1", col_name],
        mutates=False,
    )
    if walk_res.rc != 0:
        return None

    target_idx = None
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, name_val = parts[0], parts[1]
        idx = oid[len(col_name) + 1:]
        name = name_val.strip().strip('"')
        if name == item:
            target_idx = idx
            break

    if target_idx == None:
        return None

    tx_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, col_tx + "." + target_idx],
        mutates=False,
    )
    if tx_res.rc != 0:
        return None
    tx = _to_int(tx_res.stdout.strip())

    rx_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, col_rx + "." + target_idx],
        mutates=False,
    )
    if rx_res.rc != 0:
        return None
    rx = _to_int(rx_res.stdout.strip())

    if tx == None or rx == None:
        return None

    return {"transmitted": tx, "received": rx}


def _to_int(s):
    if s == "" or s == None:
        return None
    if s.isdigit():
        return int(s)
    neg = s.startswith("-")
    if neg and s[1:].isdigit():
        return int(s)
    return None


def _grade_bandwidth(value, warn, crit):
    if warn == None and crit == None:
        return "OK"
    state = "OK"
    if crit != None and value >= int(crit):
        state = "CRIT"
    elif warn != None and value >= int(warn):
        if state != "CRIT":
            state = "WARN"
    return state


def _worst_state(states):
    worst = "OK"
    for s in states:
        if s == "CRIT":
            return "CRIT"
        if s == "WARN" and worst != "CRIT":
            worst = "WARN"
        if s == "UNKNOWN" and worst == "OK":
            worst = "UNKNOWN"
    return worst


def _format_bw(b):
    return str(b) + " B/s"