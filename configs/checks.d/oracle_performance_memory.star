# Constants for SGA fields (from cmk.plugins.oracle.constants.ORACLE_SGA_FIELDS)
SGA_FIELDS = [
    {"name": "Database Buffers", "metric": "oracle_sga_database_buffers"},
    {"name": "Shared Pool", "metric": "oracle_sga_shared_pool"},
    {"name": "Large Pool", "metric": "oracle_sga_large_pool"},
    {"name": "Java Pool", "metric": "oracle_sga_java_pool"},
    {"name": "Redo Buffers", "metric": "oracle_sga_redo_buffers"},
    {"name": "Fixed Size", "metric": "oracle_sga_fixed_size"},
    {"name": "Variable Size", "metric": "oracle_sga_variable_size"},
    {"name": "Maximum SGA Size", "metric": "oracle_sga_maximum_size"},
]

# Constants for PGA fields (from cmk.plugins.oracle.constants.ORACLE_PGA_FIELDS)
PGA_FIELDS = [
    {"name": "total PGA allocated", "metric": "oracle_pga_total_allocated"},
    {"name": "total PGA inuse", "metric": "oracle_pga_total_inuse"},
    {"name": "total PGA freeable", "metric": "oracle_pga_total_freeable"},
    {"name": "maximum PGA allocated", "metric": "oracle_pga_maximum_allocated"},
]

# Helper: check levels for memory values (bytes) - matches Checkmk's check_levels
def _check_levels_value(value, levels_upper, metric_name, label, render_func):
    warn = None
    crit = None
    if levels_upper != None:
        warn = levels_upper.get("warn")
        crit = levels_upper.get("crit")
    if warn == None and crit == None:
        return {"state": "OK", "summary": "%s: %s" % (label, render_func(value)), "metric": {metric_name: value}, "notice_only": True}
    state = "OK"
    summary = "%s: %s" % (label, render_func(value))
    if crit != None and value >= crit:
        state = "CRIT"
        summary = "%s (crit. at %s)" % (summary, render_func(crit))
    elif warn != None and value >= warn:
        state = "WARN"
        summary = "%s (warn. at %s)" % (summary, render_func(warn))
    return {"state": state, "summary": summary, "metric": {metric_name: value}, "notice_only": True}

# Render function for bytes
def _render_bytes(value):
    # Approximate render.bytes: returns human-readable bytes string
    if value < 1024:
        return "%f B" % value
    elif value < 1024 * 1024:
        return "%f KB" % (value / 1024.0)
    elif value < 1024 * 1024 * 1024:
        return "%f MB" % (value / (1024.0 * 1024.0))
    else:
        return "%f GB" % (value / (1024.0 * 1024.0 * 1024.0))

# Core memory check logic (reproduces _check_oracle_memory_info)
def _check_oracle_memory_info(data, params, sticky_fields, fields):
    results = []
    for ga_field in fields:
        value = data.get(ga_field.get("name"))
        if value == None:
            continue
        metric_name = ga_field.get("metric")
        label = ga_field.get("name")
        sticky = label in sticky_fields
        res = _check_levels_value(value, params.get(metric_name), metric_name, label, _render_bytes)
        results.append({
            "state": res.get("state"),
            "summary": res.get("summary"),
            "metric": res.get("metric"),
            "notice_only": (not sticky),
        })
    return results

def main(ctx, params):
    item = params.get("item", "")
    if params.get("_discover"):
        # Discovery: emit one service per SID in the performance section
        # We need to get performance data to enumerate SIDs
        # For Starlark agent, we assume the agent provides oracle_performance data via a JSON file
        agent_file = "/var/lib/yolo-agent/oracle_performance.json"
        if not ctx.file_exists(agent_file):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        raw = ctx.file_read(agent_file)
        data = json.decode(raw)
        sids = data.keys() if type(data) == "dict" else []
        discovery_list = []
        for sid in sids:
            if type(sid) == "string":
                # Check if SID has SGA_info to justify memory check
                instance_data = data.get(sid, {})
                sga_info = instance_data.get("SGA_info", {})
                if type(sga_info) == "dict" and len(sga_info) > 0:
                    discovery_list.append({"item": sid, "params": {}, "metrics": ["oracle_sga_database_buffers", "oracle_pga_total_allocated"]})
        return {"changed": False, "msg": "discovered %d instances" % len(discovery_list), "data": {"discovery": discovery_list}}
    # Check mode for one item
    agent_file = "/var/lib/yolo-agent/oracle_performance.json"
    if not ctx.file_exists(agent_file):
        return {"changed": False, "msg": "agent data not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = ctx.file_read(agent_file)
    data = json.decode(raw)
    instance_data = data.get(item, {})
    if type(instance_data) != "dict":
        return {"changed": False, "msg": "no data for instance " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sga_info = instance_data.get("SGA_info", {})
    if type(sga_info) != "dict":
        return {"changed": False, "msg": "no SGA info for instance " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Run the memory check
    results = _check_oracle_memory_info(sga_info, {}, ["Maximum SGA Size"], SGA_FIELDS)
    pga_info_raw = instance_data.get("PGA_info", {})
    pga_info = {}
    if type(pga_info_raw) == "dict":
        for field, val_list in pga_info_raw.items():
            if type(val_list) == "list" and len(val_list) > 0:
                pga_info[field] = val_list[0]
    results += _check_oracle_memory_info(pga_info, {}, ["total PGA allocated"], PGA_FIELDS)
    # Aggregate results
    state = "OK"
    summaries = []
    metrics = {}
    for res in results:
        if res.get("state") != "OK":
            state = res.get("state")
        summaries.append(res.get("summary"))
        metrics.update(res.get("metric"))
    details = ", ".join(summaries)
    msg = details if details != "" else "Memory metrics OK"
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}