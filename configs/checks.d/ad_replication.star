UNKNOWN_TIMESTAMPS = ["0", "(never)", ""]

def _is_iso_date(s):
    return len(s) >= 10 and s[4] == "-" and s[7] == "-"

def _strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s

def _parse_repl_line(raw):
    processed = raw.replace(",CN=", ";CN=").replace(",DC=", ";DC=").replace(",OU=", ";OU=")
    return [_strip_quotes(f.strip()) for f in processed.split(",")]

def _safe_int(s):
    s = s.strip()
    if s.isdigit():
        return int(s)
    return 0

def main(ctx, params):
    res = ctx.run(["repadmin", "/showrepl", "/csv"], mutates=False)
    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "repadmin failed: " + res.stderr,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "repadmin failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data_lines = []
    for raw in res.stdout.splitlines():
        raw = raw.strip()
        if raw == "" or raw.lower().startswith("destination"):
            continue
        parts = _parse_repl_line(raw)
        if len(parts) == 10:
            data_lines.append(parts)

    if params.get("_discover"):
        seen = []
        discovery = []
        for parts in data_lines:
            entry = parts[3] + "/" + parts[4]
            if entry not in seen:
                seen.append(entry)
                discovery.append({
                    "item": entry,
                    "params": {"failure_levels": [15, 20]},
                    "metrics": ["num_failures", "failed_repl_count"],
                })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    levels = params.get("failure_levels", [15, 20])
    max_warn = levels[0]
    max_crit = levels[1]

    found = False
    status = 0
    count_failures = 0
    count_failed_repl = 0
    details = []

    for parts in data_lines:
        src_site = parts[3]
        src_dc = parts[4]
        if src_site + "/" + src_dc != item:
            continue

        found = True
        naming_ctx = parts[2]
        num_fail = _safe_int(parts[6])
        t_fail = parts[7].strip()
        t_success = parts[8].strip()
        fail_status = parts[9].strip()

        t_fail_label = t_fail if t_fail not in UNKNOWN_TIMESTAMPS else "never"
        t_success_label = t_success if t_success not in UNKNOWN_TIMESTAMPS else "never"

        if num_fail > max_warn or num_fail > max_crit:
            if num_fail > max_crit:
                status = 2
                marker = "(!!)"
            else:
                if status < 1:
                    status = 1
                marker = "(!)"
            count_failures += num_fail
            count_failed_repl += 1
            details.append(
                "%s/%s context %s reached threshold (%d failures >= %d) (last_ok=%s last_fail=%s status=%s)%s" % (
                    src_site, src_dc, naming_ctx,
                    num_fail, max_warn,
                    t_success_label, t_fail_label, fail_status, marker,
                )
            )

        fail_valid = t_fail not in UNKNOWN_TIMESTAMPS and _is_iso_date(t_fail)
        success_valid = t_success not in UNKNOWN_TIMESTAMPS and _is_iso_date(t_success)
        if fail_valid and success_valid and t_fail > t_success:
            status = 2
            count_failures += 1
            count_failed_repl += 1
            details.append(
                "%s/%s context %s failed: last failure (%s) newer than last success (%s) [fails=%d status=%s](!!)" % (
                    src_site, src_dc, naming_ctx,
                    t_fail, t_success, num_fail, fail_status,
                )
            )

    if not found:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if status == 2:
        state_str = "CRIT"
    elif status == 1:
        state_str = "WARN"
    else:
        state_str = "OK"

    if status == 0:
        msg = "All replications are OK."
    else:
        msg = "Replications with failures: %d, Total failures: %d" % (
            count_failed_repl, count_failures)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": {"num_failures": count_failures, "failed_repl_count": count_failed_repl},
            "details": "\n".join(details),
        },
    }