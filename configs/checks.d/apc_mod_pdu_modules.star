# Top-level helper functions
def _savefloat(s):
    if s == None:
        return 0.0
    s = s.strip()
    if s == "":
        return 0.0
    # Check if it's an integer (including negative)
    if s.startswith("-"):
        if s[1:] == "" or not s[1:].isdigit():
            return 0.0
        return float(int(s))
    if s.isdigit():
        return float(int(s))
    # Handle simple float with decimal point
    if "." in s:
        parts = s.split(".", 1)
        if len(parts) == 2:
            int_part = parts[0]
            dec_part = parts[1]
            # Validate integer part (may be negative)
            if int_part.startswith("-"):
                int_part = int_part[1:]
                if int_part == "" or not int_part.isdigit():
                    return 0.0
                sign = -1.0
            else:
                if int_part == "" or not int_part.isdigit():
                    return 0.0
                sign = 1.0
            # Validate decimal part
            if dec_part == "" or not dec_part.isdigit():
                return 0.0
            return sign * (float(int(int_part)) + float("0." + dec_part))
    return 0.0

def _saveint(s):
    if s == None:
        return 0
    s = s.strip()
    if s == "":
        return 0
    if s.startswith("-"):
        if len(s) > 1 and s[1:].isdigit():
            return int(s)
        return 0
    if s.isdigit():
        return int(s)
    return 0

# Status mapping per MIB
_APC_STATES = {
    1: "normal",
    2: "warning",
    3: "notPresent",
    6: "unknown",
}

def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.318.1.1.22.2.6.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse snmpwalk output lines
        names = {}
        statuses = {}
        powers = {}

        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()

            if oid_full.endswith(".4.1"):
                names[1] = value.strip('"')
            elif oid_full.endswith(".6.1"):
                statuses[1] = _saveint(value)
            elif oid_full.endswith(".20.1"):
                powers[1] = _savefloat(value)

        # Extract module name if available
        module_name = names.get(1, "")
        if module_name == "":
            module_name = "1"

        # Build discovery list
        discovery = []
        if module_name != "":
            discovery.append({
                "item": module_name,
                "params": {},
                "metrics": ["power"]
            })

        return {
            "changed": False,
            "msg": "discovered %d modules" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch all module data via snmpwalk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.318.1.1.22.2.6.1"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpwalk output into a lookup table
    modules = []
    current_name = ""
    current_status = 0
    current_power = 0.0

    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()

        if oid_full.endswith(".4.1"):
            current_name = value.strip('"')
        elif oid_full.endswith(".6.1"):
            current_status = _saveint(value)
        elif oid_full.endswith(".20.1"):
            current_power = _savefloat(value)
            # Complete one module record
            if current_name != "":
                modules.append([current_name, str(current_status), str(current_power)])
                current_name = ""
                current_status = 0
                current_power = 0.0

    # Search for requested item
    for name, status_r, current_power_r in modules:
        if name == item:
            status = _saveint(status_r)
            power_kw = _savefloat(current_power_r) / 10.0
            status_str = _APC_STATES.get(status, "unknown")
            message = "Status %s, current: %f kW" % (status_str, power_kw)

            # Power metrics in Watts
            power_w = power_kw * 1000.0

            # Determine state
            if status == 2:
                state = "WARN"
            elif status in [3, 6]:
                state = "CRIT"
            elif status == 1:
                state = "OK"
            else:
                state = "UNKNOWN"

            return {
                "changed": False,
                "msg": message,
                "data": {
                    "state": state,
                    "metrics": {"power": power_w},
                    "details": ""
                }
            }

    # Item not found
    return {
        "changed": False,
        "msg": "module not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }