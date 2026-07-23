# Discovery and check for Checkmk orion_backup plugin (read-only Starlark module)

# SNMP OID constants
ORION_BACKUP_BASE = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.5.3.3"
OID_BACKUP_STATUS = "2"
OID_BACKUP_TIME = "3"

# State mapping: status code -> (State, readable string)
# State values: OK=0, WARN=1, CRIT=2, UNKNOWN=3
STATUS_MAP = {
    "1": ("WARN", "inactive"),
    "2": ("OK", "OK"),
    "3": ("WARN", "occured"),
    "4": ("CRIT", "fail"),
}


def main(ctx, params):
    # DISCOVERY MODE: always yield exactly one service for this check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []}
            ]},
        }

    # CHECK MODE: gather backup status via SNMP (single service, item="")
    # Use snmpwalk-style command: snmpget -Oqv -v2c -c <community> <host> <oid>
    # We'll run two separate snmpget commands for each OID
    status_oid = ORION_BACKUP_BASE + "." + OID_BACKUP_STATUS
    time_oid = ORION_BACKUP_BASE + "." + OID_BACKUP_TIME

    res_status = ctx.run(["snmpget", "-Oqv", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"), status_oid], mutates=False)
    res_time = ctx.run(["snmpget", "-Oqv", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"), time_oid], mutates=False)

    # Verify responses
    if res_status.rc != 0 or res_time.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract values
    backup_status_raw = res_status.stdout.strip()
    backup_time_raw = res_time.stdout.strip()

    # Validate status code and map
    if backup_status_raw not in STATUS_MAP:
        return {
            "changed": False,
            "msg": "unknown backup status: " + backup_status_raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_readable, _ = STATUS_MAP[backup_status_raw]
    # Note: the original code used map_states[backup_time_status][0] but then accessed [1] for readable
    # We need to fix the indexing: map_states[status_code] returns (State, str)
    state_key, state_readable = STATUS_MAP[backup_status_raw]

    # Format message per Checkmk style
    msg = "Status: " + state_readable + ", Expected time: " + backup_time_raw + " minutes"

    # Map to Checkmk states (OK=0, WARN=1, CRIT=2)
    state_map = {"OK": "OK", "WARN": "WARN", "CRIT": "CRIT"}
    state = state_map.get(state_key, "UNKNOWN")

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
