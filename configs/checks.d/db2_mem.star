def main(ctx, params):
    # Read agent data using db2pd -mem (the underlying source for db2_mem)
    res = ctx.run(["db2pd", "-mem"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "db2pd command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    
    # Discovery mode
    if params.get("_discover"):
        items = []
        in_instance_block = False
        for line in lines:
            fields = line.split()
            if len(fields) >= 2 and fields[0] == "Instance":
                items.append({"item": fields[1], "params": {"levels_lower": [10.0, 5.0]},
                              "metrics": ["mem_used"]})
                in_instance_block = True
            elif in_instance_block and fields and fields[0] != "Instance":
                # End of instance block (next section starts)
                break
        return {"changed": False, "msg": "discovered %d instances" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    levels_lower = params.get("levels_lower", [10.0, 5.0])
    
    # Parse section for the requested item
    in_block = False
    limit = None
    usage = None
    
    for line in lines:
        fields = line.split()
        if len(fields) < 3:
            continue
        if fields[0] == "Instance" and len(fields) >= 2 and fields[1] == item:
            in_block = True
            continue
        if in_block:
            # End of current section when we hit another top-level field
            if fields[0] in ("Database", "Agent", "DatabaseMonitor", "Bufferpool", "Sort"):
                break
            # Look for lines with value and unit at the end
            if len(fields) >= 3 and fields[-1].lower() in ("kb", "mb"):
                value_str = fields[-2]
                unit = fields[-1].lower()
                if value_str.isdigit():
                    value = int(value_str)
                    if unit == "kb":
                        value *= 1024
                    elif unit == "mb":
                        value *= 1024 * 1024
                    if limit == None:
                        limit = value
                    else:
                        usage = value
                        break
    
    if limit == None or usage == None:
        return {"changed": False, "msg": "No memory data found for instance " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    perc_free = (limit - usage) / limit * 100.0
    
    # Determine state
    state = "OK"
    details_parts = []
    details_parts.append("Max " + str(limit))
    
    # For "Free" percentage, check levels_lower (warn, crit thresholds)
    if perc_free <= levels_lower[1]:
        state = "CRIT"
    elif perc_free <= levels_lower[0]:
        state = "WARN"
    
    details_parts.append("Free " + str(int(perc_free)) + "%")
    
    return {"changed": False, "msg": "; ".join(details_parts),
            "data": {"state": state, "metrics": {"mem_used": usage},
                     "details": "; ".join(details_parts)}}
