def _parse_state(value):
    table = {
        "1": "notRunning(1)",
        "2": "running(2)",
        "3": "restart(3)",
        "4": "shutDown(4)",
        "5": "unknown(5)",
        "6": "primary(6)",
        "7": "secondary(7)",
        "8": "inProgress(8)",
        "9": "failed(9)",
        "10": "stopped(10)",
        "11": "starting(11)",
        "12": "stopping(12)",
        "13": "deleting(13)",
        "14": "reset(14)",
        "15": "inactive(15)",
        "16": "deactivating(16)",
        "17": "activating(17)",
        "18": "maintenance(18)",
        "19": "resuming(19)",
        "20": "freezing(20)",
        "21": "frozen(21)",
        "22": "thawing(22)",
    }
    return table.get(value, "unknown(%s)" % value)

def _grade_state(state_value):
    # operational state grading: notRunning/restart/shutDown/failed/stopped/inactive -> CRIT
    # unknown -> UNKNOWN, running/primary/secondary -> OK, inProgress/starting/stopping/deleting/reset/activating/deactivating/maintenance/resuming/freezing/frozen/thawing -> WARN
    critical = ["notRunning(1)", "restart(3)", "shutDown(4)", "failed(9)", "stopped(10)", "inactive(15)"]
    ok = ["running(2)", "primary(6)", "secondary(7)"]
    if state_value in ok:
        return "OK"
    if state_value in critical:
        return "CRIT"
    if state_value.startswith("unknown"):
        return "UNKNOWN"
    return "WARN"

def _probe_is_audiocodes(ctx, params):
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.5003.9.10.10.4.27.1.1.1.0"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0 or not res.stdout:
        return None
    return res.stdout.strip()

def main(ctx, params):
    if params.get("_discover"):
        sys_id = _probe_is_audiocodes(ctx, params)
        if sys_id == None:
            return {"changed": False, "msg": "Audiocodes device not present", "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), base + ".8"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "Audiocodes device not present", "data": {"discovery": []}}

        items = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            # index is the suffix after the column OID
            index = oid[len(base + ".8") + 1:]
            if not index:
                continue
            items.append(index)

        discovery = []
        for item in items:
            discovery.append({"item": item, "params": {}, "metrics": ["operational_state"]})
        return {"changed": False, "msg": "discovered %d redundant modules" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    sys_id = _probe_is_audiocodes(ctx, params)
    if sys_id == None:
        return {"changed": False, "msg": "Audiocodes device not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no audiocodes device found"}}

    base = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1"

    # Walk the HA status column (.9) to find which indices exist and confirm the item
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), base + ".9"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "Audiocodes device not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no audiocodes device found"}}

    ha_map = {}
    found = False
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        index = oid[len(base + ".9") + 1:]
        if not index:
            continue
        ha_map[index] = parts[1]
        if index == item:
            found = True

    if not found:
        return {"changed": False, "msg": "redundant module %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "item not found in section"}}

    # Read operational state (.8), presence (.4), HA status (.9) for this item
    op_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".8." + item], mutates=False)
    if op_res.rc == 127 or op_res.rc != 0 or not op_res.stdout:
        return {"changed": False, "msg": "failed to read operational state for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "no data"}}

    pres_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".4." + item], mutates=False)
    presence = pres_res.stdout.strip() if pres_res.rc == 0 and pres_res.stdout else "unknown"

    ha_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".9." + item], mutates=False)
    ha_status = ha_res.stdout.strip() if ha_res.rc == 0 and ha_res.stdout else "unknown"

    op_state = _parse_state(op_res.stdout.strip())
    state = _grade_state(op_state)

    details = "Operational state: %s\nPresence: %s\nHA status: %s" % (op_state, presence, ha_status)

    return {"changed": False, "msg": "Operational state redundant module %s: %s" % (item, op_state), "data": {"state": state, "metrics": {}, "details": details}}