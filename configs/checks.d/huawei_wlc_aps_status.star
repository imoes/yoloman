# ===== module: huawei_wlc_aps_status.star =====
# Translated from Checkmk plugin: checkmk.huawei_wlc_aps_status
# Read-only Starlark check (discovery + check); no mutations.

def _map_radio_state(value):
    # 1 -> up/OK, 2 -> down/CRIT
    if value == "1":
        return {"state": "OK", "label": "up"}
    elif value == "2":
        return {"state": "CRIT", "label": "down"}
    else:
        return {"state": "UNKNOWN", "label": "not available"}

def _map_ap_state(value):
    # All AP states mapped per Checkmk source
    if value == "1":  return {"state": "CRIT", "label": "Idle"}
    elif value == "2": return {"state": "WARN", "label": "Auto find"}
    elif value == "3": return {"state": "CRIT", "label": "Type not match"}
    elif value == "4": return {"state": "CRIT", "label": "Fault"}
    elif value == "5": return {"state": "CRIT", "label": "Config"}
    elif value == "6": return {"state": "CRIT", "label": "Config failed"}
    elif value == "7": return {"state": "WARN", "label": "Download"}
    elif value == "8": return {"state": "OK", "label": "Normal"}
    elif value == "9": return {"state": "CRIT", "label": "Committing"}
    elif value == "10": return {"state": "CRIT", "label": "Commit failed"}
    elif value == "11": return {"state": "WARN", "label": "Standy"}
    elif value == "12": return {"state": "CRIT", "label": "Version mismatch"}
    elif value == "13": return {"state": "CRIT", "label": "Name conflicted"}
    elif value == "14": return {"state": "CRIT", "label": "Invalid"}
    elif value == "15": return {"state": "CRIT", "label": "Country code mismatch"}
    else: return {"state": "UNKNOWN", "label": "not available"}

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid_aps_info1 = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
    base_oid_aps_info2 = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
    
    # OID list per section
    # Section 1: status(6), mem(40), cpu(41), temp(43), con_users(44)
    # Section 2: ap_id(3), radio_state_2GHz(6), ch_usage_2GHz(25), users_online_2GHz(40)
    #            then ap_id(3), radio_state_5GHz(6), ch_usage_5GHz(25), users_online_5GHz(40)
    oid_list_1 = ["6", "40", "41", "43", "44"]
    oid_list_2 = ["3", "6", "25", "40"]
    
    # Build full OIDs
    oids1 = [base_oid_aps_info1 + "." + oid for oid in oid_list_1]
    oids2 = [base_oid_aps_info2 + "." + oid for oid in oid_list_2]
    
    # Fetch section 1
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + oids1, mutates=False)
    if res1.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res1.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch section 2
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + oids2, mutates=False)
    if res2.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res2.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse section 1: AP-level info (index order)
    # Each line: <OID> = <TYPE>: <value>
    lines1 = res1.stdout.splitlines()
    section1 = {}
    for line in lines1:
        if not line.strip():
            continue
        if line.find(" = ") == -1:
            continue
        oid_part, val_part = line.strip().split(" = ", 1)
        if val_part.find(": ") == -1:
            continue
        value = val_part.split(": ", 1)[1].strip().strip('"')
        # Extract index from OID
        base_len = len(base_oid_aps_info1)
        if len(oid_part) <= base_len:
            continue
        suffix = oid_part[base_len+1:]
        # OIDs: 6,40,41,43,44
        # suffix pattern: index.oid_index, e.g. "1.6"
        if suffix.find(".") == -1:
            continue
        ap_idx_str, oid_idx_str = suffix.split(".", 1)
        # ap_idx_str is the AP index (integer)
        if not ap_idx_str.isdigit():
            continue
        ap_idx = int(ap_idx_str)
        # Only keep first occurrence per AP index (we process 5 OIDs per AP)
        if ap_idx not in section1:
            section1[ap_idx] = {"status": None, "mem": None, "cpu": None, "temp": None, "con_users": None}
        # Map oid index to field
        if oid_idx_str == "6":    section1[ap_idx]["status"] = value
        elif oid_idx_str == "40": section1[ap_idx]["mem"] = value
        elif oid_idx_str == "41": section1[ap_idx]["cpu"] = value
        elif oid_idx_str == "43": section1[ap_idx]["temp"] = value
        elif oid_idx_str == "44": section1[ap_idx]["con_users"] = value
    
    # Parse section 2: AP and radio info (2 rows per AP: 2.4GHz then 5GHz)
    lines2 = res2.stdout.splitlines()
    section2 = {}
    for line in lines2:
        if not line.strip():
            continue
        if line.find(" = ") == -1:
            continue
        oid_part, val_part = line.strip().split(" = ", 1)
        if val_part.find(": ") == -1:
            continue
        value = val_part.split(": ", 1)[1].strip().strip('"')
        # Extract index from OID
        base_len = len(base_oid_aps_info2)
        if len(oid_part) <= base_len:
            continue
        suffix = oid_part[base_len+1:]
        # suffix: ap_idx.radio_oid_idx
        # Example: "1.3", "1.6", "1.25", "1.40", then "2.3", ...
        if suffix.find(".") == -1:
            continue
        ap_idx_str, radio_oid_idx_str = suffix.split(".", 1)
        if not ap_idx_str.isdigit():
            continue
        ap_idx = int(ap_idx_str)
        if not ap_idx in section2:
            section2[ap_idx] = []
        section2[ap_idx].append({"radio_oid_idx": radio_oid_idx_str, "value": value})
    
    # Build merged AP info: per AP index, extract AP id from radio_oid_idx==3, and 2.4/5GHz info
    aps = {}
    for ap_idx in section1:
        if ap_idx not in section2:
            continue
        # Get AP id from section2: radio_oid_idx==3
        ap_id = ""
        for item in section2[ap_idx]:
            if item["radio_oid_idx"] == "3":
                ap_id = item["value"]
                break
        if not ap_id:
            continue
        
        # Get 2.4GHz and 5GHz rows from section2[ap_idx]
        # Actually: row order is [3,6,25,40], repeated per AP
        # So indices: 0:3 (ap_id), 1:6 (radio_state_2GHz), 2:25 (ch_usage_2GHz), 3:40 (users_online_2GHz)
        # Next 4: ap_id, radio_state_5GHz, ch_usage_5GHz, users_online_5GHz
        rows = section2[ap_idx]
        if len(rows) < 8:
            continue
        
        # Extract per-band info
        # 2.4GHz row
        radio_state_2GHz = ""
        ch_usage_2GHz = ""
        users_online_2GHz = ""
        for row in rows:
            if row["radio_oid_idx"] == "6":       radio_state_2GHz = row["value"]
            elif row["radio_oid_idx"] == "25":    ch_usage_2GHz = row["value"]
            elif row["radio_oid_idx"] == "40":    users_online_2GHz = row["value"]
        
        # 5GHz row: skip next ap_id row (index 4)
        radio_state_5GHz = ""
        ch_usage_5GHz = ""
        users_online_5GHz = ""
        # Next 4 rows after first ap_id (row0) are [6,25,40], then next ap_id (row4), then [6,25,40]
        # So rows 4-7 correspond to 5GHz
        for i in range(4, 8):
            if i >= len(rows):
                continue
            if rows[i]["radio_oid_idx"] == "6":       radio_state_5GHz = rows[i]["value"]
            elif rows[i]["radio_oid_idx"] == "25":    ch_usage_5GHz = rows[i]["value"]
            elif rows[i]["radio_oid_idx"] == "40":    users_online_5GHz = rows[i]["value"]
        
        # Build AP entry
        ap_data = section1[ap_idx]
        temp_val = ap_data["temp"]
        if temp_val == "255":
            temp_val = "invalid"
        else:
            # Guard instead of try/except
            if temp_val.isdigit() or (temp_val.startswith("-") and temp_val[1:].isdigit()):
                temp_val = float(temp_val)
            else:
                temp_val = "invalid"
        
        aps[ap_id] = {
            "cmk_status": _map_ap_state(ap_data["status"])["state"],
            "state_readable": _map_ap_state(ap_data["status"])["label"],
            "mem_used_percent": float(ap_data["mem"]) if ap_data["mem"] != None and ap_data["mem"].isdigit() else 0.0,
            "cpu_percent": float(ap_data["cpu"]) if ap_data["cpu"] != None and ap_data["cpu"].isdigit() else 0.0,
            "temp": temp_val,
            "con_users": ap_data["con_users"],
            "24ghz": {
                "radio_cmk_state": _map_radio_state(radio_state_2GHz)["state"],
                "radio_readable_state": _map_radio_state(radio_state_2GHz)["label"],
                "ch_usage": float(ch_usage_2GHz) if ch_usage_2GHz.isdigit() else 0.0,
                "users_online": int(users_online_2GHz) if users_online_2GHz.isdigit() else 0,
            },
            "5ghz": {
                "radio_cmk_state": _map_radio_state(radio_state_5GHz)["state"],
                "radio_readable_state": _map_radio_state(radio_state_5GHz)["label"],
                "ch_usage": float(ch_usage_5GHz) if ch_usage_5GHz.isdigit() else 0.0,
                "users_online": int(users_online_5GHz) if users_online_5GHz.isdigit() else 0,
            },
        }
    
    # ========== DISCOVERY MODE ==========
    if params.get("_discover"):
        items = []
        for item_name in aps:
            items.append({"item": item_name,
                          "params": {"levels": [80.0, 90.0]},
                          "metrics": ["24ghz_clients", "5ghz_clients", "channel_utilization_24ghz", "channel_utilization_5ghz"]})
        return {"changed": False, "msg": "discovered %d APs" % len(items),
                "data": {"discovery": items}}
    
    # ========== CHECK MODE ==========
    item = params.get("item", "")
    data = aps.get(item)
    if data == None:
        return {"changed": False, "msg": "AP not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Core status
    state = data["cmk_status"]
    msg = data["state_readable"]
    
    # Connected users
    con_users = data["con_users"]
    if con_users:
        msg += ", Connected users: " + con_users
    
    # Build metrics and per-band info
    metrics = {}
    band_info = []
    
    for radio, metric_name, band_label in [
        (data["24ghz"], "24ghz", "2.4GHz"),
        (data["5ghz"], "5ghz", "5GHz"),
    ]:
        users = radio["users_online"]
        metrics[metric_name + "_clients"] = users
        band_info.append("Users online [%s]: %d" % (band_label, users))
        
        radio_state = radio["radio_readable_state"]
        msg += ", Radio state [%s]: %s" % (band_label, radio_state)
        
        ch_usage = radio["ch_usage"]
        metrics["channel_utilization_" + metric_name] = ch_usage
        band_info.append("Channel usage [%s]: %d%%" % (band_label, ch_usage))
    
    # Thresholds for channel usage (upper levels)
    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0]
    crit = levels[1]
    
    # Determine worst state across bands
    worst_state = state
    for radio in [data["24ghz"], data["5ghz"]]:
        ch = radio["ch_usage"]
        if ch >= crit:
            worst_state = "CRIT"
        elif ch >= warn and worst_state != "CRIT":
            worst_state = "WARN"
    
    return {"changed": False, "msg": msg,
            "data": {"state": worst_state, "metrics": metrics, "details": "; ".join(band_info)}}
