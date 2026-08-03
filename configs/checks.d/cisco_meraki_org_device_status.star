def main(ctx, params):
    if params.get("_discover"):
        device_data = _fetch_device_status_from_agent(ctx)
        if device_data == None:
            return {"changed": False, "msg": "no Meraki device data available", "data": {"discovery": []}}
        
        discovery = []
        discovery.append({"item": "", "params": {"status_map": _DEFAULT_STATUS_MAP, "last_reported_upper_levels": ("no_levels", None)}, "metrics": ["last_reported"]})
        
        ps_list = device_data.get("power_supplies", [])
        for ps in ps_list:
            slot = str(ps.get("slot", ""))
            discovery.append({"item": slot, "params": {"state_not_powering": 1}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    if item == "":
        return _check_device_status(ctx, params)
    else:
        return _check_power_supply(ctx, params, item)


def _check_device_status(ctx, params):
    device_data = _fetch_device_status_from_agent(ctx)
    if device_data == None:
        return {"changed": False, "msg": "no Meraki device data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = device_data.get("status", "")
    status_map = params.get("status_map", _DEFAULT_STATUS_MAP)
    state_num = status_map.get(status, 3)
    state_str = _STATE_NAMES.get(state_num, "UNKNOWN")
    
    last_reported = device_data.get("last_reported")
    metrics = {}
    details = "Status: " + status
    
    if last_reported != None and last_reported != "":
        last_ts = _parse_iso8601_to_epoch(last_reported)
        if last_ts > 0:
            now_ts = _current_epoch(ctx)
            age = now_ts - last_ts
            if age < 0:
                age = 0
            metrics["last_reported"] = age
            details = details + ", Age: " + _format_timespan(age)
    
    levels_upper = params.get("last_reported_upper_levels", ("no_levels", None))
    age_state = "OK"
    if last_reported != None and last_reported != "" and metrics.get("last_reported") != None:
        age_state = _check_levels_state(metrics["last_reported"], levels_upper)
    
    combined_state = _worst_state(state_str, age_state)
    
    return {"changed": False, "msg": details, "data": {"state": combined_state, "metrics": metrics, "details": ""}}


def _check_power_supply(ctx, params, item):
    device_data = _fetch_device_status_from_agent(ctx)
    if device_data == None:
        return {"changed": False, "msg": "no Meraki device data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    ps_list = device_data.get("power_supplies", [])
    found_ps = None
    for ps in ps_list:
        if str(ps.get("slot", "")) == item:
            found_ps = ps
            break
    
    if found_ps == None:
        return {"changed": False, "msg": "power supply slot %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    ps_status = found_ps.get("status", "").lower()
    state_not_powering = params.get("state_not_powering", 1)
    
    if ps_status == "powering":
        state_str = "OK"
    else:
        state_str = _STATE_NAMES.get(state_not_powering, "WARN")
    
    details = "Status: " + found_ps.get("status", "") + ", Model: " + found_ps.get("model", "") + ", Serial: " + found_ps.get("serial", "")
    
    return {"changed": False, "msg": "Status: " + found_ps.get("status", ""), "data": {"state": state_str, "metrics": {}, "details": details}}


_DEFAULT_STATUS_MAP = {
    "online": 0,
    "alerting": 2,
    "offline": 1,
    "dormant": 1,
}

_STATE_NAMES = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
    3: "UNKNOWN",
}

_STATE_TO_NUM = {
    "OK": 0,
    "WARN": 1,
    "CRIT": 2,
    "UNKNOWN": 3,
}

def _worst_state(a, b):
    a_num = _STATE_TO_NUM.get(a, 3)
    b_num = _STATE_TO_NUM.get(b, 3)
    worst = a_num
    if b_num > worst:
        worst = b_num
    return _STATE_NAMES.get(worst, "UNKNOWN")

def _check_levels_state(value, levels):
    if type(levels) == "list" or type(levels) == "tuple":
        if len(levels) >= 2 and levels[1] != None:
            crit_level = levels[1]
            warn_level = levels[0]
            if value >= crit_level:
                return "CRIT"
            if value >= warn_level:
                return "WARN"
            return "OK"
    return "OK"

def _current_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0 and res.stdout.strip().isdigit():
        return int(res.stdout.strip())
    return 0

def _fetch_device_status_from_agent(ctx):
    res = ctx.run(["cat", "/var/cache/cisco_meraki/cisco_meraki_org_device_status.json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    decoded = json.decode(res.stdout)
    if decoded == None:
        return None
    if type(decoded) != "list" or len(decoded) < 1:
        return None
    return decoded[0]

def _parse_iso8601_to_epoch(ts_str):
    s = ts_str
    if not s.endswith("Z"):
        return 0
    s = s[:-1]
    
    parts = s.split("T")
    if len(parts) != 2:
        return 0
    
    date_parts = parts[0].split("-")
    time_parts = parts[1].split(":")
    if len(date_parts) != 3 or len(time_parts) < 2:
        return 0
    
    year = int(date_parts[0]) if date_parts[0].isdigit() else 0
    month = int(date_parts[1]) if date_parts[1].isdigit() else 0
    day = int(date_parts[2]) if date_parts[2].isdigit() else 0
    hour = int(time_parts[0]) if time_parts[0].isdigit() else 0
    minute = int(time_parts[1]) if time_parts[1].isdigit() else 0
    second = 0
    micro = 0
    
    if len(time_parts) >= 3:
        sec_str = time_parts[2]
        if "." in sec_str:
            sec_parts = sec_str.split(".")
            second = int(sec_parts[0]) if sec_parts[0].isdigit() else 0
            micro_str = sec_parts[1]
            if micro_str.isdigit():
                micro = int(micro_str.ljust(6, "0")[:6])
        else:
            second = int(sec_str) if sec_str.isdigit() else 0
    
    return _to_epoch(year, month, day, hour, minute, second, micro)

def _to_epoch(year, month, day, hour, minute, second, micro):
    y = year - 1
    era_days = y * 365 + y // 4 - y // 100 + y // 400
    
    month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
    day_of_year = month_days[month - 1] + day
    if month > 2 and leap:
        day_of_year = day_of_year + 1
    
    total_days = era_days + day_of_year - 1
    total_seconds = total_days * 86400 + hour * 3600 + minute * 60 + second
    return total_seconds

def _format_timespan(seconds):
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    if days > 0:
        return "%d days %d h %d m" % (days, hours, minutes)
    if hours > 0:
        return "%d h %d m %d s" % (hours, minutes, secs)
    return "%d min %d s" % (minutes, secs)