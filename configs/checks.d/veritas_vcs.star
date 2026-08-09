# veritas_vcs Starlark check module
# Read-only: never mutates, always changed=False.

STATE_MAP_DEFAULT = {
    "ONLINE": 0,
    "RUNNING": 0,
    "OK": 0,
    "OFFLINE": 1,
    "EXITED": 1,
    "PARTIAL": 1,
    "FAULTED": 2,
    "UNKNOWN": 3,
    "default": 1,
}

FROZEN_MAP_DEFAULT = {
    "tfrozen": 1,
    "frozen": 2,
}

BOIL_DOWN_ORDER = ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]

def _state_num(state_text, smap):
    if state_text == None:
        return smap.get("default", 1)
    return smap.get(state_text, smap.get("default", 1))

def _boil_down(states):
    if len(states) == 1:
        return states[0]
    for dominant in BOIL_DOWN_ORDER:
        for s in states:
            if s == dominant:
                return dominant
    return "default"

def _frozen_results(list_vcs, frozen_map):
    results = []
    for vcs in list_vcs:
        attr = vcs["attr"].lower()
        if vcs["attr"].endswith("Frozen") and vcs["value"] != "0":
            summary = attr.replace("t", "temporarily ")
            results.append({"state": _state_num(attr, frozen_map), "summary": summary})
    return results

def _cluster_name(list_vcs):
    cname = None
    for vcs in list_vcs:
        if vcs["cluster"] != None:
            cname = vcs["cluster"]
    return cname

def _node_state(list_vcs, smap):
    summaries = []
    states = []
    for vcs in list_vcs:
        if vcs["attr"].endswith("State"):
            states.append(vcs["value"])
    state_text = None
    if states:
        state_text = _boil_down(states)
        for s in states:
            summaries.append(s.lower())
    return state_text, states, summaries

def _worst(a, b):
    if a == 3 or b == 3:
        return 3
    if a >= b:
        return a
    return b

def _worst_list(nums):
    w = 0
    for n in nums:
        w = _worst(w, n)
    return w

def _gather_vcs(ctx):
    probe = ctx.run(["which", "hasys"], mutates=False)
    if probe.rc != 0:
        return None, "VCS binaries not found"
    out = []
    hasys = ctx.run(["hasys", "-list"], mutates=False)
    if hasys.rc == 0:
        for line in hasys.stdout.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append([line, "RUNNING"])
    hacf = ctx.run(["hacf", "-list", "-cls"], mutates=False)
    if hacf.rc == 0:
        for line in hacf.stdout.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append([line, "RUNNING"])
    return out, None

def _parse_section(lines):
    parsed = {}
    section = None
    attr_idx = 0
    value_idx = 0
    attr = ""
    value = ""
    cluster_name = None
    for line in lines:
        if len(line) == 1 and line[0] == "#":
            continue
        if len(line) < 2:
            continue
        if line[0] == "ClusState":
            section = parsed.setdefault("cluster", {})
            attr = line[0]
            value = line[1]
        elif line[0] == "ClusterName":
            cluster_name = line[1]
            section.setdefault(cluster_name, []).append({
                "attr": attr, "value": value, "cluster": None
            })
        elif line[0].startswith("#"):
            section = parsed.setdefault(line[0][1:].lower(), {})
            attr_idx = 0
            value_idx = 0
            for i in range(len(line)):
                if line[i] == "Attribute":
                    attr_idx = i
                if line[i] == "Value":
                    value_idx = i
        elif len(line) > 2:
            item_name = line[0]
            attr = line[attr_idx]
            raw_value = line[value_idx].replace("|", "")
            if "UNKNOWN" in raw_value:
                raw_value = "UNKNOWN"
            section.setdefault(item_name, []).append({
                "attr": attr, "value": raw_value, "cluster": cluster_name
            })
    if not parsed:
        return None
    return parsed

def _subsection_items(section, key):
    items = []
    sub = section.get(key)
    if sub != None and type(sub) == "dict":
        for k in sub:
            items.append(k)
    return items

