# oracle_diva_csm_objects — read-only Starlark check module
#
# Translates Checkmk plugin oracle_diva_csm_objects (one of several sub-checks
# sharing the oracle_diva_csm SNMP section). Discovery enumerates on-host DIVA
# libraries; the check reports library/object/tape status metrics.

# OID roots used by the oracle_diva_csm section
LIB_STATUS_OID = ".1.3.6.1.4.1.110901.1.2.1.1"          # col: 1,2
DRIVE_STATUS_BASE = ".1.3.6.1.4.1.110901.1.2.2.1.1"      # col: 3,8
ACTOR_STATUS_BASE = ".1.3.6.1.4.1.110901.1.3.1.1"        # col: 2,4
ARCHIVE_STATUS_OID = ".1.3.6.1.4.1.110901.1.4.1.0"
OBJECTS_OID = ".1.3.6.1.4.1.110901.1.4.2.0"
BLANK_TAPES_OID = ".1.3.6.1.4.1.110901.1.4.3.0"
REMAINING_SIZE_OID = ".1.3.6.1.4.1.110901.1.4.4.0"
TOTAL_SIZE_OID = ".1.3.6.1.4.1.110901.1.4.5.0"

# Detection: Checkmk detects a DIVA library via sysObjectID
# .1.3.6.1.2.1.1.2.0 == .1.3.6.1.4.1.311.1.1.3.1.2.

GB = 1024 * 1024 * 1024


def _read_snmp(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.rstrip("\n")


def _walk_snmp(ctx, base_oid, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        rows.append((line[:sp], line[sp + 1:]))
    return rows


def _is_diva_library(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sys_oid = _read_snmp(ctx, ".1.3.6.1.2.1.1.2.0", community, host)
    if sys_oid == ".1.3.6.1.4.1.311.1.1.3.1.2":
        return True
    if sys_oid.startswith(".1.3.6.1.4.1.110901"):
        return True
    return False


def _status_result(reading):
    if reading == "1":
        return "OK", "online"
    if reading == "2":
        return "CRIT", "offline"
    if reading == "3":
        return "WARN", "unknown"
    return "UNKNOWN", "unexpected state"


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    if params.get("_discover"):
        if not _is_diva_library(ctx, params):
            return {"changed": False, "msg": "no DIVA library found",
                    "data": {"discovery": []}}

        discovery = []

        # Library-level status
        lib_rows = _walk_snmp(ctx, LIB_STATUS_OID, community, host)
        for oid, value in lib_rows:
            idx = oid[len(LIB_STATUS_OID) + 1:] if oid.startswith(LIB_STATUS_OID + ".") else ""
            if idx == "":
                continue
            discovery.append({
                "item": "Library %s" % value,
                "params": {},
                "metrics": ["status"],
            })

        # Drive status
        drive_rows = _walk_snmp(ctx, DRIVE_STATUS_BASE, community, host)
        for oid, value in drive_rows:
            idx = oid[len(DRIVE_STATUS_BASE) + 1:] if oid.startswith(DRIVE_STATUS_BASE + ".") else ""
            if idx == "":
                continue
            discovery.append({
                "item": "Drive %s" % value,
                "params": {},
                "metrics": ["status"],
            })

        # Actor status
        actor_rows = _walk_snmp(ctx, ACTOR_STATUS_BASE, community, host)
        for oid, value in actor_rows:
            idx = oid[len(ACTOR_STATUS_BASE) + 1:] if oid.startswith(ACTOR_STATUS_BASE + ".") else ""
            if idx == "":
                continue
            discovery.append({
                "item": "Actor %s" % value,
                "params": {},
                "metrics": ["status"],
            })

        # Managed Objects (single-service check)
        objects_raw = _read_snmp(ctx, OBJECTS_OID, community, host)
        remaining_raw = _read_snmp(ctx, REMAINING_SIZE_OID, community, host)
        total_raw = _read_snmp(ctx, TOTAL_SIZE_OID, community, host)
        if objects_raw != "" and remaining_raw != "" and total_raw != "":
            discovery.append({
                "item": "",
                "params": {},
                "metrics": ["managed_object_count", "storage_used"],
            })

        # Blank Tapes (single-service check)
        blank_raw = _read_snmp(ctx, BLANK_TAPES_OID, community, host)
        if blank_raw != "":
            ll = params.get("levels_lower", [5, 1])
            ll_val = [5, 1]
            if isinstance(ll, list) and len(ll) == 2:
                ll_val = [ll[0], ll[1]]
            discovery.append({
                "item": "",
                "params": {"levels_lower": ll_val},
                "metrics": ["tapes_free"],
            })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # --- Check mode ---
    if not _is_diva_library(ctx, params):
        return {"changed": False, "msg": "no DIVA library found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []

    if item == "" or item.startswith("Library"):
        status_raw = _read_snmp(ctx, LIB_STATUS_OID, community, host)
        if status_raw:
            state, summary = _status_result(status_raw)
            details_lines.append("Library %s" % summary)
            if state == "CRIT":
                return {"changed": False,
                        "msg": "Library %s" % summary,
                        "data": {"state": state, "metrics": {}, "details": ""}}

        objects_raw = _read_snmp(ctx, OBJECTS_OID, community, host)
        remaining_raw = _read_snmp(ctx, REMAINING_SIZE_OID, community, host)
        total_raw = _read_snmp(ctx, TOTAL_SIZE_OID, community, host)
        if objects_raw != "" and remaining_raw != "" and total_raw != "":
            if not (objects_raw.lstrip("-").isdigit() and remaining_raw.lstrip("-").isdigit() and total_raw.lstrip("-").isdigit()):
                return {"changed": False,
                        "msg": "unexpected value format",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            object_count = int(objects_raw)
            remaining_size = int(remaining_raw)
            total_size = int(total_raw)
            infotext = "managed objects: %d, remaining size: %d GB of %d GB" % (
                object_count, remaining_size, total_size)
            details_lines.append(infotext)
            metrics["managed_object_count"] = object_count
            metrics["storage_used"] = (total_size - remaining_size) * GB

        state = "OK"
        if not details_lines:
            state = "UNKNOWN"
        msg = "; ".join(details_lines) if details_lines else "no data"
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": metrics, "details": ""}}

    if item.startswith("Drive"):
        drive_rows = _walk_snmp(ctx, DRIVE_STATUS_BASE, community, host)
        target_label = item[len("Drive "):]
        for oid, value in drive_rows:
            idx = oid[len(DRIVE_STATUS_BASE) + 1:] if oid.startswith(DRIVE_STATUS_BASE + ".") else ""
            if idx == "":
                continue
            if value == target_label or idx == target_label:
                state, summary = _status_result(value)
                return {"changed": False,
                        "msg": "Drive %s %s" % (target_label, summary),
                        "data": {"state": state, "metrics": metrics, "details": ""}}
        return {"changed": False,
                "msg": "drive %s not found" % target_label,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item.startswith("Actor"):
        actor_rows = _walk_snmp(ctx, ACTOR_STATUS_BASE, community, host)
        target_label = item[len("Actor "):]
        for oid, value in actor_rows:
            idx = oid[len(ACTOR_STATUS_BASE) + 1:] if oid.startswith(ACTOR_STATUS_BASE + ".") else ""
            if idx == "":
                continue
            if idx == target_label:
                state, summary = _status_result(value)
                return {"changed": False,
                        "msg": "Actor %s %s" % (target_label, summary),
                        "data": {"state": state, "metrics": metrics, "details": ""}}
        return {"changed": False,
                "msg": "actor %s not found" % target_label,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Blank Tapes sub-check
    blank_raw = _read_snmp(ctx, BLANK_TAPES_OID, community, host)
    if blank_raw != "":
        if not blank_raw.lstrip("-").isdigit():
            return {"changed": False,
                    "msg": "unexpected value format",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        blank_tapes = int(blank_raw)
        warn, crit = 5, 1
        ll = params.get("levels_lower", [5, 1])
        if isinstance(ll, list) and len(ll) == 2:
            warn, crit = ll[0], ll[1]
        state = "OK"
        if blank_tapes <= crit:
            state = "CRIT"
        elif blank_tapes <= warn:
            state = "WARN"
        metrics["tapes_free"] = blank_tapes
        return {"changed": False,
                "msg": "Blank tapes: %d" % blank_tapes,
                "data": {"state": state, "metrics": metrics, "details": ""}}

    return {"changed": False,
            "msg": "no data for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}