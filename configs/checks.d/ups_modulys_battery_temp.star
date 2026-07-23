# Top-level helper to parse SNMP OID lines (format: "<oid> = <type>: <value>")
def _parse_snmp_line(line):
    if line.find("=") == -1:
        return None, None
    parts = line.split("=", 1)
    if len(parts) != 2:
        return None, None
    oid_part = parts[0].strip()
    value_part = parts[1].strip()
    colon_pos = value_part.find(":")
    if colon_pos == -1:
        return oid_part, ""
    # Strip type prefix (e.g., "INTEGER:", "Gauge32:", "Integer32:", etc.)
    if colon_pos + 1 < len(value_part):
        value = value_part[colon_pos + 1:].strip()
    else:
        value = ""
    return oid_part, value


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.2254.2.4.7"
        # Fetch required OIDs in one walk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1", base_oid + ".4", base_oid + ".5", base_oid + ".8", base_oid + ".9"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Map OID suffix to parsed value
        values = {}
        lines = res.stdout.splitlines()
        for i in range(len(lines)):
            line = lines[i]
            oid_s, val = _parse_snmp_line(line.strip())
            if oid_s == None:
                continue
            # Extract suffix from OID like ".1.3.6.1.4.1.2254.2.4.7.1"
            if oid_s.startswith(base_oid + "."):
                suffix = oid_s[len(base_oid) + 1:]
                values[suffix] = val

        # Require all 5 values to exist for a valid section
        required = ["1", "4", "5", "8", "9"]
        has_all = True
        for s in required:
            if values.get(s) == None:
                has_all = False
                break
        if not has_all:
            return {"changed": False, "msg": "missing sensor data", "data": {"discovery": []}}

        # Parse temperature (OID .9)
        temp_str = values["9"]
        if temp_str == "":
            return {"changed": False, "msg": "temperature not reported", "data": {"discovery": []}}
        
        temp = 0.0
        if temp_str.find(".") == -1 and temp_str.lstrip("-").isdigit():
            temp = float(int(temp_str))
        elif temp_str.replace(".", "", 1).lstrip("-").isdigit():
            temp = float(temp_str)
        else:
            return {"changed": False, "msg": "temperature not reported", "data": {"discovery": []}}

        # Single item "Battery"
        return {
            "changed": False,
            "msg": "discovered 1 temperature item",
            "data": {
                "discovery": [
                    {"item": "Battery", "params": {}, "metrics": ["temp"]}
                ]
            },
        }

    # Check mode
    item = params.get("item", "")
    if item != "Battery":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.2254.2.4.7"

    # Fetch only the temperature OID (.9) — same OID used in discovery
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".9"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp = None
    lines = res.stdout.splitlines()
    for i in range(len(lines)):
        line = lines[i]
        _, val = _parse_snmp_line(line.strip())
        if val == "":
            continue
        # Parse float safely
        temp_str = val
        if temp_str.find(".") == -1 and temp_str.lstrip("-").isdigit():
            temp = float(int(temp_str))
        elif temp_str.replace(".", "", 1).lstrip("-").isdigit():
            temp = float(temp_str)
        break

    if temp == None:
        return {
            "changed": False,
            "msg": "temperature not reported",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply temperature thresholds using Checkmk defaults
    # Checkmk uses "temperature" ruleset with defaults: warn=25.0, crit=30.0
    warn_val = params.get("warn", 25.0)
    crit_val = params.get("crit", 30.0)

    # State logic: upper thresholds
    state = "CRIT" if temp >= crit_val else ("WARN" if temp >= warn_val else "OK")
    status = "OK" if state == "OK" else ("WARN" if state == "WARN" else "CRIT")

    # Build message like Checkmk: "Battery 28.5 °C"
    msg = "Battery %f C" % temp
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": status,
            "metrics": {"temp": temp},
            "details": ""
        }
    }