def main(ctx, params):
    checkname = params.get("checkname", "veritas_vcs")
    item = params.get("item", "")
    discover = params.get("_discover", False)

    smap = params.get("map_states", STATE_MAP_DEFAULT)
    frozen_map = params.get("map_frozen", FROZEN_MAP_DEFAULT)

    lines, err = _gather_vcs(ctx)
    if lines == None:
        if discover:
            return {"changed": False, "msg": "VCS not present: " + str(err),
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "VCS not present: " + str(err),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_section(lines)
    if section == None:
        if discover:
            return {"changed": False, "msg": "no VCS data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no VCS data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    is_cluster = checkname.find("_cluster") >= 0

    if is_cluster:
        if "_servicegroup" in checkname or "group" in checkname:
            sub_key = "group"
        elif checkname == "veritas_vcs_system_cluster" or "system" in checkname:
            sub_key = "system"
        elif "resource" in checkname:
            sub_key = "resource"
        else:
            sub_key = "cluster"
    else:
        if checkname == "veritas_vcs":
            sub_key = "cluster"
        elif checkname == "veritas_vcs_system":
            sub_key = "system"
        elif checkname == "veritas_vcs_group" or checkname == "veritas_vcs_servicegroup":
            sub_key = "group"
        elif checkname == "veritas_vcs_resource":
            sub_key = "resource"
        else:
            sub_key = "cluster"

    if discover:
        items = _subsection_items(section, sub_key)
        discovery = []
        for it in items:
            discovery.append({
                "item": it,
                "params": {"map_states": smap, "map_frozen": frozen_map},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d VCS %s items" % (len(discovery), sub_key),
                "data": {"discovery": discovery}}

    if is_cluster:
        node_results = []
        cluster_name = None
        nodes = _subsection_items(section, "system")
        if not nodes and section.get("cluster") != None:
            nodes = _subsection_items(section, "cluster")
        states_to_consider = []
        for node_name in nodes:
            node_sub = section.get(sub_key, {})
            if node_sub == None:
                continue
            item_sub = node_sub.get(item)
            if item_sub == None:
                continue
            fr = _frozen_results(item_sub, frozen_map)
            node_frozen = _worst_list([f["state"] for f in fr]) if fr else 0
            node_summaries = [f["summary"] for f in fr]
            state_text, states, st_summaries = _node_state(item_sub, smap)
            if state_text != None:
                node_summaries.append(state_text.lower())
                states_to_consider.append(node_frozen)
                states_to_consider.append(_state_num(state_text, smap))
            else:
                states_to_consider.append(node_frozen)
            node_results.append({
                "node_name": node_name,
                "summaries": node_summaries,
            })
            cn = _cluster_name(item_sub)
            if cn != None and cn != "":
                cluster_name = cn
        if not node_results:
            return {"changed": False, "msg": "no VCS node data for item " + str(item),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        cluster_state = _worst_list(states_to_consider)
        state_str = "OK"
        if cluster_state == 1:
            state_str = "WARN"
        elif cluster_state == 2:
            state_str = "CRIT"
        elif cluster_state == 3:
            state_str = "UNKNOWN"
        notice_parts = []
        for n in node_results:
            part = "[" + n["node_name"] + "]: " + ", ".join(n["summaries"])
            notice_parts.append(part)
        notice = ", ".join(notice_parts)
        details_lines = [notice]
        if cluster_state == 0:
            details_lines.append("All nodes OK")
        if cluster_name != None and cluster_name != "":
            details_lines.append("cluster: " + cluster_name)
        details = "\n".join(details_lines)
        msg = str(item)
        if cluster_state == 0:
            msg = msg + " OK"
        elif cluster_state == 1:
            msg = msg + " WARN"
        elif cluster_state == 2:
            msg = msg + " CRIT"
        else:
            msg = msg + " UNKNOWN"
        return {"changed": False, "msg": msg,
                "data": {"state": state_str, "metrics": {}, "details": details}}

    subsection = section.get(sub_key, {})
    if subsection == None or subsection.get(item) == None:
        return {"changed": False,
                "msg": "item " + str(item) + " not found in " + sub_key,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    list_vcs = subsection.get(item)
    fr = _frozen_results(list_vcs, frozen_map)
    state_text, states, st_summaries = _node_state(list_vcs, smap)
    cluster_name = _cluster_name(list_vcs)

    worst = 0
    for f in fr:
        worst = _worst(worst, f["state"])
    if states:
        bt = _boil_down(states)
        worst = _worst(worst, _state_num(bt, smap))

    state_str = "OK"
    if worst == 1:
        state_str = "WARN"
    elif worst == 2:
        state_str = "CRIT"
    elif worst == 3:
        state_str = "UNKNOWN"

    summaries = []
    for f in fr:
        summaries.append(f["summary"])
    for s in st_summaries:
        summaries.append(s)
    if cluster_name != None and cluster_name != "":
        summaries.append("cluster: " + cluster_name)

    details = ", ".join(summaries)
    msg = str(item) + " " + details

    return {"changed": False, "msg": msg,
            "data": {"state": state_str, "metrics": {}, "details": details}}