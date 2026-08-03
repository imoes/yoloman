# Watchdog SNMP temperature sensor check — read-only Starlark translation.
#
# Source checkmk plugin: cmk/plugins/watchdog/agent_based/watchdog_sensors.py
#
# This module reproduces the `watchdog_sensors_temp` check only (the temperature
# sub-check). It walks the Watchdog sensor table over SNMP, discovers one
# service per sensor (named by its description), and grades the temperature
# reading against operator-supplied warn/crit levels.
#
# The check is purely read-only and never mutates the system.

def _to_temp_params(params):
    """Extract (warn, crit) temperature levels from params, with Checkmk defaults."""
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", 30)
        crit = params.get("crit", 35)
    return warn, crit


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", 2)
    base = ".1.3.6.1.4.1.21239.5.1"
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    item = params.get("item", "")

    if params.get("_discover"):
        # --- DISCOVERY -------------------------------------------------------
        # First confirm the Watchdog product is present by reading the
        # system OID. If it is not the Watchdog enterprise OID, the device
        # is not a Watchdog sensor and nothing is discovered.
        probe = ctx.run(
            ["snmpget", "-v%d" % version, "-c", community, "-Oqv", host, sys_oid],
            mutates=False,
        )
        if probe.rc != 0 or probe.skipped:
            return {"changed": False, "msg": "no SNMP access",
                    "data": {"discovery": []}}
        sys_oid_val = probe.stdout.strip()
        if not sys_oid_val.startswith(".1.3.6.1.4.1.21239.5.1") and \
           not sys_oid_val.startswith(".1.3.6.1.4.1.21239.42.1"):
            return {"changed": False, "msg": "not a Watchdog device",
                    "data": {"discovery": []}}

        # Read version + temperature unit from the general scalar table.
        general = ctx.run(
            ["snmpget", "-v%d" % version, "-c", community, "-Oqv", host,
             base + ".1.1.2.0"],
            mutates=False,
        )
        unit_oid = ctx.run(
            ["snmpget", "-v%d" % version, "-c", community, "-Oqv", host,
             base + ".1.1.7.0"],
            mutates=False,
        )
        if general.rc != 0 or unit_oid.rc != 0 or general.skipped or unit_oid.skipped:
            return {"changed": False, "msg": "Watchdog general OIDs unreadable",
                    "data": {"discovery": []}}
        version_str = general.stdout.strip()
        unit_raw = unit_oid.stdout.strip()
        temp_unit = "C" if unit_raw == "1" else ("F" if unit_raw == "0" else "C")

        # Walk the sensor table: column-OID .1.3.6.1.4.1.21239.5.1.2.1.3
        # (description) — item is the description VALUE; temperature column
        # is .1.3.6.1.4.1.21239.5.1.2.1.6 (value*10 integer).
        walk = ctx.run(
            ["snmpwalk", "-v%d" % version, "-c", community, "-Oqn", host,
             base + ".2.1.3"],
            mutates=False,
        )
        if walk.rc != 0 or walk.skipped:
            return {"changed": False, "msg": "no Watchdog sensor table",
                    "data": {"discovery": []}}

        discovery = []
        for line in walk.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            index = oid[len(base + ".2.1.3") + 1:]
            warn, crit = _to_temp_params(params)
            discovery.append({
                "item": value,
                "params": {"warn": warn, "crit": crit},
                "metrics": ["temperature"],
            })
        return {"changed": False,
                "msg": "discovered %d Watchdog temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK MODE --------------------------------------------------------
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Re-walk the description column to find the numeric index for this item.
    walk = ctx.run(
        ["snmpwalk", "-v%d" % version, "-c", community, "-Oqn", host,
         base + ".2.1.3"],
        mutates=False,
    )
    if walk.rc != 0 or walk.skipped or walk.stdout == "":
        return {"changed": False, "msg": "no Watchdog sensor table reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    for line in walk.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        if value == item:
            index = oid[len(base + ".2.1.3") + 1:]
            break

    if index == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the temperature value for the matched index.
    temp_res = ctx.run(
        ["snmpget", "-v%d" % version, "-c", community, "-Oqv", host,
         base + ".2.1.6." + index],
        mutates=False,
    )
    unit_res = ctx.run(
        ["snmpget", "-v%d" % version, "-c", community, "-Oqv", host,
         base + ".1.1.7.0"],
        mutates=False,
    )
    if temp_res.rc != 0 or temp_res.skipped or temp_res.stdout == "":
        return {"changed": False, "msg": "could not read temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_raw = temp_res.stdout.strip()
    unit_raw = unit_res.stdout.strip() if (unit_res.rc == 0 and not unit_res.skipped) else "1"
    temp_unit = "C" if unit_raw == "1" else "F"

    if not temp_raw.lstrip("-").isdigit():
        return {"changed": False,
                "msg": "invalid temperature value: " + temp_raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = int(temp_raw) / 10.0
    if temp_unit == "F":
        reading = (reading - 32.0) * 5.0 / 9.0
        unit = "c"
    else:
        unit = "c"

    warn, crit = _to_temp_params(params)
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%s %f%s" % (item, reading, unit)
    if state != "OK":
        msg += " (warn/crit at %d/%d%s)" % (warn, crit, unit)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}