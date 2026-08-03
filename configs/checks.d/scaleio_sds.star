# Constants
SUPPORTED_UNITS = {
    "Bytes": 1.0 / 1024.0 / 1024.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1024.0 * 1024.0,
}

# FILESYSTEM_DEFAULT_PARAMS equivalent from df_check
DEFAULT_PARAMS_FILESYSTEM = {
    "levels": (80.0, 90.0),
    "reserved": 0.0,
}

def main(ctx, params):
    plugin_name = params.get("plugin", "scaleio_sds")

    if params.get("_discover"):
        return _discovery(ctx, plugin_name)

    return _check(ctx, params, plugin_name)

def _discovery(ctx, plugin_name):
    data = _gather_sds_data(ctx)
    if data == None:
        return {"changed": False, "msg": "no ScaleIO SDS found", "data": {"discovery": [], "host_labels": {}}}

    sections = _parse_scaleio(data, "SDS")
    out = []
    for sds_id, sds_data in sections.items():
        item = sds_id
        if plugin_name == "scaleio_sds":
            out.append({"item": item, "params": dict(DEFAULT_PARAMS_FILESYSTEM), "metrics": ["used_percent"]})
        elif plugin_name == "scaleio_sds_status":
            out.append({"item": item, "params": {}, "metrics": []})
    return {"changed": False, "msg": "discovered %d SDS nodes" % len(out), "data": {"discovery": out, "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "linux")}}}

def _check(ctx, params, plugin_name):
    data = _gather_sds_data(ctx)
    if data == None:
        return {"changed": False, "msg": "ScaleIO SDS data not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no ScaleIO SDS found on this host"}}

    sections = _parse_scaleio(data, "SDS")
    item = params.get("item", "")
    sds_data = sections.get(item)
    if sds_data == None:
        return {"changed": False, "msg": "no data for SDS: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": "SDS " + str(item) + " not found in data"}}

    if plugin_name == "scaleio_sds":
        return _check_capacity(item, params, sds_data)
    elif plugin_name == "scaleio_sds_status":
        return _check_status(item, sds_data)
    return {"changed": False, "msg": "unsupported plugin: " + str(plugin_name), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _check_capacity(item, params, sds_data):
    max_cap = sds_data.get("MAX_CAPACITY_IN_KB", [])
    unused_cap = sds_data.get("UNUSED_CAPACITY_IN_KB", [])
    if len(max_cap) < 4 or len(unused_cap) < 4:
        return {"changed": False, "msg": "incomplete capacity data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "MAX_CAPACITY_IN_KB or UNUSED_CAPACITY_IN_KB data incomplete"}}

    unit = max_cap[3].strip(")")
    if unit not in SUPPORTED_UNITS:
        return {"changed": False, "msg": "Unknown unit: " + unit, "data": {"state": "UNKNOWN", "metrics": {}, "details": "Cannot convert capacity with unknown unit: " + unit}}

    total_mb = _convert_space(unit, float(max_cap[2].strip("(")))
    free_mb = _convert_space(unit, float(unused_cap[2].strip("(")))
    used_mb = total_mb - free_mb
    used_percent = (used_mb / total_mb * 100.0) if total_mb > 0 else 0.0

    levels = params.get("levels", (80.0, 90.0))
    warn, crit = levels[0], levels[1]
    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
    return {"changed": False, "msg": "%s: %f%% used (%f MB of %f MB)" % (item, used_percent, used_mb, total_mb), "data": {"state": state, "metrics": {"used_percent": used_percent, "total_mb": total_mb, "used_mb": used_mb, "free_mb": free_mb}, "details": "Total: %f MB, Used: %f MB, Free: %f MB" % (total_mb, used_mb, free_mb)}}

def _check_status(item, sds_data):
    name_val = _first(sds_data.get("NAME", []))
    pd_id_val = _first(sds_data.get("PROTECTION_DOMAIN_ID", []))
    summary_parts = []
    if name_val != "":
        summary_parts.append("Name: " + name_val)
    if pd_id_val != "":
        summary_parts.append("PD: " + pd_id_val)
    if len(summary_parts) == 0:
        return {"changed": False, "msg": "no status data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "SDS status data incomplete"}}

    details_lines = [", ".join(summary_parts)]
    worst_state = "OK"

    state = _first(sds_data.get("STATE", []))
    if state != "":
        details_lines.append("State: " + state)
        if "normal" not in state.lower():
            worst_state = _worsen(worst_state, "CRIT")

    maint = _first(sds_data.get("MAINTENANCE_MODE_STATE", []))
    if maint != "":
        details_lines.append("Maintenance: " + maint)
        if "no_maintenance" not in maint.lower() and "no maintenance" not in maint.lower():
            worst_state = _worsen(worst_state, "WARN")

    conn = _first(sds_data.get("MDM_CONNECTION_STATE", []))
    if conn != "":
        details_lines.append("Connection state: " + conn)
        if "connected" not in conn.lower():
            worst_state = _worsen(worst_state, "CRIT")

    member = _first(sds_data.get("MEMBERSHIP_STATE", []))
    if member != "":
        details_lines.append("Membership: " + member)
        if "joined" not in member.lower():
            worst_state = _worsen(worst_state, "CRIT")

    return {"changed": False, "msg": ", ".join(summary_parts), "data": {"state": worst_state, "metrics": {}, "details": "\n".join(details_lines)}}

def _gather_sds_data(ctx):
    # Probe for the real thing: ScaleIO CLI / MDM management
    res = ctx.run(["scli", "--version"], mutates=False)
    if res.rc == 127:
        # Try alternative ScaleIO query command used by agent plugin
        res2 = ctx.run(["scli", "--query_sds"], mutates=False)
        if res2.rc == 127:
            return None
        return res2.stdout
    # Use the real ScaleIO query that the Checkmk agent plugin runs
    res2 = ctx.run(["scli", "--query_sds"], mutates=False)
    if res2.rc != 0:
        return None
    return res2.stdout

def _parse_scaleio(string_table, section_name):
    section = {}
    sys_id = ""
    for line in string_table.split("\n"):
        fields = line.split()
        if len(fields) < 2:
            continue
        if fields[0].startswith(section_name):
            sys_id = fields[1].replace(":", "")
            section.setdefault(sys_id, {})
        elif sys_id in section and sys_id != "":
            section[sys_id][fields[0]] = fields[1:]
    return section

def _convert_space(unit, value):
    return value * SUPPORTED_UNITS[unit]

def _first(lst):
    if len(lst) > 0:
        return str(lst[0])
    return ""

def _worsen(current, new_state):
    order = ["OK", "WARN", "CRIT", "UNKNOWN"]
    cur_idx = order.index(current)
    new_idx = order.index(new_state)
    return order[max(cur_idx, new_idx)]