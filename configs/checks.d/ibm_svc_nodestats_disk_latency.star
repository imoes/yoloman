def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk/ibm_svc_nodestats"], mutates=False)
        lines = res.stdout.splitlines()
        parsed = {}
        for line in lines:
            parts = line.split(":")
            if len(parts) < 6:
                continue
            node_id = parts[0]
            node_name = parts[1]
            stat_name = parts[2]
            stat_current = parts[3]
            val = 0.0
            if stat_current.isdigit() or (stat_current.find(".") >= 0 and stat_current.replace(".", "", 1).isdigit()):
                val = float(stat_current)
            else:
                continue
            item_name = ""
            if stat_name in ("vdisk_r_mb", "vdisk_w_mb", "vdisk_r_io", "vdisk_w_io", "vdisk_r_ms", "vdisk_w_ms"):
                item_name = "VDisks " + node_name
                stat_name = stat_name.replace("vdisk_", "")
            elif stat_name in ("mdisk_r_mb", "mdisk_w_mb", "mdisk_r_io", "mdisk_w_io", "mdisk_r_ms", "mdisk_w_ms"):
                item_name = "MDisks " + node_name
                stat_name = stat_name.replace("mdisk_", "")
            elif stat_name in ("drive_r_mb", "drive_w_mb", "drive_r_io", "drive_w_io", "drive_r_ms", "drive_w_ms"):
                item_name = "Drives " + node_name
                stat_name = stat_name.replace("drive_", "")
            elif stat_name in ("write_cache_pc", "total_cache_pc", "cpu_pc"):
                item_name = node_name
            else:
                continue
            if item_name not in parsed:
                parsed[item_name] = {}
            parsed[item_name][stat_name] = val
        out = []
        for node_name, data in parsed.items():
            if "r_ms" in data and "w_ms" in data:
                out.append({"item": node_name, "params": {}, "metrics": ["read_latency", "write_latency"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/cmk/ibm_svc_nodestats"], mutates=False)
    lines = res.stdout.splitlines()
    parsed = {}
    for line in lines:
        parts = line.split(":")
        if len(parts) < 6:
            continue
        node_name = parts[1]
        stat_name = parts[2]
        stat_current = parts[3]
        val = 0.0
        if stat_current.isdigit() or (stat_current.find(".") >= 0 and stat_current.replace(".", "", 1).isdigit()):
            val = float(stat_current)
        else:
            continue
        item_name = ""
        if stat_name in ("vdisk_r_mb", "vdisk_w_mb", "vdisk_r_io", "vdisk_w_io", "vdisk_r_ms", "vdisk_w_ms"):
            item_name = "VDisks " + node_name
            stat_name = stat_name.replace("vdisk_", "")
        elif stat_name in ("mdisk_r_mb", "mdisk_w_mb", "mdisk_r_io", "mdisk_w_io", "mdisk_r_ms", "mdisk_w_ms"):
            item_name = "MDisks " + node_name
            stat_name = stat_name.replace("mdisk_", "")
        elif stat_name in ("drive_r_mb", "drive_w_mb", "drive_r_io", "drive_w_io", "drive_r_ms", "drive_w_ms"):
            item_name = "Drives " + node_name
            stat_name = stat_name.replace("drive_", "")
        elif stat_name in ("write_cache_pc", "total_cache_pc", "cpu_pc"):
            item_name = node_name
        else:
            continue
        if item_name not in parsed:
            parsed[item_name] = {}
        parsed[item_name][stat_name] = val
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    read_latency = data.get("r_ms", 0.0)
    write_latency = data.get("w_ms", 0.0)
    return {"changed": False, "msg": "Latency is %s ms for read, %s ms for write" % (str(read_latency), str(write_latency)), "data": {"state": "OK", "metrics": {"read_latency": read_latency, "write_latency": write_latency}, "details": ""}}