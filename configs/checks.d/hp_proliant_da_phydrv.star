# Checkmk check: hp_proliant_da_phydrv
# Translated to a read-only Starlark check module for the yolo-man agent.
# This is an SNMP-based check that monitors HP ProLiant drive bay physical drives.

MAP_CONDITION = {
    "0": "n/a",
    "1": "other",
    "2": "ok",
    "3": "degraded",
    "4": "failed",
}

MAP_STATUS = {
    "1": "other",
    "2": "ok",
    "3": "failed",
    "4": "predictive failure",
    "5": "erasing",
    "6": "erase done",
    "7": "erase queued",
    "8": "SSD wear out",
    "9": "not authenticated",
    "10": "spare",
}

MAP_SMART_STATUS = {
    "1": "other",
    "2": "ok",
    "3": "replace drive",
    "4": "replace drive SSD wear out",
}

MAP_TYPES = {
    "1": "other",
    "2": "parallel SCSI",
    "3": "SATA",
    "4": "SAS",
}

BASE_OID = ".1.3.6.1.4.1.232.3.2.5.1.1"
COL_CONTROLLER_INDEX = "1"
COL_DRIVE_INDEX = "2"
COL_BAY = "5"
COL_STATUS = "6"
COL_REF_HOURS = "9"
COL_SIZE = "45"
COL_CONDITION = "37"
COL_BUS_NUMBER = "50"
COL_SMART_STATUS = "57"
COL_MODEL = "3"
COL_SERIAL = "51"
COL_TYPE = "60"
COL_FW_REV = "4"
PRODUCT_NAME_OID = ".1.3.6.1.4.1.232.2.2.4.2.0"


def condition_to_state(condition):
    if condition == "other":
        return "UNKNOWN"
    if condition == "ok":
        return "OK"
    if condition in ("degraded", "failed"):
        return "CRIT"
    return "UNKNOWN"


def render_disksize(size_bytes):
    mb = 1024 * 1024
    gb = 1024 * mb
    if size_bytes >= gb:
        return "%f GB" % (size_bytes / gb)
    if size_bytes >= mb:
        return "%f MB" % (size_bytes / mb)
    return "%d B" % size_bytes


def is_proliant(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, PRODUCT_NAME_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip().lower()
    return "proliant" in val or "storeeasy" in val or "synergy" in val


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not is_proliant(ctx, host, community):
            return {"changed": False, "msg": "not an HP ProLiant system", "data": {"discovery": []}}

        col_oid = BASE_OID + "." + COL_DRIVE_INDEX
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no physical drives found", "data": {"discovery": []}}

        drives = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            idx = oid_full[len(col_oid) + 1:]
            if not idx:
                continue
            drives.append({
                "item": idx,
                "params": {},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d physical drives" % len(drives),
            "data": {"discovery": drives},
        }

    item = params.get("item", "")

    if not is_proliant(ctx, host, community):
        return {
            "changed": False,
            "msg": "not an HP ProLiant system",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    def snmp_get_col(col_oid):
        r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, BASE_OID + "." + col_oid + "." + item],
            mutates=False,
        )
        if r.rc != 0:
            return ""
        return r.stdout.strip()

    drive_index = snmp_get_col(COL_DRIVE_INDEX)
    bay = snmp_get_col(COL_BAY)
    status_raw = snmp_get_col(COL_STATUS)
    ref_hours = snmp_get_col(COL_REF_HOURS)
    size_raw = snmp_get_col(COL_SIZE)
    condition_raw = snmp_get_col(COL_CONDITION)
    bus_number = snmp_get_col(COL_BUS_NUMBER)
    smart_status_raw = snmp_get_col(COL_SMART_STATUS)

    if not drive_index:
        return {
            "changed": False,
            "msg": "no such physical drive: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = MAP_STATUS.get(status_raw, "unknown(%s)" % status_raw)
    condition = MAP_CONDITION.get(condition_raw, "unknown(%s)" % condition_raw)
    smart_status = MAP_SMART_STATUS.get(smart_status_raw, "unknown(%s)" % smart_status_raw)

    size_bytes = 0
    if size_raw.isdigit():
        size_bytes = int(size_raw) * 1024 * 1024

    state = condition_to_state(condition)

    summary_parts = []
    summary_parts.append("Bay: %s" % bay)
    summary_parts.append("Bus number: %s" % bus_number)
    summary_parts.append("Status: %s" % status)
    summary_parts.append("Smart status: %s" % smart_status)
    summary_parts.append("Ref hours: %s" % ref_hours)
    summary_parts.append("Size: %s" % render_disksize(size_bytes))
    summary_parts.append("Condition: %s" % condition)

    summary = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"size": size_bytes},
            "details": summary,
        },
    }