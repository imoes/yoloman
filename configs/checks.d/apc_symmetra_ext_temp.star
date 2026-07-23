# Constants for SNMP OIDs
BASE_OID = ".1.3.6.1.4.1.318.1.1.10.2.3.2.1"
OID_INDEX = "1"
OID_STATUS = "3"
OID_TEMP = "4"
OID_TEMP_UNIT = "5"
SYS_OID = ".1.3.6.1.2.1.1.2.0"
APC_OID_PREFIX = ".1.3.6.1.4.1.318"

# Temperature unit constants
TEMP_UNIT_CELSIUS = "1"
TEMP_UNIT_FAHRENHEIT = "2"

# Status constants (from SNMP data)
STATUS_ACTIVE = "2"


def main(ctx, params):
    # Discovery mode: enumerate all external temperature sensors that are active
    if params.get("_discover"):
        # Fetch SNMP data: index, status, temp, temp_unit
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse the output into lines
        lines = res.stdout.splitlines()
        items = []
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            # Check if this line matches one of our OIDs (base OID prefix)
            if line.startswith(BASE_OID + "."):
                # Collect the four consecutive values for one entry
                values = []
                while i < len(lines) and len(values) < 4:
                    l = lines[i].strip()
                    if l.startswith(BASE_OID + "."):
                        # Extract value after '='
                        eq_pos = l.find("=")
                        if eq_pos != -1:
                            val = l[eq_pos+1:].strip()
                            # Remove type prefix (e.g., "Gauge32:", "INTEGER:", etc.)
                            if ":" in val:
                                val = val.split(":", 1)[1].strip()
                            values.append(val)
                        i += 1
                    else:
                        break
                
                if len(values) >= 4:
                    index, status, temp, temp_unit = values[0], values[1], values[2], values[3]
                    # Only include if status == "2" (active)
                    if status == STATUS_ACTIVE:
                        # Extract numeric index (last OID component)
                        idx = index.rsplit(".", 1)[-1]
                        items.append({
                            "item": idx,
                            "params": {"levels": (30.0, 35.0)},
                            "metrics": ["temp"]
                        })
            else:
                i += 1
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify one specific sensor (item is the index)
    item = params.get("item", "")
    if item == None:
        item = ""

    # Fetch SNMP data for the specific sensor item
    # We'll fetch all and filter in code since snmpget with index-specific OID may vary
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        BASE_OID
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse section into list of entries
    section = []
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith(BASE_OID + "."):
            values = []
            while i < len(lines) and len(values) < 4:
                l = lines[i].strip()
                if l.startswith(BASE_OID + "."):
                    eq_pos = l.find("=")
                    if eq_pos != -1:
                        val = l[eq_pos+1:].strip()
                        if ":" in val:
                            val = val.split(":", 1)[1].strip()
                        values.append(val)
                    i += 1
                else:
                    break

            if len(values) >= 4:
                idx = values[0].rsplit(".", 1)[-1]
                status, temp, temp_unit = values[1], values[2], values[3]
                section.append((idx, status, temp, temp_unit))
        else:
            i += 1

    # Find matching item
    reading = None
    dev_unit = "c"
    for idx, status, temp, temp_unit in section:
        if idx == item:
            if status == STATUS_ACTIVE:
                # Guard before parsing integer
                if temp.isdigit() or (temp.startswith("-") and temp[1:].isdigit()):
                    reading = int(temp)
                dev_unit = "f" if temp_unit == TEMP_UNIT_FAHRENHEIT else "c"
            break

    # If sensor not found or not active -> UNKNOWN
    if reading == None:
        return {
            "changed": False,
            "msg": "Sensor not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds from params with Checkmk defaults
    levels = params.get("levels", (30.0, 35.0))
    warn, crit = levels[0], levels[1]

    # Determine state
    # Use integer comparison (readings are integer per the source)
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format message
    unit_str = "F" if dev_unit == "f" else "C"
    return {
        "changed": False,
        "msg": "Temperature: %d.%d °%s" % (reading // 1, abs(reading % 1) * 10, unit_str),
        "data": {
            "state": state,
            "metrics": {"temp": float(reading)},
            "details": ""
        }
    }
