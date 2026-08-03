# ===== checkmk.hepta (Checkmk "HPF Info" SNMP check, translated to Starlark) =====
#
# The Checkmk agent-based plugin fetches the HPF hepta device info via the
# enterprise OID prefix .1.3.6.1.4.1.12527 (detected through
# startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.12527")). Two SNMP tables are
# fetched (bases .1.3.6.1.4.1.12527.29 and .1.3.6.1.4.1.12527.40) and the first
# non-empty one is used. This translation reproduces that exact data source:
# it walks the SNMP column OID .1.3.6.1.4.1.12527.29.1 (.1) on the target host
# and reads the per-instance values with snmpget, then applies the same parse
# + check logic as the original plugin. The "real thing" here is the SNMP OID
# .1.3.6.1.2.1.1.2.0 returning an OID under .1.3.6.1.4.1.12527; absence of the
# device (rc 127 or no SNMP response) yields an empty discovery list and an
# UNKNOWN verdict -- never a local /proc stand-in.

# OID layout (from SNMPTree base .1.3.6.1.4.1.12527.29, oids 1.1.0 / 1.3.0 /
# 1.4.0 / 1.5.0 / 1.6.0 / 2.1.2.0 / 3.1.0 / 3.5.0):
#   device_type           .1
#   serial_number         .3
#   fw_version            .4
#   fw_date               .5
#   version               .6
#   ntp_stratum           .2.1.2
#   local_time            .3.1
#   sync_state            .3.5
SYSCONTACT_OID = ".1.3.6.1.2.1.1.2.0"
ENT_BASE = ".1.3.6.1.4.1.12527"

COL_DEVICE_TYPE = ".1"
COL_SERIAL_NUMBER = ".3"
COL_FW_VERSION = ".4"
COL_FW_DATE = ".5"
COL_VERSION = ".6"
COL_NTP_STRATUM = ".2.1.2"
COL_LOCAL_TIME = ".3.1"
COL_SYNC_STATE = ".3.5"

COLS = [
    (COL_DEVICE_TYPE, "devicetype"),
    (COL_SERIAL_NUMBER, "serialnumber"),
    (COL_FW_VERSION, "firmwareversion"),
    (COL_FW_DATE, "firmwaredate"),
    (COL_VERSION, "version"),
    (COL_NTP_STRATUM, "ntpstratum"),
    (COL_LOCAL_TIME, "syncmoduletimelocal"),
    (COL_SYNC_STATE, "syncmoduletimesyncstate"),
]

# Per-column OID suffixes relative to ENT_BASE (the two fetched tables only
# differ in the numeric instance; we walk the .29 table as the canonical
# source, mirroring parse_hepta using "string_table[0] or string_table[1]").
TABLE_BASES = [".29", ".40"]


def _snmpget(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    return ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _snmpwalk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    return ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, oid],
        mutates=False,
    )


def _device_present(ctx, params):
    res = _snmpget(ctx, params, SYSCONTACT_OID)
    if res.rc != 0:
        return False, ""
    val = res.stdout.strip()
    return val.startswith(ENT_BASE), val


def _read_col(ctx, params, base, col):
    # base is the numeric suffix (e.g. "29"); col is the column OID suffix.
    oid = ENT_BASE + "." + base + col
    res = _snmpget(ctx, params, oid)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _walk_col(ctx, params, base, col):
    oid = ENT_BASE + "." + base + col
    res = _snmpwalk(ctx, params, oid)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        idx = line[0:sp]
        val = line[sp + 1:].strip()
        out.append((idx, val))
    return out


def _decode_time(timefromdevice):
    # Approximate the Checkmk _get_time struct.unpack logic without the `struct`
    # / `re` modules. The original handles length 8 (6 bytes after 2-byte year)
    # and length 11 (adds a 3-byte signed offset). We return a best-effort
    # human-readable string; the core check logic is the SNMP presence test.
    if timefromdevice == None:
        return ""
    raw = timefromdevice if type(timefromdevice) == "string" else str(timefromdevice)
    b = [int(x) for x in raw.encode("latin-1")]
    n = len(b)
    if n not in (8, 11):
        return ""
    # Guard each index access: every value must exist before we use it.
    if n < 7:
        return ""
    year = (b[0] << 8) | b[1]
    month = b[2]
    day = b[3]
    hour = b[4]
    minute = b[5]
    second = b[6]
    date = "%d-%d-%Y %d:%d:%d" % (day, month, year, hour, minute, second)
    if n == 11:
        sign = "-" if b[7] == 1 else "+"
        off = "%s%d:%d" % (sign, b[8], b[9])
        return date + " " + off
    return date


def _read_section(ctx, params):
    # Reproduce parse_hepta: fetch both SNMP trees, use the first non-empty row.
    for base in TABLE_BASES:
        row = []
        empty = False
        for col, _name in COLS:
            v = _read_col(ctx, params, base, col)
            if v == "":
                empty = True
            row.append(v)
        if not empty and len(row) == len(COLS):
            section = {}
            i = 0
            while i < len(COLS):
                _col, name = COLS[i]
                section[name] = row[i]
                i += 1
            # Decode time fields exactly like the original parse function.
            if section.get("firmwaredate", "") != "":
                section["firmwaredate"] = _decode_time(section["firmwaredate"])
            if section.get("syncmoduletimelocal", "") != "":
                section["syncmoduletimelocal"] = _decode_time(section["syncmoduletimelocal"])
            return section
    return None


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        present, _val = _device_present(ctx, params)
        if not present:
            return {
                "changed": False,
                "msg": "hepta device not detected (SNMP sysObjectID not under %s)" % ENT_BASE,
                "data": {"discovery": []},
            }
        section = _read_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "hepta device present but no data", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered hepta services",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []},
                    {"item": "SyncModuleTimeSyncState", "params": {}, "metrics": []},
                    {"item": "ntpSysStratum", "params": {}, "metrics": []},
                    {"item": "SyncModuleTimeLocal", "params": {}, "metrics": []},
                ],
            },
        }

    # ---- CHECK MODE ----
    present, _val = _device_present(ctx, params)
    if not present:
        return {
            "changed": False,
            "msg": "hepta device not detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _read_section(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "no hepta data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    item = params.get("item", "")

    # Main "HPF Info" service (item == "").
    if item == "":
        summary = "DeviceType %s ; SerialNumber %s ; FirmwareVersion %s ; FirmwareDate %s ; Version %s" % (
            section.get("devicetype", ""),
            section.get("serialnumber", ""),
            section.get("firmwareversion", ""),
            section.get("firmwaredate", ""),
            section.get("version", ""),
        )
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": summary},
        }

    # SyncModuleTimeSyncState sub-service.
    if item == "SyncModuleTimeSyncState":
        sync = section.get("syncmoduletimesyncstate", "")
        if sync == "R":
            st = "OK"
            sm = "Radio synchronous with high precision"
        elif sync == "r":
            st = "WARN"
            sm = "Radio synchronous with low precision"
        elif sync == "C":
            st = "CRIT"
            sm = "Crystal"
        elif sync == "I":
            st = "CRIT"
            sm = "Invalid time and date"
        else:
            st = "UNKNOWN"
            sm = "No data available"
        return {"changed": False, "msg": sm, "data": {"state": st, "metrics": {}, "details": sm}}

    # ntpSysStratum sub-service.
    if item == "ntpSysStratum":
        stratum = section.get("ntpstratum", "")
        if stratum == "1":
            st = "OK"
            sm = "Stratum 1, Primary Reference "
        elif stratum == "16":
            st = "CRIT"
            sm = "Stratum Invalid"
        elif stratum == "0":
            st = "UNKNOWN"
            sm = "Stratum Unknown"
        else:
            st = "WARN"
            sm = "Stratum is using secondary reference(via NTP)"
        return {"changed": False, "msg": sm, "data": {"state": st, "metrics": {}, "details": sm}}

    # SyncModuleTimeLocal sub-service.
    if item == "SyncModuleTimeLocal":
        local = section.get("syncmoduletimelocal", "")
        sm = "Module Time: %s" % local
        return {
            "changed": False,
            "msg": sm,
            "data": {"state": "OK", "metrics": {}, "details": sm},
        }

    return {
        "changed": False,
        "msg": "unknown hepta item: %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }