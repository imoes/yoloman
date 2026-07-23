SAP_HANA_EVENTS_MAP = {
    "open_events": ("CRIT", "Unacknowledged events"),
    "disabled_alerts": ("WARN", "Disabled alerts"),
    "high_alerts": ("CRIT", "High alerts"),
}

ORDERED_KEYS = ["open_events", "disabled_alerts", "high_alerts"]

SQL_QUERIES = {
    "open_events": "SELECT COUNT(*) FROM _SYS_STATISTICS.STATISTICS_ALERTS_BASE WHERE IS_ACKNOWLEDGED='FALSE'",
    "disabled_alerts": "SELECT COUNT(*) FROM _SYS_STATISTICS.STATISTICS_ALERT_DEFINITION WHERE IS_ENABLED='FALSE'",
    "high_alerts": "SELECT COUNT(*) FROM _SYS_STATISTICS.STATISTICS_ALERTS_BASE WHERE ALERT_RATING=3",
}

def _parse_count(stdout):
    for line in stdout.strip().splitlines():
        val = line.strip().strip('"').strip()
        if val.isdigit():
            return int(val)
    return -1

def _hdbsql(ctx, executable, host, port, user, password, sql):
    res = ctx.run(
        [executable, "-n", host + ":" + str(port), "-u", user, "-p", password, "-a", "-x", sql],
        mutates=False,
        ok_codes=[0, 1, 2, 3, 4, 126, 127, 255],
    )
    if res.rc != 0:
        return -1
    return _parse_count(res.stdout)

def _find_hana_sids(ctx):
    res = ctx.run(["ls", "/usr/sap"], mutates=False, ok_codes=[0, 1, 2])
    if res.rc != 0:
        return []
    sids = []
    for entry in res.stdout.splitlines():
        entry = entry.strip()
        if len(entry) == 3 and entry.isalnum() and entry == entry.upper():
            sids.append(entry)
    return sids

def _find_instance_numbers(ctx, sid):
    res = ctx.run(["ls", "/usr/sap/" + sid], mutates=False, ok_codes=[0, 1, 2])
    if res.rc != 0:
        return []
    nums = []
    for entry in res.stdout.splitlines():
        entry = entry.strip()
        if entry.startswith("HDB") and len(entry) == 5 and entry[3:].isdigit():
            nums.append(entry[3:])
    return nums

def main(ctx, params):
    if params.get("_discover"):
        discovery = []
        for sid in _find_hana_sids(ctx):
            for inst_num in _find_instance_numbers(ctx, sid):
                discovery.append({
                    "item": sid + " " + inst_num,
                    "params": {},
                    "metrics": ["num_open_events", "num_disabled_alerts", "num_high_alerts"],
                })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    item_parts = item.split()
    sid = item_parts[0] if len(item_parts) >= 1 else ""
    inst_num = item_parts[1] if len(item_parts) >= 2 else "00"

    if len(inst_num) != 2 or not inst_num.isdigit():
        inst_num = "00"

    host = params.get("host", "localhost")
    user = params.get("user", "SYSTEM")
    password = params.get("password", "")
    port = params.get("port", int("3" + inst_num + "15"))

    hdbsql_bin = params.get("hdbsql_bin", "")
    if hdbsql_bin == "":
        candidate = "/usr/sap/" + sid + "/HDB" + inst_num + "/exe/hdbsql"
        if ctx.file_exists(candidate):
            hdbsql_bin = candidate
        else:
            hdbsql_bin = "hdbsql"

    counts = {}
    any_ok = False
    for key in ORDERED_KEYS:
        count = _hdbsql(ctx, hdbsql_bin, host, port, user, password, SQL_QUERIES[key])
        if count >= 0:
            counts[key] = count
            any_ok = True

    if not any_ok:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    overall_state = "OK"
    msg_parts = []
    metrics = {}

    for key in ORDERED_KEYS:
        count = counts.get(key, 0)
        event_state, label = SAP_HANA_EVENTS_MAP.get(key, ("UNKNOWN", "unknown[%s]" % key))
        msg_parts.append("%s: %d" % (label, count))
        metrics["num_" + key] = count
        if count > 0:
            if event_state == "CRIT" and overall_state != "CRIT":
                overall_state = "CRIT"
            elif event_state == "WARN" and overall_state == "OK":
                overall_state = "WARN"

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": overall_state,
            "metrics": metrics,
            "details": "",
        },
    }