SAP_STATE_MAP = {
    0: "OK",
    1: "OK",
    2: "WARN",
    3: "CRIT",
}

def _is_numeric(s):
    if not s:
        return False
    clean = s.lstrip("-")
    if not clean:
        return False
    parts = clean.split(".")
    if len(parts) > 2:
        return False
    ok = True
    for p in parts:
        if p != "" and not p.isdigit():
            ok = False
    return ok

def _safe_float(s):
    return float(s) if _is_numeric(s) else 0.0

def _parse_sap_data(content):
    entries = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        sid = parts[0].strip()
        state_raw = parts[1].strip()
        path = parts[3].strip()
        reading_raw = parts[4].strip()
        unit = parts[5].strip()
        output_parts = []
        for i in range(6, len(parts)):
            output_parts.append(parts[i].strip())
        output = " ".join(output_parts)

        state_int = int(state_raw) if state_raw.isdigit() else 1
        if state_int < 0 or state_int > 3:
            state_int = 1

        reading = None
        if reading_raw != "-" and reading_raw != "":
            reading = _safe_float(reading_raw)

        entries.append({
            "sid": sid,
            "state": state_int,
            "path": path,
            "reading": reading,
            "unit": unit,
            "output": output,
        })
    return entries

def _item_path(entry, limit):
    path = entry["path"]
    if limit != None and limit > 0:
        parts = path.split("/")
        start = len(parts) - limit
        if start < 0:
            start = 0
        return "/".join(parts[start:])
    return path

def main(ctx, params):
    data_file = params.get("data_file", "/var/lib/agentic/sap/data.tsv")

    if not ctx.file_exists(data_file):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "SAP data file not found: " + data_file,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(data_file)
    entries = _parse_sap_data(content)

    if params.get("_discover"):
        discovered = []
        seen = set()
        for entry in entries:
            item = entry["sid"] + " " + entry["path"]
            if item not in seen:
                seen.add(item)
                disc_metrics = ["value"] if entry["reading"] != None else []
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": disc_metrics,
                })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovered),
                "data": {"discovery": discovered}}

    item = params.get("item", "")
    limit = params.get("limit_item_levels")

    found = None
    for entry in entries:
        this_path = _item_path(entry, limit)
        if entry["sid"] + " " + this_path == item:
            found = entry
            break

    if found == None:
        return {"changed": False,
                "msg": "no output about sap value in agent output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = SAP_STATE_MAP.get(found["state"], "OK")

    if found["reading"] != None:
        reading = found["reading"]
        unit = found["unit"]
        unit_str = "" if unit == "-" else unit
        msg = "%f%s" % (reading, unit_str)
        metrics = {"value": reading}
    else:
        msg = found["output"] if found["output"] != "" else "(no output)"
        metrics = {}

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}