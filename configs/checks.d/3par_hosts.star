def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cmk", "-d", "3par_hosts"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "failed to retrieve 3par_hosts data",
                "data": {"discovery": []},
            }
        # simple JSON parser for top-level object with members array
        content = res.stdout.strip()
        if not content.startswith("{") or not content.endswith("}"):
            return {
                "changed": False,
                "msg": "invalid JSON in 3par_hosts data",
                "data": {"discovery": []},
            }
        # extract members array
        start = content.find('"members"')
        if start == -1:
            return {
                "changed": False,
                "msg": "no members found in 3par_hosts data",
                "data": {"discovery": []},
            }
        start = content.find("[", start)
        if start == -1:
            return {
                "changed": False,
                "msg": "invalid members array",
                "data": {"discovery": []},
            }
        # naive extraction: find matching ]
        depth = 1
        end = start + 1
        while end < len(content) and depth > 0 and content[end] != ']':
            if content[end] == '[':
                depth += 1
            elif content[end] == ']':
                depth -= 1
            end += 1
        if depth != 0:
            end = len(content)
        members_str = content[start+1:end]
        items = []
        # split by "name": "..." entries
        idx = 0
        while idx < len(members_str):
            pos = members_str.find('"name"', idx)
            if pos == -1:
                break
            q1 = members_str.find('"', pos + 6)
            if q1 == -1:
                break
            q2 = members_str.find('"', q1 + 1)
            if q2 == -1:
                break
            name = members_str[q1+1:q2]
            items.append({"item": name, "params": {}, "metrics": []})
            idx = q2 + 1
        return {
            "changed": False,
            "msg": "discovered %d hosts" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run(["cmk", "-d", "3par_hosts"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve 3par_hosts data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    content = res.stdout.strip()
    if not content.startswith("{") or not content.endswith("}"):
        return {
            "changed": False,
            "msg": "invalid JSON in 3par_hosts data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    # find host with matching name
    item_pos = content.find('"name":"%s"' % item)
    if item_pos == -1:
        item_pos = content.find('"name" : "%s"' % item)
    if item_pos == -1:
        return {
            "changed": False,
            "msg": "host not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    # find start of host object (nearest '{' before item_pos)
    start_obj = content.rfind("{", 0, item_pos)
    if start_obj == -1:
        return {
            "changed": False,
            "msg": "could not locate host object",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    # find end of host object (next '}' after item_pos)
    end_obj = content.find("}", item_pos)
    if end_obj == -1:
        end_obj = len(content)
    host_str = content[start_obj:end_obj+1]

    # extract id
    id_pos = host_str.find('"id"')
    host_id = ""
    if id_pos != -1:
        colon = host_str.find(":", id_pos)
        if colon != -1:
            val_end = colon + 1
            while val_end < len(host_str) and (host_str[val_end] == ' ' or host_str[val_end] == '\t'):
                val_end += 1
            num_start = val_end
            while num_end < len(host_str) and host_str[num_end].isdigit():
                num_end += 1
            if num_end > num_start:
                host_id = host_str[num_start:num_end]

    # extract os
    os_pos = host_str.find('"os"')
    os_val = None
    if os_pos != -1:
        q1 = host_str.find('"', os_pos)
        if q1 != -1:
            q2 = host_str.find('"', q1 + 1)
            if q2 != -1:
                os_val = host_str[q1+1:q2]

    # count fc paths
    fc_pos = host_str.find('"FCPaths"')
    fc_count = 0
    if fc_pos != -1:
        arr_start = host_str.find("[", fc_pos)
        if arr_start != -1:
            arr_end = host_str.find("]", arr_start)
            if arr_end != -1:
                inner = host_str[arr_start+1:arr_end]
                fc_count = inner.count('{')

    # count iscsi paths
    iscsi_pos = host_str.find('"iSCSIPaths"')
    iscsi_count = 0
    if iscsi_pos != -1:
        arr_start = host_str.find("[", iscsi_pos)
        if arr_start != -1:
            arr_end = host_str.find("]", arr_start)
            if arr_end != -1:
                inner = host_str[arr_start+1:arr_end]
                iscsi_count = inner.count('{')

    parts = []
    parts.append("ID: %s" % host_id)
    if os_val != None:
        parts.append("OS: %s" % os_val)
    if fc_count > 0:
        parts.append("FC Paths: %d" % fc_count)
    elif iscsi_count > 0:
        parts.append("iSCSI Paths: %d" % iscsi_count)

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
