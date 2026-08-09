# Translation of Checkmk checkmk.akcp_daisy_temp (SNMP-based temperature check).

SNMP_SYS_OID = ".1.3.6.1.2.1.1.2.0"
AKCP_SYS_OID_1 = ".1.3.6.1.4.1.3854.1"
AKCP_SYS_OID_2 = ".1.3.6.1.4.1.3854.1.2.2.1.1"
AKCP_DAISY_BASE_2 = ".1.3.6.1.4.1.3854.2."

# 8 SNMPTree bases, each with OIDEnd(), "1" (port), "2" (subport), "14" (name + temp)
DAISY_TABLES = [
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.1.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.2.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.3.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.4.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.5.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.6.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.7.2.1",
    ".1.3.6.1.4.1.3854.1.2.2.1.19.33.8.2.1",
]

DEFAULT_WARN = 28.0
DEFAULT_CRIT = 32.0


def _strip_snmp_value(raw):
    # Strip leading "<TYPE>: " tag and surrounding quotes if present.
    if raw == None:
        return raw
    s = raw
    if s.startswith("STRING: ") or s.startswith("INTEGER: ") or s.startswith("OID: "):
        s = s.split(": ", 1)[1]
    if len(s) >= 2 and s[0] == "\"" and s[-1] == "\"":
        s = s[1:-1]
    return s


def _probe_device(ctx, host, community):
    # 1. Verify the device is an AKCP daisy-chain capable unit via sysObjectID.
    res_sys = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SNMP_SYS_OID],
        mutates=False,
    )
    if res_sys.rc != 0:
        return None
    sys_oid = _strip_snmp_value(res_sys.stdout.strip())

    is_akcp = (sys_oid == AKCP_SYS_OID_1) or (sys_oid == AKCP_SYS_OID_2)
    if not is_akcp:
        return None

    # 2. Confirm the daisy-chain extension (.2) does NOT exist (detect's not_exists).
    res_not = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, AKCP_DAISY_BASE_2 + "1"],
        mutates=False,
    )
    if res_not.rc == 0:
        # Daisy-chain extension exists -> this is the non-daisy variant; skip.
        return None

    # 3. Confirm daisy-chain data exists (detect's exists on .19.*).
    res_exist = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, DAISY_TABLES[0] + ".1"],
        mutates=False,
    )
    if res_exist.rc != 0:
        return None

    # 4. Walk all 8 daisy-chain tables with -Oqn for clean OID/value lines.
    rows = []
    for base in DAISY_TABLES:
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            space = line.find(" ")
            if space == -1:
                continue
            oid = line[:space]
            value = _strip_snmp_value(line[space + 1:].strip())
            idx = oid[len(base) + 1:]
            if idx == "":
                continue
            rows.append((base, idx, value))
    return rows


def _build_records(rows):
    # Each table row OID is "<base>.<idx>" with oids [OIDEnd, "1", "2", "14"]
    # We collected rows as (base, idx, value). Reconstruct per-index records.
    records = {}
    for base, idx, value in rows:
        key = base + "." + idx
        rec = records.get(idx)
        if rec == None:
            rec = {"port": None, "subport": None, "name": None, "rawtemp": None}
            records[idx] = rec
        # Determine which column by the last OID suffix in base
        last = base.rsplit(".", 1)[-1]
        if last == "1":
            rec["port"] = value
        elif last == "2":
            rec["subport"] = value
        elif last == "14":
            rec["name"] = value
            rec["rawtemp"] = value
    return records


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        rows = _probe_device(ctx, host, community)
        if rows == None:
            return {"changed": False, "msg": "not an AKCP daisy-chain device", "data": {"discovery": []}}
        records = _build_records(rows)
        discovery = []
        for idx, rec in records.items():
            subport = rec["subport"]
            if subport == None or subport == "-1" or subport == "0":
                continue
            name = rec["name"]
            if name == None or name == "":
                continue
            discovery.append({
                "item": name,
                "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode for a single item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _probe_device(ctx, host, community)
    if rows == None:
        return {
            "changed": False,
            "msg": "host %s is not an AKCP daisy-chain device" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    records = _build_records(rows)

    rec = None
    for idx, r in records.items():
        if r["name"] == item:
            rec = r
            break
    if rec == None:
        return {
            "changed": False,
            "msg": "no sensor named %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    subport = rec["subport"]
    if subport == None or subport == "-1" or subport == "0":
        return {
            "changed": False,
            "msg": "sensor %s is handled by akcp_sensor_temp" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rawtemp = rec["rawtemp"]
    if rawtemp == None or not rawtemp.lstrip("-\'").isdigit():
        return {
            "changed": False,
            "msg": "no temperature for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = float(int(rawtemp)) / 10.0
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature %s %f C" % (item, temp),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "raw=%s, port=%s, subport=%s" % (rawtemp, rec["port"], subport),
        },
    }