def _render_timespan(seconds):
    seconds = int(seconds)
    if seconds < 0:
        seconds = 0
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    if days > 0:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours > 0:
        return "%dh %dm %ds" % (hours, minutes, secs)
    if minutes > 0:
        return "%dm %ds" % (minutes, secs)
    return "%ds" % secs


def _parse_datetime(date_text, time_text):
    # date_text: "DD.MM.YYYY", time_text: "HH:MM:SS"
    parts = date_text.split(".")
    if len(parts) != 3:
        return None
    day_str, month_str, year_str = parts
    if not (day_str.isdigit() and month_str.isdigit() and year_str.isdigit()):
        return None
    day = int(day_str)
    month = int(month_str)
    year = int(year_str)
    tparts = time_text.split(":")
    if len(tparts) != 3:
        return None
    if not (tparts[0].isdigit() and tparts[1].isdigit() and tparts[2].isdigit()):
        return None
    hour = int(tparts[0])
    minute = int(tparts[1])
    second = int(tparts[2])
    if month < 1 or month > 12:
        return None
    if day < 1 or day > 31:
        return None
    if hour < 0 or hour > 23:
        return None
    if minute < 0 or minute > 59:
        return None
    if second < 0 or second > 59:
        return None
    days_in_month = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if day > days_in_month[month - 1]:
        return None
    # Compute epoch using days from 1970-01-01
    total_days = 0
    for y in range(1970, year):
        if _is_leap(y):
            total_days += 366
        else:
            total_days += 365
    for m in range(1, month):
        total_days += days_in_month[m - 1]
    total_days += day - 1
    return total_days * 86400 + hour * 3600 + minute * 60 + second


def _is_leap(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


def main(ctx, params):
    # Probe for the real Kaspersky AV client on this host
    probe = ctx.run(["klnagchk", "-p"], mutates=False)
    if probe.rc == 127 or (probe.rc != 0 and not probe.stdout):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "klnagchk not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get current time as epoch seconds
    now_res = ctx.run(["date", "+%s"], mutates=False)
    if not now_res.stdout or not now_res.stdout.strip().isdigit():
        current_time = 0.0
    else:
        current_time = float(now_res.stdout.strip())

    section = {}
    if probe.rc == 0 and probe.stdout:
        for line in probe.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2 or parts[1] == "Missing":
                continue
            date_text = parts[1]
            time_text = parts[2] if len(parts) > 2 else "00:00:00"
            parsed_time = _parse_datetime(date_text, time_text)
            if parsed_time == None:
                continue
            age = current_time - parsed_time
            if parts[0] == "Signatures":
                section["signature_age"] = age
            elif parts[0] == "Fullscan":
                section["fullscan_age"] = age
                if len(parts) == 4:
                    section["fullscan_failed"] = parts[3] != "0"

    if params.get("_discover"):
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {
                                "signature_age": (86400, 7 * 86400),
                                "fullscan_age": (86400, 7 * 86400),
                            },
                            "metrics": ["signature_age", "fullscan_age"],
                        }
                    ],
                    "host_labels": {},
                },
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    sig_levels = params.get("signature_age", (86400, 7 * 86400))
    full_levels = params.get("fullscan_age", (86400, 7 * 86400))

    results = []

    sig_age = section.get("signature_age")
    if sig_age == None:
        results.append({"state": "UNKNOWN", "summary": "Last update of signatures unkown", "details": "", "metrics": {}})
    else:
        state = "OK"
        if sig_age >= sig_levels[1]:
            state = "CRIT"
        elif sig_age >= sig_levels[0]:
            state = "WARN"
        results.append({
            "state": state,
            "summary": "Last update of signatures: %s ago" % _render_timespan(sig_age),
            "details": "",
            "metrics": {"signature_age": sig_age},
        })

    full_age = section.get("fullscan_age")
    if full_age == None:
        results.append({"state": "UNKNOWN", "summary": "Last fullscan unkown", "details": "", "metrics": {}})
    else:
        state = "OK"
        if full_age >= full_levels[1]:
            state = "CRIT"
        elif full_age >= full_levels[0]:
            state = "WARN"
        results.append({
            "state": state,
            "summary": "Last fullscan: %s ago" % _render_timespan(full_age),
            "details": "",
            "metrics": {"fullscan_age": full_age},
        })

    if section.get("fullscan_failed"):
        results.append({"state": "CRIT", "summary": "Last fullscan failed", "details": "", "metrics": {}})

    if len(results) == 0:
        return {"changed": False, "msg": "no kaspersky data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_priority = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst_state = "OK"
    worst_summary = ""
    all_metrics = {}
    all_details = []
    for r in results:
        r_pri = state_priority.get(r["state"], 3)
        w_pri = state_priority.get(worst_state, 0)
        if r_pri > w_pri:
            worst_state = r["state"]
            worst_summary = r["summary"]
        elif r_pri == w_pri and r_pri > 0:
            worst_summary = r["summary"]
        elif worst_state == "OK" and r["state"] == "OK" and worst_summary == "":
            worst_summary = r["summary"]
        all_metrics.update(r["metrics"])
        if r["details"]:
            all_details.append(r["details"])

    return {
        "changed": False,
        "msg": worst_summary,
        "data": {
            "state": worst_state,
            "metrics": all_metrics,
            "details": "\n".join(all_details),
        },
    }