def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk-agent/agent_rc/cisco_meraki_org_licenses_overview"], mutates=False)
        if res.rc != 0 or res.stdout == None or res.stdout.strip() == "":
            return {"changed": False, "msg": "no data available", "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout.strip() != "" else None
        if data == None or type(data) != "list" or len(data) == 0:
            return {"changed": False, "msg": "invalid data format", "data": {"discovery": []}}
        out = []
        for item in data:
            if type(item) != "dict":
                continue
            org_name = item.get("organisation_name", "")
            org_id = item.get("organisation_id", "")
            identifier = org_name + "/" + org_id
            if identifier == "":
                continue
            out.append({"item": identifier, "params": {}, "metrics": ["remaining_time", "license_total"]})
        return {"changed": False, "msg": "discovered %d organizations" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/cmk-agent/agent_rc/cisco_meraki_org_licenses_overview"], mutates=False)
    if res.rc != 0 or res.stdout == None or res.stdout.strip() == "":
        return {"changed": False, "msg": "no data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout) if res.stdout.strip() != "" else None
    if data == None or type(data) != "list":
        return {"changed": False, "msg": "invalid data format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    overview = None
    for item_data in data:
        if type(item_data) != "dict":
            continue
        org_name = item_data.get("organisation_name", "")
        org_id = item_data.get("organisation_id", "")
        if org_name + "/" + org_id == item:
            overview = item_data
            break
    if overview == None:
        return {"changed": False, "msg": "organization not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    org_id = overview.get("organisation_id", "")
    org_name = overview.get("organisation_name", "")
    status = overview.get("status", "UNKNOWN")
    raw_exp = overview.get("expirationDate", None)
    licensed_counts = overview.get("licensedDeviceCounts", {})
    
    state_license_not_ok = params.get("state_license_not_ok", 1)
    status_state = "OK" if status == "OK" else ("WARN" if state_license_not_ok == 1 else "CRIT")
    
    exp_ts = None
    if raw_exp != None:
        exp_str = str(raw_exp)
        if exp_str.endswith(" UTC"):
            exp_str = exp_str[:-4]
        parts = exp_str.split()
        if len(parts) >= 3:
            month_str = parts[0]
            day_str = parts[1].rstrip(",")
            year_str = parts[2]
            if day_str.isdigit() and year_str.isdigit():
                month_map = {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                             "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}
                month = month_map.get(month_str, 1)
                day = int(day_str)
                year = int(year_str)
                days = (year - 1970) * 365 + (year - 1969) // 4
                days_in_month = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
                days += days_in_month[month - 1] + day - 1
                if month > 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
                    days += 1
                exp_ts = days * 86400
    
    msg_parts = ["Status: " + str(status)]
    metrics = {}
    
    remaining_time = None
    if exp_ts != None:
        date_res = ctx.run(["date", "+%s"], mutates=False)
        if date_res.rc == 0 and date_res.stdout != None and date_res.stdout.strip() != "":
            now_str = date_res.stdout.strip()
            if now_str.isdigit():
                now = int(now_str)
                remaining_time = exp_ts - now
    
    state = status_state
    
    if remaining_time != None:
        if remaining_time < 0:
            state = "CRIT"
            msg_parts.append("Expired " + str(abs(remaining_time)) + "s ago")
        else:
            levels = params.get("remaining_expiration_time", ("no_levels", None))
            if type(levels) == "list" and len(levels) >= 2:
                mode = levels[0] if len(levels) > 0 else "no_levels"
                if mode == "fixed" or mode == "perc":
                    warn_val = None
                    crit_val = None
                    if type(levels[1]) == "list" and len(levels[1]) >= 1:
                        warn_val = levels[1][0]
                    if type(levels[1]) == "list" and len(levels[1]) >= 2:
                        crit_val = levels[1][1]
                    if warn_val != None and remaining_time <= warn_val:
                        state = "WARN"
                    if crit_val != None and remaining_time <= crit_val:
                        state = "CRIT"
            msg_parts.append("Remaining: " + str(remaining_time) + "s")
            metrics["remaining_time"] = remaining_time
    
    if type(licensed_counts) == "dict":
        total = 0
        for key, val in licensed_counts.items():
            if type(val) == "int":
                total += val
        if total > 0:
            metrics["license_total"] = total
    
    details = []
    if org_id != None and str(org_id).strip() != "":
        details.append("Organization ID: " + str(org_id))
    if org_name != None and str(org_name).strip() != "":
        details.append("Organization name: " + str(org_name))
    
    msg = "; ".join(msg_parts)
    if len(details) > 0:
        msg += " | " + "; ".join(details)
    
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details)}}