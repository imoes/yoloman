# Check: checkmk.apc_symmetra_elphase
# Translated from Checkmk checkmk.apc_symmetra_elphase
# Monitors UPS battery-output (el phase) current per phase via SNMP on APC Symmetra.

# --- constants -----------------------------------------------------------

# OID bases used by the original SNMPTree definitions.
# elphase data lives under this base + column sub-OIDs.
ELPHASE_BASE = ".1.3.6.1.4.1.318.1.1.1.2.3.10.2.1"

# elphase column OIDs: 6 = current value, 2 = current state
ELPHASE_CURRENT_COL = 6
ELPHASE_STATE_COL = 2

# state mapping for elphase currents
ELPHASE_STATE_OK = 1
ELPHASE_STATE_DOWN = 2
ELPHASE_STATE_ACFAIL = 3
ELPHASE_STATE_UNKNOWN = 4

# --- helpers -------------------------------------------------------------

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None, "not installed"
    if res.rc != 0:
        return None, "snmp error"
    return res.stdout.strip(), ""

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None, "not installed"
    if res.rc != 0:
        return None, "snmp error"
    return res.stdout.strip(), ""

def _strip_type_prefix(value):
    v = value
    if ":" in v:
        idx = v.find(":")
        v = v[idx + 1:].strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    return v

def _parse_int(value):
    v = _strip_type_prefix(value)
    if v == "" or v == "No Value":
        return None
    # handle numeric strings; extract leading integer
    v = v.strip()
    # remove optional sign and extract digits
    s = v
    if s.startswith("-"):
        s = s[1:]
    digits = ""
    for ch in s:
        if ch in "0123456789":
            digits = digits + ch
        else:
            if digits != "":
                break
    if digits == "" or not digits.isdigit():
        return None
    return int(digits)

def _is_numeric_float(v):
    s = v.strip()
    if s == "":
        return False
    if s.startswith("-"):
        s = s[1:]
    if "." in s:
        # split into integer and fractional parts
        parts = s.split(".")
        if len(parts) != 2:
            return False
        int_part = parts[0]
        frac_part = parts[1]
        if int_part != "" and not int_part.isdigit():
            return False
        if frac_part == "" or not frac_part.isdigit():
            return False
        return True
    return s.isdigit()

def _parse_float(value):
    v = _strip_type_prefix(value)
    if v == "" or v == "No Value":
        return None
    if not _is_numeric_float(v):
        return None
    return float(v)

def _grade_upper(value, warn, crit):
    # upper levels: warn if value >= warn, crit if value >= crit
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _elphase_state_name(code):
    names = {
        1: "ok",
        2: "down",
        3: "acfail",
        4: "unknown",
    }
    return names.get(code, "unexpected(%s)" % code)

def _extract_levels(param_val):
    # param_val may be ("fixed", (warn, crit)) or (warn, crit)
    warn = None
    crit = None
    if param_val == None:
        return warn, crit
    if type(param_val) == "list" and len(param_val) == 2:
        # check if it's ("fixed", (w, c))
        first = param_val[0]
        if first == "fixed" or first == "relative" or first == "no_levels":
            inner = param_val[1]
            if type(inner) == "list" and len(inner) == 2:
                warn = inner[0]
                crit = inner[1]
        else:
            # assume (warn, crit) directly
            if _is_numeric_float(str(first)) and _is_numeric_float(str(param_val[1])):
                warn = float(first)
                crit = float(param_val[1])
    return warn, crit

# --- main ---------------------------------------------------------------

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode: enumerate phases that report current
    if params.get("_discover"):
        phase_oids, err = _snmp_walk(ctx, host, community, ELPHASE_BASE + ".6")
        if err != "" or phase_oids == None:
            return {
                "changed": False,
                "msg": err if err != "" else "no data",
                "data": {"discovery": []},
            }
        discovery = []
        for line in phase_oids.split("\n"):
            if line == "":
                continue
            idx = line.find(" ")
            if idx < 0:
                continue
            oid_part = line[0:idx]
            col_oid = ELPHASE_BASE + ".6"
            if not oid_part.startswith(col_oid + "."):
                continue
            phase_index = oid_part[len(col_oid) + 1:]
            if phase_index == "":
                continue
            discovery.append({
                "item": phase_index,
                "params": {},
                "metrics": ["current"],
            })
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: check ONE phase
    item = params.get("item", "")

    current_oid = ELPHASE_BASE + ".6." + item
    state_oid = ELPHASE_BASE + ".2." + item

    cur_raw, cur_err = _snmp_get(ctx, host, community, current_oid)
    if cur_err != "" or cur_raw == None:
        return {
            "changed": False,
            "msg": "phase %s: no data (%s)" % (item, cur_err if cur_err != "" else "no response"),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    current_val = _parse_float(cur_raw)
    if current_val == None:
        return {
            "changed": False,
            "msg": "phase %s: no current value" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    st_raw, st_err = _snmp_get(ctx, host, community, state_oid)
    state_code = None
    if st_err == "" and st_raw != None:
        state_code = _parse_int(st_raw)

    # Grade the current value using ups_outphase levels (upper levels)
    warn, crit = _extract_levels(params.get("levels"))
    if warn == None and crit == None:
        warn, crit = _extract_levels(params.get("levels_lower"))

    state = _grade_upper(current_val, warn, crit)

    details = "phase %s current: %f A" % (item, current_val)
    if state_code != None:
        details = details + ", state: " + _elphase_state_name(state_code)

    msg = "Phase %s: %f A" % (item, current_val)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"current": current_val},
            "details": details,
        },
    }