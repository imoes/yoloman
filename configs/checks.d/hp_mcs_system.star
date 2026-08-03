# ===== Starlark module: hp_mcs_system (translated from Checkmk SNMP check) =====

_STATUS_MAP = {
    0: ("CRIT", "Not available"),
    1: ("UNKNOWN", "Other"),
    2: ("OK", "OK"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

_HEX_CHARS = "0123456789abcdefABCDEF"


def _strip_type(value):
    idx = value.find(": ")
    if idx >= 0:
        value = value[idx + 2:]
    value = value.strip()
    if len(value) >= 2 and value[0] == "\"" and value[-1] == "\"":
        value = value[1:-1]
    return value


def _strip_all_quotes(value):
    while len(value) >= 2 and value[0] == "\"" and value[-1] == "\"":
        value = value[1:-1]
    return value


def _safe_hex_int(token):
    if not token:
        return None
    clean = token
    if clean.startswith("0x") or clean.startswith("0X"):
        clean = clean[2:]
    if len(clean) == 0:
        return None
    for c in clean:
        if c not in _HEX_CHARS:
            return None
    return int(clean, 16)


def _safe_dec_int(token):
    if not token:
        return None
    clean = token.strip()
    if clean.lstrip("-").isdigit():
        return int(clean)
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- Discovery path ---
    if params.get("_discover"):
        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_descr.rc != 0:
            return {"changed": False, "msg": "no SNMP agent or not an HP MCS device",
                    "data": {"discovery": [], "host_labels": {}}}

        descr = _strip_type(sys_descr.stdout) if sys_descr.stdout else ""
        if not descr.startswith(".1.3.6.1.4.1.232.167"):
            return {"changed": False, "msg": "not an HP MCS device",
                    "data": {"discovery": [], "host_labels": {}}}

        name_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.2.2.4.2"],
            mutates=False,
        )
        if name_res.rc != 0:
            return {"changed": False, "msg": "could not fetch system name",
                    "data": {"discovery": [], "host_labels": {}}}

        name = _strip_type(name_res.stdout) if name_res.stdout else ""
        name = name.strip()
        if not name:
            return {"changed": False, "msg": "no system name found",
                    "data": {"discovery": [], "host_labels": {}}}

        return {
            "changed": False,
            "msg": "discovered 1 HP MCS system",
            "data": {
                "discovery": [
                    {
                        "item": name,
                        "params": {},
                        "metrics": ["system_status"],
                    }
                ],
                "host_labels": {"cmk/os_family": "hp_mcs"},
            },
        }

    # --- Check path ---
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_descr.rc != 0:
        return {"changed": False, "msg": "SNMP agent not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    descr = _strip_type(sys_descr.stdout) if sys_descr.stdout else ""
    if not descr.startswith(".1.3.6.1.4.1.232.167"):
        return {"changed": False, "msg": "not an HP MCS device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.2.2.4.2"],
        mutates=False,
    )
    if name_res.rc != 0:
        return {"changed": False, "msg": "could not fetch system name",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fetched_name = _strip_type(name_res.stdout).strip()
    if fetched_name != item:
        return {"changed": False,
                "msg": "item mismatch: expected '%s', found '%s'" % (item, fetched_name),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Status OID (11.2.10.1): OIDBytes yields a list of integers.
    status_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-BIN", host, ".1.3.6.1.4.1.232.11.2.10.1"],
        mutates=False,
    )
    if status_res.rc != 0:
        return {"changed": False, "msg": "could not fetch system status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_raw = status_res.stdout.strip()
    if not status_raw:
        return {"changed": False, "msg": "empty status response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the OIDBytes value: snmpget -BIN returns hex bytes like 07 03 ...
    status_values = []
    parts = status_raw.replace(":", " ").split()
    for t in parts:
        iv = _safe_hex_int(t)
        if iv != None:
            status_values.append(iv)
            continue
        iv = _safe_dec_int(t)
        if iv != None:
            status_values.append(iv)

    if len(status_values) < 4:
        return {"changed": False, "msg": "status value too short",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # _idx1, status, _idx2, _dev_type = status_bytes
    status_int = status_values[1]

    # Serial OID (11.2.10.3).
    serial_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.232.11.2.10.3"],
        mutates=False,
    )
    if serial_res.rc != 0:
        return {"changed": False, "msg": "could not fetch serial number",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    serial = _strip_all_quotes(_strip_type(serial_res.stdout)).strip()

    # Map status to Checkmk state.
    entry = _STATUS_MAP.get(status_int, ("UNKNOWN", "Unknown"))
    state, state_readable = entry

    details = "Status: %s, Serial: %s" % (state_readable, serial)

    return {
        "changed": False,
        "msg": "Serial: %s" % serial,
        "data": {
            "state": state,
            "metrics": {"system_status": status_int},
            "details": details,
        },
    }