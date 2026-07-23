# Discovery and check for Checkmk oracle_locks plugin
# <<<oracle_locks>>> format:
# TUX12C|273|2985|ora12c.local|sqlplus@ora12c.local (TNS V1-V3)|46148|oracle|633|NULL|NULL
# newdb|25|15231|ol6131|sqlplus@ol6131 (TNS V1-V3)|13275|oracle|SYS|3782|VALID|1|407|1463|ol6131|sqlplus@ol6131 (TNS V1-V3)|13018|oracle|SYS

DEFAULT_LEVELS = (1800, 3600)

def _parse_time_offset(seconds):
    """Return Checkmk-style time offset string (e.g. '30m', '2h 15m')"""
    if seconds < 60:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%dm" % minutes
    hours = minutes // 60
    mins = minutes % 60
    if mins == 0:
        return "%dh" % hours
    return "%dh %dm" % (hours, mins)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_locks"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            # Agent not available -> no items
            return {"changed": False, "msg": "no oracle_locks data available",
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            fields = line.split("|")
            if len(fields) >= 10:
                sid = fields[0]
                items.append({"item": sid, "params": {"levels": DEFAULT_LEVELS},
                              "metrics": []})
        return {"changed": False, "msg": "discovered %d oracle_locks items" % len(items),
                "data": {"discovery": items}}
    
    # CHECK MODE
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    warn, crit = levels[0], levels[1]
    
    res = ctx.run(["cat", "/proc/oracle_locks"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "no oracle_locks data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK"
    infotext = ""
    lockcount = 0
    found_item = False
    
    for line in res.stdout.splitlines():
        fields = line.split("|")
        if len(fields) < 10:
            continue
        if fields[0] != item:
            continue
        
        found_item = True
        
        # Skip lines with empty sidnr (line[1])
        if fields[1] == "":
            state = state if state != "UNKNOWN" else "OK"
            continue
        
        # Process valid lock line
        if len(fields) == 10:
            # old format
            sidnr = fields[1]
            serial = fields[2]
            machine = fields[3]
            process = fields[5]
            osuser = fields[6]
            raw_ctime = fields[8]
            object_owner = fields[9]
            object_name = ""
        elif len(fields) == 18:
            # new format
            sidnr = fields[1]
            serial = fields[2]
            machine = fields[3]
            process = fields[5]
            osuser = fields[6]
            raw_ctime = fields[8]
            object_owner = ""
            object_name = ""
        else:
            # Unexpected field count -> UNKNOWN
            return {"changed": False, "msg": "unexpected agent output format",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Guard: verify raw_ctime is integer before converting
        ctime = int(raw_ctime) if raw_ctime.isdigit() else -1
        if ctime < 0:
            # ctime not integer -> skip
            continue
        
        if crit == 0 and warn == 0:
            # No levels configured
            infotext += "locktime %s Session (sid,serial, proc) %s,%s,%s machine %s osuser %s object: %s.%s ; " % (
                _parse_time_offset(ctime), sidnr, serial, process, machine, osuser, object_owner, object_name
            )
        elif ctime >= crit:
            state = "CRIT"
            lockcount += 1
            infotext += "locktime %s (!!) Session (sid,serial, proc) %s,%s,%s machine %s osuser %s object: %s.%s ; " % (
                _parse_time_offset(ctime), sidnr, serial, process, machine, osuser, object_owner, object_name
            )
        elif ctime >= warn:
            if state == "OK":
                state = "WARN"
            lockcount += 1
            infotext += "locktime %s (!) Session (sid,serial, proc) %s,%s,%s machine %s osuser %s object: %s.%s ; " % (
                _parse_time_offset(ctime), sidnr, serial, process, machine, osuser, object_owner, object_name
            )
    
    if infotext == "":
        infotext = "No locks existing"
    elif lockcount > 10:
        infotext = "more then 10 locks existing!"
    
    if not found_item:
        return {"changed": False, "msg": "no oracle_locks item found for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {"lockcount": lockcount}, "details": ""}}
