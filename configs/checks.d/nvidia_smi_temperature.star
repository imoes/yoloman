def main(ctx, params):
    # Import XML parser via helper (no try/except allowed)
    def parse_xml(text):
        # Parse XML using simple string search — no XML library
        if text == "":
            return None
        # Very basic check: does it contain <gpu>?
        return text.find("<gpu>") >= 0

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 GPUs (nvidia-smi failed)",
                "data": {"discovery": []},
            }
        if res.stdout == "":
            return {
                "changed": False,
                "msg": "discovered 0 GPUs (empty output)",
                "data": {"discovery": []},
            }
        has_gpus = parse_xml(res.stdout)
        if not has_gpus:
            return {
                "changed": False,
                "msg": "discovered 0 GPUs (no GPU XML found)",
                "data": {"discovery": []},
            }

        # Simple extraction: find all <gpu id="..."> tags via string search
        discovered = []
        offset = 0
        while True:
            gpu_start = res.stdout.find("<gpu", offset)
            if gpu_start == -1:
                break
            id_start = res.stdout.find('id="', gpu_start)
            if id_start == -1:
                break
            id_start += 4
            id_end = res.stdout.find('"', id_start)
            if id_end == -1:
                break
            gpu_id = res.stdout[id_start:id_end]
            # Look for temperature/gpu_temp block after this GPU tag
            temp_tag_start = res.stdout.find("<temperature>", gpu_start)
            if temp_tag_start == -1 or temp_tag_start > gpu_start + 5000:  # crude bound
                offset = gpu_start + 1
                continue
            gpu_temp_start = res.stdout.find("<gpu_temp>", temp_tag_start)
            if gpu_temp_start == -1:
                offset = gpu_start + 1
                continue
            end_tag = res.stdout.find("</gpu_temp>", gpu_temp_start)
            if end_tag == -1:
                offset = gpu_start + 1
                continue
            temp_node_text = res.stdout[gpu_temp_start + 10:end_tag].strip()
            # Check numeric + unit "C"
            if temp_node_text != "" and temp_node_text.endswith("C"):
                val_part = temp_node_text[:-1]
                # Simple numeric check
                val_clean = val_part.replace(".", "").replace("-", "")
                if val_clean.isdigit():
                    discovered.append({
                        "item": gpu_id,
                        "params": {},
                        "metrics": ["gpu_temp"],
                    })
            offset = gpu_start + 1
        return {
            "changed": False,
            "msg": "discovered %d GPUs" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "GPU %s unavailable (nvidia-smi failed)" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if res.stdout == "":
        return {
            "changed": False,
            "msg": "GPU %s unavailable (empty output)" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if parse_xml(res.stdout) == False:
        return {
            "changed": False,
            "msg": "GPU %s unavailable (no XML)" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Locate GPU by ID
    gpu_start = res.stdout.find("<gpu")
    found = False
    while gpu_start != -1:
        id_start = res.stdout.find('id="', gpu_start)
        if id_start != -1:
            id_start += 4
            id_end = res.stdout.find('"', id_start)
            if id_end != -1:
                gpu_id = res.stdout[id_start:id_end]
                if gpu_id == item:
                    found = True
                    break
        next_gpu = res.stdout.find("<gpu", gpu_start + 1)
        if next_gpu == gpu_start:
            break
        gpu_start = next_gpu if next_gpu != -1 else -1

    if found == False:
        return {
            "changed": False,
            "msg": "no such GPU: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract temperature
    temp_start = res.stdout.find("<temperature>", gpu_start)
    if temp_start == -1:
        return {
            "changed": False,
            "msg": "GPU %s temperature section missing" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    gpu_temp_start = res.stdout.find("<gpu_temp>", temp_start)
    if gpu_temp_start == -1:
        return {
            "changed": False,
            "msg": "GPU %s temperature data missing" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    temp_end = res.stdout.find("</gpu_temp>", gpu_temp_start)
    if temp_end == -1:
        return {
            "changed": False,
            "msg": "GPU %s temperature data malformed" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    temp_str_full = res.stdout[gpu_temp_start + 10:temp_end].strip()

    if temp_str_full == "":
        return {
            "changed": False,
            "msg": "GPU %s temperature value empty" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not temp_str_full.endswith("C"):
        return {
            "changed": False,
            "msg": "GPU %s temperature unit missing" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    temp_val_str = temp_str_full[:-1]
    val_clean = temp_val_str.replace(".", "").replace("-", "")
    if not val_clean.isdigit():
        return {
            "changed": False,
            "msg": "GPU %s temperature not numeric: %s" % (item, temp_val_str),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    reading = float(temp_val_str)

    # Thresholds
    levels = params.get("levels")
    if levels == None:
        warn_high = None
        crit_high = None
    else:
        warn_high = levels[0] if len(levels) >= 1 else None
        crit_high = levels[1] if len(levels) >= 2 else None

    state = "OK"
    details_parts = []
    if crit_high != None and reading >= crit_high:
        state = "CRIT"
        details_parts.append(">= %s C (crit)" % str(crit_high))
    elif warn_high != None and reading >= warn_high:
        state = "WARN"
        details_parts.append(">= %s C (warn)" % str(warn_high))

    details = ""
    if len(details_parts) > 0:
        details = "thresholds: " + ", ".join(details_parts)

    return {
        "changed": False,
        "msg": "Temperature: %f C" % reading,
        "data": {
            "state": state,
            "metrics": {"gpu_temp": reading},
            "details": details,
        },
    }