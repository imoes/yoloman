def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "nvidia-smi command failed",
                    "data": {"discovery": []}}
        if not res.stdout.strip():
            return {"changed": False, "msg": "nvidia-smi returned empty output",
                    "data": {"discovery": []}}
        
        gpus = _extract_gpus_from_xml(res.stdout)
        discovery_items = []
        for gpu_id, gpu_data in gpus.items():
            if gpu_data.get("gpu_util") != None:
                discovery_items.append({
                    "item": gpu_id,
                    "params": {"levels": None},
                    "metrics": ["gpu_utilization"]
                })
        
        return {"changed": False, "msg": "discovered %d GPUs" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode: process one item
    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "nvidia-smi command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout.strip():
        return {"changed": False, "msg": "nvidia-smi returned empty output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    gpus = _extract_gpus_from_xml(res.stdout)
    
    gpu_data = gpus.get(item)
    if gpu_data == None:
        return {"changed": False, "msg": "no such GPU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    gpu_util = gpu_data.get("gpu_util")
    if gpu_util == None:
        return {"changed": False, "msg": "GPU utilization data not available for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply threshold logic (upper levels only)
    levels = params.get("levels")
    warn = None
    crit = None
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    
    state = "OK"
    if crit != None and gpu_util >= crit:
        state = "CRIT"
    elif warn != None and gpu_util >= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Utilization: %f%%" % gpu_util,
        "data": {
            "state": state,
            "metrics": {"gpu_utilization": gpu_util},
            "details": "",
        },
    }


def _extract_gpus_from_xml(xml_text):
    result = {}
    
    gpu_sections = _split_xml_section(xml_text, "<gpu>", "</gpu>")
    for gpu_section in gpu_sections:
        gpu_id = _extract_single_tag(gpu_section, "id")
        if not gpu_id:
            continue
        
        util_section = _extract_subsection(gpu_section, "utilization")
        gpu_util = _extract_single_float(util_section, "gpu_util", "%")
        
        result[gpu_id] = {
            "gpu_util": gpu_util
        }
    
    return result


def _split_xml_section(text, start_tag, end_tag):
    sections = []
    start_idx = 0
    while True:
        start_pos = text.find(start_tag, start_idx)
        if start_pos == -1:
            break
        end_pos = text.find(end_tag, start_pos)
        if end_pos == -1:
            break
        sections.append(text[start_pos:end_pos + len(end_tag)])
        start_idx = end_pos + len(end_tag)
    return sections


def _extract_single_tag(xml_text, tag):
    start_tag = "<" + tag + ">"
    end_tag = "</" + tag + ">"
    start_pos = xml_text.find(start_tag)
    if start_pos == -1:
        return None
    end_pos = xml_text.find(end_tag, start_pos)
    if end_pos == -1:
        return None
    content_start = start_pos + len(start_tag)
    content_end = end_pos
    return xml_text[content_start:content_end].strip()


def _extract_subsection(xml_text, tag):
    start_tag = "<" + tag + ">"
    end_tag = "</" + tag + ">"
    start_pos = xml_text.find(start_tag)
    if start_pos == -1:
        return ""
    end_pos = xml_text.find(end_tag, start_pos)
    if end_pos == -1:
        return ""
    content_start = start_pos + len(start_tag)
    return xml_text[content_start:end_pos]


def _extract_single_float(xml_text, tag, unit):
    content = _extract_single_tag(xml_text, tag)
    if not content:
        return None
    
    content = content.strip()
    if not content.endswith(unit):
        return None
    
    value_str = content[:-len(unit)].strip()
    if value_str == "":
        return None
    
    # Validate that value_str looks like a number
    # Remove whitespace
    clean_value = ""
    for c in value_str:
        if c in "0123456789.-":
            clean_value = clean_value + c
    
    # Must have at least one digit
    has_digit = False
    for c in clean_value:
        if c in "0123456789":
            has_digit = True
            break
    
    if not has_digit:
        return None
    
    # Handle negative numbers
    negative = False
    if clean_value.startswith("-"):
        negative = True
        clean_value = clean_value[1:]
    
    # Split on dot
    parts = clean_value.split(".")
    integer_part = parts[0]
    fractional_part = ""
    if len(parts) > 1:
        fractional_part = parts[1]
    
    # Check integer part is digits or empty
    if integer_part == "":
        integer_part = "0"
    for c in integer_part:
        if c not in "0123456789":
            return None
    
    # Check fractional part is digits (if exists)
    for c in fractional_part:
        if c not in "0123456789":
            return None
    
    # Build the float representation using string conversion
    if fractional_part == "":
        value_str_clean = integer_part + ".0"
    else:
        value_str_clean = integer_part + "." + fractional_part
    
    if negative:
        value_str_clean = "-" + value_str_clean
    
    # Parse the float string using Starlark's float() builtin
    # Since we've validated the format, this should always work
    return float(value_str_clean)