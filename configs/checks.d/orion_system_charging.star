# Translation of Checkmk check: checkmk.orion_system_charging
# Source: cmk/plugins/orion/agent_based/orion_system.py
# SNMP section orion_system: base .1.3.6.1.4.1.20246.2.3.1.1.1.2.3
# OIDs (indexed 1..8): system_voltage(1), load_current(2), battery_current(3),
# battery_temp(4), charge_state(5), _battery_current_limit(6),
# rectifier_current(7), system_power(8)
#
# This is the "Charge %s" check (check_plugin_orion_system_charging).
# It reports the charge state of the "Battery" entity.

def _discover(ctx, params):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    # sysObjectID must start with the Orion enterprise prefix
    sysoid = res.stdout.strip() if res.rc == 0 else ""
    if not sysoid.startswith(".1.3.6.1.4.1.20246"):
        return {"changed": False, "msg": "no Orion device",
                "data": {"discovery": []}}

    # Fetch the 8 OIDs of the orion_system table row via snmpwalk on the base.
    # Each OID line is "<base>.<n> <value>".
    base = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
    wres = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", "-On", params.get("host", "localhost"), base],
        mutates=False,
    )
    values = {}
    if wres.rc == 0:
        for line in wres.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp+1:].strip()
            suffix = oid[len(base)+1:]
            if suffix.isdigit():
                values[int(suffix)] = val

    charge_state = values.get(5, "")
    parsed = _parse_charge_state(charge_state)
    state_int, state_readable = parsed

    discovery = []
    metrics = []
    if state_int == 0:
        discovery.append({
            "item": "Battery",
            "params": {},
            "metrics": metrics,
        })

    return {"changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery}}


def _parse_charge_state(cs):
    # Mirrors map_charge_states; unknown -> (3, "unknown[...]")
    states = {
        "1": (0, "float charging"),
        "2": (0, "discharge"),
        "3": (0, "equalize"),
        "4": (0, "boost"),
        "5": (0, "battery test"),
        "6": (0, "recharge"),
        "7": (0, "separate charge"),
        "8": (0, "event control charge"),
    }
    if cs in states:
        return states[cs]
    return (3, "unknown[%s]" % cs)


def _check(ctx, params):
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"

    # Re-fetch the row to read the charge state OID (.5).
    wres = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", "-On", params.get("host", "localhost"), base],
        mutates=False,
    )
    values = {}
    if wres.rc == 0:
        for line in wres.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp+1:].strip()
            suffix = oid[len(base)+1:]
            if suffix.isdigit():
                values[int(suffix)] = val

    charge_state = values.get(5, "")
    state_int, state_readable = _parse_charge_state(charge_state)

    # Map state_int: 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN
    if state_int == 0:
        state = "OK"
    elif state_int == 1:
        state = "WARN"
    elif state_int == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": "Status: %s" % state_readable,
        "data": {
            "state": state,
            "metrics": {},
            "details": "Item: %s, Charge state: %s" % (item, state_readable),
        },
    }


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)