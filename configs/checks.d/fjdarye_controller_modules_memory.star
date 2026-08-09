def main(ctx, params):
    if params.get("_discover"):
        if not _fjdarye_present(ctx):
            return {"changed": False, "msg": "no FJDARY-E device found",
                    "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c",
                       "-c", params.get("community", "public"),
                       "-Oqn", "-OQ",
                       params.get("host", "localhost"),
                       ".1.3.6.1.4.1.211.1.21.1.1.60.2.3.2.1.1"],
                      mutates=False)
        items = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            oid = f[0]
            idx = _index_from_oid(oid, "1.3.6.1.4.1.211.1.21.1.1.60.2.3.2.1.1")
            if idx == "":
                continue
            st = _read_status(ctx, params, "1.3.6.1.4.1.211.1.21.1.1.60.2.3.2.1.3", idx)
            if st != "4":
                items.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    st = _read_status(ctx, params, _status_base(ctx, params), item)
    if st == "":
        return {"changed": False, "msg": "no such controller module: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": _status_msg(st),
            "data": {"state": _status_state(st), "metrics": {}, "details": ""}}


def _fjdarye_present(ctx):
    res = ctx.run(["snmpget", "-v2c",
                   "-c", "public", "-Oqv",
                   "localhost", ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    for oid in [".1.3.6.1.4.1.211.1.21.1.60",
                ".1.3.6.1.4.1.211.1.21.1.100",
                ".1.3.6.1.4.1.211.1.21.1.101",
                ".1.3.6.1.4.1.211.1.21.1.150",
                ".1.3.6.1.4.1.211.1.21.1.153"]:
        if val == oid:
            return True
    return False


def _detect_base(ctx, params):
    res = ctx.run(["snmpget", "-v2c",
                   "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc == 127 or res.rc != 0:
        return ""
    val = res.stdout.strip()
    if val in [".1.3.6.1.4.1.211.1.21.1.60",
               ".1.3.6.1.4.1.211.1.21.1.100",
               ".1.3.6.1.4.1.211.1.21.1.101"]:
        return "1.3.6.1.4.1.211.1.21.1.1.60"
    if val in [".1.3.6.1.4.1.211.1.21.1.150",
               ".1.3.6.1.4.1.211.1.21.1.153"]:
        return "1.3.6.1.4.1.211.1.21.1.1.150"
    return ""


def _status_base(ctx, params):
    base = _detect_base(ctx, params)
    if base == "1.3.6.1.4.1.211.1.21.1.1.60":
        return "1.3.6.1.4.1.211.1.21.1.1.60.2.3.2.1.3"
    return "1.3.6.1.4.1.211.1.21.1.1.150.2.4.2.1.3"


def _read_status(ctx, params, base_oid, idx):
    full = base_oid + "." + idx
    res = ctx.run(["snmpget", "-v2c",
                   "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), full],
                  mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _index_from_oid(oid, col_base):
    col_base = "." + col_base + "."
    if oid.startswith(col_base):
        return oid[len(col_base):]
    return ""


def _status_msg(st):
    msgs = {"1": "Normal", "2": "Alarm", "3": "Warning",
            "4": "Invalid", "5": "Maintenance", "6": "Undefined"}
    return msgs.get(st, "Unknown")


def _status_state(st):
    states = {"1": "OK", "2": "CRIT", "3": "WARN",
              "4": "CRIT", "5": "CRIT", "6": "CRIT"}
    return states.get(st, "UNKNOWN")