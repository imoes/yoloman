def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2021.2.1.2"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), base_oid], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if line.find(" = ") != -1:
                name_part = line.split(" = ", 1)[1].strip()
                if name_part.endswith("-Processes"):
                    item_name = name_part[:-len("-Processes")]
                    items.append({"item": item_name, "params": {}, "metrics": ["processes"]})
        return {"changed": False, "msg": "discovered %d processes" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "item is required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    base_oid = ".1.3.6.1.4.1.2021.2.1"
    
    res_names = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", base_oid + ".2"], mutates=False)
    res_min = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", base_oid + ".3"], mutates=False)
    res_max = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", base_oid + ".4"], mutates=False)
    res_count = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", base_oid + ".5"], mutates=False)
    res_err_flag = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-On", base_oid + ".100"], mutates=False)
    res_err_msg = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", base_oid + ".101"], mutates=False)
    
    def parse_snmpwalk(output):
        result = {}
        for line in output.splitlines():
            if line.find(" = ") != -1:
                oid_part, value_part = line.split(" = ", 1)
                parts = oid_part.strip().split(".")
                if len(parts) > 0:
                    index_str = parts[-1]
                    value = value_part.strip()
                    if value.startswith("STRING: "):
                        value = value[8:]
                    result[index_str] = value
        return result
    
    names = parse_snmpwalk(res_names.stdout)
    mins = parse_snmpwalk(res_min.stdout)
    maxs = parse_snmpwalk(res_max.stdout)
    counts = parse_snmpwalk(res_count.stdout)
    err_flags = parse_snmpwalk(res_err_flag.stdout)
    err_msgs = parse_snmpwalk(res_err_msg.stdout)
    
    found = False
    for idx in names:
        name = names[idx]
        item_name = name.replace("-Processes", "")
        if item_name == item:
            found = True
            count_str = counts.get(idx, "0")
            min_str = mins.get(idx, "0")
            max_str = maxs.get(idx, "999999")
            err_flag_str = err_flags.get(idx, "0")
            err_msg = err_msgs.get(idx, "")
            
            state = "OK"
            infotext = "Total: " + count_str
            
            if not err_flag_str.isdigit():
                err_flag = 0
            else:
                err_flag = int(err_flag_str)
            
            if err_flag != 0:
                state = "CRIT"
                if err_msg:
                    infotext += ", " + err_msg
                infotext += " (lower/upper crit at " + min_str + "/" + max_str + ")"
            
            if not count_str.isdigit():
                count = 0
            else:
                count = int(count_str)
            
            return {"changed": False, "msg": infotext,
                    "data": {"state": state, "metrics": {"processes": count}, "details": ""}}
    
    return {"changed": False, "msg": "process not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}