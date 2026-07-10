def main(ctx, params):
    # Discovery mode: enumerate CPGs with VVs
    if params.get("_discover"):
        if not ctx.file_exists("/var/lib/dummy/3par_cpgs"):
            return {"changed": False, "msg": "discovered 0 CPGs",
                    "data": {"discovery": []}}
        content = ctx.file_read("/var/lib/dummy/3par_cpgs").strip()
        # Parse JSON manually (safe for known small structure)
        members_start = content.find('"members"')
        if members_start == -1:
            return {"changed": False, "msg": "discovered 0 CPGs",
                    "data": {"discovery": []}}
        bracket_start = content.find('[', members_start)
        if bracket_start == -1:
            return {"changed": False, "msg": "discovered 0 CPGs",
                    "data": {"discovery": []}}
        depth = 1
        pos = bracket_start + 1
        while pos < len(content) and depth > 0:
            if content[pos] == '[':
                depth += 1
            elif content[pos] == ']':
                depth -= 1
            pos += 1
        if depth != 0:
            return {"changed": False, "msg": "discovered 0 CPGs",
                    "data": {"discovery": []}}
        members_str = content[bracket_start:pos]

        discovered = []
        obj_start = 0
        while True:
            obj_start = members_str.find('{', obj_start)
            if obj_start == -1:
                break
            depth = 1
            obj_end = obj_start + 1
            while obj_end < len(members_str) and depth > 0:
                if members_str[obj_end] == '{':
                    depth += 1
                elif members_str[obj_end] == '}':
                    depth -= 1
                obj_end += 1
            if depth == 0:
                obj_str = members_str[obj_start:obj_end]
                name_key = '"name"'
                name_idx = obj_str.find(name_key)
                cpg_name = ""
                if name_idx != -1:
                    colon = obj_str.find(':', name_idx)
                    if colon != -1:
                        name_val_start = obj_str.find('"', colon)
                        if name_val_start != -1:
                            name_val_end = obj_str.find('"', name_val_start + 1)
                            if name_val_end != -1:
                                cpg_name = obj_str[name_val_start + 1:name_val_end]
                # Extract state
                state_key = '"state"'
                state_idx = obj_str.find(state_key)
                state_val = -1
                if state_idx != -1:
                    colon = obj_str.find(':', state_idx)
                    if colon != -1:
                        num_start = colon + 1
                        while num_start < len(obj_str) and obj_str[num_start] in ' \t':
                            num_start += 1
                        num_end = num_start
                        while num_end < len(obj_str) and obj_str[num_end] in '0123456789':
                            num_end += 1
                        if num_end > num_start:
                            state_val = int(obj_str[num_start:num_end])
                # Extract VV counts
                vv_total = 0
                for key in ['"numFPVVs"', '"numTDVVs"', '"numTPVVs"']:
                    idx = obj_str.find(key)
                    if idx != -1:
                        colon = obj_str.find(':', idx)
                        if colon != -1:
                            num_start = colon + 1
                            while num_start < len(obj_str) and obj_str[num_start] in ' \t':
                                num_start += 1
                            num_end = num_start
                            while num_end < len(obj_str) and obj_str[num_end] in '0123456789':
                                num_end += 1
                            if num_end > num_start:
                                vv_total += int(obj_str[num_start:num_end])
                if cpg_name != "" and vv_total > 0:
                    discovered.append({
                        "item": cpg_name,
                        "params": {},
                        "metrics": []
                    })
                obj_start = obj_end
            else:
                obj_start += 1
        return {"changed": False, "msg": "discovered %d CPGs" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode: single item
    item = params.get("item", "")
    if item == "":
        fail("item is required")

    if item.endswith(" SAUsage") or item.endswith(" SDUsage") or item.endswith(" UsrUsage"):
        fail("Usage check requires JSON data; not supported in this read-only translation")

    if not ctx.file_exists("/var/lib/dummy/3par_cpgs"):
        return {"changed": False, "msg": "no 3par_cpgs data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/var/lib/dummy/3par_cpgs")
    members_start = content.find('"members"')
    if members_start == -1:
        return {"changed": False, "msg": "no members array in data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    bracket_start = content.find('[', members_start)
    if bracket_start == -1:
        return {"changed": False, "msg": "no members array in data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    depth = 1
    pos = bracket_start + 1
    while pos < len(content) and depth > 0:
        if content[pos] == '[':
            depth += 1
        elif content[pos] == ']':
            depth -= 1
        pos += 1
    if depth != 0:
        return {"changed": False, "msg": "malformed JSON",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    members_str = content[bracket_start:pos]

    cpgs = {}
    obj_start = 0
    while True:
        obj_start = members_str.find('{', obj_start)
        if obj_start == -1:
            break
        depth = 1
        obj_end = obj_start + 1
        while obj_end < len(members_str) and depth > 0:
            if members_str[obj_end] == '{':
                depth += 1
            elif members_str[obj_end] == '}':
                depth -= 1
            obj_end += 1
        if depth == 0:
            obj_str = members_str[obj_start:obj_end]
            name_key = '"name"'
            name_idx = obj_str.find(name_key)
            cpg_name = ""
            if name_idx != -1:
                colon = obj_str.find(':', name_idx)
                if colon != -1:
                    name_val_start = obj_str.find('"', colon)
                    if name_val_start != -1:
                        name_val_end = obj_str.find('"', name_val_start + 1)
                        if name_val_end != -1:
                            cpg_name = obj_str[name_val_start + 1:name_val_end]
            state_key = '"state"'
            state_idx = obj_str.find(state_key)
            state_val = -1
            if state_idx != -1:
                colon = obj_str.find(':', state_idx)
                if colon != -1:
                    num_start = colon + 1
                    while num_start < len(obj_str) and obj_str[num_start] in ' \t':
                        num_start += 1
                    num_end = num_start
                    while num_end < len(obj_str) and obj_str[num_end] in '0123456789':
                        num_end += 1
                    if num_end > num_start:
                        state_val = int(obj_str[num_start:num_end])
            vv_total = 0
            for key in ['"numFPVVs"', '"numTDVVs"', '"numTPVVs"']:
                idx = obj_str.find(key)
                if idx != -1:
                    colon = obj_str.find(':', idx)
                    if colon != -1:
                        num_start = colon + 1
                        while num_start < len(obj_str) and obj_str[num_start] in ' \t':
                            num_start += 1
                        num_end = num_start
                        while num_end < len(obj_str) and obj_str[num_end] in '0123456789':
                            num_end += 1
                        if num_end > num_start:
                            vv_total += int(obj_str[num_start:num_end])
            if cpg_name != "":
                cpgs[cpg_name] = {"state": state_val, "vvs": vv_total}
            obj_start = obj_end
        else:
            obj_start += 1

    cpg = cpgs.get(item)
    if cpg == None:
        return {"changed": False, "msg": "CPG not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_val = cpg.get("state")
    if state_val == None or state_val not in [1, 2, 3]:
        return {"changed": False, "msg": "invalid state value for CPG",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if state_val == 1:
        state_name = "OK"
        summary = "Normal, %d VVs" % cpg.get("vvs", 0)
    elif state_val == 2:
        state_name = "WARN"
        summary = "Degraded, %d VVs" % cpg.get("vvs", 0)
    else:  # 3
        state_name = "CRIT"
        summary = "Failed, %d VVs" % cpg.get("vvs", 0)

    return {"changed": False, "msg": summary,
            "data": {"state": state_name, "metrics": {}, "details": ""}}
