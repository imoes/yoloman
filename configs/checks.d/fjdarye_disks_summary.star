# ===== Starlark check: checkmk.fjdarye_disks_summary =====
# Disk summary for Fujitsu FJDARY-E storage systems
# This check monitors the summary state of disks via SNMP.

# Status mapping: string status code -> (state_str, state_text)
DISK_STATUS = {
    "1": ("ok", "available"),
    "2": ("crit", "broken"),
    "3": ("warn", "notavailable"),
    "4": ("warn", "notsupported"),
    "5": ("ok", "present"),
    "6": ("warn", "readying"),
    "7": ("warn", "recovering"),
    "64": ("warn", "partbroken"),
    "65": ("warn", "spare"),
    "66": ("ok", "formatting"),
    "67": ("ok", "unformated"),
    "68": ("warn", "notexist"),
    "69": ("warn", "copying"),
}

# Map device OID to correct disk OID suffix
def _get_disk_oid_for_device(device_oid):
    if device_oid == ".1.3.6.1.4.1.211.1.21.1.60" or device_oid == ".1.3.6.1.4.1.211.1.21.1.101":
        return ".2.12.2.1"
    if device_oid == ".1.3.6.1.4.1.211.1.21.1.100" or device_oid == ".1.3.6.1.4.1.211.1.21.1.150" or device_oid == ".1.3.6.1.4.1.211.1.21.1.153":
        return ".2.19.2.1"
    return ""

# Detect supported devices by checking system OID (sysObjectID)
def _get_device_oid(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return ""
    line = res.stdout.strip()
    # Format: OID = STRING: "..." or OID = OID: ".x.y.z"
    idx = line.find(" = ")
    if idx == -1:
        return ""
    value = line[idx + 3:].strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    if not value.startswith("."):
        return ""
    return value

# Parse a snmpwalk line: ".1.2.3.4 = INTEGER: 123" -> (oid_tail, value)
def _parse_snmp_line(line):
    idx = line.find(" = ")
    if idx == -1:
        return "", ""
    oid_part = line[:idx]
    val_part = line[idx + 3:].strip()
    parts = oid_part.split(".")
    if len(parts) < 2:
        return "", ""
    tail = parts[-1]
    if val_part.startswith("INTEGER: "):
        val = val_part[len("INTEGER: "):]
        return tail, val
    elif val_part.startswith("STRING: "):
        val = val_part[len("STRING: "):].strip('"')
        return tail, val
    else:
        return tail, val_part

# Main function
def main(ctx, params):
    # Get connection parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        device_oid = _get_device_oid(ctx, community, host)
        disk_base = _get_disk_oid_for_device(device_oid)
        if disk_base == "":
            return {"changed": False, "msg": "no supported Fujitsu device detected",
                    "data": {"discovery": []}}
        base = device_oid + disk_base
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": []}}

        state_counts = {}
        for line in res.stdout.splitlines():
            tail, val = _parse_snmp_line(line)
            if tail == "":
                continue
            if tail == "1":
                index = val
            elif tail == "3":
                status = val
                _, state_txt = DISK_STATUS.get(status, ("unknown", "unknown[" + status + "]"))
                # Exclude disk in state 3 (notavailable) from discovery
                if status != "3":
                    state_counts[state_txt] = state_counts.get(state_txt, 0) + 1

        # If no disks found, return empty discovery
        if len(state_counts) == 0:
            return {"changed": False, "msg": "no disks found",
                    "data": {"discovery": []}}

        # Yield single service for disk summary
        return {
            "changed": False,
            "msg": "discovered disk summary",
            "data": {"discovery": [{"item": "", "params": state_counts, "metrics": []}]}
        }

    # CHECK MODE (non-discovery)
    device_oid = _get_device_oid(ctx, community, host)
    disk_base = _get_disk_oid_for_device(device_oid)
    if disk_base == "":
        return {
            "changed": False,
            "msg": "no supported Fujitsu device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base = device_oid + disk_base
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Count disk states (excluding notavailable)
    state_counts = {}
    current_states = []
    for line in res.stdout.splitlines():
        tail, val = _parse_snmp_line(line)
        if tail == "":
            continue
        if tail == "1":
            index = val
        elif tail == "3":
            status = val
            _, state_txt = DISK_STATUS.get(status, ("unknown", "unknown[" + status + "]"))
            if status != "3":
                state_counts[state_txt] = state_counts.get(state_txt, 0) + 1
            current_states.append(state_txt)

    # Compute summary text
    summary_parts = []
    for key in sorted(state_counts.keys()):
        summary_parts.append(key.title() + ": " + str(state_counts[key]))
    current_disks_states_text = ", ".join(summary_parts)

    # If use_device_states is set, take worst state of all disks
    if params.get("use_device_states", False):
        worst = "ok"
        for s in current_states:
            if s == "broken" or s == "partbroken":
                worst = "crit"
                break
            elif s in ["notavailable", "notsupported", "readying", "recovering", "notexist", "copying"]:
                if worst == "ok":
                    worst = "warn"
            elif s == "spare":
                if worst == "ok":
                    worst = "warn"
        if worst == "crit":
            state = "CRIT"
        elif worst == "warn":
            state = "WARN"
        else:
            state = "OK"
        msg = current_disks_states_text + " (using device states)"
        return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": ""}}

    # Compare current state counts with expected (params excluding 'use_device_states')
    expected_state = {}
    for k, v in params.items():
        if k != "use_device_states":
            expected_state[k] = v

    if state_counts == expected_state:
        return {"changed": False, "msg": current_disks_states_text,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    expected_text = ""
    for key in sorted(expected_state.keys()):
        expected_text += key.title() + ": " + str(expected_state[key]) + ", "
    if len(expected_text) > 0:
        expected_text = expected_text[:-2]
    summary = current_disks_states_text + " (expected: " + expected_text + ")"

    # Check if any expected state count is not met
    for exp_state_name, exp_count in expected_state.items():
        if state_counts.get(exp_state_name, 0) < exp_count:
            return {"changed": False, "msg": summary,
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": summary,
            "data": {"state": "WARN", "metrics": {}, "details": ""}}
