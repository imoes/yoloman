# ===== Starlark check module: hp_proliant_da_cntlr =====
# Translation of Checkmk check: checkmk.hp_proliant_da_cntlr
# Reads SNMP data for HP Proliant controller status (read-only)

def main(ctx, params):
    # ----- DISCOVERY MODE -------------------------------------------------
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.232.3.2.2.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        items = []
        lines = res.stdout.splitlines()
        idx_map = {}
        
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if val.startswith("INTEGER: "):
                val = val[9:]
            elif val.startswith("STRING: "):
                val = val[8:].strip('"')
            elif val.startswith("Gauge32: "):
                val = val[9:]
            
            # Extract last component
            last = oid_val.rsplit(".", 1)[-1]
            parts2 = oid_val.rsplit(".", 2)
            if len(parts2) < 3:
                continue
            
            # Guard instead of try/except
            if not parts2[-2].isdigit():
                continue
            ctrl_idx = int(parts2[-2])
            
            if ctrl_idx not in idx_map:
                idx_map[ctrl_idx] = {}
            
            if not last.isdigit():
                continue
            leaf = int(last)
            if leaf == 1:
                idx_map[ctrl_idx]["index"] = val
            elif leaf == 2:
                idx_map[ctrl_idx]["model"] = val
            elif leaf == 5:
                idx_map[ctrl_idx]["slot"] = val
            elif leaf == 6:
                idx_map[ctrl_idx]["cond"] = val
            elif leaf == 9:
                idx_map[ctrl_idx]["role"] = val
            elif leaf == 10:
                idx_map[ctrl_idx]["b_status"] = val
            elif leaf == 12:
                idx_map[ctrl_idx]["b_cond"] = val
            elif leaf == 15:
                idx_map[ctrl_idx]["serial"] = val
        
        for ctrl_idx in idx_map:
            entry = idx_map[ctrl_idx]
            if ("cond" in entry and entry["cond"] == "0") or \
               ("role" in entry and entry["role"] == "0") or \
               ("b_status" in entry and entry["b_status"] == "0") or \
               ("b_cond" in entry and entry["b_cond"] == "0"):
                continue
            
            if "model" not in entry or "slot" not in entry or "serial" not in entry:
                continue
            
            item_name = str(ctrl_idx)
            items.append({
                "item": item_name,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d controllers" % len(items),
            "data": {"discovery": items}
        }
    
    # ----- CHECK MODE -----------------------------------------------------
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.232.3.2.2.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    entry = None
    
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_val = parts[0].strip()
        val = parts[1].strip()
        if val.startswith("INTEGER: "):
            val = val[9:]
        elif val.startswith("STRING: "):
            val = val[8:].strip('"')
        elif val.startswith("Gauge32: "):
            val = val[9:]
        
        # Parse OID
        parts2 = oid_val.rsplit(".", 2)
        if len(parts2) < 3:
            continue
        
        last = parts2[-1]
        if not parts2[-2].isdigit() or not last.isdigit():
            continue
        
        ctrl_idx = int(parts2[-2])
        last = int(last)
        
        if str(ctrl_idx) != item:
            continue
        
        if entry == None:
            entry = {}
        
        if last == 1:
            entry["index"] = val
        elif last == 2:
            entry["model"] = val
        elif last == 5:
            entry["slot"] = val
        elif last == 6:
            entry["cond"] = val
        elif last == 9:
            entry["role"] = val
        elif last == 10:
            entry["b_status"] = val
        elif last == 12:
            entry["b_cond"] = val
        elif last == 15:
            entry["serial"] = val
    
    if entry == None or "model" not in entry:
        return {
            "changed": False,
            "msg": "Controller not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if ("cond" in entry and entry["cond"] == "0") or \
       ("role" in entry and entry["role"] == "0") or \
       ("b_status" in entry and entry["b_status"] == "0") or \
       ("b_cond" in entry and entry["b_cond"] == "0"):
        return {
            "changed": False,
            "msg": "Controller data invalid (zero values)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    PARSER_COND_MAP = {
        "1": "other", "2": "ok", "3": "degraded", "4": "failed"
    }
    PARSER_STATE_MAP = {
        "1": "other", "2": "ok", "3": "general_failure", "4": "cable_problem",
        "5": "powered_off", "6": "cache_module_missing", "7": "degraded",
        "8": "enabled", "9": "disabled", "10": "standby_offline",
        "11": "standby_spare", "12": "in_test", "13": "starting",
        "14": "absent", "16": "unavailable", "17": "deferring",
        "18": "quisced", "19": "updating", "20": "qualified"
    }
    
    def cond_to_state(val):
        if val == "ok":
            return "OK"
        elif val in ["other", "degraded"]:
            return "WARN"
        elif val == "failed":
            return "CRIT"
        else:
            return "WARN"
    
    def state_to_state(val):
        if val in ["ok", "enabled", "disabled", "standby_spare", "starting", "deferring", "quisced", "qualified"]:
            return "OK"
        elif val in ["other", "cache_module_missing", "standby_offline", "in_test", "updating"]:
            return "WARN"
        elif val in ["general_failure", "cable_problem", "powered_off", "degraded", "absent", "unavailable"]:
            return "CRIT"
        else:
            return "WARN"
    
    cond = PARSER_COND_MAP.get(entry.get("cond", "1"), "other")
    b_status = PARSER_STATE_MAP.get(entry.get("b_status", "1"), "other")
    b_cond = PARSER_COND_MAP.get(entry.get("b_cond", "1"), "other")
    
    role = entry.get("role", "1")
    role_str = {
        "1": "other", "2": "notDuplexed", "3": "active", "4": "backup"
    }.get(role, "other")
    
    states = {
        "Condition": cond_to_state(cond),
        "Board-Condition": cond_to_state(b_cond),
        "Board-Status": state_to_state(b_status)
    }
    
    worst = "OK"
    for s in states.values():
        if s == "CRIT":
            worst = "CRIT"
        elif s == "WARN" and worst != "CRIT":
            worst = "WARN"
    
    states_summary = []
    for label in ["Condition", "Board-Condition", "Board-Status"]:
        states_summary.append("%s: %s" % (label, states[label]))
    
    msg = ", ".join(states_summary) + " (Role: %s, Model: %s, Slot: %s, Serial: %s)" % (
        role_str, entry.get("model", ""), entry.get("slot", ""), entry.get("serial", "")
    )
    
    details = ""
    if cond == "other" or b_status == "other" or b_cond == "other" or states["Board-Status"] == "WARN":
        details = "The instrument agent does not recognize the status of the controller. You may need to upgrade the instrument agent."
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": worst,
            "metrics": {},
            "details": details
        }
    }