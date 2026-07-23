def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.795.14.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        lines = res.stdout.splitlines()
        slot_ids = []
        disk_ids = []
        disk_types = []
        disk_states = []
        slot_descs = []
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_path = parts[0].strip()
            value = parts[1].strip()
            if value.startswith("STRING: "):
                value = value[8:].strip('"')
            elif value.startswith("INTEGER: "):
                value = value[9:].strip()
            
            suffix = oid_path.split(".")[-1]
            if suffix == "503.1.1.4":
                slot_ids.append(value)
            elif suffix == "400.1.1.1":
                disk_ids.append(value)
            elif suffix == "400.1.1.5":
                disk_types.append(value)
            elif suffix == "400.1.1.11":
                disk_states.append(value)
            elif suffix == "400.1.1.12":
                slot_descs.append(value)
        
        data = {}
        n = min(len(slot_ids), len(disk_ids), len(disk_types), len(disk_states), len(slot_descs))
        for i in range(n):
            slot_desc = slot_descs[i] if i < len(slot_descs) else ""
            
            if slot_desc and "slot" in slot_desc.lower():
                parts_desc = slot_desc.split(", ")
                if len(parts_desc) >= 3:
                    last_part = parts_desc[-1]
                    enc_part = parts_desc[-2]
                    hba_part = parts_desc[-3]
                    if last_part and enc_part and hba_part:
                        last_digit = last_part[-1]
                        enc_digit = enc_part[-1]
                        hba_digit = hba_part[-1]
                        if last_digit.isdigit() and enc_digit.isdigit() and hba_digit.isdigit():
                            slot_id_int = int(last_digit)
                            enc_id = int(enc_digit)
                            hba_id = int(hba_digit)
                            disk_path = str(hba_id) + "/" + str(enc_id) + "/" + str(slot_id_int)
                            data[disk_path] = (
                                slot_id_int,
                                disk_ids[i] if i < len(disk_ids) else "",
                                disk_types[i] if i < len(disk_types) else "",
                                disk_states[i] if i < len(disk_states) else "",
                                slot_desc
                            )
        
        discovery_list = []
        for disk_path, disk_entry in data.items():
            _slot_label, _disk_id, _disk_type, _disk_state, _slot_desc = disk_entry
            discovery_list.append({
                "item": disk_path,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d pdisks" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.795.14.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    slot_ids = []
    disk_ids = []
    disk_types = []
    disk_states = []
    slot_descs = []
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_path = parts[0].strip()
        value = parts[1].strip()
        if value.startswith("STRING: "):
            value = value[8:].strip('"')
        elif value.startswith("INTEGER: "):
            value = value[9:].strip()
        
        suffix = oid_path.split(".")[-1]
        if suffix == "503.1.1.4":
            slot_ids.append(value)
        elif suffix == "400.1.1.1":
            disk_ids.append(value)
        elif suffix == "400.1.1.5":
            disk_types.append(value)
        elif suffix == "400.1.1.11":
            disk_states.append(value)
        elif suffix == "400.1.1.12":
            slot_descs.append(value)
    
    n = min(len(slot_ids), len(disk_ids), len(disk_types), len(disk_states), len(slot_descs))
    data = {}
    for i in range(n):
        slot_desc = slot_descs[i] if i < len(slot_descs) else ""
        
        if slot_desc and "slot" in slot_desc.lower():
            parts_desc = slot_desc.split(", ")
            if len(parts_desc) >= 3:
                last_part = parts_desc[-1]
                enc_part = parts_desc[-2]
                hba_part = parts_desc[-3]
                if last_part and enc_part and hba_part:
                    last_digit = last_part[-1]
                    enc_digit = enc_part[-1]
                    hba_digit = hba_part[-1]
                    if last_digit.isdigit() and enc_digit.isdigit() and hba_digit.isdigit():
                        slot_id_int = int(last_digit)
                        enc_id = int(enc_digit)
                        hba_id = int(hba_digit)
                        disk_path = str(hba_id) + "/" + str(enc_id) + "/" + str(slot_id_int)
                        data[disk_path] = (
                            slot_id_int,
                            disk_ids[i] if i < len(disk_ids) else "",
                            disk_types[i] if i < len(disk_types) else "",
                            disk_states[i] if i < len(disk_states) else "",
                            slot_desc
                        )
    
    for disk_path, disk_entry in data.items():
        if disk_path == item:
            _slot_label, _disk_id, _disk_type, disk_state, slot_desc = disk_entry
            if disk_state == "3":
                return {
                    "changed": False,
                    "msg": "Disk is active [%s]" % slot_desc,
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
            if disk_state == "4":
                return {
                    "changed": False,
                    "msg": "Disk is rebuilding [%s]" % slot_desc,
                    "data": {"state": "WARN", "metrics": {}, "details": ""}
                }
            if disk_state == "5":
                return {
                    "changed": False,
                    "msg": "Disk is dead [%s]" % slot_desc,
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}
                }
    
    return {
        "changed": False,
        "msg": "disk is missing",
        "data": {"state": "CRIT", "metrics": {}, "details": ""}
    }