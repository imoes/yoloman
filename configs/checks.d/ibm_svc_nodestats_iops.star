def _to_float(v):
    if v == None:
        return None
    s = str(v).strip()
    if len(s) == 0:
        return None
    body = s
    if body.startswith("-") or body.startswith("+"):
        body = body[1:]
    if body == "" or not body.replace(".", "", 1).isdigit():
        return None
    return float(s)

def _render_io(b):
    m = b / (1024 * 1024)
    if m >= 1024:
        return "%f GB/s" % (m / 1024)
    if m >= 1:
        return "%f MB/s" % m
    if b >= 1024:
        return "%f KB/s" % (b / 1024)
    return "%d B/s" % int(b)

_METRIC_READ = "read"
_METRIC_WRITE = "write"
_METRIC_READ_LATENCY = "read_latency"
_METRIC_WRITE_LATENCY = "write_latency"
_METRIC_CPU = "cpu_util"

def _discover_diskio(nodes):
    out = []
    for node_name, data in nodes.items():
        if "r_mb" in data and "w_mb" in data:
            out.append({"item": node_name})
    return out

def _discover_iops(nodes):
    out = []
    for node_name, data in nodes.items():
        if "r_io" in data and "w_io" in data:
            out.append({"item": node_name})
    return out

def _discover_latency(nodes):
    out = []
    for node_name, data in nodes.items():
        if "r_ms" in data and "w_ms" in data:
            out.append({"item": node_name})
    return out

def _discover_cpu(nodes):
    out = []
    for node_name, data in nodes.items():
        if "cpu_pc" in data:
            out.append({"item": node_name})
    return out

def _discover_cache(nodes):
    out = []
    for node_name, data in nodes.items():
        if "write_cache_pc" in data and "total_cache_pc" in data:
            out.append({"item": node_name})
    return out

def _gather(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    test = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "3", "-r", "1",
                    host, "1.3.6.1.2.1.1.3.0"], mutates=False)
    if test.rc != 0:
        return None
    base = "1.3.6.1.4.1.791.1.5.4.1"
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-t", "5", "-r", "1",
                    "-Oqn", "-On", host, base + ".3"], mutates=False)
    if walk.rc != 0 or len(walk.stdout) == 0:
        return None
    rows = []
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid_full = line[:sp]
        name = line[sp + 1:]
        idx = oid_full[len(base + ".3") + 1:]
        if idx == "":
            continue
        rows.append({"index": idx, "stat": name})
    if len(rows) == 0:
        return None
    nodes = {}
    for r in rows:
        idx = r["index"]
        stat = r["stat"]
        nm = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "3", "-r", "1",
                      host, base + ".2." + idx], mutates=False)
        node_name = nm.stdout.strip() if nm.rc == 0 else idx
        if node_name == "" or node_name == None:
            node_name = idx
        cur = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "3", "-r", "1",
                       host, base + ".4." + idx], mutates=False)
        val = _to_float(cur.stdout.strip()) if cur.rc == 0 else None
        entry = nodes.setdefault(node_name, {})
        if stat == "r_mb":
            entry["r_mb"] = val
        elif stat == "w_mb":
            entry["w_mb"] = val
        elif stat == "r_io":
            entry["r_io"] = val
        elif stat == "w_io":
            entry["w_io"] = val
        elif stat == "r_ms":
            entry["r_ms"] = val
        elif stat == "w_ms":
            entry["w_ms"] = val
        elif stat == "cpu_pc":
            entry["cpu_pc"] = val
        elif stat == "write_cache_pc":
            entry["write_cache_pc"] = val
        elif stat == "total_cache_pc":
            entry["total_cache_pc"] = val
    return nodes

