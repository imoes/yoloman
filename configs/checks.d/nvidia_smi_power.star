def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "nvidia-smi failed or no output",
                    "data": {"discovery": []}}
        gpus = []
        parts = res.stdout.split("<gpu")
        for i in range(1, len(parts)):
            part = "<gpu" + parts[i]
            if "<power_management>Supported</power_management>" not in part and \
               "<power_management> SUPPORTED</power_management>" not in part and \
               "<power_management>Supported</power_management>" not in part.lower():
                continue
            id_start = part.find('id="')
            if id_start >= 0:
                id_start += 4
                id_end = part.find('"', id_start)
                gpu_id = part[id_start:id_end] if id_end > id_start else ""
            else:
                gpu_id = ""
            if not gpu_id:
                continue
            gpus.append({"item": gpu_id, "params": {"levels": None},
                         "metrics": ["power_usage", "power_limit"]})
        return {"changed": False, "msg": "discovered %d GPUs" % len(gpus),
                "data": {"discovery": gpus}}

    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "nvidia-smi failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "nvidia-smi error"}}

    gpus = res.stdout.split("<gpu")
    target = None
    for i in range(1, len(gpus)):
        part = "<gpu" + gpus[i]
        id_start = part.find('id="')
        if id_start >= 0:
            id_start += 4
            id_end = part.find('"', id_start)
            gpu_id = part[id_start:id_end] if id_end > id_start else ""
        else:
            gpu_id = ""
        if gpu_id == item:
            target = part
            break
    if target == None:
        return {"changed": False, "msg": "GPU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "GPU %s not found" % item}}

    def get_float_from_xml(tag_name, part):
        nested = part.find("<" + tag_name + ">")
        if nested < 0:
            nested_start = part.find("<power_readings>")
            if nested_start >= 0:
                nested_end = part.find("</power_readings>")
                if nested_end > nested_start:
                    nested = part.find("<" + tag_name + ">", nested_start, nested_end)
            if nested < 0:
                return None
        tag_content_start = part.find(">", nested)
        if tag_content_start < 0:
            return None
        tag_content_start += 1
        tag_content_end = part.find("<", tag_content_start)
        if tag_content_end < 0:
            return None
        text = part[tag_content_start:tag_content_end].strip()
        if text == "N/A":
            return None
        if text.endswith("W"):
            val = text[:-1]
            if val == "":
                return None
            # Check for valid numeric format without try/except
            if val.find(".") != -1:
                parts_num = val.split(".")
                if len(parts_num) != 2:
                    return None
                left = parts_num[0]
                right = parts_num[1]
                if left == "" and right == "":
                    return None
                left_clean = left[1:] if left.startswith("-") else left
                if not left_clean.isdigit() or not right.isdigit():
                    return None
            else:
                if not val.lstrip("-").isdigit():
                    return None
            return float(val)  # Starlark float() accepts string representation
        return None

    power_draw = get_float_from_xml("power_draw", target)
    power_limit = get_float_from_xml("power_limit", target)
    min_power_limit = get_float_from_xml("min_power_limit", target)
    max_power_limit = get_float_from_xml("max_power_limit", target)

    warn = None
    crit = None
    levels = params.get("levels", None)
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    notice_lines = []

    if power_draw != None:
        if crit != None and power_draw >= crit:
            state = "CRIT"
        elif warn != None and power_draw >= warn:
            state = "WARN"

    if power_limit != None:
        notice_lines.append("Power limit: %f W" % power_limit)
    else:
        notice_lines.append("Power limit: N/A")
    if min_power_limit != None:
        notice_lines.append("Min power limit: %f W" % min_power_limit)
    if max_power_limit != None:
        notice_lines.append("Max power limit: %f W" % max_power_limit)

    details = ", ".join(notice_lines)

    metrics = {}
    if power_draw != None:
        metrics["power_usage"] = power_draw
    if power_limit != None:
        metrics["power_limit"] = power_limit

    return {"changed": False,
            "msg": "Power Draw: %f W" % power_draw if power_draw != None else "Power Draw: N/A",
            "data": {
                "state": state,
                "metrics": metrics,
                "details": details,
            }}