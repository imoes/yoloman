# Map from SNMP operstatus code to (State, name)
AVAYA_CARD_STATUS = {
    1: ("OK", "up"),
    2: ("CRIT", "down"),
    3: ("OK", "testing"),
    4: ("UNKNOWN", "unknown"),
    5: ("OK", "dormant"),
}

# SNMP base OID for avaya_chassis_card
AVAYA_CARD_BASE_OID = ".1.3.6.1.4.1.2272.1.4.9.1.1.1"
AVAYA_CARD_STATUS_OID = ".1.3.6.1.4.1.2272.1.4.9.1.1.6"

# OID for sysObjectID (for detection)
SYSOBJECT_OID = ".1.3.6.1.2.1.1.2.0"
AVAYA_ENTERPRISE_OID = ".1.3.6.1.4.1.2272"


def _snmp_value_to_str(val):
    # Parse "STRING: value" or just "value" depending on snmpwalk output
    # Checkmk uses -On, so values are like "OID: ..." or "STRING: ..." or plain numbers
    idx = val.find(": ")
    if idx != -1:
        return val[idx + 2:].strip()
    return val.strip()


def _has_avaya_sysobject(ctx, host, community):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community,
        "-On", host, SYSOBJECT_OID
    ], mutates=False)
    if res.rc != 0:
        return False
    # Parse output like: .1.3.6.1.2.1.1.2.0 = OID: .1.3.6.1.4.1.2272.1.4.9.1
    line = res.stdout.strip()
    eq_idx = line.find("=")
    if eq_idx == -1:
        return False
    value_part = line[eq_idx + 1:].strip()
    return value_part.startswith(AVAYA_ENTERPRISE_OID)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detection: only run if device is Avaya
    if not _has_avaya_sysobject(ctx, host, community):
        if params.get("_discover"):
            return {"changed": False, "msg": "detected 0 items (not Avaya)",
                    "data": {"discovery": []}}
        # Not an Avaya device, return UNKNOWN for any item
        return {"changed": False,
                "msg": "device is not Avaya",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode: enumerate cards
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-On", host, AVAYA_CARD_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": []}}

        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Output format: OID = STRING: <card_name>
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            item_name = _snmp_value_to_str(line[eq_idx + 1:])
            # Skip empty names
            if item_name:
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d cards" % len(items),
                "data": {"discovery": items}}

    # Check mode: single item
    item = params.get("item", "")
    status_oid_full = AVAYA_CARD_STATUS_OID + "." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community,
        "-On", host, status_oid_full
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "card not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    line = res.stdout.strip()
    if not line:
        return {"changed": False,
                "msg": "card not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse: .1.3.6.1.4.1.2272.1.4.9.1.1.6.<item> = INTEGER: 1
    eq_idx = line.find("=")
    if eq_idx == -1:
        return {"changed": False,
                "msg": "unexpected response format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_str = _snmp_value_to_str(line[eq_idx + 1:])
    # Extract integer value (guard instead of try/except)
    code = 0
    if val_str.isdigit():
        code = int(val_str)
    else:
        return {"changed": False,
                "msg": "invalid status code: " + val_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status, name = AVAYA_CARD_STATUS.get(code, ("UNKNOWN", "unknown"))

    return {"changed": False,
            "msg": "Operational status: " + name,
            "data": {"state": status, "metrics": {}, "details": ""}}
