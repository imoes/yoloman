# Checkmk check plugin: checkmk.acme_temp
# Translated to a read-only Starlark check module for the yolo-man agent.
# Source: ACMEPACKET-ENVMON-MIB temperature sensors via SNMP.

BASE_OID = ".1.3.6.1.4.1.9148"

# apEnvMonTemperatureStatusDescr column OID: .3 (under base .1.3.6.1.4.1.9148.3.3.1.3.1.1)
COLUMN_DESCR = ".3"
COLUMN_VALUE = ".4"
COLUMN_STATE = ".5"

ACME_ENVIRONMENT_STATES = {
    "1": (0, "initial"),
    "2": (0, "normal"),
    "3": (1, "minor"),
    "4": (1, "major"),
    "5": (2, "critical"),
    "6": (2, "shutdown"),
    "7": (2, "not present"),
    "8": (2, "not functioning"),
    "9": (2, "unknown"),
}

# Column OID (relative to the SNMP section base) -> local name used in parse.
# We fetch columns 3 (descr), 4 (value), 5 (state) and correlate by OID index.


def _snmp_value(res):
    if res == None:
        return ""
    return res

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # ---- Discovery guard: ensure this is an ACME device via sysObjectID ----
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid_res.rc != 0 or sysid_res.stdout == "" or sysid_res.stdout.find(BASE_OID) != 0:
        # Not an ACME device (rc 127 = binary missing, or value not matching)
        if params.get("_discover"):
            return {"changed": False, "msg": "not an ACME device", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "no ACME environment found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # ---- Fetch descriptor column to enumerate sensors (snmpwalk -Oqn) ----
    descr_base = ".1.3.6.1.4.1.9148.3.3.1.3.1.1" + COLUMN_DESCR
    descr_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, descr_base],
        mutates=False,
    )

    if params.get("_discover"):
        discovery = []
        if descr_res.rc == 0 and descr_res.stdout != "":
            for line in descr_res.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                value = line[sp + 1:]
                # index is the OID suffix after the column base
                col_len = len(descr_base)
                idx = oid[col_len + 1:] if len(oid) > col_len + 1 else oid[col_len:]
                if idx == "":
                    continue
                # fetch state for this index to honor "skip state 7"
                st_res = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, descr_base.replace(".3", ".5") + "." + idx],
                    mutates=False,
                )
                st_val = st_res.stdout.strip()
                if st_val == "7":
                    continue
                # fetch value (temperature reading)
                val_res = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, descr_base.replace(".3", ".4") + "." + idx],
                    mutates=False,
                )
                val = val_res.stdout.strip()
                if val == "" or _is_bad_gauge(val):
                    continue
                discovery.append({
                    "item": value,
                    "params": {},
                    "metrics": ["temperature"],
                })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- Check mode: evaluate one item ----
    item = params.get("item", "")
    warn = params.get("warn")
    crit = params.get("crit")

    found = False
    value = 0.0
    dev_state_code = 0
    dev_state_readable = "normal"

    if descr_res.rc == 0 and descr_res.stdout != "":
        for line in descr_res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            desc_val = line[sp + 1:]
            col_len = len(descr_base)
            idx = oid[col_len + 1:] if len(oid) > col_len + 1 else oid[col_len:]
            if desc_val == item:
                found = True
                # read value column (.4)
                vres = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9148.3.3.1.3.1.1.4." + idx],
                    mutates=False,
                )
                vstr = vres.stdout.strip()
                value = float(vstr) if _is_int(vstr) else 0.0

                # read state column (.5)
                sres = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9148.3.3.1.3.1.1.5." + idx],
                    mutates=False,
                )
                sstr = sres.stdout.strip()
                entry = ACME_ENVIRONMENT_STATES.get(sstr)
                if entry != None:
                    dev_state_code, dev_state_readable = entry
                else:
                    dev_state_code = 2
                    dev_state_readable = "unknown"
                break

    if not found:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Temperature threshold grading: higher is worse.
    state = "OK"
    if warn != None and value >= warn:
        state = "WARN"
    if crit != None and value >= crit:
        state = "CRIT"
    # Device status overrides: CRIT states from the device dominate.
    if dev_state_code == 2 and state != "CRIT":
        state = "WARN"
    if dev_state_code == 2 and dev_state_readable == "shutdown":
        state = "CRIT"
    # Map device OK/minor/major -> keep but reflect in details.

    details = "descr: " + item + ", value: %s C, dev_status: %s" % (str(value), dev_state_readable)
    if state == "CRIT":
        details = details + " (device critical)"
    elif state == "WARN" and dev_state_code == 1:
        details = details + " (device warn)"

    return {
        "changed": False,
        "msg": "Temperature %s: %s C" % (item, str(value)),
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": details,
        },
    }


def _is_int(s):
    if s == None or s == "":
        return False
    return s.lstrip("-").isdigit()

def _is_bad_gauge(v):
    return v == "" or v == "NOSUCHOBJECT" or v == "NOSUCHINSTANCE" or v == "ENDOFMIBVIEW"