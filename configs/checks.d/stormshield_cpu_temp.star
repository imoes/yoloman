# checkmk.stormshield_cpu_temp → read-only Starlark check module
# Translated from the Checkmk stormshield_cpu_temp check plugin.

# OID roots
SYS_SYSID = ".1.3.6.1.2.1.1.2.0"
STORMSHIELD_BASIC = ".1.3.6.1.4.1.11256.1.0.1.0"
CPU_TEMP_BASE = ".1.3.6.1.4.1.11256.1.10.7.1"
# column OIDs under the CPU temperature table
COL_INDEX = "1"
COL_TEMP = "2"

# Stormshield enterprise OID prefix and the legacy/old variants
SS_PREFIX_NEW = ".1.3.6.1.4.1.11256.1"
SS_OID_OLD = ".1.3.6.1.4.1.11256.2.0"
NETSNMP_GENERAL = ".1.3.6.1.4.1.8072"

def _is_stormshield(sysid, basic_exists):
    """Reproduce DETECT_STORMSHIELD: the host must look like a Stormshield device."""
    if not basic_exists:
        return False
    if sysid == SS_OID_OLD:
        return True
    if sysid.startswith(NETSNMP_GENERAL):
        return True
    if sysid.startswith(SS_PREFIX_NEW):
        return True
    return False

def _is_int(s):
    if s == None or len(s) == 0:
        return False
    if s[0] == "-":
        return s[1:].isdigit() if len(s) > 1 else False
    return s.isdigit()

def main(ctx, params):
    # --- discovery mode -------------------------------------------------
    if params.get("_discover"):
        # Verify this is really a Stormshield device before discovering.
        sid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), SYS_SYSID],
            mutates=False)
        if sid.rc != 0 and sid.rc != 127:
            # treat as not installed / unreachable
            return {"changed": False,
                    "msg": "no stormshield device found",
                    "data": {"discovery": []}}
        sysid = sid.stdout.strip() if sid.rc == 0 else ""

        basic = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), STORMSHIELD_BASIC],
            mutates=False)
        basic_exists = basic.rc == 0

        if not _is_stormshield(sysid, basic_exists):
            return {"changed": False,
                    "msg": "no stormshield device found",
                    "data": {"discovery": []}}

        # Walk the CPU temperature table with -Oqn for clean OID<->value lines.
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), CPU_TEMP_BASE],
            mutates=False)
        if walk.rc != 0:
            return {"changed": False,
                    "msg": "could not reach stormshield cpu temp table",
                    "data": {"discovery": []}}

        # Correlate index and temperature columns by their shared index suffix.
        temp_for = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            # oid looks like ".1.3.6.1.4.1.11256.1.10.7.1.1.<index>" (index col)
            if oid.startswith(CPU_TEMP_BASE + "." + COL_INDEX + "."):
                idx = oid[len(CPU_TEMP_BASE + "." + COL_INDEX + "."):]
                idx = idx.lstrip("0") or "0"
                # Remember index; temperature may arrive on a separate row.
                if idx not in temp_for:
                    temp_for[idx] = None
            elif oid.startswith(CPU_TEMP_BASE + "." + COL_TEMP + "."):
                idx = oid[len(CPU_TEMP_BASE + "." + COL_TEMP + "."):]
                idx = idx.lstrip("0") or "0"
                temp_for[idx] = val

        discovery = []
        for idx in sorted(temp_for.keys()):
            discovery.append({
                "item": idx,
                "params": {"warn": 70, "crit": 80},
                "metrics": ["temperature"],
            })
        return {"changed": False,
                "msg": "discovered %d cpu temp sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # --- check mode -----------------------------------------------------
    item = params.get("item", "")
    if item == None or item == "":
        return {"changed": False,
                "msg": "no stormshield cpu temp item specified",
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "missing item parameter"}}

    # Confirm the device is Stormshield (same gating as discovery).
    sid = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), SYS_SYSID],
        mutates=False)
    sysid = sid.stdout.strip() if sid.rc == 0 else ""
    basic = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), STORMSHIELD_BASIC],
        mutates=False)
    if not _is_stormshield(sysid, basic.rc == 0):
        return {"changed": False,
                "msg": "host is not a stormshield device",
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "DETECT_STORMSHIELD did not match"}}

    # Read the temperature for this index directly.
    get_oid = CPU_TEMP_BASE + "." + COL_TEMP + "." + item
    temp = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), get_oid],
        mutates=False)
    if temp.rc != 0:
        return {"changed": False,
                "msg": "no cpu temperature for index %s" % item,
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "item %s not found in cpu temp table" % item}}

    raw = temp.stdout.strip()
    if not _is_int(raw):
        return {"changed": False,
                "msg": "invalid cpu temperature for index %s: %s" % (item, raw),
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "non-numeric temperature value"}}

    reading = float(raw)
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "CPU Temp %s: %f C" % (item, reading),
            "data": {"state": state,
                     "metrics": {"temperature": reading},
                     "details": "stormshield cpu temp sensor %s = %f C" % (item, reading)}}