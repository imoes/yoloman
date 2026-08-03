# Checkmk check: veritas_vcs_resource — VCS Resource monitor (read-only)
# Translated to a Starlark check module. READ-ONLY: never mutates, never writes.

MAP_FROZEN = {
    "tfrozen": 1,
    "frozen": 2,
}

STATE_MAPPING = {
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

STATE_DOMINANCE = ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]


def _boil_down_states(states):
    if len(states) == 1:
        return states[0]
    for dominant in STATE_DOMINANCE:
        if dominant in states:
            return dominant
    return "default"


def _state_level(value, mapping):
    if value == None:
        return 1
    return mapping.get(value, mapping["default"])


def _worst_level(levels):
    worst = 0
    for lv in levels:
        if lv > worst:
            worst = lv
    return worst


def _level_to_state(level):
    if level == 0:
        return "OK"
    elif level == 1:
        return "WARN"
    elif level == 2:
        return "CRIT"
    else:
        return "UNKNOWN"


def _parse_vauxas(stdout):
    section = {}
    cluster_name = None
    current_section = None
    g_attr = ""
    g_value = ""
    attr_idx = 0
    value_idx = 0

    for raw_line in stdout.splitlines():
        line = raw_line.rstrip("\n")
        if line == "":
            continue
        fields = line.split()
        if fields == ["#"]:
            continue

        first = fields[0]

        if first == "ClusState":
            current_section = section.setdefault("cluster", {})
            attr_idx = 0
            value_idx = 1
            g_attr = fields[0]
            g_value = fields[1]
            continue

        if first == "ClusterName":
            cluster_name = fields[1]
            if current_section == None:
                current_section = section.setdefault("cluster", {})
            if g_attr != "" and g_value != "":
                current_section.setdefault(cluster_name, []).append({
                    "attr": g_attr,
                    "value": g_value,
                    "cluster": None,
                })
            continue

        if first.startswith("#"):
            category = first[1:].lower()
            current_section = section.setdefault(category, {})
            if "Attribute" in fields:
                attr_idx = fields.index("Attribute")
            else:
                attr_idx = 0
            if "Value" in fields:
                value_idx = fields.index("Value")
            else:
                value_idx = len(fields) - 1
            continue

        if len(fields) > 2 and current_section != None:
            item_name = fields[0]
            attr = fields[attr_idx]
            val = fields[value_idx].replace("|", "")
            if "UNKNOWN" in val:
                val = "UNKNOWN"
            current_section.setdefault(item_name, []).append({
                "attr": attr,
                "value": val,
                "cluster": cluster_name,
            })

    return section if section else None


def _gather_raw(ctx):
    res1 = ctx.run(["hauxas"], mutates=False)
    if res1.rc == 0 and res1.stdout != "":
        return res1.stdout, False

    res2 = ctx.run(["hacf", "-list"], mutates=False)
    if res2.rc == 0 and res2.stdout != "":
        return res2.stdout, False

    return "", True


def _subsection(section, kind):
    if section == None:
        return None
    return section.get(kind, {})


def _frozen_results(item_tuples, map_frozen):
    results = []
    for vcs in item_tuples:
        attr_lower = vcs["attr"].lower()
        if vcs["attr"].endswith("Frozen") and vcs["value"] != "0":
            level = map_frozen.get(attr_lower, 1)
            if attr_lower == "tfrozen":
                summary = "frozen temporarily"
            else:
                summary = "frozen"
            results.append({"summary": summary, "level": level})
    return results


def _cluster_name(item_tuples):
    name = None
    for vcs in item_tuples:
        if vcs["cluster"] != None:
            name = vcs["cluster"]
    return name


def _check_subsection(item, params, subsection):
    if subsection == None:
        return (3, "UNKNOWN", "no subsection data")

    item_tuples = subsection.get(item)
    if item_tuples == None:
        return (3, "UNKNOWN", "item vanished")

    levels = []
    summaries = []

    frozen = _frozen_results(item_tuples, params.get("map_frozen", MAP_FROZEN))
    for fr in frozen:
        levels.append(fr["level"])
        summaries.append(fr["summary"])

    state_texts = []
    for vcs in item_tuples:
        if vcs["attr"].endswith("State"):
            state_texts.append(vcs["value"])

    if state_texts:
        boiled = _boil_down_states(state_texts)
        lvl = _worst_level([_state_level(boiled, params.get("map_states", STATE_MAPPING))])
        levels.append(lvl)
        lowered = []
        for s in state_texts:
            lowered.append(s.lower())
        summaries.append(", ".join(lowered))
    else:
        lvl = _state_level(None, params.get("map_states", STATE_MAPPING))
        levels.append(lvl)

    cluster = _cluster_name(item_tuples)
    if cluster != None:
        summaries.append("cluster: " + cluster)

    overall = _worst_level(levels)
    detail = "; ".join(summaries)
    return (overall, ", ".join(summaries), detail)


def main(ctx, params):
    if params.get("_discover"):
        raw, missing = _gather_raw(ctx)
        if missing or raw == "":
            return {"changed": False, "msg": "no VCS data (hauxas/hacf not available)",
                    "data": {"discovery": [], "host_labels": {}}}

        section = _parse_vauxas(raw)
        if section == None:
            return {"changed": False, "msg": "parsed VCS section is empty",
                    "data": {"discovery": [], "host_labels": {}}}

        resource_sub = _subsection(section, "resource")
        if resource_sub == None or len(resource_sub) == 0:
            return {"changed": False, "msg": "no VCS resources discovered",
                    "data": {"discovery": [], "host_labels": {}}}

        discovery = []
        for item_name in sorted(resource_sub.keys()):
            discovery.append({
                "item": item_name,
                "params": {
                    "map_frozen": {"tfrozen": 1, "frozen": 2},
                    "map_states": {
                        "ONLINE": 0, "RUNNING": 0, "OK": 0,
                        "OFFLINE": 1, "EXITED": 1, "PARTIAL": 1,
                        "FAULTED": 2, "UNKNOWN": 3, "default": 1,
                    },
                },
                "metrics": [],
            })

        return {"changed": False, "msg": "discovered %d resources" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/veritas_vcs": "present"}}}

    item = params.get("item", "")
    if item == "" or item == None:
        return {"changed": False,
                "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no item"}}

    raw, missing = _gather_raw(ctx)
    if missing or raw == "":
        return {"changed": False,
                "msg": "no VCS data (hauxas/hacf not available)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no VCS data"}}

    section = _parse_vauxas(raw)
    if section == None:
        return {"changed": False,
                "msg": "parsed VCS section is empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "empty section"}}

    resource_sub = _subsection(section, "resource")
    if resource_sub == None:
        return {"changed": False,
                "msg": "no 'resource' subsection in VCS data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no resource subsection"}}

    level, summary, details = _check_subsection(item, params, resource_sub)
    if level == 3:
        return {"changed": False, "msg": "VCS Resource %s: UNKNOWN" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": details}}

    st = _level_to_state(level)
    return {"changed": False, "msg": summary,
            "data": {"state": st, "metrics": {}, "details": details}}