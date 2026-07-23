# Top-level constants
DEFAULT_WARN = 40.0
DEFAULT_CRIT = 46.0
OID_BASE = ".1.3.6.1.4.1.4998.1.1.10.1.4.2.1"
OID_NAME = OID_BASE + ".3"
OID_TEMP = OID_BASE + ".29"
SYS_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_OID_VALUE = ".1.3.6.1.4.1.4998.2.1"


def _parse_snmp_output(output_lines):
    """Parse snmpwalk output lines into list of (name, temp) tuples."""
    result = []
    name_map = {}
    temp_map = {}
    for line in output_lines:
        line = line.strip()
        if not line:
            continue
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if oid_part.startswith(OID_NAME + "."):
            suffix = oid_part[len(OID_NAME) + 1:]
            name = value_part
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1]
            name_map[suffix] = name
        elif oid_part.startswith(OID_TEMP + "."):
            suffix = oid_part[len(OID_TEMP) + 1:]
            temp_str = value_part
            if temp_str.startswith("INTEGER:"):
                temp_str = temp_str[8:].strip()
            if temp_str.isdigit() or (temp_str.startswith('-') and temp_str[1:].isdigit()):
                temp_int = int(temp_str)
            else:
                temp_int = 999
            temp_map[suffix] = temp_int

    for suffix in name_map:
        if suffix in temp_map:
            name = name_map[suffix]
            temp = temp_map[suffix]
            result.append((name, temp))
    for suffix in temp_map:
        if suffix not in name_map:
            result.append(("", temp_map[suffix]))
    return result


def main(ctx, params):
    if params.get("_discover"):
        sys_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                           params.get("host", "localhost"), SYS_OID], mutates=False)
        if sys_res.rc != 0 or sys_res.stdout.find(DETECT_OID_VALUE) == -1:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                            params.get("host", "localhost"), OID_NAME], mutates=False)
        temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                            params.get("host", "localhost"), OID_TEMP], mutates=False)
        if name_res.rc != 0 or temp_res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        name_lines = name_res.stdout.splitlines()
        temp_lines = temp_res.stdout.splitlines()
        all_lines = name_lines + temp_lines
        section = _parse_snmp_output(all_lines)

        items = []
        for name, temp in section:
            if temp != 999:
                items.append({"item": name, "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)},
                              "metrics": ["temp"]})
        return {"changed": False, "msg": "discovered %d modules" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    warn, crit = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))

    sys_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), SYS_OID], mutates=False)
    if sys_res.rc != 0 or sys_res.stdout.find(DETECT_OID_VALUE) == -1:
        return {"changed": False, "msg": "device not an Arris CMTS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), OID_NAME], mutates=False)
    temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), OID_TEMP], mutates=False)
    if name_res.rc != 0 or temp_res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    all_lines = name_res.stdout.splitlines() + temp_res.stdout.splitlines()
    section = _parse_snmp_output(all_lines)

    for name, temp in section:
        if name == item:
            temp_val = float(temp)
            if temp_val >= crit:
                state = "CRIT"
                msg = "Temperature %s: %f °C (warn at %f °C, crit at %f °C)" % (item, temp_val, warn, crit)
            elif temp_val >= warn:
                state = "WARN"
                msg = "Temperature %s: %f °C (warn at %f °C, crit at %f °C)" % (item, temp_val, warn, crit)
            else:
                state = "OK"
                msg = "Temperature %s: %f °C" % (item, temp_val)
            return {"changed": False, "msg": msg,
                    "data": {"state": state, "metrics": {"temp": temp_val}, "details": ""}}

    return {"changed": False, "msg": "Sensor not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
