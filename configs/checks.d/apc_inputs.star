# ===== module-level constants =====
OID_BASE = ".1.3.6.1.4.1.318.1.1.25.2.2.1"
OID_NAME = OID_BASE + ".3"
OID_LOCATION = OID_BASE + ".4"
OID_STATE = OID_BASE + ".5"
OID_ALARM_STATUS = OID_BASE + ".6"

# SNMP OID mapping for states and alarm statuses
STATES_MAP = {
    "1": "closed",
    "2": "open",
    "3": "disabled",
    "4": "not applicable",
}

ALARM_STATES_MAP = {
    "1": "normal",
    "2": "warning",
    "3": "critical",
    "4": "not applicable",
}

# Detect OID for ATS devices (same logic as DETECT in source)
SYSOID = ".1.3.6.1.2.1.1.2.0"
DETECT_ATS_OIDS = [
    ".1.3.6.1.4.1.318.1.3.11",
    ".1.3.6.1.4.1.318.1.3.32",
    ".1.3.6.1.4.1.318.1.3.38",
]

# ===== helper: parse snmpwalk output =====
def _parse_snmp_line(line):
    # Format: OID = TYPE: value  or  OID::name = TYPE: value
    # Example: .1.3.6.1.4.1.318.1.1.25.2.2.1.3.1 = STRING: "Inlet 1"
    if "=" not in line:
        return None, None
    left, right = line.split("=", 1)
    oid_part = left.strip()
    value_part = right.strip()
    
    # Extract value after colon or space after type
    # e.g., "STRING: \"Inlet 1\"" -> "\"Inlet 1\""
    if ":" in value_part:
        value = value_part.split(":", 1)[1].strip()
    else:
        value = value_part
    # Strip quotes if present
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    return oid_part, value


def _get_sysoid(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, SYSOID], mutates=False)
    if res.rc != 0:
        return ""
    line = res.stdout.strip()
    _, value = _parse_snmp_line(line)
    return value.strip() if value else ""


def _is_ats_device(ctx, host, community):
    sysoid = _get_sysoid(ctx, host, community)
    if sysoid == "":
        return False
    for oid in DETECT_ATS_OIDS:
        if sysoid == oid:
            return True
    # Also match if sysoid starts with .1.3.6.1.4.1.318 (DETECT = startswith)
    if sysoid.startswith(".1.3.6.1.4.1.318"):
        return True
    return False


def _walk_oid(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    lines = res.stdout.splitlines()
    out = []
    for line in lines:
        if line.strip() == "":
            continue
        oid, value = _parse_snmp_line(line)
        if oid != None and value != None:
            # Extract numeric suffix (last number after last dot)
            # e.g., .1.3.6.1.4.1.318.1.1.25.2.2.1.3.1 -> "1"
            suffix = oid.rsplit(".", 1)[-1] if "." in oid else oid
            out.append((oid, suffix, value))
    return out


def _gather_inputs(ctx, host, community):
    # Gather all four columns in parallel (same index → same row)
    names = _walk_oid(ctx, host, community, OID_NAME)
    locations = _walk_oid(ctx, host, community, OID_LOCATION)
    states = _walk_oid(ctx, host, community, OID_STATE)
    alarm_statuses = _walk_oid(ctx, host, community, OID_ALARM_STATUS)

    # Build map by suffix (index) for each column
    name_map = {suffix: value for _, suffix, value in names}
    loc_map = {suffix: value for _, suffix, value in locations}
    state_map = {suffix: value for _, suffix, value in states}
    alarm_map = {suffix: value for _, suffix, value in alarm_statuses}

    # Collect all suffixes
    all_suffixes = set()
    for _, suffix, _ in names + locations + states + alarm_statuses:
        all_suffixes.add(suffix)

    # Build section rows
    section = []
    for suffix in sorted(all_suffixes, key=lambda x: int(x) if x.isdigit() else 0):
        name = name_map.get(suffix, "")
        location = loc_map.get(suffix, "")
        state = state_map.get(suffix, "")
        alarm_status = alarm_map.get(suffix, "")

        # Skip if no name (empty item) — ensure at least name exists
        if name == "":
            continue
        # Only discover if state not in ["3", "4"] (same as source)
        if state in ["3", "4"]:
            continue

        section.append([name, location, state, alarm_status])

    return section


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode
    if params.get("_discover"):
        if not _is_ats_device(ctx, host, community):
            return {"changed": False, "msg": "not an ATS device", "data": {"discovery": []}}

        section = _gather_inputs(ctx, host, community)
        discovery_list = []
        for line in section:
            name = line[0]
            state = line[2]
            if state not in ["3", "4"]:
                discovery_list.append({
                    "item": name,
                    "params": {"state": state},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d inputs" % len(discovery_list),
            "data": {"discovery": discovery_list},
        }

    # Check mode (single item)
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _is_ats_device(ctx, host, community):
        return {
            "changed": False,
            "msg": "not an ATS device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _gather_inputs(ctx, host, community)
    found = False
    for name, location, state, alarm_status in section:
        if name == item:
            found = True
            # Determine check_state from alarm_status
            check_state = "UNKNOWN"
            if alarm_status in ["2", "4"]:
                check_state = "WARN"
            elif alarm_status == "3":
                check_state = "CRIT"
            elif alarm_status == "1":
                check_state = "OK"

            # Build summary
            alarm_desc = ALARM_STATES_MAP.get(alarm_status, "unknown")
            msg = "State is %s" % alarm_desc

            # Check for port state change
            saved_state = params.get("state", "")
            if saved_state != "" and saved_state != state:
                saved_desc = STATES_MAP.get(saved_state, "unknown")
                curr_desc = STATES_MAP.get(state, "unknown")
                msg += "; Port state Change from %s to %s" % (saved_desc, curr_desc)
                # If alarm_status was OK, upgrade to WARN due to state change
                if alarm_status == "1":
                    check_state = "WARN"

            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": check_state,
                    "metrics": {},
                    "details": "",
                },
            }

    # Item not found
    return {
        "changed": False,
        "msg": "input not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }
