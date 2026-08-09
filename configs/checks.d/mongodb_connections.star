UNKNOWN_DATA = {"state": "UNKNOWN", "metrics": {}, "details": ""}

def _query_mongodb(ctx, host, port, username, password):
    cmd = ["mongosh", "--host", host, "--port", str(port), "--quiet"]
    if username != None:
        cmd.append("--username")
        cmd.append(username)
    if password != None:
        cmd.append("--password")
        cmd.append(password)
    cmd.append("--eval")
    cmd.append("JSON.stringify(db.adminCommand({serverStatus: 1}).connections)")
    return ctx.run(cmd, mutates=False, ok_codes=[0, 1])

def _parse_connections(stdout):
    start = stdout.find("{")
    end = stdout.rfind("}")
    if start < 0 or end < 0 or (end <= start):
        return None
    return json.decode(stdout[start:end + 1])

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 27017)
    username = params.get("username")
    password = params.get("password")

    if params.get("_discover"):
        res = _query_mongodb(ctx, host, port, username, password)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = _parse_connections(res.stdout)
        if data == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {
                    "item": "Connections",
                    "params": {"levels_perc": [80.0, 90.0]},
                    "metrics": ["connections", "used_percent"],
                }
            ]},
        }

    res = _query_mongodb(ctx, host, port, username, password)
    if res.rc != 0:
        return {"changed": False,
                "msg": "cannot reach MongoDB at %s:%s" % (host, port),
                "data": UNKNOWN_DATA}
    if not res.stdout.strip():
        return {"changed": False, "msg": "no output from mongosh",
                "data": UNKNOWN_DATA}

    data = _parse_connections(res.stdout)
    if data == None:
        return {"changed": False, "msg": "cannot parse MongoDB connections output",
                "data": UNKNOWN_DATA}

    current = data.get("current")
    available = data.get("available")
    total_created = data.get("totalCreated")

    if current == None or available == None:
        return {"changed": False, "msg": "missing fields in MongoDB connections data",
                "data": UNKNOWN_DATA}

    current = int(current)
    available = int(available)
    maximum = current + available

    if maximum == 0:
        return {"changed": False, "msg": "maximum connections is zero",
                "data": UNKNOWN_DATA}

    used_perc = float(current) / float(maximum) * 100.0

    levels_abs = params.get("levels_abs")
    levels_perc = params.get("levels_perc", [80.0, 90.0])

    state = "OK"

    if levels_abs != None:
        warn_abs = levels_abs[0]
        crit_abs = levels_abs[1]
        if current >= crit_abs:
            state = "CRIT"
        elif current >= warn_abs:
            state = "WARN"

    if levels_perc != None:
        warn_perc = levels_perc[0]
        crit_perc = levels_perc[1]
        if used_perc >= crit_perc:
            state = "CRIT"
        elif (used_perc >= warn_perc) and (state != "CRIT"):
            state = "WARN"

    metrics = {"connections": current, "used_percent": used_perc}
    if total_created != None:
        metrics["total_created"] = int(total_created)

    msg = "Used connections: %d, Used percentage: %f%%" % (current, used_perc)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }