COUNTER_SUFFIXES = [
    "i/o database reads (attached) average latency",
    "i/o database reads (recovery) average latency",
    "i/o database writes (attached) average latency",
    "i/o log writes average latency",
]

COUNTER_DISPLAY = [
    "I/O Database Reads (Attached) Average Latency",
    "I/O Database Reads (Recovery) Average Latency",
    "I/O Database Writes (Attached) Average Latency",
    "I/O Log Writes Average Latency",
]

PARAM_KEYS = [
    "read_attached_latency_s",
    "read_recovery_latency_s",
    "write_latency_s",
    "log_latency_s",
]

METRIC_NAMES = [
    "db_read_latency_s",
    "db_read_recovery_latency_s",
    "db_write_latency_s",
    "db_log_latency_s",
]

METRIC_LABELS = [
    "DB read (attached) latency",
    "DB read (recovery) latency",
    "DB write (attached) latency",
    "Log latency",
]

DEFAULT_WARN = [0.2, 0.15, 0.04, 0.005]
DEFAULT_CRIT = [0.25, 0.2, 0.05, 0.01]


def _strip_log_verifier(instance):
    if "/log verifier" in instance.lower():
        parts = instance.rsplit(" ", 1)
        if len(parts) > 1:
            return parts[0]
    return instance


def _parse_json_array(raw):
    s = raw.strip()
    if not s or s == "null":
        return []
    if not s.startswith("["):
        if s.startswith('"') or s.startswith("{"):
            s = "[" + s + "]"
        else:
            return []
    return json.decode(s)


def main(ctx, params):
    if params.get("_discover"):
        ps = (
            "$r = Get-Counter '\\MSExchange Database(*)\\I/O Database Reads (Attached) Average Latency'"
            + " -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue;"
            + " if ($r) {"
            + " ConvertTo-Json -Compress -InputObject @($r.CounterSamples.InstanceName | Sort-Object -Unique)"
            + " } else { '[]' }"
        )
        res = ctx.run(
            ["powershell", "-NonInteractive", "-Command", ps],
            mutates=False,
            ok_codes=[0, 1],
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 instances",
                    "data": {"discovery": []}}

        instances_raw = _parse_json_array(res.stdout)
        out = []
        seen = {}
        for inst in instances_raw:
            if type(inst) != "string":
                continue
            norm = _strip_log_verifier(inst)
            if norm in seen:
                continue
            seen[norm] = True
            out.append({
                "item": norm,
                "params": {
                    "read_attached_latency_s": [0.2, 0.25],
                    "read_recovery_latency_s": [0.15, 0.2],
                    "write_latency_s": [0.04, 0.05],
                    "log_latency_s": [0.005, 0.01],
                },
                "metrics": list(METRIC_NAMES),
            })
        return {"changed": False, "msg": "discovered %d instances" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    base = "\\MSExchange Database(" + item + ")\\"
    counters = [
        "'" + base + COUNTER_DISPLAY[0] + "'",
        "'" + base + COUNTER_DISPLAY[1] + "'",
        "'" + base + COUNTER_DISPLAY[2] + "'",
        "'" + base + COUNTER_DISPLAY[3] + "'",
    ]
    ps = (
        "$c = @(" + ",".join(counters) + ");"
        + " $r = Get-Counter -Counter $c -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue;"
        + " if ($r) { ConvertTo-Json -Compress -InputObject @($r.CounterSamples | Select-Object Path,CookedValue) }"
        + " else { '[]' }"
    )
    res = ctx.run(
        ["powershell", "-NonInteractive", "-Command", ps],
        mutates=False,
        ok_codes=[0, 1],
    )

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data for instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    samples = _parse_json_array(res.stdout)
    if not samples:
        return {"changed": False, "msg": "no counters found for instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx_values = {}
    for sample in samples:
        if type(sample) != "dict":
            continue
        path = sample.get("Path", None)
        cooked = sample.get("CookedValue", None)
        if path == None or cooked == None:
            continue
        path_lc = path.lower()
        for i in range(4):
            if path_lc.endswith(COUNTER_SUFFIXES[i]):
                idx_values[i] = float(cooked) / 1000.0
                break

    state = "OK"
    msgs = []
    metrics = {}

    for i in range(4):
        val = idx_values.get(i, None)
        if val == None:
            continue

        levels = params.get(PARAM_KEYS[i], [DEFAULT_WARN[i], DEFAULT_CRIT[i]])
        warn = levels[0] if len(levels) > 0 else DEFAULT_WARN[i]
        crit = levels[1] if len(levels) > 1 else DEFAULT_CRIT[i]

        if val >= crit:
            s = "CRIT"
        elif val >= warn:
            s = "WARN"
        else:
            s = "OK"

        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN" and state == "OK":
            state = "WARN"

        metrics[METRIC_NAMES[i]] = val
        msgs.append("%s: %f s" % (METRIC_LABELS[i], val))

    if not msgs:
        return {"changed": False, "msg": "no metrics for instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }