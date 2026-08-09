# Checkmk varnish_cache check -> read-only Starlark check module
# Reproduces check_plugin_varnish_cache: grades per-second rates of
# cache_miss / cache_hit / cache_hitpass against per-key (warn, crit)
# levels (upper-levels). The Checkmk agent section parses `varnishstats -1`
# output into a nested dict; here we read that same command directly.

VARNISH_KEYS = ["cache_miss", "cache_hit", "cache_hitpass"]

def _split_path(raw_path):
    if "(" not in raw_path:
        return raw_path.split(".")
    head_str, middle = raw_path.split("(", 1)
    address, tail = middle.split(")", 1)
    head = head_str.strip(".").split(".")
    return head[:-1] + [head[-1] + "(" + address + ")"] + tail.strip(".").split(".")

def _is_int(s):
    if s == None:
        return False
    st = s.strip()
    if st == "":
        return False
    if st.startswith("-"):
        return st[1:].isdigit()
    return st.isdigit()

def _parse_int(s):
    st = s.strip()
    neg = False
    body = st
    if body.startswith("-"):
        neg = True
        body = body[1:]
    if not body.isdigit():
        return None
    v = 0
    for ch in body:
        v = v * 10 + (ord(ch) - 48)
    return (0 - v) if neg else v

def _to_number(s):
    if s == None:
        return None
    st = s.strip()
    if _is_int(st):
        return _parse_int(st)
    # float fallback without ** / pow()
    neg = False
    body = st
    if body.startswith("-"):
        neg = True
        body = body[1:]
    if "." not in body:
        return None
    if body.replace(".", "").isdigit():
        parts = body.split(".")
        whole = parts[0]
        frac = parts[1] if len(parts) > 1 else "0"
        wi = _parse_int(whole)
        if wi == None:
            wi = 0
        fi = 0
        for ch in frac:
            fi = fi * 10 + (ord(ch) - 48)
        denom = 1
        for _ in frac:
            denom = denom * 10
        v = wi + fi / denom
        return (0.0 - v) if neg else v
    return None

def _parse_varnish(string_table):
    parsed = {}
    for line in string_table:
        if len(line) < 4:
            continue
        raw_path = line[0]
        value_str = line[1]
        parsed_path = _split_path(raw_path)
        node = parsed
        for i, part in enumerate(parsed_path):
            if i == len(parsed_path) - 1:
                break
            nxt = node.get(part)
            if nxt == None or type(nxt) != "dict":
                node[part] = {}
            node = node[part]
        leaf_key = parsed_path[-1]
        existing = node.get(leaf_key)
        if existing == None or type(existing) != "dict":
            node[leaf_key] = {}
        leaf = node[leaf_key]
        value = _to_number(value_str)
        if len(line) > 3 and line[3].lower() in raw_path:
            descr = " ".join(line[4:]) if len(line) > 4 else ""
        else:
            descr = " ".join(line[3:]) if len(line) > 3 else ""
        descr = descr.replace("/", " ")
        perf_var_name = "varnish_" + parsed_path[-1] + "_rate"
        if perf_var_name.startswith("varnish_n_wrk"):
            perf_var_name = perf_var_name.replace("n_wrk", "worker")
        elif perf_var_name.startswith("varnish_n_"):
            perf_var_name = perf_var_name.replace("n_", "objects_")
        params_var_name = parsed_path[-1].split("_", 1)[-1]
        leaf.update({
            "value": value,
            "descr": descr,
            "perf_var_name": perf_var_name,
            "params_var_name": params_var_name,
        })
    for key in ["MAIN", "MGT"]:
        sub = parsed.pop(key, {})
        if type(sub) == "dict":
            parsed.update(sub)
    return parsed

def _grade_rate(value, warn, crit):
    if value == None:
        return "UNKNOWN", ""
    state = "OK"
    detail = "%f/s" % value
    if warn != None and value >= warn:
        state = "WARN"
    if crit != None and value >= crit:
        state = "CRIT"
    return state, detail

def _read_levels(params, params_var_name):
    raw = params.get(params_var_name, None)
    if raw == None:
        return None, None
    if type(raw) == "list" or type(raw) == "tuple":
        w = raw[0] if len(raw) > 0 else None
        c = raw[1] if len(raw) > 1 else None
        return w, c
    return raw, None

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["varnishstats", "-1"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "varnish not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if probe.rc != 0:
            return {"changed": False, "msg": "varnishstats failed",
                    "data": {"discovery": []}}
        lines = []
        for raw in probe.stdout.splitlines():
            parts = raw.split()
            if len(parts) < 2:
                continue
            lines.append(parts)
        section = _parse_varnish(lines)
        present = False
        for k in VARNISH_KEYS:
            if section.get(k) != None:
                present = True
                break
        if not present:
            return {"changed": False, "msg": "discovered 0 varnish items",
                    "data": {"discovery": []}}
        metrics = []
        for k in VARNISH_KEYS:
            data = section.get(k)
            if data != None and type(data) == "dict":
                metrics.append(data.get("perf_var_name", "varnish_" + k + "_rate"))
        return {"changed": False, "msg": "discovered varnish item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": metrics}
                ]}}
    probe = ctx.run(["varnishstats", "-1"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "varnish is not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        return {"changed": False, "msg": "varnishstats failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = []
    for raw in probe.stdout.splitlines():
        parts = raw.split()
        if len(parts) < 2:
            continue
        lines.append(parts)
    section = _parse_varnish(lines)
    item = params.get("item", "")
    metrics = {}
    states = []
    msgs = []
    for k in VARNISH_KEYS:
        data = section.get(k)
        if data == None or type(data) != "dict":
            continue
        value = data.get("value")
        if value == None:
            continue
        warn, crit = _read_levels(params, data.get("params_var_name"))
        state, rate_str = _grade_rate(value, warn, crit)
        if state != "OK":
            states.append(state)
            msgs.append(data.get("descr", k) + ": " + rate_str + " " + state)
        metrics[data.get("perf_var_name", "varnish_" + k + "_rate")] = value
    if not metrics:
        return {"changed": False,
                "msg": "no varnish cache statistics found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    final = "CRIT" if "CRIT" in states else ("WARN" if "WARN" in states else "OK")
    summary = "; ".join(msgs) if msgs else "Varnish Cache OK"
    return {"changed": False, "msg": summary,
            "data": {"state": final, "metrics": metrics, "details": ""}}