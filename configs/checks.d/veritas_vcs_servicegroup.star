# Checkmk VCS Service Group check - read-only Starlark translation
# Monitors Veritas Cluster Server service groups via hagrp -state

DEFAULT_MAP_STATES = {
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

DEFAULT_MAP_FROZEN = {
    "tfrozen": 1,
    "frozen": 2,
}


def _probe_vcs_running(ctx):
    res = ctx.run(["hagrp", "-state"], mutates=False)
    return res


def _parse_vcs_groups(ctx):
    res = _probe_vcs_running(ctx)
    if res.rc != 0:
        return None

    groups = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        group_name = parts[0]
        state = parts[1]
        system = parts[2]
        clean_state = state.replace("|", "")
        if "UNKNOWN" in clean_state:
            clean_state = "UNKNOWN"
        groups.setdefault(group_name, []).append({
            "attr": "State",
            "value": clean_state,
            "cluster": system,
        })
    return groups


def _parse_frozen_info(ctx):
    res = ctx.run(["hagrp", "-display"], mutates=False)
    if res.rc != 0:
        return {}
    frozen_map = {}
    current_group = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Group ") and len(line.split()) >= 3:
            current_group = line.split()[2]
        elif current_group != None and stripped.startswith("Frozen ") and len(stripped.split()) >= 3:
            frozen_map.setdefault(current_group, {})["frozen"] = stripped.split()[2]
        elif current_group != None and stripped.startswith("TFrozen ") and len(stripped.split()) >= 3:
            frozen_map.setdefault(current_group, {})["tfrozen"] = stripped.split()[2]
    return frozen_map


def _boil_down_states(states):
    if len(states) == 1:
        return states[0]
    for dominant in ["FAULTED", "UNKNOWN", "ONLINE", "RUNNING"]:
        if dominant in states:
            return dominant
    return "default"


def _collect_states(tuples):
    states = []
    for v in tuples:
        if v["attr"].endswith("State"):
            states.append(v["value"])
    return states


def _get_cluster_name(tuples):
    for v in tuples:
        if v["cluster"] != None:
            return v["cluster"]
    return None


def _join_summary(parts):
    result = ""
    for p in parts:
        if result == "":
            result = p
        else:
            result = result + ", " + p
    return result


def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["hagrp", "--version"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "hagrp not found", "data": {"discovery": []}}

        groups = _parse_vcs_groups(ctx)
        if groups == None or len(groups) == 0:
            return {"changed": False, "msg": "no VCS service groups found", "data": {"discovery": []}}

        map_frozen = params.get("map_frozen", DEFAULT_MAP_FROZEN)
        map_states = params.get("map_states", DEFAULT_MAP_STATES)

        discovery = []
        for group_name in sorted(groups.keys()):
            discovery.append({
                "item": group_name,
                "params": {"map_frozen": map_frozen, "map_states": map_states},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d service groups" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    map_frozen = params.get("map_frozen", DEFAULT_MAP_FROZEN)
    map_states = params.get("map_states", DEFAULT_MAP_STATES)

    probe = ctx.run(["hagrp", "--version"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "VCS not installed: hagrp not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    groups = _parse_vcs_groups(ctx)
    if groups == None:
        return {
            "changed": False,
            "msg": "unable to read VCS group state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if item not in groups:
        return {
            "changed": False,
            "msg": "service group %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    tuples = groups[item]
    frozen_info = _parse_frozen_info(ctx)
    item_frozen = frozen_info.get(item, {})

    tfrozen_val = item_frozen.get("tfrozen", "0")
    frozen_val = item_frozen.get("frozen", "0")

    frozen_states = []
    frozen_texts = []

    if tfrozen_val != "0":
        frozen_states.append(map_frozen.get("tfrozen", 1))
        frozen_texts.append("temporarily frozen")
    if frozen_val != "0":
        frozen_states.append(map_frozen.get("frozen", 2))
        frozen_texts.append("frozen")

    states = _collect_states(tuples)

    summary_parts = []
    worst_frozen = 0
    for s in frozen_states:
        if s > worst_frozen:
            worst_frozen = s
    if len(frozen_texts) > 0:
        summary_parts = summary_parts + frozen_texts

    state = "OK"
    if len(states) > 0:
        state_text = _boil_down_states(states)
        state_num = map_states.get(state_text, map_states["default"])
        lowered = []
        for s in states:
            lowered.append(s.lower())
        summary_parts.append(_join_summary(lowered))
        if state_num == 0:
            state = "OK"
        elif state_num == 1:
            state = "WARN"
        elif state_num == 2:
            state = "CRIT"
        elif state_num == 3:
            state = "UNKNOWN"
        if worst_frozen > 0:
            if worst_frozen == 2:
                state = "CRIT"
            elif worst_frozen == 1:
                if state != "CRIT":
                    state = "WARN"

    if state == "OK" and len(summary_parts) == 0:
        summary_parts.append("online")

    cluster_name = _get_cluster_name(tuples)

    msg_parts = []
    if state != "OK":
        msg_parts.append(state + ": " + item)
    if len(summary_parts) > 0:
        msg_parts.append(_join_summary(summary_parts))
    if cluster_name != None:
        msg_parts.append("cluster: " + str(cluster_name))

    msg = _join_summary(msg_parts)
    if len(msg_parts) == 0:
        msg = item + ": " + state
    else:
        msg = " | ".join(msg_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": _join_summary(summary_parts),
        },
    }