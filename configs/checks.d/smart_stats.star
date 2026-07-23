def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["smartctl", "--scan-open"], mutates=False)
        disks = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                disk_path = parts[0]
                disks.append({
                    "item": disk_path,
                    "params": {},
                    "metrics": [
                        "Reallocated_Sectors",
                        "Power_On_Hours",
                        "Spin_Retries",
                        "Power_Cycles",
                        "End_to_End_Errors",
                        "Uncorrectable_Errors",
                        "Command_Timeout_Counter",
                        "Reallocated_Events",
                        "Pending_Sectors",
                        "UDMA_CRC_Errors",
                        "CRC_Errors",
                        "Critical_Warning",
                        "Media_and_Data_Integrity_Errors",
                        "Available_Spare",
                        "Percentage_Used",
                        "Error_Information_Log_Entries",
                        "Data_Units_Read",
                        "Data_Units_Written"
                    ]
                })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(disks),
            "data": {"discovery": disks}
        }

    item = params.get("item", "")
    res = ctx.run(["smartctl", "-A", item], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "smartctl failed for %s: %s" % (item, res.stderr.strip()),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    section = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 13:
            continue
        if parts[0] == "ID#":
            continue
        disk_path = parts[0]
        if disk_path != item:
            continue
        if len(parts) < 11:
            continue
        ID = parts[1]
        attribute_name = parts[2]
        raw_value = parts[10]
        
        if attribute_name == "Unknown_Attribute":
            continue

        if ID == "199":
            if attribute_name == "UDMA_CRC_Error_Count":
                key = "UDMA_CRC_Errors"
            else:
                key = "CRC_Errors"
        else:
            key = ID
            if ID == "5":
                key = "Reallocated_Sectors"
            elif ID == "9":
                key = "Power_On_Hours"
            elif ID == "10":
                key = "Spin_Retries"
            elif ID == "12":
                key = "Power_Cycles"
            elif ID == "184":
                key = "End_to_End_Errors"
            elif ID == "187":
                key = "Uncorrectable_Errors"
            elif ID == "188":
                key = "Command_Timeout_Counter"
            elif ID == "194":
                key = "Temperature"
            elif ID == "196":
                key = "Reallocated_Events"
            elif ID == "197":
                key = "Pending_Sectors"
            elif ID == "199":
                key = "UDMA_CRC_Errors"
        
        if key == "Temperature":
            continue
        
        raw_int = int(raw_value) if raw_value.isdigit() else 0
        section[key] = raw_int

    if not section:
        return {
            "changed": False,
            "msg": "no SMART attributes found for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"
    details_parts = []

    for attr in [
        "Reallocated_Sectors",
        "Power_On_Hours",
        "Spin_Retries",
        "Power_Cycles",
        "End_to_End_Errors",
        "Uncorrectable_Errors",
        "Command_Timeout_Counter",
        "Reallocated_Events",
        "Pending_Sectors",
        "UDMA_CRC_Errors",
        "CRC_Errors",
        "Critical_Warning",
        "Media_and_Data_Integrity_Errors",
        "Available_Spare",
        "Percentage_Used",
        "Error_Information_Log_Entries",
        "Data_Units_Read",
        "Data_Units_Written"
    ]:
        if attr not in section:
            continue
        
        value = section[attr]
        
        if attr == "Critical_Warning":
            if value != 0:
                state = "CRIT"
                details_parts.append("Critical_Warning: %d" % value)
        elif attr == "Available_Spare":
            if value < 10:
                state = "CRIT"
                details_parts.append("Available_Spare: %d%%" % value)
        elif attr == "Percentage_Used":
            if value > 100:
                state = "CRIT"
                details_parts.append("Percentage_Used: %d%%" % value)
        elif attr in ["Reallocated_Sectors", "Reallocated_Events", "Pending_Sectors",
                      "Uncorrectable_Errors", "End_to_End_Errors", "UDMA_CRC_Errors",
                      "CRC_Errors"]:
            if value > 0:
                if state == "OK":
                    state = "WARN"
                details_parts.append("%s: %d" % (attr.replace("_", " "), value))
        elif attr == "Command_Timeout_Counter":
            if value > 100:
                state = "CRIT"
                details_parts.append("Command_Timeout_Counter: %d" % value)

    summary_parts = []
    for attr in section:
        summary_parts.append("%s: %d" % (attr.replace("_", " "), section[attr]))
    
    msg = "; ".join(summary_parts)
    if state != "OK":
        msg += " (%s)" % state
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": section,
            "details": "; ".join(details_parts) if details_parts else ""
        }
    }