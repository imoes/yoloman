def _parse_lvm_lvs(output):
    lines = output.splitlines()
    if len(lines) < 2:
        return {}
    entries = {}
    for line in lines[1:]:
        parts = line.split()
        if len(parts) < 8:
            continue
        lv_name = parts[0]
        vg_name = parts[1]
        pool_lv = parts[4]
        # Skip entries without pool LV
        if pool_lv == "":
            continue
        item = vg_name + "/" + pool_lv
        data_str = parts[6]
        meta_str = parts[7]
        # Guard: only parse numeric strings
        data_val = float(data_str) if data_str.replace(".", "").replace("-", "").isdigit() else 0.0
        meta_val = float(meta_str) if meta_str.replace(".", "").replace("-", "").isdigit() else 0.0
        entries[item] = {"data": data_val, "meta": meta_val}
    return entries

def main(ctx, params):
    # Discovery mode: enumerate LV pools
    if params.get("_discover"):
        res = ctx.run(["lvs", "--noheadings", "-o", "lv_name,vg_name,pool_lv,data_percent,meta_percent,lv_attr", "--units", "b", "--nosuffix"], mutates=False)
        section = _parse_lvm_lvs(res.stdout)
        discovery = []
        for item, values in section.items():
            discovery.append({
                "item": item,
                "params": {
                    "levels_data": ("fixed", (80.0, 90.0)),
                    "levels_meta": ("fixed", (80.0, 90.0)),
                },
                "metrics": ["data_usage", "meta_usage"],
            })
        return {
            "changed": False,
            "msg": "discovered %d LVM LV pools" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: process one item
    item = params.get("item", "")
    res = ctx.run(["lvs", "--noheadings", "-o", "lv_name,vg_name,pool_lv,data_percent,meta_percent,lv_attr", "--units", "b", "--nosuffix"], mutates=False)
    section = _parse_lvm_lvs(res.stdout)
    if not section:
        return {
            "changed": False,
            "msg": "no LVM LV pools found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if item not in section:
        return {
            "changed": False,
            "msg": "pool not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entry = section[item]
    data_val = entry.get("data", 0.0)
    meta_val = entry.get("meta", 0.0)

    # Get thresholds from params (Checkmk defaults)
    # Format: ("fixed", (warn, crit))
    levels_data = params.get("levels_data", ("fixed", (80.0, 90.0)))
    levels_meta = params.get("levels_meta", ("fixed", (80.0, 90.0)))

    def _check_levels(value, levels):
        if levels[0] == "fixed":
            warn, crit = levels[1]
            if value >= crit:
                return "CRIT"
            elif value >= warn:
                return "WARN"
            return "OK"
        # Fallback
        return "OK"

    data_state = _check_levels(data_val, levels_data)
    meta_state = _check_levels(meta_val, levels_meta)

    # Determine overall state: worst of data/meta
    state = "OK"
    if data_state == "CRIT" or meta_state == "CRIT":
        state = "CRIT"
    elif data_state == "WARN" or meta_state == "WARN":
        state = "WARN"

    msg = "Data: %f%%, Meta: %f%%" % (data_val, meta_val)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "data_usage": data_val,
                "meta_usage": meta_val,
            },
            "details": "",
        },
    }