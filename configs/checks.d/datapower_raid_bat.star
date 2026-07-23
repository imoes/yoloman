# Map status codes to (state, text) - State.OK/WARN/CRIT mapped to "OK"/"WARN"/"CRIT"
DATAPOWER_RIAD_BAT_STATUS = {
    "1": ("OK", "charging"),
    "2": ("WARN", "discharging"),
    "3": ("CRIT", "i2c errors detected"),
    "4": ("OK", "learn cycle active"),
    "5": ("CRIT", "learn cycle failed"),
    "6": ("OK", "learn cycle requested"),
    "7": ("CRIT", "learn cycle timeout"),
    "8": ("CRIT", "pack missing"),
    "9": ("CRIT", "temperature high"),
    "10": ("CRIT", "voltage low"),
    "11": ("WARN", "periodic learn required"),
    "12": ("WARN", "remaining capacity low"),
    "13": ("CRIT", "replace pack"),
    "14": ("OK", "normal"),
    "15": ("WARN", "undefined"),
}

# Map battery type codes to text
DATAPOWER_RIAD_BAT_TYPE = {
    "1": "no battery present",
    "2": "ibbu",
    "3": "bbu",
    "4": "zcrLegacyBBU",
    "5": "itbbu3",
    "6": "ibbu08",
    "7": "unknown",
}

# Base OID for SNMP walk
BASE_OID = ".1.3.6.1.4.1.14685.3.1.258.1"


def _parse_snmp_output(res):
    """Parse snmpwalk output: '<OID> = <TYPE>: <value>' lines into list of rows."""
    rows = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Split once on '=' to get oid_part and value_part
        parts = stripped.split("=", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        # Extract last part after last dot (the actual OID leaf value)
        # We assume each row corresponds to one row in the table (5 fields per row)
        rows.append(value_part)
    # Reconstruct rows of 5 fields each
    table = []
    for i in range(0, len(rows), 5):
        chunk = rows[i:i+5]
        if len(chunk) == 5:
            table.append(chunk)
    return table


def _discover_item(section):
    """Return list of discovered items from parsed section."""
    items = []
    for row in section:
        if len(row) >= 1:
            items.append({"item": row[0], "params": {}, "metrics": []})
    return items


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), BASE_OID
        ], mutates=False)

        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no SNMP data", "data": {"discovery": []}}

        section = _parse_snmp_output(res)
        discovery = _discover_item(section)
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")

    # Gather data via snmpwalk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), BASE_OID
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no SNMP data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_snmp_output(res)
    state = "UNKNOWN"
    state_txt = "not found"
    type_txt = ""
    serial = ""
    name = ""

    for row in section:
        if len(row) >= 5:
            controller_id, bat_type, serial, name, status = row[0], row[1], row[2], row[3], row[4]
            if controller_id == item:
                # Look up status and type
                status_key = status.strip()
                type_key = bat_type.strip()
                state, state_txt = DATAPOWER_RIAD_BAT_STATUS.get(status_key, ("UNKNOWN", "unknown status"))
                type_txt = DATAPOWER_RIAD_BAT_TYPE.get(type_key, "unknown type")
                break

    if state == "UNKNOWN":
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    infotext = "Status: " + state_txt + ", Name: " + name + ", Type: " + type_txt + ", Serial: " + serial
    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": ""}}
