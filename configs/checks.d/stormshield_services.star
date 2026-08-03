def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.11256.1.7.1.1.2"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not found",
                    "data": {"discovery": [], "host_labels": {}}}
        base_oid = ".1.3.6.1.4.1.11256.1.7.1.1"
        cols = {
            "name": ".3",
            "state": ".2",
            "uptime": ".4",
        }
        # Build index -> name; query other columns by index.
        index_to_name = {}
        index_to_state = {}
        index_to_uptime = {}
        # Walk the name column; derive index from OID suffix.
        if res.rc == 0 and res.stdout:
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, value = parts
                if not oid.startswith(base_oid + cols["name"] + "."):
                    continue
                idx = oid[len(base_oid + cols["name"] + "0"):]
                if not idx:
                    continue
                if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
                    value = value[1:-1]
                index_to_name[idx] = value
        # Query state and uptime columns for each discovered index.
        for idx in index_to_name:
            sres = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            base_oid + cols["state"] + "." + idx], mutates=False)
            if sres.rc != 0 or not sres.stdout:
                index_to_state[idx] = ""
            else:
                index_to_state[idx] = sres.stdout.strip()
            ures = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            base_oid + cols["uptime"] + "." + idx], mutates=False)
            if ures.rc != 0 or not ures.stdout:
                index_to_uptime[idx] = 0
            else:
                uval = ures.stdout.strip()
                index_to_uptime[idx] = _to_int(uval)
        discovery = []
        for idx in sorted(index_to_name.keys()):
            st = index_to_state.get(idx, "")
            if st == "1":
                discovery.append({
                    "item": index_to_name[idx],
                    "params": {},
                    "metrics": ["uptime"],
                    "service_labels": {"state": st},
                })
        return {"changed": False,
                "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}
    # CHECK MODE
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no service item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Resolve the item's index from the name column walk.
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-Oqn", params.get("host", "localhost"),
                   ".1.3.6.1.4.1.11256.1.7.1.1.2"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    base_oid = ".1.3.6.1.4.1.11256.1.7.1.1"
    cols = {
        "name": ".3",
        "state": ".2",
        "uptime": ".4",
    }
    name_oid = base_oid + cols["name"]
    found_idx = ""
    if res.rc == 0 and res.stdout:
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts
            if not oid.startswith(name_oid + "."):
                continue
            idx = oid[len(name_oid + "0"):]
            if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
                value = value[1:-1]
            if value == item:
                found_idx = idx
                break
    if not found_idx:
        return {"changed": False, "msg": "service %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sres = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-Oqv", params.get("host", "localhost"),
                    base_oid + cols["state"] + "." + found_idx], mutates=False)
    st = ""
    if sres.rc == 0 and sres.stdout:
        st = sres.stdout.strip()
    ures = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-Oqv", params.get("host", "localhost"),
                    base_oid + cols["uptime"] + "." + found_idx], mutates=False)
    uptime = 0
    if ures.rc == 0 and ures.stdout:
        uptime = _to_int(ures.stdout.strip())
    state_label = _SERVICE_STATE_MAP.get(st, "")
    if state_label == "down":
        return {"changed": False,
                "msg": "Service %s is down" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if not state_label:
        return {"changed": False,
                "msg": "service %s in unknown state (%s)" % (item, st),
                "data": {"state": "UNKNOWN", "metrics": {"uptime": uptime}, "details": ""}}
    return {"changed": False,
            "msg": "Service %s is up, Uptime: %s" % (item, _render_uptime(uptime)),
            "data": {"state": "OK", "metrics": {"uptime": uptime}, "details": ""}}


def _to_int(v):
    s = str(v).strip()
    if not s:
        return 0
    neg = False
    start = 0
    if s[0] == "-":
        neg = True
        start = 1
    body = s[start:]
    if body and body.isdigit():
        n = 0
        for ch in body:
            n = n * 10 + (ord(ch) - 48)
        return -n if neg else n
    return 0


_SERVICE_STATE_MAP = {"0": "down", "1": "up"}


def _render_uptime(seconds):
    s = int(seconds)
    d = s // 86400
    h = (s % 86400) // 3600
    m = (s % 3600) // 60
    sec = s % 60
    if d > 0:
        return "%dd %dh %dm" % (d, h, m)
    if h > 0:
        return "%dh %dm %ds" % (h, m, sec)
    if m > 0:
        return "%dm %ds" % (m, sec)
    return "%ds" % sec