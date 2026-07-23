def main(ctx, params):
    # Default parameters matching Checkmk defaults
    DEFAULTS = {
        "load_call_failure_index": {"upper": (10, 20)},
        "failed_calls_because_of_proxy": {"upper": (10, 20)},
        "failed_calls_because_of_gateway": {"upper": (10, 20)},
        "media_connectivity_failure": {"upper": (1, 2)},
    }
    
    def _levels_upper(levels):
        if levels == None or len(levels) == 0:
            return None
        return levels.get("upper")
    
    def _get_counter_value(table_name, column_name, fallback_column_name):
        # Get WMI data by running the agent command
        res = ctx.run(["wmic", "/namespace:\\\\root\\cimv2", "path", table_name, "get", "/format:csv"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return None, False
        
        # Parse CSV output - format is complex, try to get the data
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return None, False
        
        # Header line
        header = lines[0].split(",")
        col_idx = -1
        if column_name in header:
            col_idx = header.index(column_name)
        elif fallback_column_name in header:
            col_idx = header.index(fallback_column_name)
        else:
            return None, False
        
        # Find first data row with non-zero values
        for line in lines[1:]:
            if not line.strip():
                continue
            fields = line.split(",")
            if len(fields) > col_idx and fields[col_idx].strip():
                val_str = fields[col_idx].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    return int(val_str), True
        
        return None, False
    
    def _check_counter(table_name, column_name, fallback_column_name, perfvar, levels_key):
        value, found = _get_counter_value(table_name, column_name, fallback_column_name)
        if not found:
            return None, None, None
        
        levels = params.get(levels_key, DEFAULTS[levels_key])
        upper_levels = _levels_upper(levels)
        
        state = "OK"
        if upper_levels != None:
            if value >= upper_levels[1]:
                state = "CRIT"
            elif value >= upper_levels[0]:
                state = "WARN"
        
        return state, value, perfvar
    
    if params.get("_discover") == True:
        # Discovery: check if required WMI tables exist
        required_tables = [
            "LS:MediationServer - Health Indices",
            "LS:MediationServer - Global Counters",
            "LS:MediationServer - Global Per Gateway Counters",
            "LS:MediationServer - Media Relay",
        ]
        
        discovered_items = []
        
        # Try to get data for each table to confirm it exists
        for table in required_tables:
            res = ctx.run(["wmic", "/namespace:\\\\root\\cimv2", "path", table, "get", "/format:csv"], mutates=False)
            if res.rc == 0 and res.stdout:
                lines = res.stdout.splitlines()
                if len(lines) >= 2:
                    # Found at least one instance - yield one service
                    discovered_items.append({
                        "item": "",
                        "params": {
                            "load_call_failure_index": {"upper": (10, 20)},
                            "failed_calls_because_of_proxy": {"upper": (10, 20)},
                            "failed_calls_because_of_gateway": {"upper": (10, 20)},
                            "media_connectivity_failure": {"upper": (1, 2)},
                        },
                        "metrics": [
                            "mediation_load_call_failure_index",
                            "mediation_failed_calls_because_of_proxy",
                            "mediation_failed_calls_because_of_gateway",
                            "mediation_media_connectivity_failure",
                        ],
                    })
                    break
        
        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }
    
    # Check mode
    state_overall = "OK"
    metrics = {}
    details_parts = []
    
    # Check: Load Call Failure Index
    val, found = _get_counter_value("LS:MediationServer - Health Indices", 
                                    "- Load Call Failure Index", 
                                    "- Load Call Failure Index")
    if found:
        state, value, perfvar = _check_counter("LS:MediationServer - Health Indices",
                                              "- Load Call Failure Index",
                                              "- Load Call Failure Index",
                                              "mediation_load_call_failure_index",
                                              "load_call_failure_index")
        if state != None and state != "OK":
            state_overall = state
        if value != None:
            metrics["mediation_load_call_failure_index"] = value
            details_parts.append("Load call failure index: %d" % value)
    
    # Check: Failed calls because of proxy
    val, found = _get_counter_value("LS:MediationServer - Global Counters",
                                   "- Total failed calls caused by unexpected interaction from the Proxy",
                                   "- Total failed calls caused by unexpected interaction from the Proxy")
    if found:
        state, value, perfvar = _check_counter("LS:MediationServer - Global Counters",
                                              "- Total failed calls caused by unexpected interaction from the Proxy",
                                              "- Total failed calls caused by unexpected interaction from the Proxy",
                                              "mediation_failed_calls_because_of_proxy",
                                              "failed_calls_because_of_proxy")
        if state != None and state != "OK":
            state_overall = state
        if value != None:
            metrics["mediation_failed_calls_because_of_proxy"] = value
            details_parts.append("Failed calls because of proxy: %d" % value)
    
    # Check: Failed calls because of gateway
    val, found = _get_counter_value("LS:MediationServer - Global Per Gateway Counters",
                                   "- Total failed calls caused by unexpected interaction from a gateway",
                                   "- Total failed calls caused by unexpected interaction from a gateway")
    if found:
        state, value, perfvar = _check_counter("LS:MediationServer - Global Per Gateway Counters",
                                              "- Total failed calls caused by unexpected interaction from a gateway",
                                              "- Total failed calls caused by unexpected interaction from a gateway",
                                              "mediation_failed_calls_because_of_gateway",
                                              "failed_calls_because_of_gateway")
        if state != None and state != "OK":
            state_overall = state
        if value != None:
            metrics["mediation_failed_calls_because_of_gateway"] = value
            details_parts.append("Failed calls because of gateway: %d" % value)
    
    # Check: Media connectivity check failure
    val, found = _get_counter_value("LS:MediationServer - Media Relay",
                                   "- Media Connectivity Check Failure",
                                   "- Media Connectivity Check Failure")
    if found:
        state, value, perfvar = _check_counter("LS:MediationServer - Media Relay",
                                              "- Media Connectivity Check Failure",
                                              "- Media Connectivity Check Failure",
                                              "mediation_media_connectivity_failure",
                                              "media_connectivity_failure")
        if state != None and state != "OK":
            state_overall = state
        if value != None:
            metrics["mediation_media_connectivity_failure"] = value
            details_parts.append("Media connectivity check failure: %d" % value)
    
    if len(metrics) == 0:
        return {
            "changed": False,
            "msg": "no data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    return {
        "changed": False,
        "msg": ", ".join(details_parts) if len(details_parts) > 0 else "Skype Mediation Server OK",
        "data": {"state": state_overall, "metrics": metrics, "details": ""}
    }
