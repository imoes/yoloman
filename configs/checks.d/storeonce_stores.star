# Top-level constants and helpers
STATE_MAP = {
    "0": "UNKNOWN",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
}

def _parse_storeonce_stores(lines):
    """Parse raw agent output into a dict: {item: {field: value}, ...}"""
    section = {}
    current = None
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Detect ServiceSet section header
        if stripped.startswith("[") and stripped.endswith("]"):
            continue
        # Split on first tab
        if "\t" in stripped:
            parts = stripped.split("\t", 1)
            key = parts[0].strip()
            value = parts[1].strip() if len(parts) > 1 else ""
        else:
            # Try space-separated
            idx = stripped.find(" ")
            if idx != -1:
                key = stripped[:idx].strip()
                value = stripped[idx + 1:].strip()
            else:
                key = stripped
                value = ""
        if key == "Name":
            current = {"Name": value}
        elif key == "ServiceSet ID":
            if current != None:
                item_key = "ServiceSet " + value + " Store " + current.get("Name", "")
                section[item_key] = current
                current = None
        elif current != None:
            if key == "Health Level":
                current["Health Level"] = value
            elif key == "Status":
                current["Status"] = value
            elif key == "Description":
                current["Description"] = value
            elif key == "diskBytes":
                current["diskBytes"] = value
            elif key == "Dedupe Ratio" and "Dedupe Ratio" not in current:
                current["Dedupe Ratio"] = value
    return section

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["storeonce_stores"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "no data from agent section storeonce_stores",
                    "data": {"discovery": []}}
        section = _parse_storeonce_stores(res.stdout.splitlines())
        discovery = []
        for item in section:
            discovery.append({"item": item, "params": {}, "metrics": ["data_size", "dedup_rate"]})
        return {"changed": False, "msg": "discovered %d stores" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["storeonce_stores"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no data from agent section storeonce_stores",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_storeonce_stores(res.stdout.splitlines())
    values = section.get(item)
    if values == None:
        return {"changed": False, "msg": "store not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine state from Health Level
    health_level = values.get("Health Level", "0")
    state_str = STATE_MAP.get(health_level, "UNKNOWN")
    state = state_str

    # Build message
    msg_parts = []
    status = values.get("Status", "Unknown")
    msg_parts.append("Status: " + status)
    summary = ", ".join(msg_parts)

    metrics = {}
    # Size metric: diskBytes (bytes)
    disk_bytes = values.get("diskBytes")
    if disk_bytes != None and disk_bytes.isdigit():
        size = float(disk_bytes)
        metrics["data_size"] = size

    # Dedup ratio metric
    dedup = values.get("Dedupe Ratio")
    if dedup != None:
        if dedup.replace(".", "").isdigit():
            metrics["dedup_rate"] = float(dedup)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }