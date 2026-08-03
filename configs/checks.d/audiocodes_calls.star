# cmk-translated Starlark module for audiocodes_calls (SBC calls)
# Read-only SNMP check: walks the AudioCodes SBC call-monitoring scalar table
# and reports the configured metrics with threshold logic.

_AUDIOCODES_CALLS_BASE = ".1.3.6.1.4.1.5003.15.3.1.1.1"

_AUDIOCODES_METRICS = [
    ("audiocodes_average_call_duration",                "1"),
    ("audiocodes_active_calls_in",                      "2"),
    ("audiocodes_active_calls_out",                     "3"),
    ("audiocodes_established_calls_in",                 "10"),
    ("audiocodes_established_calls_out",                "11"),
    ("audiocodes_answer_seizure_ratio",                 "12"),
    ("audiocodes_network_effectiveness_ratio",          "13"),
    ("audiocodes_abnormal_terminated_calls_in_total",   "35"),
    ("audiocodes_abnormal_terminated_calls_out_total",  "36"),
]

_DEFAULT_ANSWER_SEIZURE_RATIO_LOWER = (60.0, 50.0)
_DEFAULT_NETWORK_EFFECTIVENESS_LOWER  = (95.0, 90.0)


def _snset_get_int(ctx, params, oid):
    res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        oid,
    ], mutates=False)
    if res.rc != 0:
        return None
    raw = res.stdout.strip()
    if raw == "":
        return None
    if raw == "None":
        return None
    if not raw.lstrip("-").isdigit():
        return None
    return int(raw)


def _probe_product_present(ctx, params):
    res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    if res.rc == 127:
        return {"present": False, "reason": "snmpget not installed"}
    if res.rc != 0 or res.stdout.strip() == "":
        return {"present": False, "reason": "device unreachable or no SNMP response"}
    return {"present": True, "reason": ""}


def _fmt_int(v):
    return str(v)


def _fmt_rate(v):
    return "%f/s" % float(v)


def _fmt_percent(v):
    return "%f%%" % float(v)


def _fmt_timespan(v):
    days = int(v // 86400)
    hours = int((v % 86400) // 3600)
    mins = int((v % 3600) // 60)
    secs = int(v % 60)
    parts = []
    if days > 0:
        parts.append("%dd" % days)
    if hours > 0 or days > 0:
        parts.append("%dh" % hours)
    if mins > 0 or hours > 0 or days > 0:
        parts.append("%dm" % mins)
    parts.append("%ds" % secs)
    return " ".join(parts)


def _gather_values(ctx, params):
    values = {}
    for name, suffix in _AUDIOCODES_METRICS:
        oid = _AUDIOCODES_CALLS_BASE + "." + suffix
        values[name] = _snset_get_int(ctx, params, oid)
    return values


def _apply_metric(state_acc, metrics, details_lines, value, metric_name, label, warn, crit, render_fn):
    if value == None:
        return
    metrics[metric_name] = value
    rendered = render_fn(value)
    details_lines.append("%s: %s" % (label, rendered))
    if crit != None and value <= crit:
        state_acc["state"] = "CRIT"
    elif warn != None and value <= warn:
        if state_acc["state"] != "CRIT":
            state_acc["state"] = "WARN"


def main(ctx, params):
    if params.get("_discover"):
        probe = _probe_product_present(ctx, params)
        if not probe["present"]:
            return {
                "changed": False,
                "msg": "AudioCodes SBC not detected (%s)" % probe["reason"],
                "data": {"discovery": []},
            }
        any_readable = False
        for _, suffix in _AUDIOCODES_METRICS:
            oid = _AUDIOCODES_CALLS_BASE + "." + suffix
            if _snset_get_int(ctx, params, oid) != None:
                any_readable = True
                break
        if not any_readable:
            return {
                "changed": False,
                "msg": "AudioCodes SBC present but no call metrics readable",
                "data": {"discovery": []},
            }
        metric_names = [name for name, _ in _AUDIOCODES_METRICS]
        return {
            "changed": False,
            "msg": "discovered SBC calls service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": metric_names}
                ],
            },
        }

    probe = _probe_product_present(ctx, params)
    if not probe["present"]:
        return {
            "changed": False,
            "msg": "AudioCodes SBC not reachable (%s)" % probe["reason"],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    values = _gather_values(ctx, params)
    metrics = {}
    details_lines = []
    state_acc = {"state": "OK"}

    av = values.get("audiocodes_average_call_duration")
    _apply_metric(state_acc, metrics, details_lines, av,
                  "audiocodes_average_call_duration",
                  "Average call duration", None, None, _fmt_timespan)

    avi = values.get("audiocodes_active_calls_in")
    _apply_metric(state_acc, metrics, details_lines, avi,
                  "audiocodes_active_calls_in",
                  "Active calls in", None, None, _fmt_int)

    avo = values.get("audiocodes_active_calls_out")
    _apply_metric(state_acc, metrics, details_lines, avo,
                  "audiocodes_active_calls_out",
                  "Active calls out", None, None, _fmt_int)

    eci = values.get("audiocodes_established_calls_in")
    _apply_metric(state_acc, metrics, details_lines, eci,
                  "audiocodes_established_calls_in",
                  "Established calls in rate", None, None, _fmt_rate)

    eco = values.get("audiocodes_established_calls_out")
    _apply_metric(state_acc, metrics, details_lines, eco,
                  "audiocodes_established_calls_out",
                  "Established calls out rate", None, None, _fmt_rate)

    asr_levels = params.get("answer_seizure_ratio_lower_levels", _DEFAULT_ANSWER_SEIZURE_RATIO_LOWER)
    warn_asr = asr_levels[0] if len(asr_levels) == 2 else None
    crit_asr = asr_levels[1] if len(asr_levels) == 2 else None
    asr_val = values.get("audiocodes_answer_seizure_ratio")
    _apply_metric(state_acc, metrics, details_lines, asr_val,
                  "audiocodes_answer_seizure_ratio",
                  "Answer seizure ratio", warn_asr, crit_asr, _fmt_percent)

    ner_levels = params.get("network_effectiveness_ratio_lower_levels", _DEFAULT_NETWORK_EFFECTIVENESS_LOWER)
    warn_ner = ner_levels[0] if len(ner_levels) == 2 else None
    crit_ner = ner_levels[1] if len(ner_levels) == 2 else None
    ner_val = values.get("audiocodes_network_effectiveness_ratio")
    _apply_metric(state_acc, metrics, details_lines, ner_val,
                  "audiocodes_network_effectiveness_ratio",
                  "Network effectiveness ratio", warn_ner, crit_ner, _fmt_percent)

    ati = values.get("audiocodes_abnormal_terminated_calls_in_total")
    _apply_metric(state_acc, metrics, details_lines, ati,
                  "audiocodes_abnormal_terminated_calls_in_total",
                  "Abnormal terminated calls in", None, None, _fmt_int)

    ato = values.get("audiocodes_abnormal_terminated_calls_out_total")
    _apply_metric(state_acc, metrics, details_lines, ato,
                  "audiocodes_abnormal_terminated_calls_out_total",
                  "Abnormal terminated calls out", None, None, _fmt_int)

    summary = ", ".join(details_lines) if details_lines else "no call metrics available"
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_acc["state"],
            "metrics": metrics,
            "details": "\n".join(details_lines),
        },
    }