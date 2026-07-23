# ===== Starlark check module: checkmk.quantum_libsmall_status =====
# Tape library status (read-only SNMP probe)
# No mutation, no state changes — gather status and report verdicts.

DEVICE_TYPE_MAP = {
    "1": "Power",
    "2": "Cooling",
    "3": "Control",
    "4": "Connectivity",
    "5": "Robotics",
    "6": "Media",
    "7": "Drive",
    "8": "Operator action request",
}

RAS_STATUS_MAP = {
    "1": ("OK", "good"),
    "2": ("CRIT", "failed"),
    "3": ("CRIT", "degraded"),
    "4": ("WARN", "warning"),
    "5": ("OK", "informational"),
    "6": ("UNKNOWN", "unknown"),
    "7": ("UNKNOWN", "invalid"),
}

OPNEED_STATUS_MAP = {
    "0": ("OK", "no"),
    "1": ("CRIT", "yes"),
    "2": ("OK", "no"),
}


def main(ctx, params):
    # Discovery mode: enumerate items (here: one service only, item=None)
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-On",
            "-v2c",
            "-c",
            "public",
            "localhost",
            ".1.3.6.1.4.1.3697.1.10.10.1.15.10",
            ".1.3.6.1.4.1.3764.1.10.10.12",
        ], mutates=False)
        # Detect presence by checking for any output lines
        has_data = False
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "" or not stripped.startswith("."):
                continue
            has_data = True
            break
        if has_data:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {"changed": False, "msg": "no device detected", "data": {"discovery": []}}

    # Check mode: single service (item="" or missing)
    res = ctx.run([
        "snmpwalk",
        "-On",
        "-v2c",
        "-c",
        "public",
        "localhost",
        ".1.3.6.1.4.1.3697.1.10.10.1.15.10",
        ".1.3.6.1.4.1.3764.1.10.10.12",
    ], mutates=False)

    # Parse: oidend.dev_state tuples from output
    # Each line: OID.oidend = value
    entries = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.find("=") == -1:
            continue
        left = stripped.split("=")[0].strip()
        right = stripped.split("=")[1].strip().lstrip(" ").lstrip("INTEGER: ").lstrip("STRING: ")
        # Extract OID end: after last dot
        if left.rfind(".") != -1:
            oidend = left[left.rfind(".") + 1:]
        else:
            oidend = ""
        dev_type = DEVICE_TYPE_MAP.get(oidend.split(".")[0])
        if dev_type == None or not right:
            continue
        entries.append((dev_type, right))

    if not entries:
        return {
            "changed": False,
            "msg": "no device status data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Aggregate worst state across devices
    worst_state = "OK"
    details_lines = []
    for dev_type, dev_state in entries:
        if dev_type == "Operator action request":
            state, readable = OPNEED_STATUS_MAP.get(
                dev_state, ("UNKNOWN", "unknown[%s]" % dev_state)
            )
        else:
            state, readable = RAS_STATUS_MAP.get(
                dev_state, ("UNKNOWN", "unknown[%s]" % dev_state)
            )
        details_lines.append("%s: %s" % (dev_type, readable))
        # State priority: CRIT > WARN > UNKNOWN > OK
        if state == "CRIT":
            worst_state = "CRIT"
        elif state == "WARN" and worst_state not in ("CRIT",):
            worst_state = "WARN"
        elif state == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"

    summary = "Tape library status: " + worst_state
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst_state,
            "metrics": {},
            "details": "\n".join(details_lines),
        },
    }
