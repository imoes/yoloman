SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

SENSOR_DIGITAL_VALUE_NAMES = {
    "0": "closed",
    "1": "open",
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.3699.1.1.9.1.6.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        out = []
        current_index = ""
        current_desc = ""
        current_value = ""
        current_normal = ""
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            if value_part.startswith("INTEGER:"):
                val = value_part.split("INTEGER:")[1].strip()
                if oid_part.endswith(".1"):
                    current_index = val
                elif oid_part.endswith(".2"):
                    current_value = val
                elif oid_part.endswith(".3"):
                    current_normal = val
            elif value_part.startswith("STRING:"):
                val = value_part.split("STRING:")[1].strip().strip('"')
                if oid_part.endswith(".1"):
                    current_index = val
                elif oid_part.endswith(".3"):
                    current_desc = val
            elif value_part.startswith("OCTET STRING:"):
                val = value_part.split("OCTET STRING:")[1].strip().strip('"')
                if oid_part.endswith(".1"):
                    current_index = val
                elif oid_part.endswith(".3"):
                    current_desc = val
            
            # After processing all fields for one entry (index + desc + value + normal)
            if current_index and current_desc != "" and current_value != "" and current_normal != "":
                item_name = current_desc + " " + current_index
                value = SENSOR_DIGITAL_VALUE_NAMES.get(current_value, "unknown")
                normal = SENSOR_DIGITAL_VALUE_NAMES.get(current_normal, "unknown")
                out.append({"item": item_name, "params": {},
                            "metrics": ["sensor_value"]})
                current_index = ""
                current_desc = ""
                current_value = ""
                current_normal = ""
        
        return {"changed": False, "msg": "discovered %d digital sensors" % len(out),
                "data": {"discovery": out}}

    # CHECK mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.3699.1.1.9.1.6.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_value = ""
    sensor_normal = ""

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # We need to match the item description and index; parse item name "desc index"
        if item != "":
            parts_item = item.rsplit(" ", 1)
            if len(parts_item) != 2:
                continue
            desc_part = parts_item[0]
            idx_part = parts_item[1]
            
            if oid_part.endswith(".1"):
                if value_part.startswith("STRING:"):
                    val = value_part.split("STRING:")[1].strip().strip('"')
                elif value_part.startswith("OCTET STRING:"):
                    val = value_part.split("OCTET STRING:")[1].strip().strip('"')
                else:
                    val = ""
                if val != desc_part:
                    continue
                current_index = idx_part
            elif oid_part.endswith(".3") and current_index == idx_part:
                if value_part.startswith("STRING:"):
                    val = value_part.split("STRING:")[1].strip().strip('"')
                elif value_part.startswith("OCTET STRING:"):
                    val = value_part.split("OCTET STRING:")[1].strip().strip('"')
                else:
                    val = ""
                if val != desc_part:
                    continue
                current_desc = val
            elif oid_part.endswith(".7") and current_index == idx_part:
                if value_part.startswith("INTEGER:"):
                    val = value_part.split("INTEGER:")[1].strip()
                else:
                    val = ""
                sensor_value = val
            elif oid_part.endswith(".9") and current_index == idx_part:
                if value_part.startswith("INTEGER:"):
                    val = value_part.split("INTEGER:")[1].strip()
                else:
                    val = ""
                sensor_normal = val
                break

    if not sensor_value or not sensor_normal:
        return {"changed": False, "msg": "digital sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = SENSOR_DIGITAL_VALUE_NAMES.get(sensor_value, "unknown")
    normal = SENSOR_DIGITAL_VALUE_NAMES.get(sensor_normal, "unknown")

    if value == "unknown":
        return {"changed": False, "msg": "Sensor value is unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if value == normal:
        return {"changed": False, "msg": "Sensor Value is normal: %s" % value,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Sensor Value is not normal: %s . It should be: %s" % (value, normal),
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}
