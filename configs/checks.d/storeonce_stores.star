def main(ctx, params):
    # Probe for the StoreOnce product via its CLI.
    res = ctx.run(["storeonce_cli_stores", "--json"], mutates=False)
    if res.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "StoreOnce CLI not found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no StoreOnce installation found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if res.rc != 0 or not res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "StoreOnce data unavailable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no StoreOnce data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data_list = json.decode(res.stdout)

    section = {}
    if type(data_list) == "list":
        for entry in data_list:
            if type(entry) == "dict":
                key = "ServiceSet %s Store %s" % (entry.get("ServiceSet ID", ""), entry.get("Name", ""))
                section[key] = entry

    if params.get("_discover"):
        discovery = []
        for key in sorted(section.keys()):
            discovery.append({
                "item": key,
                "params": {},
                "metrics": ["data_size", "dedup_rate"],
            })
        return {"changed": False,
                "msg": "discovered %d storeonce stores" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    values = section.get(item)
    if values == None:
        return {"changed": False, "msg": "no such storeonce store: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    health_level = str(values.get("Health Level", "0"))
    state_map = {"0": "OK", "1": "WARN", "2": "CRIT"}
    state = state_map.get(health_level, "UNKNOWN")

    details = "Status: %s" % values.get("Status", "")

    metrics = {}
    metrics["data_size"] = float(values.get("diskBytes", 0) or 0)
    if "Dedupe Ratio" in values:
        metrics["dedup_rate"] = float(values.get("Dedupe Ratio", 0) or 0)

    description = values.get("Description")
    if description:
        details = details + "\nDescription: %s" % description

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}