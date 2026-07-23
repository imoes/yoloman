# ===== Starlark check module: cisco_stack =====
# Translation of Checkmk check: checkmk.cisco_stack
# Read-only: gathers SNMP data and reports switch stack status.

def main(ctx, params):
    # SNMP constants
    SNMP_BASE = ".1.3.6.1.4.1.9.9.500.1.2.1.1"
    OID_NUM = "1"
    OID_ROLE = "3"
    OID_STATE = "6"

    # State/role mapping (as in original Checkmk code)
    SWITCH_STATE_NAMES = {
        "1": "waiting",
        "2": "progressing",
        "3": "added",
        "4": "ready",
        "5": "sdmMismatch",
        "6": "verMismatch",
        "7": "featureMismatch",
        "8": "newMasterInit",
        "9": "provisioned",
        "10": "invalid",
        "11": "removed",
    }

    SWITCH_ROLE_NAMES = {
        "1": "master",
        "2": "member",
        "3": "notMember",
        "4": "standby",
    }

    # State -> state code mapping (OK=0, WARN=1, CRIT=2, UNKNOWN=3)
    STATE_CODE_MAP = {
        "waiting": 0,
        "progressing": 0,
        "added": 0,
        "ready": 0,
        "sdmMismatch": 1,
        "verMismatch": 1,
        "featureMismatch": 1,
        "newMasterInit": 0,
        "provisioned": 0,
        "invalid": 2,
        "removed": 2,
    }

    # State descriptions
    STATE_DESCRIPTIONS = {
        "waiting": "Waiting for other switches to come online",
        "progressing": "Master election or mismatch checks in progress",
        "added": "Added to stack",
        "ready": "Ready",
        "sdmMismatch": "SDM template mismatch",
        "verMismatch": "OS version mismatch",
        "featureMismatch": "Configured feature mismatch",
        "newMasterInit": "Waiting for new master initialization",
        "provisioned": "Not an active member of the stack",
        "invalid": "State machine in invalid state",
        "removed": "Removed from stack",
    }

    # Default threshold overrides (from check_default_parameters)
    default_levels = {
        "waiting": 0,
        "progressing": 0,
        "added": 0,
        "ready": 0,
        "sdmMismatch": 1,
        "verMismatch": 1,
        "featureMismatch": 1,
        "newMasterInit": 0,
        "provisioned": 0,
        "invalid": 2,
        "removed": 2,
    }

    # Apply discovered state overrides if present (e.g., params["state_levels"])
    state_levels = {}
    for k, v in default_levels.items():
        state_levels[k] = params.get(k, v)

    # Discovery mode: enumerate all switches
    if params.get("_discover"):
        # Walk cisco stack SNMP table
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            SNMP_BASE
        ], mutates=False)

        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        # Parse raw SNMP lines: ".1.3.6.1.4.1.9.9.500.1.2.1.1.1.1 = INTEGER: 1"
        # We need to extract per-switch triplets: (switch_num, role, state)
        # OID layout:
        #   .1.3.6.1.4.1.9.9.500.1.2.1.1.1.<switch_num> = INTEGER: switch_num
        #   .1.3.6.1.4.1.9.9.500.1.2.1.1.3.<switch_num> = INTEGER: role
        #   .1.3.6.1.4.1.9.9.500.1.2.1.1.6.<switch_num> = INTEGER: state

        # Build per-switch data by scanning all OIDs
        switches = {}  # switch_num -> {"role": role, "state": state}
        lines = res.stdout.splitlines()
        for line in lines:
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            # Extract OID base and suffix
            if not oid.startswith(SNMP_BASE + "."):
                continue
            suffix = oid[len(SNMP_BASE + "."):]
            # suffix looks like "1.1", "3.1", "6.1"
            idx = suffix.find(".")
            if idx == -1:
                continue
            oid_type = suffix[:idx]
            switch_num = suffix[idx+1:]
            # Only keep numeric switch_num
            if not switch_num.isdigit():
                continue
            switch_num = switch_num

            # Initialize switch entry if needed
            if switch_num not in switches:
                switches[switch_num] = {"role": None, "state": None}

            # Map type to field
            if oid_type == "1":
                # switch_num value
                switches[switch_num]["num"] = value
            elif oid_type == "3":
                # role
                switches[switch_num]["role"] = value
            elif oid_type == "6":
                # state
                switches[switch_num]["state"] = value

        # Build discovery list: one Service per switch
        out = []
        for num, data in switches.items():
            if data["state"] == None:
                continue
            state = SWITCH_STATE_NAMES.get(data["state"], "unknown")
            item = num
            out.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d switches" % len(out),
            "data": {"discovery": out}
        }

    # CHECK MODE
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch SNMP data (same as discovery)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse relevant OID values for this switch
    # We need to match .1.3.6.1.4.1.9.9.500.1.2.1.1.{1,3,6}.{item}
    wanted_prefix = SNMP_BASE + ".1." + item + " "
    wanted_prefix_role = SNMP_BASE + ".3." + item + " "
    wanted_prefix_state = SNMP_BASE + ".6." + item + " "

    role = None
    state = None
    lines = res.stdout.splitlines()
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()

        # Extract raw value (strip type prefix like "INTEGER: ")
        if ": " in value:
            value = value.split(": ", 1)[1]

        if oid.startswith(wanted_prefix_role):
            role = value
        elif oid.startswith(wanted_prefix_state):
            state = value

    # Map raw state/role
    switch_state = SWITCH_STATE_NAMES.get(state, "unknown")
    switch_role = SWITCH_ROLE_NAMES.get(role, "unknown")

    # Determine state code (OK/WARN/CRIT/UNKNOWN)
    state_code = STATE_CODE_MAP.get(switch_state, 3)
    # Override with user-provided level if defined
    if state in state_levels:
        state_code = state_levels[state]

    # Map state code to Checkmk state string
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_str = state_map.get(state_code, "UNKNOWN")

    # Build summary message
    description = STATE_DESCRIPTIONS.get(switch_state, "Unknown")
    summary = "Switch state: %s %s; Switch role: %s" % (description, switch_state, switch_role)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }
