# FaultSeverity string -> Checkmk State (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
_SEVERITY_STATE = {
    "0": "OK",    # cleared
    "1": "OK",    # info
    "3": "WARN",  # warning
    "4": "WARN",  # minor
    "5": "CRIT",  # major
    "6": "CRIT",  # critical
}

# OID base for the fault table and the column OID suffixes (relative to base)
_FAULT_BASE = ".1.3.6.1.4.1.9.9.719.1.1.1.1"
_FAULT_COLS = {
    "5": "objectDn",      # cucsFaultAffectedObjectDn
    "6": "ack",           # cucsFaultAck
    "9": "code",          # cucsFaultCode
    "11": "description",  # cucsFaultDescription
    "20": "severity",     # cucsFaultSeverity
}

# sysObjectID prefix that identifies Cisco UCS (from the checkmk lib DECTE)
_UCS_OID_PREFIX = ".1.3.6.1.2.1.1.2.0"
_UCS_OID_VALUES = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]


def _strip_type(value):
    # Remove a leading "<TYPE>: " tag (e.g. "INTEGER:", "STRING:") and
    # surrounding quotes from a raw SNMP value.
    v = value.strip()
    if v.startswith("Hex-STRING") or v.startswith("STRING") or \
       v.startswith("INTEGER") or v.startswith("IpAddress") or \
       v.startswith("OID") or v.startswith("Timeticks") or \
       v.startswith("Counter32") or v.startswith("Counter64") or \
       v.startswith("Gauge32") or v.startswith("Gauge64") or \
       v.startswith("TruthValue") or v.startswith("DisplayString") or \
       v.startswith("PhysAddress") or v.startswith("ObjectIdentifier"):
        idx = v.find(":")
        if idx >= 0:
            v = v[idx + 1:].strip()
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        v = v[1:-1]
    elif len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    return v


def main(ctx, params):
    host = params.get("host", params.get("hostname", "localhost"))
    community = params.get("community", "public")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        sys_res = ctx.run(["snmpget", "-v", "2c", "-c", community, "-Oqv",
                           "-v", "2c", host, _UCS_OID_PREFIX], mutates=False)
        is_ucs = False
        if sys_res.rc == 0:
            sys_oid = _strip_type(sys_res.stdout)
            for ucs_val in _UCS_OID_VALUES:
                if sys_oid == ucs_val or sys_oid.startswith(ucs_val):
                    is_ucs = True
                    break
        if not is_ucs:
            return {"changed": False, "msg": "no Cisco UCS device found",
                    "data": {"discovery": []}}

        # Walk the fault table columns to enumerate distinct fault objects.
        walk = ctx.run(["snmpwalk", "-v", "2c", "-c", community, "-Oq",
                        "-O", "qv", "-v", "2c", host, _FAULT_BASE + ".5"],
                       mutates=False)
        items = []
        seen = {}
        if walk.rc == 0:
            for line in walk.stdout.splitlines():
                # "<OID> <value>" — first space separates OID from value
                sp = line.find(" ")
                if sp < 0:
                    continue
                oid = line[:sp]
                idx = oid
                for col in _FAULT_COLS:
                    full = _FAULT_BASE + "." + col
                    if idx.startswith(full):
                        idx = idx[len(full) + 1:]
                        break
                val = _strip_type(line[sp + 1:])
                seen[idx] = val

        for idx, name in seen.items():
            items.append({"item": name, "params": {}, "metrics": []})

        return {"changed": False,
                "msg": "discovered %d faults" % len(items),
                "data": {"discovery": items}}

    # --- CHECK MODE ---
    item = params.get("item", "")

    sys_res = ctx.run(["snmpget", "-v", "2c", "-c", community, "-Oqv",
                       host, _UCS_OID_PREFIX], mutates=False)
    is_ucs = False
    if sys_res.rc == 0:
        sys_oid = _strip_type(sys_res.stdout)
        for ucs_val in _UCS_OID_VALUES:
            if sys_oid == ucs_val or sys_oid.startswith(ucs_val):
                is_ucs = True
                break
    if not is_ucs:
        return {"changed": False, "msg": "no Cisco UCS device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine the index for this item by walking the objectDn column.
    walk = ctx.run(["snmpwalk", "-v", "2c", "-c", community, "-Oq",
                    "-O", "qv", host, _FAULT_BASE + ".5"], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "no faults",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        name = _strip_type(line[sp + 1:])
        idx = oid
        for col in _FAULT_COLS:
            full = _FAULT_BASE + "." + col
            if idx.startswith(full):
                idx = idx[len(full) + 1:]
                break
        if name == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "fault object not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all columns for this index.
    fault = {}
    for col, label in _FAULT_COLS.items():
        res = ctx.run(["snmpget", "-v", "2c", "-c", community, "-Oqv",
                       host, _FAULT_BASE + "." + col + "." + target_idx],
                      mutates=False)
        if res.rc == 0:
            fault[label] = _strip_type(res.stdout)
        else:
            fault[label] = ""

    severity = fault.get("severity", "1")
    state = _SEVERITY_STATE.get(severity, "UNKNOWN")
    notice = "Fault: " + fault.get("code", "") + " - " + fault.get("description", "")
    if fault.get("ack") == "1":
        notice = notice + " (acknowledged)"

    return {"changed": False, "msg": notice,
            "data": {"state": state, "metrics": {}, "details": notice}}