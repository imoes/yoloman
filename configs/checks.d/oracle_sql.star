# Starlark module for checkmk.oracle_sql (read-only)
# Parses agent output <<<oracle_sql:sep(58)>>>

def _parse_number(value):
    if value == "":
        return None
    cleaned = value
    if cleaned.startswith("-"):
        cleaned = cleaned[1:]
    if cleaned.replace(".", "").isdigit() or (cleaned.count(".") == 1 and cleaned.replace(".", "").isdigit()):
        # Parse without try/except
        if value.find(".") != -1:
            # Float parsing without try
            parts = value.split(".")
            if len(parts) != 2:
                return None
            if not parts[0].isdigit() or not parts[1].isdigit():
                return None
            return float(value)
        else:
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                return float(value)
    return None

def _parse_metrics(line):
    metrics = []
    for entry in line.split():
        if entry == "":
            continue
        idx = entry.find("=")
        if idx == -1:
            continue
        var_name = entry[:idx]
        rest = entry[idx+1:]
        if rest.find(";") == -1:
            value = _parse_number(rest)
            if value != None:
                metrics.append({"name": var_name, "value": value, "levels": None, "boundaries": None})
            continue
        parts = rest.split(";")
        if len(parts) < 3:
            value = _parse_number(parts[0])
            if value != None:
                metrics.append({"name": var_name, "value": value, "levels": None, "boundaries": None})
            continue
        value = _parse_number(parts[0])
        level_min = _parse_number(parts[1])
        level_max = _parse_number(parts[2])
        if value == None:
            continue
        boundaries = None
        if len(parts) >= 5:
            lower = _parse_number(parts[3])
            upper = _parse_number(parts[4])
            boundaries = (lower, upper)
        metrics.append({"name": var_name, "value": value, "levels": (level_min, level_max), "boundaries": boundaries})
    return metrics

def _parse_section(lines):
    parsed = {}
    instance = None
    for line in lines:
        if line == "":
            continue
        if line.startswith("[[[") and line.endswith("]]]"):
            inner = line[3:-3]
            parts = inner.split("|")
            sid = parts[0] if len(parts) > 0 else ""
            item = parts[1] if len(parts) > 1 else ""
            key = (sid + " SQL " + item).upper()
            instance = {"details": [], "metrics": [], "long": [], "exit": 0, "elapsed": None, "parsing_error": {}, "cache_info": None}
            parsed[key] = instance
            continue
        if instance == None:
            continue
        colon_pos = line.find(":")
        if colon_pos == -1:
            key = line
            infotext = ""
        else:
            key = line[:colon_pos]
            infotext = line[colon_pos+1:].strip()
        if key.endswith("ERROR") or key.startswith("ERROR at line") or "|FAILURE|" in key:
            err_key = ("instance", "PL/SQL failure", 2)
            if err_key not in instance["parsing_error"]:
                instance["parsing_error"][err_key] = []
            instance["parsing_error"][err_key].append(infotext)
        elif key in ["details"]:
            instance["details"].append(infotext)
        elif key in ["long"]:
            instance["long"].append(infotext)
        elif key == "perfdata":
            metrics = _parse_metrics(infotext)
            instance["metrics"] = instance["metrics"] + metrics
        elif key == "exit":
            if infotext.isdigit() or (infotext.startswith("-") and infotext[1:].isdigit()):
                instance["exit"] = int(infotext)
        elif key == "elapsed":
            if infotext != "":
                instance["elapsed"] = float(infotext)
        else:
            err_key = ("unknown", 'Unexpected Keyword: "' + key + '". Line was', 3)
            if err_key not in instance["parsing_error"]:
                instance["parsing_error"][err_key] = []
            instance["parsing_error"][err_key].append(":".join([key, infotext]))
    return parsed

def main(ctx, params):
    if params.get("_discover") == True:
        section_path = "/var/tmp/oracle_sql.dat"
        if not ctx.file_exists(section_path):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        raw = ctx.file_read(section_path)
        lines = raw.split("\n")
        section = _parse_section(lines)
        out = []
        for item in section:
            out.append({"item": item, "params": {}, "metrics": ["elapsed_time"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    section_path = "/var/tmp/oracle_sql.dat"
    if not ctx.file_exists(section_path):
        return {"changed": False, "msg": "oracle_sql section missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = ctx.file_read(section_path)
    lines = raw.split("\n")
    section = _parse_section(lines)
    if item not in section:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section[item]
    state = "OK"
    summary_parts = []
    metrics = {}
    details_lines = []
    for err_key, error_lines in data["parsing_error"].items():
        error_state = err_key[2]
        error_title = err_key[1]
        summary = "%s: %s" % (error_title, " ".join(error_lines))
        if error_state >= 2:
            state = "CRIT"
        elif error_state == 1:
            if state == "OK":
                state = "WARN"
        details_lines.append(summary)
    if data["elapsed"] != None:
        elapsed = data["elapsed"]
        metrics["elapsed_time"] = elapsed
    if len(data["details"]) > 0:
        summary_parts = data["details"]
    if len(data["long"]) > 0:
        details_lines = details_lines + data["long"]
    summary = ", ".join(summary_parts) if len(summary_parts) > 0 else "OK"
    exit_code = data["exit"]
    if state == "OK" and exit_code != 0:
        state = "CRIT" if exit_code >= 2 else "WARN"
    return {"changed": False,
            "msg": summary,
            "data": {"state": state,
                     "metrics": metrics,
                     "details": "\n".join(details_lines)}}