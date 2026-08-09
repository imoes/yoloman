# Translated Checkmk check: varnish_cache_hit_ratio
# Varnish Cache Hit Ratio — read-only Starlark check module for the yolo-man agent.

def _is_int(s):
    if s == None or s == "":
        return False
    sign = 0
    body = s
    if body.startswith("-") or body.startswith("+"):
        sign = 1
        body = body[1:]
    if body == "":
        return False
    i = 0
    while i < len(body):
        c = body[i]
        if c < "0" or c > "9":
            return False
        i += 1
    return True


def _read_varnish_stats(ctx):
    """Probe for varnish and return the parsed stats dict, or None if absent."""
    # 1. Establish that Varnish is actually installed on the host.
    probe = ctx.run(["varnishd", "-V"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        # Fallback probe: varnishstat may be available even if varnishd is not in PATH.
        probe2 = ctx.run(["varnishstat", "-V"], mutates=False)
        if probe2.rc == 127 or probe2.rc != 0:
            return None

    # 2. Gather the real on-host data the Checkmk agent plugin would read.
    #    varnishstat with -1 (raw values), -j (JSON output) gives counters like
    #    MAIN.cache_hit, MAIN.cache_miss, etc.
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return None

    # varnishstat -j emits two sections: "counters" and (sometimes) "version".
    data = json.decode(res.stdout)
    counters = data.get("counters", {})
    if not counters:
        return None

    # 3. Build the same flat structure the agent section parser expects.
    parsed = {}
    for path, info in counters.items():
        components = path.split(".")
        key = components[-1]
        if key in parsed:
            continue
        value = None
        val = info.get("value")
        if val != None:
            sval = str(val)
            if _is_int(sval):
                value = int(sval)
        descr = info.get("description", "")
        perf_var_name = "varnish_%s_rate" % key
        if perf_var_name.startswith("varnish_n_wrk"):
            perf_var_name = perf_var_name.replace("n_wrk", "worker")
        elif perf_var_name.startswith("varnish_n_"):
            perf_var_name = perf_var_name.replace("n_", "objects_")
        parsed[key] = {
            "value": value,
            "descr": descr.replace("/", " "),
            "perf_var_name": perf_var_name,
            "params_var_name": key.split("_", 1)[-1],
        }
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        section = _read_varnish_stats(ctx)
        if section == None:
            return {
                "changed": False,
                "msg": "discovered 0 varnish items",
                "data": {"discovery": []},
            }
        # discover_varnish_cache_hit_ratio: requires 'cache_hit' and 'cache_miss'.
        if "cache_hit" in section and "cache_miss" in section:
            entry = {
                "item": "",
                "params": {"levels_lower": (70.0, 60.0)},
                "metrics": ["cache_hit_ratio"],
            }
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [entry]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 varnish items",
            "data": {"discovery": []},
        }

    # CHECK MODE — single-service check, item is "".
    section = _read_varnish_stats(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "varnish is not installed on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if "cache_hit" not in section or "cache_miss" not in section:
        missing = []
        if "cache_hit" not in section:
            missing.append("cache_hit")
        if "cache_miss" not in section:
            missing.append("cache_miss")
        return {
            "changed": False,
            "msg": "missing varnish counters: " + ", ".join(missing),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reference = section["cache_hit"]
    additional = section["cache_miss"]
    reference_value = reference["value"]
    additional_value = additional["value"]

    if reference_value == None or additional_value == None:
        return {
            "changed": False,
            "msg": "varnish cache_hit or cache_miss value unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = reference_value + additional_value
    ratio = 0.0
    if total > 0:
        ratio = 100.0 * reference_value / total

    levels = params.get("levels_lower", (70.0, 60.0))
    warn, crit = levels[0], levels[1]
    if ratio <= crit:
        state = "CRIT"
    elif ratio <= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Cache hit ratio: %f%%" % ratio
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"cache_hit_ratio": ratio},
            "details": "",
        },
    }