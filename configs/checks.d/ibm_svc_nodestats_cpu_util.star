def _is_float(s):
    if not s:
        return False
    clean = s.replace(".", "", 1)
    return len(clean) > 0 and clean.isdigit()

def _parse_cpu_nodes(stdout):
    nodes = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line or " command not found" in line:
            continue
        parts = line.split(":")
        if len(parts) < 4:
            continue
        if parts[0] in ("node_id", "id"):
            continue
        node_name = parts[1]
        stat_name = parts[2]
        stat_current = parts[3]
        if stat_name != "cpu_pc":
            continue
        if _is_float(stat_current):
            nodes[node_name] = float(stat_current)
    return nodes

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")

    levels = params.get("levels", None)
    if levels != None:
        warn = float(levels[0])
        crit = float(levels[1])
    else:
        warn = float(params.get("warn", 90.0))
        crit = float(params.get("crit", 95.0))

    res = ctx.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
         user + "@" + host, "lsnodestats", "-delim", ":"],
        mutates=False,
    )

    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "lsnodestats failed", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "lsnodestats failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    nodes = _parse_cpu_nodes(res.stdout)

    if params.get("_discover"):
        discovery = [
            {"item": n, "params": {"warn": 90.0, "crit": 95.0}, "metrics": ["cpu_util"]}
            for n in sorted(nodes.keys())
        ]
        return {
            "changed": False,
            "msg": "discovered %d nodes" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item not in nodes:
        return {
            "changed": False,
            "msg": "node not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    cpu_util = nodes[item]

    if cpu_util >= crit:
        state = "CRIT"
    elif cpu_util >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "CPU utilization: " + str(int(cpu_util)) + "%",
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu_util},
            "details": "",
        },
    }