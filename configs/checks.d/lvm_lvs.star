def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lvs", "--noheadings", "-o", "vg_name,lv_name,lv_attr,data_percent,metadata_percent"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no LVM found", "data": {"discovery": []}}
        discovery = []
        seen = {}
        lines = res.stdout.splitlines()
        for line in lines:
            fields = [p.strip() for p in line.split(":")]
            if len(fields) < 5:
                continue
            vg = fields[0]
            lv = fields[1]
            attr = fields[2]
            pool = ""
            if len(attr) >= 7 and attr[0] == "t":
                pool = lv
            if pool == "":
                continue
            key = vg + "/" + lv
            if key in seen:
                continue
            seen[key] = True
            discovery.append({"item": vg + "/" + lv, "params": {"levels_data": (80.0, 90.0), "levels_meta": (80.0, 90.0)}, "metrics": ["data_usage", "meta_usage"]})
        return {"changed": False, "msg": "discovered %d lv pools" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    if "/" not in item:
        return {"changed": False, "msg": "no such LV: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = item.split("/")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vg_name = parts[0]
    lv_name = parts[1]
    res = ctx.run(["lvs", "--noheadings", "-o", "vg_name,lv_name,lv_attr,data_percent,metadata_percent", vg_name + "/" + lv_name], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "no such LV: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    found = False
    data_pct = 0.0
    meta_pct = 0.0
    for line in lines:
        fields = [p.strip() for p in line.split(":")]
        if len(fields) < 5:
            continue
        if fields[0] == vg_name and fields[1] == lv_name:
            found = True
            data_str = fields[3]
            meta_str = fields[4]
            if data_str != "":
                data_pct = float(data_str)
            if meta_str != "":
                meta_pct = float(meta_str)
            break
    if not found:
        return {"changed": False, "msg": "no such LV: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels_data = params.get("levels_data", (80.0, 90.0))
    levels_meta = params.get("levels_meta", (80.0, 90.0))
    if type(levels_data) == "list":
        warn_d = levels_data[0] if len(levels_data) > 0 else 80.0
        crit_d = levels_data[1] if len(levels_data) > 1 else 90.0
    else:
        warn_d = levels_data[0] if len(levels_data) > 0 else 80.0
        crit_d = levels_data[1] if len(levels_data) > 1 else 90.0
    if type(levels_meta) == "list":
        warn_m = levels_meta[0] if len(levels_meta) > 0 else 80.0
        crit_m = levels_meta[1] if len(levels_meta) > 1 else 90.0
    else:
        warn_m = levels_meta[0] if len(levels_meta) > 0 else 80.0
        crit_m = levels_meta[1] if len(levels_meta) > 1 else 90.0
    if data_pct >= crit_d:
        state_d = "CRIT"
    elif data_pct >= warn_d:
        state_d = "WARN"
    else:
        state_d = "OK"
    if meta_pct >= crit_m:
        state_m = "CRIT"
    elif meta_pct >= warn_m:
        state_m = "WARN"
    else:
        state_m = "OK"
    if state_d == "CRIT" or state_m == "CRIT":
        state = "CRIT"
    elif state_d == "WARN" or state_m == "WARN":
        state = "WARN"
    else:
        state = "OK"
    msg = "Data: %s%%, Meta: %s%%" % (str(data_pct), str(meta_pct))
    details = "LV %s/%s\nData usage: %s%% (warn: %s, crit: %s)\nMeta usage: %s%% (warn: %s, crit: %s)" % (vg_name, lv_name, str(data_pct), str(warn_d), str(crit_d), str(meta_pct), str(warn_m), str(crit_m))
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"data_usage": data_pct, "meta_usage": meta_pct}, "details": details}}