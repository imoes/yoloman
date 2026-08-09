def _combine_item(fan_id, fan_descr):
    if fan_descr == "" or "(RPM " in fan_descr:
        return fan_id
    return fan_id + " " + fan_descr

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.1991.1.1.1.3.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "no brocade mlx equipment detected",
                    "data": {"discovery": []}}
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            val = parts[1]
            index = oid[len(base + ".1") + 1:]
            if not index:
                continue
            rows[index] = {"id": val}
        for col, label in [(".2", "descr"), (".3", "state")]:
            colres = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + col], mutates=False)
            if colres.rc == 0:
                for line in colres.stdout.splitlines():
                    parts = line.split(" ", 1)
                    if len(parts) != 2:
                        continue
                    oid = parts[0]
                    val = parts[1]
                    index = oid[len(base + col) + 1:]
                    if index in rows:
                        rows[index][label] = val
        discovery = []
        for index in sorted(rows.keys()):
            r = rows[index]
            fan_id = r.get("id", "")
            fan_descr = r.get("descr", "")
            fan_state = r.get("state", "1")
            if fan_state != "1":
                discovery.append({"item": _combine_item(fan_id, fan_descr),
                                  "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d fan(s)" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.1991.1.1.1.3.1.1"
    found = None
    for col in ["1", "2", "3"]:
        colres = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + col], mutates=False)
        if colres.rc != 0:
            return {"changed": False, "msg": "no brocade mlx equipment detected",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        for line in colres.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            val = parts[1]
            index = oid[len(base + "." + col) + 1:]
            if found == None:
                found = {}
            if index not in found:
                found[index] = {}
            if col == "1":
                found[index]["id"] = val
            elif col == "2":
                found[index]["descr"] = val
            elif col == "3":
                found[index]["state"] = val
    if found == None or len(found) == 0:
        return {"changed": False, "msg": "Fan not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    target = None
    for index in found:
        r = found[index]
        fan_id = r.get("id", "")
        fan_descr = r.get("descr", "")
        if _combine_item(fan_id, fan_descr) == item:
            target = r
            break
    if target == None:
        return {"changed": False, "msg": "Fan not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fan_state = target.get("state", "1")
    if fan_state == "2":
        return {"changed": False, "msg": "Fan reports state: normal",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if fan_state == "3":
        return {"changed": False, "msg": "Fan reports state: failure",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if fan_state == "1":
        return {"changed": False, "msg": "Fan reports state: other",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "Fan reports an unhandled state (%s)" % fan_state,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}