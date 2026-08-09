# hp_psu_temp — translated Checkmk check (read-only Starlark check module)
# Source: cmk/plugins/hp/agent_based/hp_psu.py (check_plugin_hp_psu_temp)
#
# This check monitors the temperature reported by HP ProCurve / HPE OfficeConnect
# power supplies via SNMP. It reads the same OIDs the Checkmk agent plugin reads
# and applies the temperature ruleset thresholds (default warn/crit 70/80 °C).
# The companion status plugin (hp_psu) is intentionally NOT translated: the
# task is to translate the hp_psu_temp check.

# OID layout (from SNMPTree base + OIDs):
#   base = .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1
#   column 2 = device status (STRING, e.g. "3")
#   column 4 = temperature  (INTEGER, in °C)
# The SNMP index (OIDEnd) is the left-most suffix after the base OID.

_BASE_OID = "1.3.6.1.2.1.1.1.0"  # sysDescr — used for detect()
_PSU_BASE = "1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
_STATUS_COL = "2"   # power supply status code
_TEMP_COL = "4"     # power supply temperature (°C)

_DEFAULT_LEVELS = (70.0, 80.0)  # warn, crit — check_default_parameters["levels"]


def _temperature_state(temp, warn, crit):
    """Grade a temperature reading against thresholds.

    Upper-level rules (warn/crit are maxima): WARN if temp >= warn,
    CRIT if temp >= crit. Returns (state, msg).
    """
    if temp == None:
        return ("UNKNOWN", "No temperature value")
    if temp >= crit:
        return ("CRIT", "Temperature %f°C >= crit %f°C" % (temp, crit))
    if temp >= warn:
        return ("WARN", "Temperature %f°C >= warn %f°C" % (temp, warn))
    return ("OK", "Temperature %f°C" % temp)


def _detect_is_hp(ctx, host, community):
    """Reproduce detect=all_of(contains(sysDescr, "hp"), any_of(contains "5406rzl2", contains "5412rzl2"))."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    desc = res.stdout.strip()
    if len(desc) == 0:
        return False
    lower = desc.lower()
    if lower.find("hp") == -1:
        return False
    if lower.find("5406rzl2") == -1 and lower.find("5412rzl2") == -1:
        return False
    return True


def _walk_psu(ctx, host, community):
    """Walk the PSU status column and build {index: (status, temp)}.

    Reads column 2 (status) and column 4 (temp) for every instance,
    correlating by the SNMP index (numeric suffix after the column OID).
    """
    psus = {}

    # Status column walk: <base>.<index>.2 -> <value>
    col_oid = _PSU_BASE + "." + _STATUS_COL
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 128:
        # rc 128 from snmpwalk can mean "noSuchInstance" for the whole column;
        # treat non-zero (incl. 127 = binary missing) as "no data".
        return psus
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        val = line[sp + 1:]
        # index is everything after "<base>.2."
        prefix = _PSU_BASE + "." + _STATUS_COL + "."
        if not line_oid.startswith(prefix):
            continue
        index = line_oid[len(prefix):]
        psus[index] = {"status": val, "temp": None}

    # Temperature column walk: <base>.<index>.4 -> <value>
    col_oid = _PSU_BASE + "." + _TEMP_COL
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 128:
        return psus
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        val = line[sp + 1:]
        prefix = _PSU_BASE + "." + _TEMP_COL + "."
        if not line_oid.startswith(prefix):
            continue
        index = line_oid[len(prefix):]
        if index in psus:
            # -Oqv gave us a bare integer for the temp column.
            psus[index]["temp"] = val

    return psus


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY MODE -------------------------------------------------
    if params.get("_discover"):
        if not _detect_is_hp(ctx, host, community):
            return {
                "changed": False,
                "msg": "host is not an HP 5406zl/5412zl (sysDescr detect failed)",
                "data": {"discovery": []},
            }

        psus = _walk_psu(ctx, host, community)
        if len(psus) == 0:
            return {
                "changed": False,
                "msg": "no HP power supplies found via SNMP",
                "data": {"discovery": []},
            }

        discovery = []
        for index in sorted(psus.keys()):
            discovery.append({
                "item": index,
                "params": {"warn": 70, "crit": 80,
                           "levels": list(_DEFAULT_LEVELS)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE -----------------------------------------------------
    if not _detect_is_hp(ctx, host, community):
        return {
            "changed": False,
            "msg": "not an HP 5406zl/5412zl device (sysDescr detect failed)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Host did not match HP ProCurve detection criteria.",
            },
        }

    psus = _walk_psu(ctx, host, community)
    item = params.get("item", "")
    if item not in psus:
        return {
            "changed": False,
            "msg": "no such power supply: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Power supply index %s not found via SNMP." % item,
            },
        }

    data = psus[item]
    status = data.get("status")
    raw_temp = data.get("temp")

    # Reproduce check_temperature() semantics, including the special case
    # where status "8" with temp 0 means "no temperature data available".
    if status == "8" and raw_temp == "0":
        return {
            "changed": False,
            "msg": "No temperature data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "PSU %s reports status 8 (Unplugged) with temperature 0." % item,
            },
        }

    # Parse the temperature value (guarded — no try/except in Starlark).
    temp = None
    if raw_temp != None and raw_temp != "":
        # snmpget/snmpwalk -Oqv already stripped the type tag; the value
        # should be a bare integer, but guard against noise.
        body = raw_temp
        # Strip a trailing "C" / " C" just in case, and surrounding quotes.
        body = body.strip()
        if body.startswith('"') and body.endswith('"') and len(body) >= 2:
            body = body[1:-1]
        digits = body
        # tolerate a trailing unit like "42 C"
        sp = digits.rfind(" ")
        if sp != -1:
            digits = digits[:sp].strip()
        if digits.lstrip("-").isdigit():
            temp = float(int(digits))

    if temp == None:
        return {
            "changed": False,
            "msg": "Could not parse temperature for PSU %s (raw=%r)" % (item, raw_temp),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Temperature value for PSU %s was not an integer (%r)." % (item, raw_temp),
            },
        }

    # Thresholds come from the temperature ruleset; Checkmk default is (70, 80).
    levels = params.get("levels", _DEFAULT_LEVELS)
    warn = params.get("warn", levels[0] if len(levels) > 0 else 70.0)
    crit = params.get("crit", levels[1] if len(levels) > 1 else 80.0)
    st, stmsg = _temperature_state(temp, float(warn), float(crit))

    return {
        "changed": False,
        "msg": "PSU %s %s" % (item, stmsg),
        "data": {
            "state": st,
            "metrics": {"temperature": temp},
            "details": stmsg,
        },
    }