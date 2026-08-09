# checkmk.fjdarye_ce_power_supply_units -> Fujitsu storage CPSU (power supply) SNMP check

# Status map: numeric status -> (state, summary)
FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

# Supported FJDARY device sysObjectIDs (full OIDs)
FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.100",
    ".1.3.6.1.4.1.211.1.21.1.150",
    ".1.3.6.1.4.1.211.1.21.1.153",
]

# sysObjectID OID
SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"

# PSU table column base suffix (columns: 1=index, 3=status)
PSU_TABLE_SUFFIX = ".2.13.2.1"


def discover(ctx, host, community):
    # Detect which supported device by matching sysObjectID
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OBJECT_ID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    sys_object_id = res.stdout.strip()
    device_oid = None
    for d in FJDARYE_SUPPORTED_DEVICES:
        if d == sys_object_id:
            device_oid = d
            break
    if device_oid == None:
        return None

    # Walk the status column (.3). Each line: "<base>.3.<index> <value>"
    walk_oid = device_oid + PSU_TABLE_SUFFIX + ".3"
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, walk_oid],
        mutates=False,
    )
    if walk.rc != 0:
        return []

    items = []
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        # index = suffix after "<base>.3."
        col_base = walk_oid + "."
        if oid.startswith(col_base):
            index = oid[len(col_base):]
        else:
            # fallback: strip last two numeric components (.3.<index>)
            # oid = device_oid + PSU_TABLE_SUFFIX + ".3." + index
            index = oid[len(walk_oid + "."):]
        status = value
        # discovery excludes status "4" (Invalid)
        if status == "4":
            continue
        items.append({"item": index, "status": status})
    return items


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        found = discover(ctx, host, community)
        if found == None:
            return {"changed": False, "msg": "not a FJDARY-E supported device", "data": {"discovery": []}}
        discovery = []
        for it in found:
            discovery.append({
                "item": it["item"],
                "params": {},
                "metrics": [],
            })
        return {"changed": False, "msg": "discovered %d CPSU units" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    # Re-detect the device OID
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OBJECT_ID],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "cannot reach host / no SNMP", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_object_id = res.stdout.strip()
    device_oid = None
    for d in FJDARYE_SUPPORTED_DEVICES:
        if d == sys_object_id:
            device_oid = d
            break
    if device_oid == None:
        return {"changed": False, "msg": "not a FJDARY-E supported device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the status for this specific item: snmpget <base>.3.<index>
    get_oid = device_oid + PSU_TABLE_SUFFIX + ".3." + item
    get = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, get_oid],
        mutates=False,
    )
    if get.rc != 0:
        return {"changed": False, "msg": "no CPSU unit " + item + " found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = get.stdout.strip()

    entry = FJDARYE_ITEM_STATUS.get(status)
    if entry == None:
        return {"changed": False, "msg": "CPSU %s: Unknown status %s" % (item, status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = entry[0]
    summary = entry[1]
    return {"changed": False, "msg": "CPSU %s: %s" % (item, summary),
            "data": {"state": state, "metrics": {}, "details": ""}}