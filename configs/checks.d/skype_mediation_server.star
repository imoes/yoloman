# Skype Mediation Server check plugin
# Reads Windows Performance Counter data via typeperf (the on-host source the
# Checkmk WMI section reads). Provides discovery + check for the
# "Skype Mediation Server" service.

# Default threshold tables (warn, crit) mirroring the Checkmk defaults.
DEFAULTS_MEDIATION = {
    "load_call_failure_index": {"upper": (10, 20)},
    "failed_calls_because_of_proxy": {"upper": (10, 20)},
    "failed_calls_because_of_gateway": {"upper": (10, 20)},
    "media_connectivity_failure": {"upper": (1, 2)},
}

# The list of counter paths we read for each sub-check. Each entry:
#   (perfvar, counter_path, label, levels_default_key)
MEDIATION_COUNTERS = [
    ("mediation_load_call_failure_index",
     "\\LS:MediationServer - Health Indices\\- Load Call Failure Index",
     "Load call failure index", "load_call_failure_index"),
    ("mediation_failed_calls_because_of_proxy",
     "\\LS:MediationServer - Global Counters\\- Total failed calls caused by unexpected interaction from the Proxy",
     "Failed calls because of proxy", "failed_calls_because_of_proxy"),
    ("mediation_failed_calls_because_of_gateway",
     "\\LS:MediationServer - Global Per Gateway Counters\\- Total failed calls caused by unexpected interaction from a gateway",
     "Failed calls because of gateway", "failed_calls_because_of_gateway"),
    ("mediation_media_connectivity_failure",
     "\\LS:MediationServer - Media Relay\\- Media Connectivity Check Failure",
     "Media connectivity check failure", "media_connectivity_failure"),
]


def _is_numeric(s):
    if s == None or s == "":
        return False
    neg = 0
    if s[0] == "-":
        neg = 1
    digits = s[neg:]
    if digits == "":
        return False
    has_dot = False
    for ch in digits:
        if ch == ".":
            if has_dot:
                return False
            has_dot = True
            continue
        if ch < "0" or ch > "9":
            return False
    return True


def _parse_typeperf_out(out):
    """Parse `typeperf -c ... -o - -si 1` output lines.

    Returns dict keyed by counter path -> value(float). Each line:
      "2020-01-01 00:00:00.000","<path>","<value>"
    """
    values = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        if len(parts) < 3:
            continue
        path = parts[1].strip().strip('"')
        raw_val = parts[-1].strip().strip('"')
        if raw_val == "":
            continue
        num = float(raw_val) if _is_numeric(raw_val) else 0.0
        values[path] = num
    return values


def _grade_upper(value, levels):
    if not levels:
        return "OK"
    upper = levels.get("upper")
    if upper == None:
        return "OK"
    warn = upper[0]
    crit = upper[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _run_typeperf(ctx, counter_paths):
    """Run typeperf for the given counter paths, return {path: float}.

    Returns None if the command failed (rc != 0), which the caller treats as
    absent data.
    """
    args = ["typeperf"]
    for p in counter_paths:
        args = args + ["-c", p]
    args = args + ["-o", "-", "-si", "1", "-sc", "1"]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return None
    return _parse_typeperf_out(res.stdout)


def _mediation_counter_paths():
    paths = []
    for _perfvar, cpath, _label, _key in MEDIATION_COUNTERS:
        paths.append(cpath)
    return paths


def main(ctx, params):
    if params.get("_discover"):
        paths = _mediation_counter_paths()
        vals = _run_typeperf(ctx, paths)
        if vals == None:
            return {"changed": False,
                    "msg": "discovery: no Skype Mediation Server data available",
                    "data": {"discovery": []}}
        found = False
        for cpath in paths:
            if cpath in vals:
                found = True
                break
        if not found:
            return {"changed": False,
                    "msg": "discovery: no Skype Mediation Server counters found",
                    "data": {"discovery": []}}
        metrics = []
        for perfvar, _cpath, _label, _key in MEDIATION_COUNTERS:
            metrics.append(perfvar)
        return {"changed": False,
                "msg": "discovered 1 Skype Mediation Server service",
                "data": {"discovery": [
                    {"item": "",
                     "params": DEFAULTS_MEDIATION,
                     "metrics": metrics}]}}
    item = params.get("item", "")
    if item != "":
        return {"changed": False,
                "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    paths = _mediation_counter_paths()
    vals = _run_typeperf(ctx, paths)
    if vals == None:
        return {"changed": False,
                "msg": "no Skype Mediation Server data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics_out = {}
    details_lines = []
    worst = "OK"
    for perfvar, cpath, label, key in MEDIATION_COUNTERS:
        if cpath not in vals:
            details_lines.append(label + ": (no data)")
            continue
        value = vals[cpath]
        levels = params.get(key, {})
        st = _grade_upper(value, levels)
        metrics_out[perfvar] = value
        details_lines.append(label + ": %f" % value)
        if st == "CRIT":
            worst = "CRIT"
        elif st == "WARN" and worst == "OK":
            worst = "WARN"
    if len(metrics_out) == 0:
        return {"changed": False,
                "msg": "no Skype Mediation Server counters readable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    summary = "; ".join(details_lines)
    return {"changed": False,
            "msg": summary,
            "data": {"state": worst,
                     "metrics": metrics_out,
                     "details": summary}}