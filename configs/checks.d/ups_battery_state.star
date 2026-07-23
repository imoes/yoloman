# Helper to parse "1"/"2" as True/False/None
def _parse_yes_or_no(value):
    v = value.strip() if value else ""
    if v == "1":
        return True
    elif v == "2":
        return False
    return None

# Helper to parse optional integer
def _optional_int(value):
    v = value.strip() if value else ""
    if v == "":
        return None
    if v.lstrip("-").isdigit():
        return int(v)
    return None

def _format_seconds(s):
    if s == None:
        return ""
    h = s // 3600
    m = (s % 3600) // 60
    sec = s % 60
    parts = []
    if h:
        parts.append("%d h" % h)
    if m:
        parts.append("%d m" % m)
    if sec or not parts:
        parts.append("%d s" % sec)
    return " ".join(parts)

def _assemble_battery(section_battery_warnings, section_on_battery, section_seconds_on_battery):
    merged = {
        "seconds_on_bat": None,
        "seconds_left": None,
        "percent_charged": None,
        "on_battery": None,
        "fault": None,
        "replace": None,
        "low": None,
        "not_charging": None,
        "low_condition": None,
        "on_bypass": None,
        "backup": None,
        "overload": None,
    }

    def update(src):
        if src == None:
            return
        for k in merged:
            if src.get(k) != None:
                merged[k] = src[k]

    update(section_battery_warnings)
    update(section_on_battery)
    update(section_seconds_on_battery)
    return merged

def _is_on_battery(battery):
    if battery.get("on_battery") != None:
        return battery["on_battery"]
    if battery.get("seconds_left") != None and battery.get("seconds_on_bat") != None:
        return bool(battery["seconds_on_bat"])
    return False

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            }
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res_sysobj = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res_sysobj.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: could not read sysObjectID",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    sysobj = ""
    lines_sysobj = res_sysobj.stdout.strip().split("\n")
    for line_sysobj in lines_sysobj:
        if line_sysobj.strip():
            parts = line_sysobj.strip().split(" = ")
            if len(parts) >= 2:
                sysobj = parts[-1].strip()
                break

    oid_map = {
        ".1.3.6.1.4.1.232": ".1.3.6.1.4.1.232.6.2.6.1",
        ".1.3.6.1.4.1.534": ".1.3.6.1.4.1.534.1.5.1",
        ".1.3.6.1.4.1.476": ".1.3.6.1.4.1.476.1.42.1.1.3.1",
        ".1.3.6.1.4.1.935": ".1.3.6.1.4.1.935.1.1.1.1.4.1",
    }
    target_oid = ""
    for prefix, oid in oid_map.items():
        if sysobj.startswith(prefix):
            target_oid = oid
            break

    if not target_oid:
        res_generic = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.33.1.2"], mutates=False)
        if res_generic.rc == 0 and res_generic.stdout.strip():
            target_oid = ".1.3.6.1.2.1.33.1.2.1"

    if not target_oid:
        return {
            "changed": False,
            "msg": "unknown UPS vendor or SNMP OIDs unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, target_oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed for " + target_oid,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    section_battery = {}
    section_on_battery = {}
    section_seconds = {}

    lines = res.stdout.strip().split("\n")
    for line in lines:
        if not line.strip():
            continue
        if " = " not in line:
            continue
        oid_part, value_part = line.strip().split(" = ", 1)
        value = value_part.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]

        oid_tokens = oid_part.split(".")
        if not oid_tokens:
            continue
        oid_leaf = oid_tokens[-1]
        leaf_lower = oid_leaf.lower()

        if "condition" in leaf_lower or "lowcondition" in leaf_lower:
            section_battery["low_condition"] = _parse_yes_or_no(value)
        elif "replace" in leaf_lower:
            section_battery["replace"] = _parse_yes_or_no(value)
        elif "notcharging" in leaf_lower:
            section_battery["not_charging"] = _parse_yes_or_no(value)
        elif "onbypass" in leaf_lower:
            section_battery["on_bypass"] = _parse_yes_or_no(value)
        elif "backup" in leaf_lower:
            section_battery["backup"] = _parse_yes_or_no(value)
        elif "overload" in leaf_lower:
            section_battery["overload"] = _parse_yes_or_no(value)
        elif "onbattery" in leaf_lower or "onbattery" in value.lower():
            section_on_battery["on_battery"] = _parse_yes_or_no(value)
        elif "timeonbattery" in leaf_lower or "timeonbattery" in value.lower():
            val = _optional_int(value)
            if val != None:
                section_seconds["seconds_on_bat"] = val
        elif "timeleft" in leaf_lower or "timetolow" in leaf_lower or "runtimeleft" in leaf_lower:
            val = _optional_int(value)
            if val != None:
                section_on_battery["seconds_left"] = val
        elif "charge" in leaf_lower and "capacity" in leaf_lower:
            val = _optional_int(value)
            if val != None:
                section_battery["percent_charged"] = val

    if not section_battery and not section_on_battery and not section_seconds:
        for line in lines:
            if not line.strip():
                continue
            if " = " not in line:
                continue
            oid_part, value_part = line.strip().split(" = ", 1)
            value = value_part.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]

            last_part = oid_part.split(".")[-1]
            last_num = -1
            if last_part.isdigit():
                last_num = int(last_part)

            if target_oid.startswith(".1.3.6.1.4.1.232") and last_num == 3:
                if value == "4" or value == "5":
                    section_battery["low_condition"] = True
                else:
                    section_battery["low_condition"] = False
            elif target_oid.startswith(".1.3.6.1.4.1.232") and last_num == 4:
                if value == "4" or value == "5":
                    section_battery["fault"] = True
                    section_battery["low"] = True
                else:
                    section_battery["fault"] = False
                    section_battery["low"] = False
            elif target_oid.startswith(".1.3.6.1.4.1.534") and last_num == 2:
                if value == "4":
                    section_battery["fault"] = True
                if value == "5":
                    section_battery["low"] = True

    battery = _assemble_battery(section_battery, section_on_battery, section_seconds)
    battery["on_battery"] = _is_on_battery(battery)

    state = "OK"
    msg_parts = []

    if not any(battery.values()):
        msg_parts.append("No battery warnings reported")
    else:
        if battery.get("fault") == True:
            state = "CRIT"
            msg_parts.append("Battery fault")
        elif battery.get("replace") == True:
            state = "CRIT"
            msg_parts.append("Battery to be replaced")
        elif battery.get("low") == True or battery.get("low_condition") == True:
            state = "WARN"
            msg_parts.append("Low Battery")
        elif battery.get("not_charging") == True:
            state = "WARN"
            msg_parts.append("Battery is not charging")
        elif battery.get("on_bypass") == True:
            state = "WARN"
            msg_parts.append("UPS is on bypass")
        elif battery.get("backup") == True:
            state = "WARN"
            msg_parts.append("UPS is on battery backup time")
        elif battery.get("overload") == True:
            state = "CRIT"
            msg_parts.append("Overload")
        elif battery.get("on_battery") == True:
            state = "WARN"
            msg_parts.append("UPS is on battery")

        if battery.get("seconds_on_bat") != None and battery["seconds_on_bat"] > 0:
            msg_parts.append("Time running on battery: " + _format_seconds(battery["seconds_on_bat"]))

    summary = ", ".join(msg_parts) if msg_parts else "No battery warnings reported"

    metrics = {}
    if battery.get("seconds_left") != None:
        metrics["battery_seconds_remaining"] = battery["seconds_left"]
    if battery.get("percent_charged") != None:
        metrics["battery_capacity"] = battery["percent_charged"]

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }