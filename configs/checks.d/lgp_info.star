# ===== check plugin: cmk.plugins.lgp.agent_based/lgp_info.py =====
# Translated to read-only Starlark check module for the yolo-man agent.
# Monitors Liebert (Emerson Network Power) device identity/info via SNMP.

# Mapping of known device-type OIDs to human-readable names.
_LGP_INFO_DEVICES = {
    ".1.3.6.1.4.1.476.1.42.4.8.2.1": "lgpMPX",
    ".1.3.6.1.4.1.476.1.42.4.8.2.2": "lgpMPH",
}

# SNMP OIDs used by the Checkmk SNMPSection fetch blocks.
# Tree 1 (base .1.3.6.1.4.1.476.1.42.2.1, oids 2.0/3.0/4.0):
#   .2.0 -> model/type string
#   .3.0 -> firmware revision string
#   .4.0 -> serial number string
_LGP_MODEL_OID = ".1.3.6.1.4.1.476.1.42.2.1.2.0"
_LGP_FW_OID = ".1.3.6.1.4.1.476.1.42.2.1.3.0"
_LGP_SERIAL_OID = ".1.3.6.1.4.1.476.1.42.2.1.4.0"

# Tree 2 (base .1.3.6.1.4.1.476.1.42.2.4.2.1, oids 2/3/6):
#   .2 -> device id
#   .3 -> manufacturer
#   .6 -> unit number
# Walked together via snmpwalk to obtain per-device rows.
_LGP_DEVICES_BASE = ".1.3.6.1.4.1.476.1.42.2.4.2.1"
_LGP_DEV_ID_COL = ".2"
_LGP_DEV_MFR_COL = ".3"
_LGP_DEV_UNIT_COL = ".6"

# Detection OID from DETECT_LGP: the sysObjectID must equal this value.
_LGP_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
_LGP_SYS_OBJECT_VAL = ".1.3.6.1.4.1.476.1.42"


def _strip_snmp_value(value):
    """Strip a leading 'STRING: ' / 'INTEGER: ' / etc. type tag and surrounding quotes."""
    if value == None:
        return ""
    v = value.strip()
    # Remove a leading "<TYPE>: " prefix if present (e.g. "STRING: " or "INTEGER: ").
    colon_idx = v.find(": ")
    if colon_idx >= 0:
        type_token = v[:colon_idx]
        # Only strip when the token looks like a type tag (alphabetic letters).
        if type_token.replace("-", "").isalpha():
            v = v[colon_idx + 2:]
    # Strip surrounding double or single quotes.
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1]
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1]
    return v


def _snmp_get(ctx, oid, community, host):
    """Perform a single SNMP GET returning only the bare value (-Oqv)."""
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _snmp_walk(ctx, column_oid, community, host):
    """Walk an SNMP column OID, returning lines of '<OID>.<index> <value>'."""
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )


def _gather_device_rows(ctx, community, host):
    """Correlate the three device-table columns by their common index suffix.

    Each line from '-Oqn' is '<column>.<index> <value>'. The index is the part
    after the column base OID's trailing dot.
    """
    id_walk = _snmp_walk(ctx, _LGP_DEVICES_BASE + _LGP_DEV_ID_COL, community, host)
    if id_walk.rc != 0:
        return None

    rows = {}
    for line in id_walk.stdout.splitlines():
        space_idx = line.find(" ")
        if space_idx < 0:
            continue
        oid_part = line[:space_idx]
        val_part = line[space_idx + 1:]
        # Index is everything after '<base>.<col>.'
        prefix = _LGP_DEVICES_BASE + _LGP_DEV_ID_COL + "."
        if not oid_part.startswith(prefix):
            continue
        index = oid_part[len(prefix):]
        rows[index] = {"device_id": _strip_snmp_value(val_part)}

    if len(rows) == 0:
        # No device rows walked; treat the device table as absent.
        return []

    # Fetch manufacturer column.
    mfr_walk = _snmp_walk(ctx, _LGP_DEVICES_BASE + _LGP_DEV_MFR_COL, community, host)
    if mfr_walk.rc == 0:
        for line in mfr_walk.stdout.splitlines():
            space_idx = line.find(" ")
            if space_idx < 0:
                continue
            oid_part = line[:space_idx]
            val_part = line[space_idx + 1:]
            prefix = _LGP_DEVICES_BASE + _LGP_DEV_MFR_COL + "."
            if not oid_part.startswith(prefix):
                continue
            index = oid_part[len(prefix):]
            if index in rows:
                rows[index]["manufacturer"] = _strip_snmp_value(val_part)

    # Fetch unit-number column.
    unit_walk = _snmp_walk(ctx, _LGP_DEVICES_BASE + _LGP_DEV_UNIT_COL, community, host)
    if unit_walk.rc == 0:
        for line in unit_walk.stdout.splitlines():
            space_idx = line.find(" ")
            if space_idx < 0:
                continue
            oid_part = line[:space_idx]
            val_part = line[space_idx + 1:]
            prefix = _LGP_DEVICES_BASE + _LGP_DEV_UNIT_COL + "."
            if not oid_part.startswith(prefix):
                continue
            index = oid_part[len(prefix):]
            if index in rows:
                rows[index]["unit_number"] = _strip_snmp_value(val_part)

    return list(rows.values())


def _is_liebert(ctx, community, host):
    """Probe for the real Liebert device via its sysObjectID (DETECT_LGP).

    Returns True only when the sysObjectID equals the Liebert enterprise OID.
    A missing SNMP agent / wrong community yields rc != 0 -> False (not a Liebert).
    """
    res = _snmp_get(ctx, _LGP_SYS_OBJECT_ID, community, host)
    if res.rc != 0:
        return False
    val = _strip_snmp_value(res.stdout)
    return val == _LGP_SYS_OBJECT_VAL


def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        if not _is_liebert(ctx, community, host):
            return {
                "changed": False,
                "msg": "not a Liebert device (no sysObjectID match)",
                "data": {"discovery": []},
            }
        res = _snmp_get(ctx, _LGP_MODEL_OID, community, host)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "Liebert device not reachable for info",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered Liebert info service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    # --- CHECK MODE (single-service check, item "") ---
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # ABSENCE IS AN ANSWER: probe for the real Liebert device first.
    if not _is_liebert(ctx, community, host):
        return {
            "changed": False,
            "msg": "no Liebert device found (sysObjectID mismatch)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    model_res = _snmp_get(ctx, _LGP_MODEL_OID, community, host)
    if model_res.rc != 0:
        return {
            "changed": False,
            "msg": "could not retrieve Liebert model info",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    model = _strip_snmp_value(model_res.stdout)

    fw_res = _snmp_get(ctx, _LGP_FW_OID, community, host)
    if fw_res.rc != 0:
        return {
            "changed": False,
            "msg": "could not retrieve Liebert firmware info",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    firmware = _strip_snmp_value(fw_res.stdout)

    serial_res = _snmp_get(ctx, _LGP_SERIAL_OID, community, host)
    if serial_res.rc != 0:
        return {
            "changed": False,
            "msg": "could not retrieve Liebert serial info",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    serial = _strip_snmp_value(serial_res.stdout)

    summary = "Model: %s, Firmware: %s, S/N: %s" % (model, firmware, serial)

    details = ""
    device_rows = _gather_device_rows(ctx, community, host)
    if device_rows != None and len(device_rows) > 0:
        lines = []
        for row in device_rows:
            dev_id = row.get("device_id", "")
            manufacturer = row.get("manufacturer", "")
            unit_number = row.get("unit_number", "")
            display = _LGP_INFO_DEVICES.get(dev_id, dev_id)
            lines.append(
                "ID: %s, Manufacturer: %s, Unit-Number: %s"
                % (display, manufacturer, unit_number)
            )
        details = "\n".join(lines)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": details,
        },
    }