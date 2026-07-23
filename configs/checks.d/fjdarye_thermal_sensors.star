# ===== Starlark check module: fjdarye_thermal_sensors =====
# Translated from Checkmk plugin: fjdarye_thermal_sensors
# Read-only check: gathers SNMP data on Fujitsu thermal sensors and reports status

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",   # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
]

DETECT_OID = ".1.3.6.1.2.1.1.2.0"

FJDARYE_ITEM_STATUS = {
    "1": {"state": "OK", "summary": "Normal"},
    "2": {"state": "CRIT", "summary": "Alarm"},
    "3": {"state": "WARN", "summary": "Warning"},
    "4": {"state": "CRIT", "summary": "Invalid"},
    "5": {"state": "CRIT", "summary": "Maintenance"},
    "6": {"state": "CRIT", "summary": "Undefined"},
}

def _detect_fjdarye(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, DETECT_OID], mutates=False)
    if res.rc != 0:
        return False
    # Parse "oid = STRING: <value>" or "oid = OID: <value>" format
    line = res.stdout.strip()
    if not line:
        return False
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return False
    value = parts[1].strip()
    # Remove possible prefix like "STRING:" or "OID:"
    for prefix in ["STRING:", "OID:", "INTEGER:"]:
        if value.startswith(prefix):
            value = value[len(prefix):].strip()
    return value in FJDARYE_SUPPORTED_DEVICES

def _walk_thermal_sensors(ctx, community, host):
    items = []
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        base = device_oid + ".2.11.2.1"
        # Walk base OID for index and status
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            parts_line = line.strip().split(" = ", 1)
            if len(parts_line) != 2:
                continue
            full_oid = parts_line[0].strip()
            # Extract index (the last component after dot)
            oid_parts = full_oid.rsplit(".", 1)
            if len(oid_parts) != 2:
                continue
            base_oid = oid_parts[0]
            # Only process base.1 (index) entries
            if not full_oid.endswith(".1"):
                continue
            index = oid_parts[1]
            # Get corresponding status from .3
            status_oid = base_oid + ".3"
            res_status = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
            if res_status.rc != 0:
                continue
            status_line = res_status.stdout.strip()
            if not status_line:
                continue
            status_parts = status_line.split(" = ", 1)
            if len(status_parts) != 2:
                continue
            status_value = status_parts[1].strip()
            # Remove possible prefix
            for prefix in ["STRING:", "OID:", "INTEGER:"]:
                if status_value.startswith(prefix):
                    status_value = status_value[len(prefix):].strip()
            # Only include items with status != "4" (Invalid)
            if status_value != "4":
                items.append({"item": index, "status": status_value})
    return items

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        if not _detect_fjdarye(ctx, community, host):
            return {"changed": False, "msg": "device not detected as Fujitsu FJDARY-E",
                    "data": {"discovery": []}}
        items = _walk_thermal_sensors(ctx, community, host)
        discovery_list = []
        for item in items:
            discovery_list.append({
                "item": item["item"],
                "params": {},
                "metrics": []
            })
        return {"changed": False,
                "msg": "discovered %d thermal sensors" % len(discovery_list),
                "data": {"discovery": discovery_list}}

    # Check mode (one item)
    item = params.get("item", "")
    if not item:
        fail("item parameter required for check mode")

    # Detect device first
    if not _detect_fjdarye(ctx, community, host):
        return {"changed": False,
                "msg": "device not detected as Fujitsu FJDARY-E",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get item status via snmpget
    # Find which device OID matches and construct sensor OID
    base_oid = None
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        # Sensor index OID: device_oid.2.11.2.1.<index>.1
        # Status OID: device_oid.2.11.2.1.<index>.3
        sensor_oid = device_oid + ".2.11.2.1." + item + ".3"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, sensor_oid], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            base_oid = device_oid
            break

    if not base_oid:
        return {"changed": False,
                "msg": "thermal sensor %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_oid = base_oid + ".2.11.2.1." + item + ".3"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False,
                "msg": "could not retrieve status for sensor %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    line = res.stdout.strip()
    parts_line = line.split(" = ", 1)
    if len(parts_line) != 2:
        return {"changed": False,
                "msg": "could not parse status value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_value = parts_line[1].strip()
    # Remove possible prefix
    for prefix in ["STRING:", "OID:", "INTEGER:"]:
        if status_value.startswith(prefix):
            status_value = status_value[len(prefix):].strip()

    status_info = FJDARYE_ITEM_STATUS.get(status_value, {"state": "UNKNOWN", "summary": "Unknown"})
    state = status_info["state"]
    summary = status_info["summary"]
    msg = "sensor %s: %s" % (item, summary)

    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}
