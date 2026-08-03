# Checkmk check: brocade_vdx_status
# Translated to read-only Starlark for the yolo-man agent.
# Source: cmk/plugins/brocade/agent_based/brocade_vdx_status.py

# OID base and columns used by the Checkmk SNMPTree fetch.
# base=".1.3.6.1.4.1.1588.2.1.1.1.1", oids=["6", "7"]
# => firmware at .1.3.6.1.4.1.1588.2.1.1.1.1.6.0
# => status  at .1.3.6.1.4.1.1588.2.1.1.1.1.7.0
_OID_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.1"
_OID_FIRMWARE_COL = "6"
_OID_STATUS_COL = "7"
_FIRMWARE_OID = _OID_BASE + "." + _OID_FIRMWARE_COL + ".0"
_STATUS_OID = _OID_BASE + "." + _OID_STATUS_COL + ".0"

# Detection: sysObjectID starts with 1.3.6.1.4.1.1588 or equals 1.3.6.1.4.1.1916.2.306,
# and the firmware OID must exist.
_OID_SYS_OBJID = ".1.3.6.1.2.1.1.2.0"
_SYSObjectID_PREFIX_BROCADE = ".1.3.6.1.4.1.1588"
_SYSObjectId_EQUAL_BROCADE = ".1.3.6.1.4.1.1916.2.306"

_VDX_STATUS_MAP = {
    1: "OK",
    2: "CRIT",
    3: "WARN",
    4: "CRIT",
}

_VDX_STATUS_READABLE = {
    1: "online",
    2: "offline",
    3: "testing",
    4: "faulty",
}


def _is_brocade_device(ctx, params):
    """Probe sysObjectID to confirm this is a Brocade VDX device."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_OBJID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sys_objid = res.stdout.strip()
    if sys_objid == _SYSObjectId_EQUAL_BROCADE:
        return True
    return sys_objid.startswith(_SYSObjectID_PREFIX_BROCADE)


def _firmware_oid_exists(ctx, params):
    """Confirm the firmware scalar OID exists (discovery prerequisite)."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _FIRMWARE_OID],
        mutates=False,
    )
    return res.rc == 0


def _fetch_status(ctx, params):
    """Fetch firmware and status scalar values via SNMP."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    fw_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _FIRMWARE_OID],
        mutates=False,
    )
    st_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _STATUS_OID],
        mutates=False,
    )
    if fw_res.rc != 0 or st_res.rc != 0:
        return None
    return (fw_res.stdout.strip(), st_res.stdout.strip())


def main(ctx, params):
    if params.get("_discover"):
        if not _is_brocade_device(ctx, params):
            return {"changed": False, "msg": "not a Brocade device",
                    "data": {"discovery": []}}
        if not _firmware_oid_exists(ctx, params):
            return {"changed": False, "msg": "firmware OID missing",
                    "data": {"discovery": []}}
        entry = {
            "item": "",
            "params": {},
            "metrics": ["vdx_status"],
        }
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [entry]}}

    # Check mode: single service (item "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Confirm device is present before grading; absence is an answer.
    res_probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_OBJID],
        mutates=False,
    )
    if res_probe.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res_probe.rc != 0:
        return {"changed": False, "msg": "device not present: " + res_probe.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fetched = _fetch_status(ctx, params)
    if fetched == None:
        return {"changed": False, "msg": "could not fetch status/Firmware OIDs",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    firmware, status_str = fetched
    state = int(status_str) if status_str.isdigit() else 0
    readable = _VDX_STATUS_READABLE.get(state, "unknown")
    vdx_state = _VDX_STATUS_MAP.get(state, "UNKNOWN")

    # Report two Result-like verdicts: status and firmware.
    details = "Status: %s\nFirmware: %s" % (readable, firmware)
    return {
        "changed": False,
        "msg": "State: %s, Firmware: %s" % (readable, firmware),
        "data": {
            "state": vdx_state,
            "metrics": {"vdx_status": state},
            "details": details,
        },
    }