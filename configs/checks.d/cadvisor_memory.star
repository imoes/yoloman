def _num(v):
    if v == None:
        return None
    if type(v) == "int":
        return float(v)
    if type(v) == "float":
        return v
    if type(v) == "string":
        if len(v) == 0:
            return None
        parsed = _to_float(v)
        return parsed if parsed != None else None
    return None


def _to_float(s):
    s = s.strip()
    if len(s) == 0:
        return None
    # Handle optional sign.
    sign = 1.0
    start = 0
    if s[0] == "-":
        sign = -1.0
        start = 1
    elif s[0] == "+":
        start = 1
    digits = "0123456789"
    if start >= len(s):
        return None
    # Must begin with a digit or a dot (for fractional).
    first_ok = s[start] in digits or s[start] == "."
    if not first_ok:
        return None
    has_dot = False
    has_digit = False
    for i in range(start, len(s)):
        ch = s[i]
        if ch in digits:
            has_digit = True
        elif ch == "." and not has_dot:
            has_dot = True
        else:
            return None
    if not has_digit:
        return None
    val = 0.0
    frac = 0.0
    after_dot = False
    divisor = 10.0
    for i in range(start, len(s)):
        ch = s[i]
        if ch == ".":
            after_dot = True
        elif ch in digits:
            d = 0
            for j in range(0, 10):
                if digits[j] == ch:
                    d = j
                    break
            if not after_dot:
                val = val * 10 + d
            else:
                frac = frac + d / divisor
                divisor = divisor * 10
    return sign * (val + frac)


def main(ctx, params):
    # cAdvisor is a container-level resource monitoring product. It is NOT
    # present on a generic Linux host unless explicitly running as a container
    # monitor. Probe for the real thing first.
    version_res = ctx.run(["cadvisor", "--version"], mutates=False)
    if version_res.rc == 127:
        return {
            "changed": False,
            "msg": "cAdvisor not installed (cadvisor binary not found)",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        discovery = []
        stats = _gather_cadvisor_memory(ctx)
        if stats != None:
            metrics = ["mem_used", "mem_lnx_cached", "swap_used"]
            discovery.append({
                "item": "",
                "params": {},
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE: check the single (and only) item.
    item = params.get("item", "")
    stats = _gather_cadvisor_memory(ctx)
    if stats == None:
        return {
            "changed": False,
            "msg": "no cAdvisor memory data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details = ""

    memory_used = _num(stats.get("memory_usage_container", None))
    memory_total = _num(stats.get("memory_usage_pod", None))
    infotext_extra = " (Parent pod memory usage)"

    if memory_used == None or memory_total == None:
        memory_used = _num(stats.get("memory_usage_pod", None))
        if _num(stats.get("memory_limit", None)) != None and stats.get("memory_limit", None) > 0:
            memory_total = _num(stats.get("memory_limit", None))
            infotext_extra = ""
        else:
            memory_total = _num(stats.get("memory_machine", None))
            infotext_extra = " (Available Machine Memory)"

    if memory_used == None or memory_total == None or memory_total == 0:
        return {
            "changed": False,
            "msg": "incomplete cAdvisor memory data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pct = 100.0 * memory_used / memory_total
    used_kb = memory_used / 1024
    total_kb = memory_total / 1024
    summary = "Usage: %f%% - %f kB of %f kB%s" % (pct, used_kb, total_kb, infotext_extra)
    metrics["mem_used"] = memory_used

    rss = _num(stats.get("memory_rss", None))
    if rss != None:
        rss_kb = rss / 1024
        details += "Resident size: %f kB\n" % rss_kb
    cache = _num(stats.get("memory_cache", None))
    if cache != None:
        cache_kb = cache / 1024
        details += "Cache: %f kB\n" % cache_kb
        metrics["mem_lnx_cached"] = cache
    swap = _num(stats.get("memory_swap", None))
    if swap != None:
        swap_kb = swap / 1024
        details += "Swap: %f kB\n" % swap_kb
        metrics["swap_used"] = swap

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": metrics, "details": details},
    }


def _gather_cadvisor_memory(ctx):
    # cAdvisor exposes metrics via its HTTP API. Use the local Prometheus-style
    # endpoint (machine/memory) that the cAdvisor agent plugin reads.
    res = ctx.run([
        "curl", "-fsS",
        "http://localhost:8080/api/v1.3/machine",
    ], mutates=False)
    if res.rc != 0:
        return None

    decoded = None
    if res.stdout and len(res.stdout.strip()) > 0:
        decoded = json.decode(res.stdout)
    if decoded == None:
        return None

    parsed = {}
    base = decoded.get("memory", None)
    if base == None:
        return None

    if type(base) == "dict":
        total = _num(base.get("total", None))
        if total != None and total > 0:
            parsed["memory_machine"] = total

    containers = decoded.get("containers", None)
    if containers != None:
        for c in containers:
            spec = c.get("spec", None)
            if spec != None and spec.get("container", None) != None:
                mem_usage = c.get("memory", None)
                if mem_usage != None:
                    usage = mem_usage.get("usage", None)
                    if usage != None:
                        parsed["memory_usage_container"] = usage
                    limit = mem_usage.get("workingset", None)
                    if limit != None:
                        parsed["memory_limit"] = limit
                    rss = mem_usage.get("rss", None)
                    if rss != None:
                        parsed["memory_rss"] = rss
                    cache = mem_usage.get("cache", None)
                    if cache != None:
                        parsed["memory_cache"] = cache
                    swap = mem_usage.get("swap", None)
                    if swap != None:
                        parsed["memory_swap"] = swap

    if "memory_machine" in parsed:
        if "memory_usage_pod" not in parsed:
            parsed["memory_usage_pod"] = parsed.get("memory_machine", None)
        return parsed
    return None