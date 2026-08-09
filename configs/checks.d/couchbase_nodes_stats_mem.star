# Couchbase node memory check, translated to read-only Starlark for the yolo-man agent.
# Reproduces check_plugin_couchbase_nodes_stats_mem (Couchbase %s Memory).
# Discovery enumerates cluster nodes; the check grades RAM and Swap usage per node.

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                       "1.3.6.1.4.1.22859"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "Couchbase not present",
                    "data": {"discovery": []}}
        nodes = _walk_node_names(ctx, host, community)
        if not nodes:
            return {"changed": False, "msg": "Couchbase present, no nodes",
                    "data": {"discovery": []}}
        out = []
        for name in nodes:
            out.append({"item": name, "params": {"levels": (150.0, 200.0)},
                        "metrics": ["mem_used", "swap_used"]})
        return {"changed": False, "msg": "discovered %d Couchbase nodes" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    data = _node_stats(ctx, host, community, item)
    if data == None:
        return {"changed": False, "msg": "no Couchbase node: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_total = _num(data.get("mem_total", 0))
    mem_free = _num(data.get("mem_free", 0))
    swap_total = _num(data.get("swap_total", 0))
    swap_used = _num(data.get("swap_used", 0))
    mem_used = mem_total - mem_free

    levels = params.get("levels", (150.0, 200.0))
    warn_ram = levels[0] if len(levels) > 0 else None
    crit_ram = levels[1] if len(levels) > 1 else None
    is_abs = warn_ram != None and type(warn_ram) == "int"
    mode = "abs_used" if is_abs else "perc_used"

    warn_v, crit_v = _resolve_levels(warn_ram, crit_ram, mem_used, mem_total, mode)

    metrics = {"mem_used": mem_used, "swap_used": swap_used}
    parts = []
    parts.append(_grade(mem_used, mem_total, warn_v, crit_v, "RAM"))
    parts.append(_grade(swap_used, swap_total, None, None, "Swap"))
    state = _worst_state(parts)
    details = "RAM: %s, Swap: %s" % (_fmt(mem_used), _fmt(swap_used))
    msgs = []
    for p in parts:
        msgs.append(p[1])
    msg = "%s %s" % (item, " ".join(msgs))
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}


def _node_stats(ctx, host, community, item):
    index = _index_of(ctx, host, community, item)
    if index == None:
        return None
    fields = {
        "mem_total": "1.3.6.1.4.1.22859.1.2.1.1",
        "mem_free":  "1.3.6.1.4.1.22859.1.2.1.2",
        "swap_total": "1.3.6.1.4.1.22859.1.2.1.3",
        "swap_used": "1.3.6.1.4.1.22859.1.2.1.4",
    }
    out = {}
    for key in fields:
        oid = fields[key] + "." + index
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                      mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return None
        out[key] = res.stdout.strip()
    return out


def _walk_node_names(ctx, host, community):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host,
                   "1.3.6.1.4.1.22859.1.2.1.0"], mutates=False)
    if res.rc != 0:
        return []
    names = []
    for line in res.stdout.splitlines():
        if line.strip():
            names.append(line.strip())
    return names


def _index_of(ctx, host, community, item):
    col = "1.3.6.1.4.1.22859.1.2.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col],
                  mutates=False)
    if res.rc != 0:
        return None
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx < 0:
            continue
        oid = line[:idx]
        val = line[idx + 1:].strip().strip('"')
        if val == item:
            return oid[len(col) + 1:]
    return None


def _resolve_levels(warn_ram, crit_ram, mem_used, mem_total, mode):
    if mode == "perc_used" or mem_total == 0:
        pct = (mem_used / mem_total * 100.0) if mem_total > 0 else 0.0
        w = pct if warn_ram == None else warn_ram
        c = pct if crit_ram == None else crit_ram
        return w, c
    w = mem_used if warn_ram == None else warn_ram
    c = mem_used if crit_ram == None else crit_ram
    return w, c


def _grade(value, total, warn, crit, label):
    if total != None and total > 0 and warn != None and crit != None:
        pct = value / total * 100.0
        if pct >= crit:
            return "CRIT", label + " %d%% used" % int(pct)
        if pct >= warn:
            return "WARN", label + " %d%% used" % int(pct)
        return "OK", label + " %d%% used" % int(pct)
    if warn != None and crit != None:
        if value >= crit:
            return "CRIT", label + " %s" % _fmt(value)
        if value >= warn:
            return "WARN", label + " %s" % _fmt(value)
        return "OK", label + " %s" % _fmt(value)
    return "OK", label + " %s" % _fmt(value)


def _worst_state(parts):
    state = "OK"
    for p in parts:
        s = p[0]
        if s == "CRIT":
            state = "CRIT"
            break
        if s == "WARN" and state != "CRIT":
            state = "WARN"
    return state


def _num(v):
    s = str(v).strip()
    if s.isdigit():
        return int(s)
    neg = s.startswith("-") and s[1:].isdigit()
    if neg:
        return -int(s[1:])
    return 0


def _fmt(n):
    if n >= 1073741824:
        return "%f GB" % (n / 1073741824.0)
    if n >= 1048576:
        return "%f MB" % (n / 1048576.0)
    if n >= 1024:
        return "%f kB" % (n / 1024.0)
    return str(n)