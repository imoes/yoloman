STATE_MAP = {
    "done (error)": {"state": "CRIT", "readable": "Done with errors."},
    "installing": {"state": "WARN", "readable": "Installation in progress."},
    "done (okay)": {"state": "OK", "readable": "Done without errors."},
}

def _find_hana_instances(ctx):
    res = ctx.run(
        ["find", "/usr/sap", "-maxdepth", "2", "-type", "d", "-name", "HDB??"],
        mutates=False,
        ok_codes=[0, 1],
    )
    instances = []
    seen = {}
    for line in res.stdout.splitlines():
        parts = line.split("/")
        if len(parts) >= 5:
            sid = parts[3]
            hdb = parts[4]
            if hdb.startswith("HDB") and len(hdb) == 5 and hdb[3:].isdigit():
                inst_num = hdb[3:]
                key = sid + "_" + inst_num
                if key not in seen:
                    seen[key] = True
                    instances.append({"sid": sid, "instance": inst_num})
    return instances

def main(ctx, params):
    user = params.get("user", "SYSTEM")
    password = params.get("password", "")

    if params.get("_discover"):
        instances = _find_hana_instances(ctx)
        discovery = []
        for inst in instances:
            item = inst["sid"] + " " + inst["instance"]
            discovery.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    item_parts = item.split()
    if len(item_parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sid = item_parts[0]
    instance_num = item_parts[1]

    sql = "SELECT CURRENT_TIMESTAMP, STATUS FROM SYS.M_ESS_MIGRATION"
    res = ctx.run(
        ["hdbsql", "-i", instance_num, "-u", user, "-p", password,
         "-x", "-quiet", "-a", sql],
        mutates=False,
        ok_codes=[0, 1, 2, 3],
    )

    out = res.stdout.strip()
    if not out or res.rc != 0:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()},
        }

    log = out
    timestamp = "not available"
    lines = out.splitlines()
    if lines:
        first = lines[0].replace('"', "")
        cols = first.split(",")
        if len(cols) >= 2:
            timestamp = cols[0].strip()
            log = ",".join(cols[1:]).strip()

    log_lower = log.lower()
    state = "UNKNOWN"
    readable = "Unknown [" + log + "]"

    for key in STATE_MAP:
        if key in log_lower:
            state = STATE_MAP[key]["state"]
            readable = STATE_MAP[key]["readable"]
            break

    msg = "ESS State: " + readable + " Timestamp: " + timestamp
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }