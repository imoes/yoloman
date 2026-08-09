def _render_bytes(num_bytes):
    """Render a byte count like Checkmk's render.bytes()."""
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    size = float(num_bytes)
    idx = 0
    # Use thresholds that match Checkmk's render.bytes behavior
    thresholds = [1, 1024, 1024 * 1024, 1024 * 1024 * 1024,
                  1024 * 1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024 * 1024]
    for i in range(len(thresholds) - 1):
        if size < thresholds[i + 1] or i == len(thresholds) - 2:
            idx = i
            break
    val = size / float(thresholds[idx]) if thresholds[idx] > 0 else size
    if idx == 0:
        return str(int(size)) + " " + units[idx]
    return "%f %s" % (val, units[idx])


# map_luntype: mode code -> (state_code, readable)
MAP_LUNTYPE = {
    "0": (2, "unspecified"),
    "1": (1, "simple"),
    "2": (0, "mirror"),
    "3": (1, "stripe"),
    "4": (0, "lun"),
    "5": (0, "stripeParity"),
    "6": (0, "stripeDualParity"),
    "7": (0, "mirrorStripe"),
    "8": (0, "stripeParityStripe"),
    "9": (0, "stripeDualParityStripe"),
}

# MAP_OPERABILITY: status code -> (state_code, readable)
MAP_OPERABILITY = {
    "0": (2, "unknown"),
    "1": (0, "operable"),
    "2": (2, "inoperable"),
    "3": (2, "degraded"),
    "4": (1, "poweredOff"),
    "5": (2, "powerProblem"),
    "6": (0, "removed"),
    "7": (2, "voltageProblem"),
    "8": (2, "thermalProblem"),
    "9": (1, "performanceProblem"),
    "10": (1, "accessibilityProblem"),
    "11": (1, "identityUnestablishable"),
    "12": (2, "biosPostTimeout"),
    "13": (1, "disabled"),
    "14": (1, "malformedFru"),
    "51": (1, "fabricConnProblem"),
    "52": (1, "fabricUnsupportedConn"),
    "81": (1, "config"),
    "82": (2, "equipmentProblem"),
    "83": (2, "decomissioning"),
    "84": (1, "chassisLimitExceeded"),
    "100": (1, "notSupported"),
    "101": (1, "discovery"),
    "102": (2, "discoveryFailed"),
    "103": (1, "identify"),
    "104": (2, "postFailure"),
    "105": (1, "upgradeProblem"),
    "106": (1, "peerCommProblem"),
    "107": (0, "autoUpgrade"),
    "108": (1, "linkActivateBlocked"),
}

STATE_NAMES = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
    3: "UNKNOWN",
}

# Cisco UCS sysObjectID suffixes that this check applies to
CISCO_UCS_SYSOBJECTS = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]

# LUN OIDs under the base .1.3.6.1.4.1.9.9.719.1.45.8.1
OID_LUN_BASE = ".1.3.6.1.4.1.9.9.719.1.45.8.1"
OID_LUN_MODE = "14"   # cucsStorageLocalLunType
OID_LUN_SIZE = "13"   # cucsStorageLocalLunSize
OID_LUN_STATUS = "9"  # cucsStorageLocalLunOperability


def _get_sysobject_id(ctx, params):
    """Fetch sysObjectID.0 to detect Cisco UCS."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, params, oid):
    """Walk an OID table, returning list of (oid, value) tuples."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 2:
        return None
    rows = []
    for line in res.stdout.splitlines():
        # Format: "<oid> <value>" — value may contain spaces for STRING values
        space_idx = line.find(" ")
        if space_idx < 0:
            continue
        full_oid = line[:space_idx]
        value = line[space_idx + 1:]
        rows.append((full_oid, value))
    return rows


def _snmpget_multi(ctx, params, oid):
    """Get a single scalar value, returns None if not found."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        sysobject = _get_sysobject_id(ctx, params)
        if sysobject == None:
            # Not reachable or not installed — no services
            return {"changed": False, "msg": "device not reachable", "data": {"discovery": []}}
        if sysobject not in CISCO_UCS_SYSOBJECTS:
            return {"changed": False, "msg": "not a Cisco UCS device", "data": {"discovery": []}}
        # Walk the LUN table to see if there are any LUNs
        rows = _snmpwalk(ctx, params, OID_LUN_BASE)
        if rows == None:
            return {"changed": False, "msg": "no LUNs found", "data": {"discovery": []}}
        if len(rows) == 0:
            return {"changed": False, "msg": "no LUNs found", "data": {"discovery": []}}
        # This is a single-service check — yield one Service with no item
        return {
            "changed": False,
            "msg": "discovered LUN service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode — single service, no item
    sysobject = _get_sysobject_id(ctx, params)
    if sysobject == None:
        return {
            "changed": False,
            "msg": "device not reachable via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if sysobject not in CISCO_UCS_SYSOBJECTS:
        return {
            "changed": False,
            "msg": "not a Cisco UCS device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the LUN data: type (mode), size, and operability (status)
    # The SNMPTree fetches OIDs 14, 13, 9 under the base
    # We get the first row's values
    mode = _snmpget_multi(ctx, params, OID_LUN_BASE + "." + OID_LUN_MODE)
    size = _snmpget_multi(ctx, params, OID_LUN_BASE + "." + OID_LUN_SIZE)
    status = _snmpget_multi(ctx, params, OID_LUN_BASE + "." + OID_LUN_STATUS)

    if mode == None and size == None and status == None:
        return {
            "changed": False,
            "msg": "no LUN data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Resolve status -> operability state
    state, state_readable = MAP_OPERABILITY.get(
        status, (3, "Unknown, status code %s" % status)
    )
    # Resolve mode -> lun type state
    mode_state, mode_state_readable = MAP_LUNTYPE.get(
        mode, (3, "Unknown, status code %s" % mode)
    )

    # size is in MB
    size_mb = 0
    try_value = size
    if try_value != None and try_value.isdigit():
        size_mb = int(try_value)
    size_bytes = size_mb * 1024 * 1024
    size_readable = _render_bytes(size_bytes)

    # Build the result — Checkmk yields 3 Result objects; we combine into
    # the worst state among them
    worst_state = 0
    if state > worst_state:
        worst_state = state
    if mode_state > worst_state:
        worst_state = mode_state
    # Size result is always OK

    summary_parts = []
    summary_parts.append("Status: %s" % state_readable)
    summary_parts.append("Size: %s" % size_readable)
    summary_parts.append("Mode: %s" % mode_state_readable)

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": STATE_NAMES.get(worst_state, "UNKNOWN"),
            "metrics": {"size": size_bytes},
            "details": "Status: %s | Mode: %s | Size: %s" % (
                state_readable, mode_state_readable, size_readable
            ),
        },
    }