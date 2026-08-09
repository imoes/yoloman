# Checkmk check "varnish_worker" -> read-only Starlark check module for yolo-man.
# Reproduces the Checkmk varnish_worker check logic on a host without Checkmk.

WORKER_KEYS = [
    "n_wrk_lqueue",
    "n_wrk_create",
    "n_wrk_drop",
    "n_wrk",
    "n_wrk_failed",
    "n_wrk_queued",
    "n_wrk_max",
]


def _is_varnish_installed(ctx):
    res = ctx.run(["varnishd", "-V"], mutates=False)
    if res.rc == 127:
        return False
    return True


def _read_varnishstat_json(ctx):
    res = ctx.run(
        ["varnishstat", "-j", "-1", "-n", "default"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return None
    return json.decode(res.stdout)


def _extract_counter(data, name):
    if isinstance(data, dict) and isinstance(data.get(name), dict):
        entry = data[name]
        v = entry.get("value")
        if v == None:
            return None
        if isinstance(v, int):
            return v
        if isinstance(v, str) and v.isdigit():
            return int(v)
        return None
    return None


def _fmt_name(k):
    perf = "varnish_%s_rate" % k
    if perf.startswith("varnish_n_wrk"):
        perf = perf.replace("n_wrk", "worker")
    elif perf.startswith("varnish_n_"):
        perf = perf.replace("n_", "objects_")
    return perf


def _section_exists(section, keys):
    for k in keys:
        if k not in section:
            return False
    return True


def _build_section(ctx):
    data = _read_varnishstat_json(ctx)
    if data == None:
        return None
    section = {}
    for k in WORKER_KEYS:
        val = _extract_counter(data, k)
        if val != None:
            section[k] = {
                "value": val,
                "descr": " ".join(k.replace("_", " ").split()),
                "perf_var_name": _fmt_name(k),
                "params_var_name": k,
            }
    return section


def _grade_value(val, warn, crit):
    if crit != None and val >= crit:
        return "CRIT"
    if warn != None and val >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        if not _is_varnish_installed(ctx):
            return {"changed": False, "msg": "Varnish not installed",
                    "data": {"discovery": []}}

        section = _build_section(ctx)
        if section == None or not _section_exists(section, ["n_wrk_failed", "n_wrk_queued"]):
            return {"changed": False, "msg": "no Varnish worker data",
                    "data": {"discovery": []}}

        metrics = []
        for k in WORKER_KEYS:
            if k in section:
                metrics.append(_fmt_name(k))

        return {
            "changed": False,
            "msg": "discovered 1 Varnish worker service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": metrics,
                    }
                ]
            },
        }

    # --- check mode ---
    item = params.get("item", "")

    if not _is_varnish_installed(ctx):
        return {
            "changed": False,
            "msg": "Varnish is not installed on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _build_section(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "could not read varnishstat output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _section_exists(section, ["n_wrk_failed", "n_wrk_queued"]):
        return {
            "changed": False,
            "msg": "Varnish worker counters not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details = []
    worst = "OK"
    order = ["OK", "WARN", "CRIT", "UNKNOWN"]

    for k in WORKER_KEYS:
        if k not in section:
            continue
        val = section[k]["value"]
        perf = _fmt_name(k)
        metrics[perf] = val
        details.append("%s: %d" % (section[k]["descr"], val))

    summary = "; ".join(details) if details else "no worker counters"

    return {
        "changed": False,
        "msg": "Varnish Worker: " + summary,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": details,
        },
    }