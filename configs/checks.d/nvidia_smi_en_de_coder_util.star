def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "nvidia-smi failed", "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "nvidia-smi produced no output", "data": {"discovery": []}}
        discovered = _discover_gpus(res.stdout)
        return {"changed": False, "msg": "discovered %d devices" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "nvidia-smi failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "nvidia-smi produced no output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return _check_gpu(item, params, res.stdout)


def _discover_gpus(xml):
    gpus = []
    lines = xml.splitlines()
    in_gpu = False
    gpu_id = ""
    encoder_present = False
    decoder_present = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("<gpu"):
            in_gpu = True
            idx = stripped.find('id="')
            if idx != -1:
                end = stripped.find('"', idx + 4)
                gpu_id = stripped[idx + 4:end] if end != -1 else ""
            else:
                gpu_id = ""
            encoder_present = False
            decoder_present = False
        elif stripped.startswith("</gpu>"):
            if in_gpu and (encoder_present or decoder_present):
                metrics = []
                if encoder_present:
                    metrics.append("encoder_utilization")
                if decoder_present:
                    metrics.append("decoder_utilization")
                gpus.append({
                    "item": gpu_id,
                    "params": {"encoder_levels": None, "decoder_levels": None},
                    "metrics": metrics
                })
            in_gpu = False
        elif in_gpu:
            if stripped.startswith("<encoder_util>"):
                encoder_present = _is_valid_util(stripped)
            elif stripped.startswith("<decoder_util>"):
                decoder_present = _is_valid_util(stripped)
    return gpus


def _is_valid_util(line):
    start = line.find(">")
    if start == -1:
        return False
    end = line.find("<", start + 1)
    if end == -1:
        return False
    val = line[start + 1:end].strip()
    if val == "" or val == "N/A":
        return False
    if not val.endswith("%"):
        return False
    pct = val[:-1]
    if not pct.replace(".", "", 1).isdigit():
        return False
    return True


def _check_gpu(item, params, xml):
    lines = xml.splitlines()
    in_gpu = False
    current_id = ""
    encoder_val = None
    decoder_val = None
    encoder_levels = params.get("encoder_levels")
    decoder_levels = params.get("decoder_levels")

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("<gpu"):
            in_gpu = False
            if current_id != "" and current_id == item:
                break
            idx = stripped.find('id="')
            if idx != -1:
                end = stripped.find('"', idx + 4)
                current_id = stripped[idx + 4:end] if end != -1 else ""
            else:
                current_id = ""
            encoder_val = None
            decoder_val = None
        elif stripped.startswith("</gpu>"):
            if current_id == item:
                break
            in_gpu = False
        elif in_gpu:
            if stripped.startswith("<encoder_util>"):
                encoder_val = _parse_util(stripped)
            elif stripped.startswith("<decoder_util>"):
                decoder_val = _parse_util(stripped)

    if current_id != item:
        return {"changed": False, "msg": "GPU not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    msg_parts = []

    if encoder_val != None:
        if encoder_levels != None:
            warn = encoder_levels[0]
            crit = encoder_levels[1]
            if crit != None and encoder_val >= crit:
                state = "CRIT"
            elif warn != None and encoder_val >= warn:
                state = "WARN" if state != "CRIT" else state
        msg_parts.append("Encoder: %d%%" % int(encoder_val))

    if decoder_val != None:
        if decoder_levels != None:
            warn = decoder_levels[0]
            crit = decoder_levels[1]
            if crit != None and decoder_val >= crit:
                state = "CRIT"
            elif warn != None and decoder_val >= warn:
                state = "WARN" if state != "CRIT" else state
        msg_parts.append("Decoder: %d%%" % int(decoder_val))

    metrics = {}
    if encoder_val != None:
        metrics["encoder_utilization"] = encoder_val
    if decoder_val != None:
        metrics["decoder_utilization"] = decoder_val

    msg = "NVIDIA GPU %s: %s" % (item, ", ".join(msg_parts)) if msg_parts else "NVIDIA GPU %s: no data" % item

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _parse_util(line):
    start = line.find(">")
    if start == -1:
        return None
    end = line.find("<", start + 1)
    if end == -1:
        return None
    val = line[start + 1:end].strip()
    if val == "" or val == "N/A":
        return None
    if not val.endswith("%"):
        return None
    pct = val[:-1]
    if not pct.replace(".", "", 1).isdigit():
        return None
    return float(pct)