def main(ctx, params):
    if params.get("_discover"):
        if ctx.file_exists("/var/lib/check-mk-agent/cache/ciena_health.json"):
            return {
                "changed": False,
                "msg": "discovered 1 health service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no ciena health data available",
                "data": {"discovery": []}
            }

    if not ctx.file_exists("/var/lib/check-mk-agent/cache/ciena_health.json"):
        return {
            "changed": False,
            "msg": "health data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    content = ctx.file_read("/var/lib/check-mk-agent/cache/ciena_health.json")
    data = json.decode(content)

    good_values = {
        "TceHealthStatus": "normal",
        "PowerSupplyState": "online",
        "FanStatus": "ok",
        "LeoSystemState": "normal",
        "LeoPowerSupplyState": "online",
        "LeoFanStatus": "ok"
    }

    total_items = 0
    bad_items = 0
    details_parts = []
    summary_parts = []

    for entry in data:
        display_name = entry.get("display_name", "")
        data_type = entry.get("data_type", "")
        occurrences = entry.get("occurrences", {})
        good_val = good_values.get(data_type, "")
        num_total = 0
        for _ in range(len(occurrences)):
            num_total = num_total + occurrences.values()[_] if len(occurrences.values()) > _ else num_total
        total_items = total_items + num_total

        if not good_val:
            continue

        good_count = occurrences.get(good_val, 0)
        is_all_good = num_total == good_count and num_total > 0
        if not is_all_good:
            bad_items = bad_items + 1

        detail = "%d %s | " % (num_total, display_name)
        items_list = list(occurrences.items())
        for i in range(len(items_list)):
            if i > 0:
                detail = detail + ", "
            detail = detail + "%s: %d" % (items_list[i][0], items_list[i][1])
        details_parts.append(detail)

        if num_total > 0:
            summary_parts.append("%d %s" % (num_total, display_name))

    state = "CRIT" if bad_items > 0 else "OK"

    if total_items == 0:
        summary_text = "No health items"
    elif bad_items == 0:
        summary_text = "%d items, all good" % total_items
    else:
        summary_text = "%d items, some not good" % total_items

    details_text = ""
    for i in range(len(details_parts)):
        if i > 0:
            details_text = details_text + "; "
        details_text = details_text + details_parts[i]

    return {
        "changed": False,
        "msg": summary_text,
        "data": {
            "state": state,
            "metrics": {},
            "details": details_text
        }
    }
