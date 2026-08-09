def main(ctx, params):
    if params.get("_discover"):
        hdbsql_path = _find_hdbsql(ctx)
        if hdbsql_path == None:
            return {"changed": False, "msg": "no SAP HANA client found",
                    "data": {"discovery": []}}
        res = _query_ess_migration(ctx, hdbsql_path)
        if res == None:
            return {"changed": False, "msg": "no SAP HANA databases found",
                    "data": {"discovery": []}}
        discovery = []
        for sid_instance in sorted(res.keys()):
            entry = {"item": sid_instance,
                     "params": {},
                     "metrics": ["ess_state"]}
            discovery.append(entry)
        return {"changed": False,
                "msg": "discovered %d SAP HANA ESS migration instances" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    hdbsql_path = _find_hdbsql(ctx)
    if hdbsql_path == None:
        return {"changed": False,
                "msg": "SAP HANA client (hdbsql) not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = _query_ess_migration(ctx, hdbsql_path)
    if res == None or not res.get(item):
        return {"changed": False,
                "msg": "no SAP HANA instance '%s' found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = res[item]
    if not data["log"]:
        return {"changed": False,
                "msg": "Login into database failed.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    states = _STATE_UNKNOWN
    for ident, info in _ESS_STATE_MAP.items():
        if ident.lower() in data["log"].lower():
            states = info
            break
    infotext = "ESS State: %s Timestamp: %s" % (states["state_readable"], data["timestamp"])
    return {"changed": False, "msg": infotext,
            "data": {"state": states["cmk_state"],
                     "metrics": {"ess_state": _STATE_MAP_NUMERIC.get(states["cmk_state"], 0)},
                     "details": infotext}}


def _find_hdbsql(ctx):
    res = ctx.run(["which", "hdbsql"], mutates=False)
    if res.rc != 0 or res.rc == 127:
        return None
    path = res.stdout.strip()
    if path == "":
        return None
    return path


def _query_ess_migration(ctx, hdbsql_path):
    res = ctx.run([hdbsql_path, "-j", "-n", "localhost:30015",
                   "SELECT * FROM SYS.M_DATABASE", "-u", "SYSTEM"],
                  mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return None
        entries = _parse_ess_output(res.stdout, ctx)
        if len(entries) == 0:
            return None
        return entries
    return {}


def _parse_ess_output(stdout, ctx):
    result = {}
    lines = stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped == "":
            i = i + 1
            continue
        parts = stripped.split(None, 1)
        if len(parts) < 2:
            i = i + 1
            continue
        sid_instance = parts[0]
        data_line = parts[1]
        timestamp = "not available"
        if len(data_line) >= 15 and data_line[4] == "-" and data_line[7] == "-":
            date_part = data_line[:10]
            time_part = data_line[10:]
            time_clean = time_part
            if len(time_clean) > 8:
                time_clean = time_clean[:8]
            timestamp = date_part + " " + time_clean
        result[sid_instance] = {"log": data_line, "timestamp": timestamp}
        i = i + 1
    return result


_ESS_STATE_MAP = {
    "Done (error)": {"cmk_state": "CRIT", "state_readable": "Done with errors."},
    "Installing": {"cmk_state": "WARN", "state_readable": "Installation in progress."},
    "Done (okay)": {"cmk_state": "OK", "state_readable": "Done without errors."},
}

_STATE_UNKNOWN = {"cmk_state": "UNKNOWN", "state_readable": "Unknown []"}

_STATE_MAP_NUMERIC = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}