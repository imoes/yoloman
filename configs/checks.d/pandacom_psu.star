def _snmpget(ctx, oid, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()

def main(ctx, params):
    MAP_PSU_TYPE = {
        "0": "type not configured",
        "1": "230 V AC 75 W",
        "2": "230 V AC 160 W",
        "3": "48 V DC 75 W",
        "4": "48 V DC 150 W",
        "5": "48 V DC 60 W",
        "6": "230 V AC 60 W",
        "7": "48 V DC 250 W",
        "8": "230 V AC 250 W",
        "9": "48 V DC 1100 W",
        "10": "230 V AC 1100 W",
        "255": "type not available",
        "65025": "48 V DC 60 W",
        "65026": "230 V AC 60 W",
        "65027": "48 V DC 250 W",
        "65028": "230 V AC 250 W",
        "65029": "48 V DC 1100 W",
        "65030": "230 V AC 1100 W",
        "65031": "48 V DC 1100 W 1 UH",
        "65032": "230 V AC 1100 W 1 UH",
        "65033": "230 V AC 1200W 1 UH",
    }
    MAP_PSU_STATE = {
        "0": (3, "not installed"),
        "1": (2, "fail"),
        "2": (1, "temperature warning"),
        "3": (0, "pass"),
        "255": (3, "not available"),
    }
    STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

    OID_BASE = ".1.3.6.1.4.1.3652.3.2"
    community = params.get("community", "public")
    host = params.get("host", params.get("hostname", "localhost"))

    sys_oid = _snmpget(ctx, ".1.3.6.1.2.1.1.2.0", community, host)
    if sys_oid == None or sys_oid.find(OID_BASE) != 0:
        return {
            "changed": False,
            "msg": "Pandacom device not found or wrong sysOID",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    values = {}
    indices = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
    for idx in indices:
        v = _snmpget(ctx, OID_BASE + "." + idx + ".0", community, host)
        if v == None:
            return {
                "changed": False,
                "msg": "SNMP query failed for OID " + OID_BASE + "." + idx + ".0",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        values[idx] = v

    psu_configs = [("1", "5", "2"), ("2", "6", "3"), ("3", "10", "11")]

    if params.get("_discover"):
        discovery = []
        for psu_nr, type_idx, state_idx in psu_configs:
            state_val = values[state_idx]
            if state_val not in ["0", "255"]:
                discovery.append({
                    "item": psu_nr,
                    "params": {},
                    "metrics": ["psu_state"],
                })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    psu_cfg = None
    for psu_nr, type_idx, state_idx in psu_configs:
        if psu_nr == item:
            psu_cfg = (psu_nr, type_idx, state_idx)
            break

    if psu_cfg == None:
        return {
            "changed": False,
            "msg": "unknown PSU item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    psu_nr, type_idx, state_idx = psu_cfg
    state_val = values[state_idx]
    if state_val in ["0", "255"]:
        return {
            "changed": False,
            "msg": "PSU %s not installed / not available" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    psu_type = MAP_PSU_TYPE.get(values[type_idx], "unknown")
    state_code, state_readable = MAP_PSU_STATE.get(state_val, (3, "not available"))
    state_name = STATE_NAMES.get(state_code, "UNKNOWN")

    return {
        "changed": False,
        "msg": "[%s] Operational status: %s" % (psu_type, state_readable),
        "data": {"state": state_name, "metrics": {"psu_state": state_code}, "details": ""},
    }