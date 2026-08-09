_rate_store = {}


def _oid_suffix(oid, base):
    if oid.startswith(base + "."):
        return oid[len(base) + 1:]
    return ""


def _parse_value(raw):
    val = raw
    idx = val.find(": ")
    if idx != -1:
        val = val[idx + 2:]
    val = val.strip()
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        val = val[1:-1]
    return val


def _is_aironet(ctx, params):
    res = ctx.run(
        [
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Ovqn", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return False
    sysid = _parse_value(res.stdout)
    valid = [
        ".1.3.6.1.4.1.9.1.525", ".1.3.6.1.4.1.9.1.618", ".1.3.6.1.4.1.9.1.685",
        ".1.3.6.1.4.1.9.1.758", ".1.3.6.1.4.1.9.1.1034", ".1.3.6.1.4.1.9.1.1247",
    ]
    return sysid in valid


def _walk_radios(ctx, params):
    base = ".1.3.6.1.4.1.9.9.272.1.2.1.1.1"
    res = ctx.run(
        [
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"), base,
        ],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return []
    radios = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1].strip()
        suffix = _oid_suffix(oid, base)
        idx_parts = suffix.split(".")
        if len(idx_parts) < 2:
            continue
        radio_index = idx_parts[1]
        radios.append({"index": radio_index, "errors": val})
    return radios


def _get_rate(key, now, value, store):
    prev = store.get(key, None)
    if prev == None:
        store[key] = {"t": now, "v": value}
        return 0.0
    elapsed = now - prev["t"]
    if elapsed <= 0:
        return 0.0
    rate = float(value - prev["v"]) / elapsed
    store[key] = {"t": now, "v": value}
    return rate


def _time_now(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    ts = res.stdout.strip()
    if ts.isdigit():
        return int(ts)
    return 0


def main(ctx, params):
    if params.get("_discover"):
        if not _is_aironet(ctx, params):
            return {
                "changed": False,
                "msg": "not an Aironet device",
                "data": {"discovery": []},
            }
        radios = _walk_radios(ctx, params)
        if not radios:
            return {
                "changed": False,
                "msg": "no radios found",
                "data": {"discovery": []},
            }
        discovery = []
        for r in radios:
            discovery.append({
                "item": r["index"],
                "params": {},
                "metrics": ["errors"],
            })
        return {
            "changed": False,
            "msg": "discovered %d radios" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _is_aironet(ctx, params):
        return {
            "changed": False,
            "msg": "not an Aironet device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    radios = _walk_radios(ctx, params)
    if not radios:
        return {
            "changed": False,
            "msg": "no radios found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found = False
    err_val = "0"
    for r in radios:
        if r["index"] == item:
            found = True
            err_val = r["errors"]
            break
    if not found:
        return {
            "changed": False,
            "msg": "no such radio: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    err_int = 0
    if err_val.isdigit():
        err_int = int(err_val)

    now = _time_now(ctx)
    rate_key = "aironet_errors." + str(item)
    rate = _get_rate(rate_key, now, err_int, _rate_store)

    warn = 1.0
    crit = 10.0
    state = "CRIT" if rate >= crit else ("WARN" if rate >= warn else "OK")
    return {
        "changed": False,
        "msg": "MAC CRC errors radio %s: %f Errors/s" % (str(item), rate),
        "data": {
            "state": state,
            "metrics": {"errors": rate},
            "details": "",
        },
    }