# ibm_storage_ts_drive — Checkmk check translated to read-only Starlark.
# Monitors IBM Storage TS (LTO tape library) drive health via SNMP.
# One service per drive; discovery enumerates drives present on the device.

BASE = ".1.3.6.1.4.1.2.6.210"

# sysObjectID OID used for detection of IBM Storage TS.
SYS_OID = ".1.3.6.1.2.1.1.2.0"
EXPECTED_SYS_ID = ".1.3.6.1.4.1.2.6.210"

# Drive table: column OIDs relative to the drive subtree base.
# From SNMPTree(base=".1.3.6.1.4.1.2.6.210.3.2.1", oids=["1","10","15","16","17","18"])
#   1  -> entry (drive name / label)
#   10 -> serial
#   15 -> write_err
#   16 -> write_warn
#   17 -> read_err
#   18 -> read_warn
DRIVE_BASE = BASE + ".3.2.1"
DRIVE_ENTRY_OID = DRIVE_BASE + ".1"
DRIVE_SERIAL_OID = DRIVE_BASE + ".10"
DRIVE_WRITE_ERR_OID = DRIVE_BASE + ".15"
DRIVE_WRITE_WARN_OID = DRIVE_BASE + ".16"
DRIVE_READ_ERR_OID = DRIVE_BASE + ".17"
DRIVE_READ_WARN_OID = DRIVE_BASE + ".18"

# Status name / Nagios mapping is not used for drives but kept for completeness.
TS_STATUS_MAP = {
    "1": "other",
    "2": "unknown",
    "3": "Ok",
    "4": "non-critical",
    "5": "critical",
    "6": "non-Recoverable",
}

TS_STATUS_NAGIOS = {
    "1": "WARN",
    "2": "WARN",
    "3": "OK",
    "4": "WARN",
    "5": "CRIT",
    "6": "CRIT",
}

TS_FAULT_NAGIOS = {
    "0": "OK",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "CRIT",
}


def _snmp_get_str(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmp_walk_cols(ctx, host, community, base):
    # -Oqn: one line per row "<oid> <value>", numeric OID, no type tag.
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
        mutates=False,
    )
    rows = {}
    if res.rc == 0 and res.stdout:
        for line in res.stdout.splitlines():
            idx = line.find(" ")
            if idx < 0:
                continue
            oid = line[:idx]
            val = line[idx + 1:].strip()
            # index = oid suffix after the column base
            prefix = base + "."
            if oid.startswith(prefix):
                index = oid[len(prefix):]
            else:
                index = oid[len(base):].lstrip(".")
            rows[index] = val
    return rows


def _get_drives(ctx, host, community):
    # Walk the entry column to get the set of drive indices present.
    entries = _snmp_walk_cols(ctx, host, community, DRIVE_ENTRY_OID)
    drives = []
    for index in sorted(entries.keys()):
        entry = entries[index]
        if index == "":
            continue
        drives.append({
            "entry": entry,
            "serial": _snmp_get_str(ctx, host, community, DRIVE_SERIAL_OID + "." + index),
            "write_err": _snmp_get_str(ctx, host, community, DRIVE_WRITE_ERR_OID + "." + index),
            "write_warn": _snmp_get_str(ctx, host, community, DRIVE_WRITE_WARN_OID + "." + index),
            "read_err": _snmp_get_str(ctx, host, community, DRIVE_READ_ERR_OID + "." + index),
            "read_warn": _snmp_get_str(ctx, host, community, DRIVE_READ_WARN_OID + "." + index),
        })
    return drives


def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    la = order.get(a, 3)
    lb = order.get(b, 3)
    if la >= lb:
        return a
    return b


def _check_drive(counter, state, summary):
    results = []
    if counter == "":
        results.append((state if state == "UNKNOWN" else "UNKNOWN", summary.format("got empty string for")))
        return results
    if counter != "0":
        results.append((state, summary.format(counter)))
    return results


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: detect IBM Storage TS via sysObjectID.
    sys_id = _snmp_get_str(ctx, host, community, SYS_OID)
    if sys_id != EXPECTED_SYS_ID:
        # Device is not an IBM Storage TS (or unreachable). Not applicable.
        return {
            "changed": False,
            "msg": "not an IBM Storage TS device (sysoid mismatch)",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        drives = _get_drives(ctx, host, community)
        discovery = []
        for d in drives:
            discovery.append({
                "item": d["entry"],
                "params": {},
                "metrics": ["write_err", "write_warn", "read_err", "read_warn"],
            })
        return {
            "changed": False,
            "msg": "discovered %d drives" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    drives = _get_drives(ctx, host, community)

    target = None
    for d in drives:
        if d["entry"] == item:
            target = d
            break

    if target == None:
        return {
            "changed": False,
            "msg": "drive not found: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    details = "S/N: " + str(target["serial"])

    checks = [
        _check_drive(target["write_err"], "CRIT", "{} hard write errors"),
        _check_drive(target["write_warn"], "WARN", "{} recovered write errors"),
        _check_drive(target["read_err"], "CRIT", "{} hard read errors"),
        _check_drive(target["read_warn"], "WARN", "{} recovered read errors"),
    ]

    lines = []
    for sub_state, sub_msg in checks:
        if sub_msg != "":
            lines.append(sub_msg)
            state = _worst(state, sub_state)

    if len(lines) > 0:
        details = details + ", " + ", ".join(lines)

    metrics = {}
    for name, key in [
        ("write_err", "write_err"),
        ("write_warn", "write_warn"),
        ("read_err", "read_err"),
        ("read_warn", "read_warn"),
    ]:
        raw = ""
        for d in drives:
            if d["entry"] == item:
                raw = d[key]
                break
        num = 0
        if raw != "" and raw.lstrip("-").isdigit():
            num = int(raw)
        metrics[name] = num

    summary = "S/N: " + str(target["serial"])
    if len(lines) > 0:
        summary = summary + ", " + ", ".join(lines)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": details},
    }