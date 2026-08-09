def _pow10(exp):
    result = 1
    i = 0
    while i < exp:
        result = result * 10
        i = i + 1
    return result

def _parse_bluenet2_powerrail_inlet(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res_circuits = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.31770.2.2.6.2.1"
    ], mutates=False)
    
    if res_circuits.rc != 0:
        return None
    
    circuits = {}
    for line in res_circuits.stdout.splitlines():
        eq_pos = line.find("=")
        if eq_pos == -1:
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        oid_parts = oid.split(".")
        if len(oid_parts) < 10:
            continue
        circuit_id = oid_parts[-2] + "." + oid_parts[-1]
        circuits[circuit_id] = oid
    
    res_vars = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.31770.2.2.8"
    ], mutates=False)
    
    if res_vars.rc != 0:
        return None
    
    map_status = {
        "0": (0, "expected"),
        "1": (3, "undefined"),
        "2": (0, "OK"),
        "3": (2, "error high"),
        "4": (2, "error low"),
        "5": (1, "warning high"),
        "6": (1, "warning low"),
        "7": (2, "lost"),
        "8": (1, "deactivate"),
        "9": (2, "on alarm identidy"),
        "10": (2, "off alarm identify"),
        "11": (2, "on alarm"),
        "12": (2, "off alarm"),
        "13": (1, "on warning identify"),
        "14": (1, "off warning identify"),
        "15": (1, "on warning"),
        "16": (1, "off warning"),
        "17": (0, "on identify"),
        "18": (0, "off identify"),
        "19": (0, "on"),
        "20": (1, "off"),
        "21": (2, "on child alarm"),
        "22": (2, "off child alarm"),
        "23": (1, "on child warning"),
        "24": (1, "off child warning"),
        "25": (2, "child alarm"),
        "26": (1, "child warning"),
        "27": (2, "lost child"),
        "36": (1, "update in progress"),
        "37": (2, "update error"),
        "38": (1, "ongoing switch"),
        "39": (2, "high"),
        "40": (1, "low"),
        "41": (2, "alarm"),
        "42": (1, "warning"),
        "43": (0, "ok"),
        "44": (1, "disabled"),
        "45": (1, "fw version too new"),
    }
    
    map_phase_types = {
        "1": ("inlet", "Inlet", "voltage"),
        "4": ("inlet", "Inlet", "current"),
        "18": ("inlet", "Inlet", "appower"),
        "19": ("inlet", "Inlet", "power"),
        "23": ("inlet", "Inlet", "frequency"),
        "9": ("inlet", "Inlet", "current_neutral"),
    }
    
    entries = []
    lines = res_vars.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        eq_pos = line.find("=")
        if eq_pos == -1:
            i = i + 1
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            i = i + 1
            continue
        oid = parts[0].strip()
        value_str = parts[1].strip()
        oid_info = oid.split(".")
        
        if len(oid_info) < 12:
            i = i + 1
            continue
        if oid_info[-1] != "6":
            i = i + 1
            continue
        
        ty = value_str
        base_oid = ".".join(oid_info[:-1])
        status_oid = base_oid + ".7"
        scaling_oid = base_oid + ".9"
        value_oid = base_oid + ".4.1.5"
        status = ""
        scaling = ""
        reading = ""
        
        j = 0
        while j < len(lines):
            l = lines[j]
            if l.find(status_oid) == 0:
                status_parts = l.strip().split(" = ")
                if len(status_parts) >= 2:
                    status = status_parts[1].strip()
            elif l.find(scaling_oid) == 0:
                scaling_parts = l.strip().split(" = ")
                if len(scaling_parts) >= 2:
                    scaling = scaling_parts[1].strip()
            elif l.find(value_oid) == 0:
                value_parts = l.strip().split(" = ")
                if len(value_parts) >= 2:
                    reading = value_parts[1].strip()
                break
            j = j + 1
        
        entries.append({
            "oid": oid,
            "ty": ty,
            "status": status,
            "scaling": scaling,
            "reading": reading,
            "base_oid": base_oid,
        })
        i = i + 1
    
    parsed = {"inlet": {}}
    i = 0
    while i < len(entries):
        entry = entries[i]
        ty = entry["ty"]
        if not (ty in map_phase_types):
            i = i + 1
            continue
        
        phase_ty, phase_txt, what = map_phase_types[ty]
        
        oid_info = entry["base_oid"].split(".")
        for cid, oid_end in circuits.items():
            if entry["oid"].find(".1.3.6.1.4.1.31770.2.2.6.2.1." + cid) == 0:
                item_name = "%s %s" % (cid, phase_txt)
                
                if item_name not in parsed["inlet"]:
                    parsed["inlet"][item_name] = {
                        "id": phase_txt,
                        "name": item_name,
                    }
                
                val = 0.0
                if entry["reading"] != "" and entry["scaling"] != "":
                    r = entry["reading"]
                    s = entry["scaling"]
                    is_r_int = r.isdigit() or (r.find("-") == 0 and r[1:].isdigit())
                    is_s_int = s.isdigit() or (s.find("-") == 0 and s[1:].isdigit())
                    if is_r_int and is_s_int:
                        val = float(r) * _pow10(int(s))
                
                status_info = map_status.get(entry["status"], (3, "undefined"))
                
                if what == "voltage":
                    parsed["inlet"][item_name]["voltage"] = (val, status_info)
                elif what == "current":
                    parsed["inlet"][item_name]["current"] = (val, status_info)
                elif what == "current_neutral":
                    parsed["inlet"][item_name]["current_neutral"] = (val, status_info)
                elif what == "appower":
                    parsed["inlet"][item_name]["appower"] = (val, status_info)
                elif what == "power":
                    parsed["inlet"][item_name]["power"] = (val, status_info)
                elif what == "frequency":
                    parsed["inlet"][item_name]["frequency"] = (val, status_info)
        i = i + 1
    
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        parsed = _parse_bluenet2_powerrail_inlet(ctx, params)
        if parsed == None:
            return {
                "changed": False,
                "msg": "discovered 0 inlets (SNMP probe failed)",
                "data": {"discovery": []},
            }
        
        items = []
        for item in parsed.get("inlet", {}):
            items.append({
                "item": item,
                "params": {},
                "metrics": ["voltage", "current", "current_neutral", "appower", "power", "frequency"],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d inlets" % len(items),
            "data": {"discovery": items},
        }
    
    item = params.get("item", "")
    
    parsed = _parse_bluenet2_powerrail_inlet(ctx, params)
    if parsed == None:
        return {
            "changed": False,
            "msg": "SNMP probe failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if item not in parsed.get("inlet", {}):
        return {
            "changed": False,
            "msg": "inlet not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    inlet = parsed["inlet"][item]
    state = 0
    details_parts = []
    metrics = {}
    
    for metric_name, metric_key in [
        ("Voltage", "voltage"),
        ("Current", "current"),
        ("Current Neutral", "current_neutral"),
        ("Apparent Power", "appower"),
        ("Power", "power"),
        ("Frequency", "frequency"),
    ]:
        if metric_key in inlet:
            val, (status, status_txt) = inlet[metric_key]
            metrics[metric_key] = val
            if status > state:
                state = status
            details_parts.append("%s: %s" % (metric_name, str(val)))
    
    if state == 0:
        state_str = "OK"
    elif state == 1:
        state_str = "WARN"
    elif state == 2:
        state_str = "CRIT"
    else:
        state_str = "UNKNOWN"
    
    msg = item + " - " + ", ".join(details_parts) + " (Status: " + state_str + ")"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state_str, "metrics": metrics, "details": ""},
    }