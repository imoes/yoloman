def main(ctx, params):
    # Discovery mode
    if params.get("_discover") == True:
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch active alarms from first SNMP tree
        res_alarms = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.5003.11.1.1.1.1"
        ], mutates=False)
        
        # Fetch archived history sequence numbers from second SNMP tree
        res_archived = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.5003.11.1.2.1.1"
        ], mutates=False)
        
        # Count archived alarms (non-empty list = at least one entry)
        archived_count = 0
        for line in res_archived.stdout.splitlines():
            if line.strip() != "":
                archived_count = archived_count + 1
        
        # Parse active alarms - collect values per alarm record
        lines = res_alarms.stdout.splitlines()
        alarm_values = []
        current_alarm = []
        
        for line in lines:
            if line.strip() == "":
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            value = parts[1].strip()
            # Remove type prefix if present (e.g., "Gauge32:" or "INTEGER:")
            colon_index = value.find(":")
            if colon_index != -1:
                value = value[colon_index + 1:].strip()
            current_alarm.append(value)
            
            # When we have 7 values, we have one complete alarm record
            if len(current_alarm) == 7:
                alarm_values.append(current_alarm)
                current_alarm = []
        
        # Build discovered items
        discovered_items = []
        for alarm in alarm_values:
            if len(alarm) < 7:
                continue
            seq_num = alarm[0]
            sysuptime = alarm[1]
            datetime_str = alarm[2]
            name = alarm[3]
            description = alarm[4]
            source = alarm[5]
            severity = alarm[6]
            
            # Map severity to readable form
            readable_severity = {
                "0": "cleared",
                "1": "indeterminate",
                "2": "warning",
                "3": "minor",
                "4": "major",
                "5": "critical"
            }.get(severity, "unknown")
            
            # Build discovered item (single-service check)
            discovered_items.append({
                "item": "",
                "params": {
                    "severity_state_mapping": {
                        "cleared": 0,
                        "indeterminate": 3,
                        "warning": 1,
                        "minor": 1,
                        "major": 2,
                        "critical": 2
                    }
                },
                "metrics": []
            })
        
        # Return single-service discovery
        return {
            "changed": False,
            "msg": "discovered system events service",
            "data": {"discovery": discovered_items}
        }
    
    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get SNMP data
    res_alarms = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.5003.11.1.1.1.1"
    ], mutates=False)
    
    res_archived = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.5003.11.1.2.1.1"
    ], mutates=False)
    
    # Count archived alarms
    archived_count = 0
    for line in res_archived.stdout.splitlines():
        if line.strip() != "":
            archived_count = archived_count + 1
    
    # Parse active alarms
    lines = res_alarms.stdout.splitlines()
    alarm_values = []
    current_alarm = []
    
    for line in lines:
        if line.strip() == "":
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        value = parts[1].strip()
        # Remove type prefix if present (e.g., "Gauge32:" or "INTEGER:")
        colon_index = value.find(":")
        if colon_index != -1:
            value = value[colon_index + 1:].strip()
        current_alarm.append(value)
        
        if len(current_alarm) == 7:
            alarm_values.append(current_alarm)
            current_alarm = []
    
    # Process alarms
    severity_state_mapping = params.get("severity_state_mapping", {
        "cleared": 0,
        "indeterminate": 3,
        "warning": 1,
        "minor": 1,
        "major": 2,
        "critical": 2
    })
    
    number_of_critical_alarms = 0
    number_of_warning_alarms = 0
    alarm_summaries = []
    
    for alarm in alarm_values:
        if len(alarm) < 7:
            continue
        
        seq_num = alarm[0]
        sysuptime = alarm[1]
        datetime_str = alarm[2]
        name = alarm[3]
        description = alarm[4]
        source = alarm[5]
        severity = alarm[6]
        
        # Map severity to readable form
        readable_severity = {
            "0": "cleared",
            "1": "indeterminate",
            "2": "warning",
            "3": "minor",
            "4": "major",
            "5": "critical"
        }.get(severity, "unknown")
        
        # Get state from mapping
        state_value = severity_state_mapping.get(readable_severity, 3)
        
        # Convert Checkmk states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
        if state_value == 2:
            state_str = "CRIT"
            number_of_critical_alarms = number_of_critical_alarms + 1
        elif state_value == 1:
            state_str = "WARN"
            number_of_warning_alarms = number_of_warning_alarms + 1
        elif state_value == 0:
            state_str = "OK"
        else:
            state_str = "UNKNOWN"
        
        # Build alarm summary (checkmk-style notice format)
        summary = "Alarm #%s: Name: %s, Severity: %s, Sysuptime: %s, Description: %s, Source: %s" % (
            seq_num, name, readable_severity, sysuptime, 
            description, source
        )
        
        if datetime_str != "" and datetime_str != None:
            summary = summary + ", Date and Time: %s" % datetime_str
        
        alarm_summaries.append(summary)
    
    # Build return message with summary
    summary_msg = "Critical alarms: %d, Warnings: %d" % (
        number_of_critical_alarms, number_of_warning_alarms
    )
    
    return {
        "changed": False,
        "msg": summary_msg,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
            "alarms": alarm_summaries,
            "archived": archived_count
        }
    }
