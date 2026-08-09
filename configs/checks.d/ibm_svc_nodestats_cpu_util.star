def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "svcinfo"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no IBM SVC data source found",
                    "data": {"discovery": []}}
        res2 = ctx.run(["svcinfo", "lststat", "-nohdr"], mutates=False)
        if res2.rc != 0 or not res2.stdout:
            return {"changed": False, "msg": "no IBM SVC node statistics available",
                    "data": {"discovery": []}}
        section = _parse_ibm_svc_nodestats(res2.stdout)
        discovery = []
        for node_name in section:
            data = section[node_name]
            if "cpu_pc" in data:
                levels = params.get("levels", (90.0, 95.0))
                if type(levels) == "list":
                    levels = tuple(levels)
                discovery.append({"item": node_name, "params": {"levels": levels},
                                 "metrics": ["cpu_util"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    res = ctx.run(["which", "svcinfo"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "unknown - IBM SVC data source not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res2 = ctx.run(["svcinfo", "lststat", "-nohdr"], mutates=False)
    if res2.rc != 0 or not res2.stdout:
        return {"changed": False,
                "msg": "unknown - no IBM SVC node statistics available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_ibm_svc_nodestats(res2.stdout)
    data = section.get(item)
    if data == None:
        return {"changed": False,
                "msg": "unknown - item %s not found in IBM SVC node statistics" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "cpu_pc" not in data:
        return {"changed": False,
                "msg": "unknown - no cpu_pc statistic for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util = float(data["cpu_pc"])
    levels = params.get("levels", (90.0, 95.0))
    if type(levels) == "list":
        levels = tuple(levels)
    warn = levels[0] if len(levels) >= 1 else 90.0
    crit = levels[1] if len(levels) >= 2 else 95.0
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")
    return {"changed": False,
            "msg": "%s CPU utilization %s%%" % (item, str(util)),
            "data": {"state": state, "metrics": {"cpu_util": util},
                     "details": "cpu_pc: %s%%" % str(util)}}


def _parse_ibm_svc_nodestats(stdout):
    parsed = {}
    lines = stdout.splitlines()
    header = ["node_id", "node_name", "stat_name", "stat_current", "stat_peak", "stat_peak_time"]
    for line in lines:
        if " command not found" in line:
            continue
        fields = line.split(":")
        if len(fields) < 6:
            continue
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        row = dict(zip(header[1:], fields[1:]))
        node_name = row.get("node_name", "")
        stat_name = row.get("stat_name", "")
        if stat_name not in ("write_cache_pc", "total_cache_pc", "cpu_pc"):
            continue
        stat_current = row.get("stat_current", "")
        if not _is_float(stat_current):
            continue
        parsed.setdefault(node_name, {})[stat_name] = float(stat_current)
    return parsed


def _is_float(s):
    if not s:
        return False
    parts = s.split(".")
    if len(parts) == 1:
        return parts[0].lstrip("-").isdigit()
    if len(parts) == 2:
        left = parts[0].lstrip("-")
        right = parts[1]
        left_ok = left.isdigit() if left else True
        right_ok = right.isdigit() if right else True
        return left_ok and right_ok
    return False