# Helper to convert timestamp string "+DD HH:MM:SS.fff" to seconds
def _get_seconds(timestamp):
    if timestamp == None or timestamp == "":
        return None
    if len(timestamp) < 12 or timestamp[0] != "+":
        return None
    days_str = timestamp[1:3]
    h_str = timestamp[4:6]
    min_str = timestamp[7:9]
    sec_str = timestamp[10:12]
    if not days_str.isdigit() or not h_str.isdigit() or not min_str.isdigit() or not sec_str.isdigit():
        return None
    days = int(days_str)
    h = int(h_str)
    min_ = int(min_str)
    sec = int(sec_str)
    return sec + 60 * min_ + 3600 * h + 86400 * days

# Default levels from Checkmk plugin
DEFAULT_LEVELS = {
    "apply_lag": (3600, 14400),
    "missing_apply_lag_state": 1,
    "active_dataguard_option": 1,
    "primary_broker_state": False,
}

def _check_levels(value, levels_upper, levels_lower):
    # Simplified levels handling: only "fixed" type supported
    if levels_lower != None:
        if levels_lower[1] != None and value <= levels_lower[1]:
            return "CRIT"
        if levels_lower[0] != None and value <= levels_lower[0]:
            return "WARN"
    if levels_upper != None:
        if levels_upper[1] != None and value >= levels_upper[1]:
            return "CRIT"
        if levels_upper[0] != None and value >= levels_upper[0]:
            return "WARN"
    return "OK"

def _parse_section(string_table):
    parsed = {}
    for line in string_table:
        if len(line) < 5:
            continue
        instance_key = line[0] + "." + line[1]
        instance = parsed.get(instance_key, {
            "database_role": "",
            "dgstat": {},
        })
        instance["database_role"] = line[2]
        instance["dgstat"][line[3]] = line[4]
        if len(line) >= 6:
            instance["switchover_status"] = line[5]
        if len(line) >= 13:
            instance["broker_state"] = line[6]
            instance["protection_mode"] = line[7]
            instance["fs_failover_status"] = line[8]
            instance["fs_failover_observer_present"] = line[9]
            instance["fs_failover_observer_host"] = line[10]
            instance["fs_failover_target"] = line[11]
            instance["mrp_status"] = line[12]
        if len(line) >= 14:
            instance["open_mode"] = line[13]
        parsed[instance_key] = instance
    return parsed

def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_dataguard_stats"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no dataguard data available",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        string_table = []
        for line in lines:
            if line == "":
                continue
            fields = line.split("|")
            string_table.append(fields)
        section = _parse_section(string_table)
        items = []
        for item in section:
            items.append({"item": item, "params": {}, "metrics": [
                "apply_lag", "apply_finish_time", "transport_lag"
            ]})
        return {"changed": False, "msg": "discovered %d instances" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/oracle_dataguard_stats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no dataguard data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    string_table = []
    for line in lines:
        if line == "":
            continue
        fields = line.split("|")
        string_table.append(fields)
    section = _parse_section(string_table)

    if not section.get(item):
        return {"changed": False, "msg": "instance not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dgdata = section.get(item)
    results = []
    metrics = {}
    
    # Database role
    db_role = dgdata.get("database_role", "")
    results.append("Database Role %s" % db_role.lower())

    # Protection mode
    if dgdata.get("protection_mode"):
        results.append("Protection Mode %s" % dgdata.get("protection_mode").lower())

    # Broker state and Fast Start Failover
    if dgdata.get("broker_state"):
        results.append("Broker %s" % dgdata.get("broker_state").lower())

        if dgdata.get("fs_failover_status") != None and dgdata.get("fs_failover_status") != "DISABLED":
            if dgdata.get("fs_failover_observer_present") != "YES":
                results.append("Observer not connected")
            else:
                results.append("Observer connected %s from host %s" % (
                    dgdata.get("fs_failover_observer_present").lower(),
                    dgdata.get("fs_failover_observer_host")
                ))

                # Check FSFO status
                mode = dgdata.get("protection_mode", "")
                status = dgdata.get("fs_failover_status", "")
                if (mode == "MAXIMUM PERFORMANCE" and status == "TARGET UNDER LAG LIMIT") or \
                   (mode == "MAXIMUM AVAILABILITY" and status == "SYNCHRONIZED"):
                    pass  # OK, no extra message
                else:
                    results.append("Fast Start Failover %s" % status.lower())

    # Switchover status
    if dgdata.get("switchover_status"):
        if db_role == "PRIMARY":
            if dgdata.get("switchover_status") in ("TO STANDBY", "SESSIONS ACTIVE", "RESOLVABLE GAP", "LOG SWITCH GAP"):
                results.append("Switchover to standby possible")
            else:
                primary_broker_state = params.get("primary_broker_state", DEFAULT_LEVELS["primary_broker_state"])
                if primary_broker_state or dgdata.get("broker_state", "").lower() == "enabled":
                    results.append("Switchover to standby not possible! reason: %s" % dgdata.get("switchover_status").lower())
                else:
                    results.append("Switchoverstate ignored ")
        elif db_role == "PHYSICAL STANDBY":
            if dgdata.get("switchover_status") in ("SYNCHRONIZED", "NOT ALLOWED", "SESSIONS ACTIVE"):
                results.append("Switchover to primary possible")
            else:
                results.append("Switchover to primary not possible! reason: %s" % dgdata.get("switchover_status"))

    # MRP status
    if dgdata.get("mrp_status"):
        results.append("Managed Recovery Process state %s" % dgdata.get("mrp_status").lower())
        if dgdata.get("open_mode", "") == "READ ONLY WITH APPLY":
            results.append("Active Data-Guard found")

    # Dataguard parameters (timedeltas)
    for param in ("apply finish time", "apply lag", "transport lag"):
        raw_value = dgdata.get("dgstat", {}).get(param, "")
        seconds = _get_seconds(raw_value)
        pkey = param.replace(" ", "_")
        label = param.capitalize()

        if seconds == None:
            state = "WARN"
            if param == "apply lag":
                state = "WARN" if params.get("missing_apply_lag_state") == None else "WARN"
            results.append("%s: %s" % (label, raw_value if raw_value != "" else "no value"))
        else:
            # Levels handling
            warn = None
            crit = None
            if param == "apply lag":
                default_levels = DEFAULT_LEVELS.get("apply_lag", (3600, 14400))
                warn = params.get("apply_lag", default_levels)[0]
                crit = params.get("apply_lag", default_levels)[1]
            levels_upper = (warn, crit) if warn != None and crit != None else None
            level_state = _check_levels(seconds, levels_upper, None)
            if level_state == "WARN":
                results.append("%s: %s (warn/crit at %ss/%ss)" % (
                    label, raw_value, str(int(warn)), str(int(crit))))
            elif level_state == "CRIT":
                results.append("%s: %s (warn/crit at %ss/%ss)" % (
                    label, raw_value, str(int(warn)), str(int(crit))))
            else:
                results.append("%s: %s" % (label, raw_value))
            metrics[pkey] = seconds

    # Determine final state
    state = "OK"
    for r in results:
        if "not possible" in r.lower() or "not connected" in r.lower():
            state = "CRIT"
            break
        if "Fast Start Failover" in r and "not" in r.lower():
            state = "WARN"
            break

    return {"changed": False,
            "msg": "; ".join(results),
            "data": {"state": state, "metrics": metrics, "details": ""}}