def main(ctx, params):
    sub = params.get("subcheck", "iops")
    if params.get("_discover"):
        nodes = _gather(ctx, params)
        if nodes == None or len(nodes) == 0:
            return {"changed": False, "msg": "no IBM SVC node stats available",
                    "data": {"discovery": []}}
        disc = []
        if sub == "diskio":
            for e in _discover_diskio(nodes):
                disc.append({"item": e["item"], "params": {"warn": 80, "crit": 90},
                             "metrics": [_METRIC_READ, _METRIC_WRITE]})
        elif sub == "iops":
            for e in _discover_iops(nodes):
                disc.append({"item": e["item"], "params": {"warn": 80, "crit": 90},
                             "metrics": [_METRIC_READ, _METRIC_WRITE]})
        elif sub == "latency":
            for e in _discover_latency(nodes):
                disc.append({"item": e["item"], "params": {"warn": 80, "crit": 90},
                             "metrics": [_METRIC_READ_LATENCY, _METRIC_WRITE_LATENCY]})
        elif sub == "cpu":
            for e in _discover_cpu(nodes):
                disc.append({"item": e["item"], "params": {"levels": (90.0, 95.0)},
                             "metrics": [_METRIC_CPU]})
        elif sub == "cache":
            for e in _discover_cache(nodes):
                disc.append({"item": e["item"], "params": {"warn": 80, "crit": 90},
                             "metrics": ["write_cache_pc", "total_cache_pc"]})
        return {"changed": False, "msg": "discovered %d items" % len(disc),
                "data": {"discovery": disc}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    nodes = _gather(ctx, params)
    if nodes == None or len(nodes) == 0:
        return {"changed": False, "msg": "no IBM SVC node stats available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = nodes.get(item)
    if data == None:
        return {"changed": False, "msg": "node not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if sub == "diskio":
        r_mb = data.get("r_mb")
        w_mb = data.get("w_mb")
        if r_mb == None or w_mb == None:
            return {"changed": False, "msg": "missing read/write MB stats",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        r_b = r_mb * 1024 * 1024
        w_b = w_mb * 1024 * 1024
        return {"changed": False,
                "msg": "%s read, %s write" % (_render_io(r_b), _render_io(w_b)),
                "data": {"state": "OK", "metrics": {_METRIC_READ: r_b, _METRIC_WRITE: w_b}, "details": ""}}

    if sub == "iops":
        r_io = data.get("r_io")
        w_io = data.get("w_io")
        if r_io == None or w_io == None:
            return {"changed": False, "msg": "missing read/write IOPS stats",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        state = "CRIT" if (r_io >= crit or w_io >= crit) else ("WARN" if (r_io >= warn or w_io >= warn) else "OK")
        return {"changed": False,
                "msg": "%d IO/s read, %d IO/s write" % (r_io, w_io),
                "data": {"state": state,
                         "metrics": {_METRIC_READ: r_io, _METRIC_WRITE: w_io},
                         "details": ""}}

    if sub == "latency":
        r_ms = data.get("r_ms")
        w_ms = data.get("w_ms")
        if r_ms == None or w_ms == None:
            return {"changed": False, "msg": "missing read/write latency stats",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        state = "CRIT" if (r_ms >= crit or w_ms >= crit) else ("WARN" if (r_ms >= warn or w_ms >= warn) else "OK")
        return {"changed": False,
                "msg": "Latency is %s ms for read, %s ms for write" % (r_ms, w_ms),
                "data": {"state": state,
                         "metrics": {_METRIC_READ_LATENCY: r_ms, _METRIC_WRITE_LATENCY: w_ms},
                         "details": ""}}

    if sub == "cpu":
        cpu = data.get("cpu_pc")
        if cpu == None:
            return {"changed": False, "msg": "missing cpu_pc stat",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        levels = params.get("levels", (90.0, 95.0))
        warn = levels[0] if len(levels) > 0 else 90.0
        crit = levels[1] if len(levels) > 1 else 95.0
        state = "CRIT" if cpu >= crit else ("WARN" if cpu >= warn else "OK")
        return {"changed": False,
                "msg": "CPU utilization %f%%" % cpu,
                "data": {"state": state, "metrics": {_METRIC_CPU: cpu}, "details": ""}}

    if sub == "cache":
        wc = data.get("write_cache_pc")
        tc = data.get("total_cache_pc")
        if wc == None or tc == None:
            return {"changed": False, "msg": "missing cache stats",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        state = "CRIT" if (wc >= crit or tc >= crit) else ("WARN" if (wc >= warn or tc >= warn) else "OK")
        return {"changed": False,
                "msg": "Write cache usage is %d%%, total cache usage is %d%%" % (int(wc), int(tc)),
                "data": {"state": state,
                         "metrics": {"write_cache_pc": wc, "total_cache_pc": tc},
                         "details": ""}}

    return {"changed": False, "msg": "unknown subcheck",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}