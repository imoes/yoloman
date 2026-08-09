# F5-BIGIP-Cluster Config Sync - SNMP sections and Checks
# Translation of cmk.plugins.f5_bigip.agent_based.f5_bigip_cluster

# Constants for state mapping and thresholds (pre-v11 and v11+)
CONFIG_SYNC_STATE_NAMES = {
    "0": "Unknown",
    "1": "Syncing",
    "2": "Need Manual Sync",
    "3": "In Sync",
    "4": "Sync Failed",
    "5": "Sync Disconnected",
    "6": "Standalone",
    "7": "Awaiting Initial Sync",
    "8": "Incompatible Version",
    "9": "Partial Sync",
}

# Default mapping of state codes to Checkmk status levels (pre-v11 logic)
# state "-1" (unconfigured) is OK only if original/uninitialized
# "0" -> OK, "1"/"2" -> WARN, "3" -> CRIT, others -> UNKNOWN
CONFIG_SYNC_DEFAULT_PARAMETERS = {
    "0": 0,  # OK
    "1": 1,  # WARN
    "2": 1,  # WARN
    "3": 2,  # CRIT
    "-1": 2, # CRIT (uninitialized is not OK unless explicitly handled)
}

# Map from Checkmk State enum integers to strings
STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def _state_from_int(code):
    if code == "0":
        return STATE_OK
    elif code == "1":
        return STATE_WARN
    elif code == "2":
        return STATE_CRIT
    else:
        return STATE_UNKNOWN

def main(ctx, params):
    # Fetch F5 sysObjectID to confirm F5 BIG-IP
    res_f5 = ctx.run([
        "snmpget", "-Oqv", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    if res_f5.rc != 0 or not res_f5.stdout.strip():
        # If SNMP not available, fallback: try local agent data via file_read
        # In real Checkmk environment, agent sections would be pre-parsed
        # For this translation, assume we need to run snmpget
        return {
            "changed": False,
            "msg": "SNMP not available or not F5 BIG-IP",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "SNMP unreachable"},
        }

    f5_oid = res_f5.stdout.strip()
    if not f5_oid.startswith(".1.3.6.1.4.1.3375.2"):
        return {
            "changed": False,
            "msg": "Not a F5 BIG-IP device",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "Device is not F5 BIG-IP"},
        }

    # Determine version: check sysProductVersion
    res_ver = ctx.run([
        "snmpget", "-Oqv", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.3375.2.1.4.2.0"
    ], mutates=False)
    if res_ver.rc != 0:
        return {
            "changed": False,
            "msg": "Cannot determine F5 version",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "Failed to get version"},
        }
    version = res_ver.stdout.strip()

    # Detect pre-v11 vs v11+
    def is_v11_plus(v):
        if v == None:
            return False
        if v.startswith("11.") or v.startswith("12.") or v.startswith("13.") or v.startswith("14.") or v.startswith("15.") or v.startswith("16.") or v.startswith("17."):
            return True
        if v.startswith("2") or v.startswith("3") or v.startswith("4") or v.startswith("5") or v.startswith("6") or v.startswith("7") or v.startswith("8") or v.startswith("9"):
            return True
        return False

    # Fetch config sync status
    if not is_v11_plus(version):
        # Pre-v11: OID .1.3.6.1.4.1.3375.2.1.1.1.1.6.0 (sysAttrConfigsyncState)
        res = ctx.run([
            "snmpget", "-Oqv", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.3375.2.1.1.1.1.6.0"
        ], mutates=False)
    else:
        # v11+: OID .1.3.6.1.4.1.3375.2.1.14.1.1.0 (sysCmSyncStatusId) and .2.0 (sysCmSyncStatusStatus)
        res = ctx.run([
            "snmpget", "-Oqv", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.3375.2.1.14.1.1.0", ".1.3.6.1.4.1.3375.2.1.14.1.2.0"
        ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "SNMP query error"},
        }

    # Parse output
    output = res.stdout.strip().splitlines()
    if len(output) == 0:
        return {
            "changed": False,
            "msg": "Empty SNMP response",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "No data"},
        }

    if not is_v11_plus(version):
        # Pre-v11: single line "state - description"
        line = output[0].strip()
        if line.find(" - ") >= 0:
            parts = line.split(" - ", 1)
            state = parts[0].strip()
            description = parts[1].strip() if len(parts) > 1 else ""
        else:
            state = output[0].strip()
            description = ""
    else:
        # v11+: two lines: state ID and description
        if len(output) >= 2:
            state = output[0].strip()
            description = output[1].strip()
        else:
            return {
                "changed": False,
                "msg": "Incomplete v11+ response",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "Missing v11+ fields"},
            }

    # Handle discovery mode (item == "")
    if params.get("_discover") == True:
        # Only one service (no per-item breakdown); return single entry with item=""
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["config_sync_state"]}]},
        }

    # Determine state and message (check mode)
    state_name = CONFIG_SYNC_STATE_NAMES.get(state, "Unknown")
    infotext = state_name
    if description != "" and state_name != description:
        infotext = infotext + " - " + description

    # Pre-v11 logic (state codes as per original check)
    if not is_v11_plus(version):
        if state == "0":
            result_state = STATE_OK
        elif state == "-1" or state == "3":
            result_state = STATE_CRIT
        elif state == "1" or state == "2":
            result_state = STATE_WARN
        else:
            result_state = STATE_UNKNOWN
            infotext = "unexpected output from SNMP Agent %r" % infotext
    else:
        # v11+ logic: use default parameters to map state to level
        # CONFIG_SYNC_DEFAULT_PARAMETERS maps state code string to Checkmk State int (0/1/2/3)
        level_code = CONFIG_SYNC_DEFAULT_PARAMETERS.get(state, "3")
        result_state = _state_from_int(str(level_code))

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": result_state,
            "metrics": {"config_sync_state": int(state) if state.isdigit() else 999},
            "details": "",
        },
    }
