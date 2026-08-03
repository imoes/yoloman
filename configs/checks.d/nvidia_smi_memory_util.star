def _parse_float(s):
    if s == None or s == "N/A" or s == "":
        return None
    return float(s)

def _find_text(xml_str, tag):
    open_t = xml_str.find("<" + tag + ">")
    if open_t == -1:
        open_t = xml_str.find("<" + tag + " ")
        if open_t == -1:
            return None
    close_t = xml_str.find(">", open_t)
    if close_t == -1:
        return None
    end_t = xml_str.find("</" + tag + ">", close_t + 1)
    if end_t == -1:
        return None
    inner = xml_str[close_t + 1:end_t]
    return inner.strip()

def _find_all_gpus(xml_str):
    gpus = []
    pos = 0
    while True:
        start = xml_str.find("<gpu ", pos)
        if start == -1:
            start = xml_str.find("<gpu>", pos)
            if start == -1:
                break
        end = xml_str.find("</gpu>", start)
        if end == -1:
            break
        gpus.append(xml_str[start:end + len("</gpu>")])
        pos = end + len("</gpu>")
    return gpus

def _parse_gpu(gpu_str):
    id_val = _find_text(gpu_str, "id")
    product_name = _find_text(gpu_str, "product_name")
    fb_total = _find_text(gpu_str, "fb_memory_usage/total")
    fb_used = _find_text(gpu_str, "fb_memory_usage/used")
    fb_free = _find_text(gpu_str, "fb_memory_usage/free")
    bar1_total = _find_text(gpu_str, "bar1_memory_usage/total")
    bar1_used = _find_text(gpu_str, "bar1_memory_usage/used")
    bar1_free = _find_text(gpu_str, "bar1_memory_usage/free")
    gpu_util = _find_text(gpu_str, "utilization/gpu_util")
    return {"id": id_val, "product_name": product_name,
            "fb_total": _parse_float(fb_total), "fb_used": _parse_float(fb_used),
            "fb_free": _parse_float(fb_free),
            "bar1_total": _parse_float(bar1_total), "bar1_used": _parse_float(bar1_used),
            "bar1_free": _parse_float(bar1_free), "gpu_util": _parse_float(gpu_util)}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-d", "MEMORY,UTILIZATION", "-x"], mutates=False)
        if res.rc == 127 or not res.stdout:
            return {"changed": False, "msg": "no nvidia-smi found", "data": {"discovery": [], "host_labels": {}}}
        xml = res.stdout
        gpus = _find_all_gpus(xml)
        out = []
        for gpu_str in gpus:
            gpu = _parse_gpu(gpu_str)
            if gpu["id"] == None and gpu["fb_total"] == None:
                continue
            out.append({"item": gpu["id"], "params": {"levels_total": (80, 90), "levels_bar1": (80, 90), "levels_fb": (80, 90)}, "metrics": ["fb_mem_usage_used", "bar1_mem_usage_used"], "service_labels": {"product_name": gpu["product_name"]}})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out, "host_labels": {"cmk/vendor": "nvidia"}}}
    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-d", "MEMORY,UTILIZATION", "-x"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {"changed": False, "msg": "no nvidia-smi found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    xml = res.stdout
    gpus = _find_all_gpus(xml)
    gpu = None
    for gpu_str in gpus:
        g = _parse_gpu(gpu_str)
        if g["id"] == item:
            gpu = g
            break
    if gpu == None:
        return {"changed": False, "msg": "gpu %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fb_total = gpu["fb_total"]
    fb_used = gpu["fb_used"]
    bar1_total = gpu["bar1_total"]
    bar1_used = gpu["bar1_used"]
    levels_total = params.get("levels_total", (80, 90))
    levels_bar1 = params.get("levels_bar1", (80, 90))
    levels_fb = params.get("levels_fb", (80, 90))
    metrics = {}
    details = ""
    state = "OK"
    if fb_total != None and fb_used != None and bar1_total != None and bar1_used != None:
        sum_total = fb_total + bar1_total
        sum_used = fb_used + bar1_used
        if sum_total > 0:
            perc = (sum_used / sum_total) * 100.0
            metrics["total_mem_usage_used"] = perc
            w_tot = levels_total[0] if levels_total else 80
            c_tot = levels_total[1] if levels_total else 90
            if perc >= c_tot:
                state = "CRIT"
            elif perc >= w_tot:
                state = "WARN"
            details = details + "Total memory %d%% used.\n" % int(perc)
    if fb_used != None and fb_total != None:
        if fb_total > 0:
            perc = (fb_used / fb_total) * 100.0
            metrics["fb_mem_usage_used"] = perc
            w_fb = levels_fb[0] if levels_fb else 80
            c_fb = levels_fb[1] if levels_fb else 90
            if perc >= c_fb and state != "CRIT":
                state = "CRIT"
            elif perc >= w_fb and state == "OK":
                state = "WARN"
            details = details + "FB memory %d%% used.\n" % int(perc)
    if bar1_used != None and bar1_total != None:
        if bar1_total > 0:
            perc = (bar1_used / bar1_total) * 100.0
            metrics["bar1_mem_usage_used"] = perc
            w_b1 = levels_bar1[0] if levels_bar1 else 80
            c_b1 = levels_bar1[1] if levels_bar1 else 90
            if perc >= c_b1 and state != "CRIT":
                state = "CRIT"
            elif perc >= w_b1 and state == "OK":
                state = "WARN"
            details = details + "BAR1 memory %d%% used.\n" % int(perc)
    return {"changed": False, "msg": ("%s memory: %s" % (item, details.strip())).strip(), "data": {"state": state, "metrics": metrics, "details": details.strip()}}