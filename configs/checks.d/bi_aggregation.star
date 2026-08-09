def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/var/lib/check-mk-agent/local/bi_aggregation"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        content = ctx.file_read("/var/lib/check-mk-agent/local/bi_aggregation")
        if not content.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        items = []
        for line in content.splitlines():
            line = line.strip()
            if not line:
                continue
            if not (line.startswith("{") and line.endswith("}")):
                continue
            obj = json.decode(line) if line else None
            if obj == None or type(obj) != "dict":
                continue
            for key in obj.keys():
                items.append({"item": key, "params": {},
                              "metrics": []})
        return {"changed": False, "msg": "discovered %d aggregations" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not ctx.file_exists("/var/lib/check-mk-agent/local/bi_aggregation"):
        return {"changed": False, "msg": "bi_aggregation file missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/var/lib/check-mk-agent/local/bi_aggregation")
    data = None
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        if not (line.startswith("{") and line.endswith("}")):
            continue
        obj = json.decode(line) if line else None
        if obj == None or type(obj) != "dict":
            continue
        if obj.get(item) != None:
            data = obj.get(item)
            break

    if data == None:
        return {"changed": False, "msg": "aggregation not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    overall_state = data.get("state_computed_by_agent", 3)
    if overall_state == -1:
        overall_state = 0
    state_map = {0: "Ok", 1: "Warning", 2: "Critical", 3: "Unknown", -1: "Pending"}
    state_str = state_map.get(overall_state, "Unknown")

    state = "OK"
    if overall_state == 1:
        state = "WARN"
    elif overall_state == 2:
        state = "CRIT"
    elif overall_state == 3:
        state = "UNKNOWN"

    downtime = "yes" if data.get("in_downtime", False) else "no"
    acknowledged = "yes" if data.get("acknowledged", False) else "no"

    details = ""
    if data.get("infos") != None:
        error_state = data.get("error", {}).get("state")
        custom_output = data.get("custom", {}).get("output")
        if error_state != None:
            details = "+-- Error during aggregation"
        elif custom_output != None:
            details = custom_output

    return {
        "changed": False,
        "msg": "Aggregation state: %s, In downtime: %s, Acknowledged: %s" % (state_str, downtime, acknowledged),
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }