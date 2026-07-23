def _parse_int(s):
    return int(s) if s.isdigit() else 0

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 1883)
    timeout = params.get("timeout", 5)

    if params.get("_discover"):
        res = ctx.run(
            ["mosquitto_sub", "-h", host, "-p", str(port),
             "-t", "$SYS/broker/clients/#", "-C", "10", "-W", str(timeout), "-v"],
            mutates=False, ok_codes=[0, 1, 27]
        )
        if res.rc != 0 and res.rc != 27:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        raw = {}
        for ln in res.stdout.splitlines():
            kv = ln.strip().split(" ", 1)
            if len(kv) == 2:
                raw[kv[0]] = kv[1].strip()

        has_data = (
            raw.get("$SYS/broker/clients/connected") != None or
            raw.get("$SYS/broker/clients/maximum") != None or
            raw.get("$SYS/broker/clients/total") != None
        )
        if not has_data:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": str(port),
                "params": {"host": host, "port": port},
                "metrics": ["clients_connected", "clients_maximum", "clients_total"],
            }]},
        }

    # Check mode
    item = params.get("item", str(port))
    check_port = int(item) if item.isdigit() else port

    res = ctx.run(
        ["mosquitto_sub", "-h", host, "-p", str(check_port),
         "-t", "$SYS/broker/clients/#", "-C", "10", "-W", str(timeout), "-v"],
        mutates=False, ok_codes=[0, 1, 27]
    )

    if res.rc != 0 and res.rc != 27:
        return {
            "changed": False,
            "msg": "cannot connect to MQTT broker %s:%s" % (host, check_port),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = {}
    for ln in res.stdout.splitlines():
        kv = ln.strip().split(" ", 1)
        if len(kv) == 2:
            raw[kv[0]] = kv[1].strip()

    if not raw:
        return {
            "changed": False,
            "msg": "no data from MQTT broker %s:%s" % (host, check_port),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    connected = _parse_int(raw.get("$SYS/broker/clients/connected", ""))
    maximum = _parse_int(raw.get("$SYS/broker/clients/maximum", ""))
    total = _parse_int(raw.get("$SYS/broker/clients/total", ""))

    state = "OK"
    summary = []

    warn_connected = params.get("warn_connected")
    crit_connected = params.get("crit_connected")
    if "$SYS/broker/clients/connected" in raw:
        summary.append("Connected clients: %d" % connected)
        if crit_connected != None and connected >= crit_connected:
            state = "CRIT"
        elif warn_connected != None and connected >= warn_connected:
            if state != "CRIT":
                state = "WARN"

    if "$SYS/broker/clients/maximum" in raw:
        summary.append("Maximum connected since startup: %d" % maximum)

    warn_total = params.get("warn_total")
    crit_total = params.get("crit_total")
    if "$SYS/broker/clients/total" in raw:
        summary.append("Total connected: %d" % total)
        if crit_total != None and total >= crit_total:
            state = "CRIT"
        elif warn_total != None and total >= warn_total:
            if state != "CRIT":
                state = "WARN"

    if not summary:
        return {
            "changed": False,
            "msg": "no client metrics for broker %s:%s" % (host, check_port),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": ", ".join(summary),
        "data": {
            "state": state,
            "metrics": {
                "clients_connected": connected,
                "clients_maximum": maximum,
                "clients_total": total,
            },
            "details": "",
        },
    }