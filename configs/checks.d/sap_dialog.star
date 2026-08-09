# Checkmk check translation: checkmk.sap_dialog
# Monitors SAP dialog server entries gathered by the "sap" section.
# This module is read-only.

# The path prefix used to identify dialog-related entries.
RESPONSE_TIME_PATH = "SAP CCMS Monitor Templates/Dialog Overview/"

# Map SAP color codes (key values) to Nagios state codes.
_SAP_NAGIOS_STATE_MAP = {
    0: "OK",    # GRAY  (inactive or no current info available) -> OK
    1: "OK",    # GREEN  -> OK
    2: "WARN",  # YELLOW -> WARNING
    3: "CRIT",  # RED    -> CRITICAL
}


def _safe_float(raw):
    """Try to parse a float from raw; return 0.0 on failure."""
    if raw == None or not _is_number(raw):
        return 0.0
    return float(raw)


def _is_number(s):
    """Return True if the string s represents a valid number."""
    if s == "" or s == None:
        return False
    cleaned = s.strip()
    if cleaned == "" or cleaned == None:
        return False
    # Handle optional leading sign
    start = 0
    if cleaned[0] == "-" or cleaned[0] == "+":
        start = 1
        if len(cleaned) == 1:
            return False
    has_digit = False
    has_dot = False
    for i in range(start, len(cleaned)):
        c = cleaned[i]
        if c.isdigit():
            has_digit = True
        elif c == "." and not has_dot:
            has_dot = True
        else:
            return False
    return has_digit


def _clean_perf_key(s):
    """Make a string safe for use as a metric name."""
    out = s.replace("(", "_").replace(")", "_").replace(" ", "_").replace(".", "_")
    # rstrip "_" equivalent
    while len(out) > 0 and out[len(out) - 1] == "_":
        out = out[:len(out) - 1]
    return out


def discover_sap(ctx, params):
    """Discovery: enumerate SID entries that have a Dialog Response Time entry."""
    res = ctx.run(["sap_dialog_data"], mutates=False)
    if res.rc != 0:
        # No SAP data available on this host.
        return {"changed": False, "msg": "no SAP data available", "data": {"discovery": []}}

    out = []
    seen = {}
    for line in res.stdout.splitlines():
        f = line.split()
        # Expected columns: sid state _unused path reading unit [output...]
        if len(f) < 7:
            continue
        sid = f[0]
        path = f[4]
        if path != "%sDialog Response Time/ResponseTime" % RESPONSE_TIME_PATH:
            continue
        if sid in seen:
            continue
        seen[sid] = True
        entry = {"item": sid, "params": {}, "metrics": ["value"]}
        out.append(entry)

    return {"changed": False, "msg": "discovered %d SAP dialog instances" % len(out),
            "data": {"discovery": out}}


def check_sap(ctx, params):
    """Check one SAP dialog instance (item = SID)."""
    item = params.get("item", "")

    res = ctx.run(["sap_dialog_data"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "no SAP data available for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the section into Entry-like dicts.
    entries = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 7:
            continue
        sid = f[0]
        state_raw = f[1]
        path = f[4]
        reading_raw = f[5]
        unit = f[6]
        output = " ".join(f[7:])

        state_code_int = int(state_raw) if state_raw.isdigit() else 0
        # Handle negative or invalid: guard against non-digit
        if not state_raw.lstrip("-").isdigit():
            state_code_int = 0
        state = _SAP_NAGIOS_STATE_MAP.get(state_code_int, "OK")

        reading = None if reading_raw == "-" else _safe_float(reading_raw)

        entry = {"sid": sid, "state": state, "path": path,
                 "reading": reading, "unit": unit, "output": output}
        entries.append(entry)

    # Collect dialog metrics for the requested SID.
    dialog = {}
    for entry in entries:
        if entry["sid"] == item and entry["path"].startswith(RESPONSE_TIME_PATH) and entry["reading"] != None:
            key = entry["path"].split("/")[-1]
            dialog[key] = (entry["reading"], entry["unit"])

    if not dialog:
        return {"changed": False,
                "msg": "no dialog output for SAP instance %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build metrics using perf-clean keys.
    metrics = {}
    for key, (value, unit) in dialog.items():
        metric_name = _clean_perf_key(key)
        metrics[metric_name] = value

    # Determine overall state from the raw SAP state of dialog entries.
    state = "OK"
    for entry in entries:
        if entry["sid"] == item and entry["path"].startswith(RESPONSE_TIME_PATH):
            if entry["state"] == "CRIT":
                state = "CRIT"
            elif entry["state"] == "WARN" and state != "CRIT":
                state = "WARN"

    # Build a one-line summary (Checkmk-style).
    detail_parts = []
    for key, (value, unit) in dialog.items():
        if unit == "-":
            detail_parts.append("%s: %f" % (key, value))
        else:
            detail_parts.append("%s: %f %s" % (key, value, unit))
    summary = "; ".join(detail_parts) if detail_parts else "no dialog metrics"

    return {"changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def main(ctx, params):
    if params.get("_discover"):
        return discover_sap(ctx, params)
    return check_sap(ctx, params)