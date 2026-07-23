def _format_bytes(b):
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(b) < 1024.0:
            return "%f %s" % (b, unit)
        b = b / 1024.0
    return "%f %s" % (b, "PB")

def _format_timespan(s):
    s = int(s)
    parts = []
    for unit, name in [(60, "min"), (60, "h"), (24, "d"), (365, "y")]:
        if s >= unit:
            val = s // unit
            parts.insert(0, "%d %s" % (val, name))
            s = s % unit
    if s > 0 or len(parts) == 0:
        parts.insert(0, "%d s" % s)
    return " ".join(parts)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["systemctl", "list-units", "--type=service", "--no-legend", "--no-pager"], mutates=False)
        discovery = []
        for line in res.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 4:
                unit = fields[0]
                if unit.endswith(".service"):
                    name = unit[:-8]
                else:
                    continue
                if name.find("check-mk-agent@") == 0:
                    continue
                res_status = ctx.run(["systemctl", "show", unit, "--property=ActiveState,SubState,Description,CPUUsageNSec,MemoryCurrent,TasksCurrent,StateChangeTimestampMonotonic"], mutates=False)
                status = {"ActiveState": "", "SubState": "", "Description": ""}
                for st_line in res_status.stdout.splitlines():
                    if st_line.find("=") != -1:
                        k, v = st_line.split("=", 1)
                        status[k] = v.strip()
                item_params = {
                    "states": {
                        "active": 0,
                        "inactive": 0,
                        "failed": 2,
                    },
                    "states_default": 2,
                }
                discovery.append({
                    "item": name,
                    "params": item_params,
                    "metrics": ["cpu_time", "active_since", "mem_used", "number_of_tasks"]
                })
        return {"changed": False, "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    unit_name = item + ".service"
    
    res_exists = ctx.run(["systemctl", "is-active", unit_name], mutates=False)
    if res_exists.rc != 0:
        else_state = params.get("else", 2)
        state_str = "CRIT" if else_state == 2 else ("WARN" if else_state == 1 else "OK")
        return {
            "changed": False,
            "msg": "Unit not found",
            "data": {
                "state": state_str,
                "metrics": {},
                "details": "Only units currently in memory are found. These can be shown with `systemctl --all --type service --type socket`."
            }
        }
    
    res_show = ctx.run(["systemctl", "show", unit_name, "--property=ActiveState,Description,CPUUsageNSec,MemoryCurrent,TasksCurrent,StateChangeTimestampMonotonic"], mutates=False)
    props = {}
    for line in res_show.stdout.splitlines():
        if line.find("=") != -1:
            key, val = line.split("=", 1)
            props[key] = val.strip()
    
    active_status = props.get("ActiveState", "")
    description = props.get("Description", "")
    
    states = params.get("states", {"active": 0, "inactive": 0, "failed": 2})
    state_val = states.get(active_status, params.get("states_default", 2))
    if state_val == 2:
        state_str = "CRIT"
    elif state_val == 1:
        state_str = "WARN"
    else:
        state_str = "OK"
    
    metrics = {}
    details = []
    
    cpu_ns_str = props.get("CPUUsageNSec")
    if cpu_ns_str and cpu_ns_str != "":
        if cpu_ns_str.isdigit():
            cpu_ns = int(cpu_ns_str)
            if cpu_ns != 18446744073709551615:
                cpu_seconds = float(cpu_ns) / 1000000000.0
                metrics["cpu_time"] = cpu_seconds
                details.append("CPU Time: %f s" % cpu_seconds)
                cpu_levels = params.get("cpu_time")
                if cpu_levels != None:
                    warn_val, crit_val = cpu_levels
                    if crit_val != None and cpu_seconds >= crit_val:
                        state_str = "CRIT"
                    elif warn_val != None and cpu_seconds >= warn_val:
                        state_str = "WARN" if state_str != "CRIT" else state_str
        else:
            cpu_ns = 0
    
    mem_str = props.get("MemoryCurrent")
    if mem_str and mem_str != "":
        if mem_str.isdigit():
            mem_bytes = int(mem_str)
            if mem_bytes != 18446744073709551615:
                metrics["mem_used"] = mem_bytes
                details.append("Memory: %s" % _format_bytes(mem_bytes))
                mem_levels = params.get("memory")
                if mem_levels != None:
                    warn_val, crit_val = mem_levels
                    if crit_val != None and mem_bytes >= crit_val:
                        state_str = "CRIT"
                    elif crit_val == None and warn_val != None and mem_bytes >= warn_val:
                        state_str = "WARN" if state_str != "CRIT" else state_str
        else:
            mem_bytes = 0
    
    tasks_str = props.get("TasksCurrent")
    if tasks_str and tasks_str != "":
        if tasks_str.isdigit():
            tasks = int(tasks_str)
            if tasks != 18446744073709551615:
                metrics["number_of_tasks"] = tasks
                details.append("Tasks: %d" % tasks)
        else:
            tasks = 0
    
    if active_status == "active":
        timestamp_str = props.get("StateChangeTimestampMonotonic")
        if timestamp_str and timestamp_str != "":
            if timestamp_str.isdigit():
                ts_us = int(timestamp_str)
                if ts_us > 0:
                    res_uptime = ctx.run(["cat", "/proc/uptime"], mutates=False)
                    if res_uptime.rc == 0:
                        uptime_str = res_uptime.stdout.split()[0]
                        if uptime_str.find(".") != -1:
                            uptime_parts = uptime_str.split(".")
                            if uptime_parts[0].isdigit() and uptime_parts[1].isdigit():
                                uptime = float(uptime_parts[0]) + float("." + uptime_parts[1])
                            else:
                                uptime = 0.0
                        elif uptime_str.isdigit():
                            uptime = float(uptime_str)
                        else:
                            uptime = 0.0
                        
                        elapsed = uptime - (float(ts_us) / 1000000.0)
                        if elapsed >= 0:
                            metrics["active_since"] = elapsed
                            details.append("Active since: %s" % _format_timespan(elapsed))
                            active_levels = params.get("active_since_lower")
                            if active_levels != None:
                                warn_val, crit_val = active_levels
                                if crit_val != None and elapsed <= crit_val:
                                    state_str = "CRIT"
                                elif warn_val != None and elapsed <= warn_val:
                                    state_str = "WARN" if state_str != "CRIT" else state_str
            else:
                ts_us = 0
    
    msg = "Status: %s, %s" % (active_status, description)
    if len(details) > 0:
        msg += ", " + ", ".join(details)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": ""
        }
    }