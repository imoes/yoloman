# Translated Checkmk check: checkmk.avaya_chassis_card
# SNMP-based check for Avaya chassis cards.

BASE_OID = ".1.3.6.1.4.1.2272.1.4.9.1.1"
SYSCONTACT_OID = ".1.3.6.1.2.1.1.2.0"      # used by DETECT_AVAYA
NAME_COL = "1"   # .1 -> card name
STATUS_COL = "6" # .6 -> operational status

AVAYA_ENTERPRISE_PREFIX = ".1.3.6.1.4.1.2272"

# Status code -> (state, name)
STATUS_CODES = {
    1: ("OK", "up"),
    2: ("CRIT", "down"),
    3: ("OK", "testing"),
    4: ("UNKNOWN", "unknown"),
    5: ("OK", "dormant"),
}


def main(ctx, params):
    if params.get("_discover"):
        # Probe for Avaya device presence via sysObjectId.
        ver = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Ov", params.get("host", "localhost"), SYSCONTACT_OID],
            mutates=False)
        if ver.rc != 0 or not ver.stdout:
            return {"changed": False, "msg": "host is not an Avaya device",
                    "data": {"discovery": []}}
        if AVAYA_ENTERPRISE_PREFIX not in ver.stdout:
            return {"changed": False, "msg": "host is not an Avaya device",
                    "data": {"discovery": []}}

        # Walk the name column to discover card items.
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             "." + BASE_OID + "." + NAME_COL],
            mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": []}}

        discovery = []
        seen = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            name_val = parts[1].strip()
            if name_val.startswith('"') and name_val.endswith('"') and len(name_val) >= 2:
                name_val = name_val[1:-1]
            idx = oid[len(BASE_OID) + 1:]
            if idx in seen:
                continue
            seen.append(idx)
            discovery.append({
                "item": name_val,
                "metrics": [],
            })

        return {"changed": False,
                "msg": "discovered %d cards" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: examine one specific card item.
    item = params.get("item", "")

    # Fetch the card name column via snmpwalk to resolve index.
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"),
         "." + BASE_OID + "." + NAME_COL],
        mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no card data: snmpwalk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    found = False
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        name_val = parts[1].strip()
        if name_val.startswith('"') and name_val.endswith('"') and len(name_val) >= 2:
            name_val = name_val[1:-1]
        idx = oid[len(BASE_OID) + 1:]
        if name_val == item:
            index = idx
            found = True
            break

    if not found:
        return {"changed": False, "msg": "no such card: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch operational status for the matched index.
    st = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         "." + BASE_OID + "." + STATUS_COL + "." + index],
        mutates=False)
    if st.rc != 0 or not st.stdout:
        return {"changed": False, "msg": "no status for card " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = st.stdout.strip()
    if not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid status value: " + raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    code = int(raw)
    if code in STATUS_CODES:
        state, name = STATUS_CODES[code]
    else:
        state, name = ("UNKNOWN", "unknown (code %d)" % code)

    return {"changed": False,
            "msg": "Operational status: %s" % name,
            "data": {"state": state, "metrics": {}, "details": ""}}