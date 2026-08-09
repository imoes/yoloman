# FJDAR-E storage array disk check (Checkmk fjdarye_disks + fjdarye_disks_summary).
#
# This check monitors Fujitsu storage systems that support the FJDARY-E60,
# FJDARY-E100, FJDARY-E101, FJDARY-E500 or FJDARY-E600 MIB. Disk states are
# fetched via SNMP from the array's MIB. It is a pure read-only monitor: it
# never mutates the system and is offered only when the device is actually an
# Fujitsu array (detected by sysObjectID).

# Mapping of supported sysObjectID values to their disk table base OID suffix.
FJDARYE_DISKS = {
    ".1.3.6.1.4.1.211.1.21.1.60":  ".2.12.2.1",  # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.19.2.1",  # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.12.2.1",  # fjdarye101
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.19.2.1",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.19.2.1",  # fjdarye600
}

# Disk status codes: code -> (state, description).
# state: "OK" | "WARN" | "CRIT" | "UNKNOWN"
FJDARYE_DISKS_STATUS = {
    "1":  ("OK", "available"),
    "2":  ("CRIT", "broken"),
    "3":  ("WARN", "notavailable"),
    "4":  ("WARN", "notsupported"),
    "5":  ("OK", "present"),
    "6":  ("WARN", "readying"),
    "7":  ("WARN", "recovering"),
    "64": ("WARN", "partbroken"),
    "65": ("WARN", "spare"),
    "66": ("OK", "formatting"),
    "67": ("OK", "unformated"),
    "68": ("WARN", "notexist"),
    "69": ("WARN", "copying"),
}

# Worst-state precedence for summary aggregation.
_STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}


def _oid_suffix(oid, index):
    # Build "<oid>.<index>" — index is the numeric SNMP table index.
    return oid + "." + index


def _state_rank(state):
    r = _STATE_RANK.get(state)
    return r if r != None else 3


def _worst_state(states):
    worst = "OK"
    for s in states:
        if _state_rank(s) > _state_rank(worst):
            worst = s
    return worst


def _print_states(states):
    # states: {"description": count} -> "Available: 4, Notavailable: 1"
    parts = []
    for s in sorted(states.keys()):
        parts.append(s.title() + ": " + str(states[s]))
    return ", ".join(parts)


def _state_for_disk(disk_state):
    # disk_state is the raw numeric code string from the SNMP table.
    mapped = FJDARYE_DISKS_STATUS.get(disk_state)
    if mapped != None:
        return mapped[0], mapped[1]
    return "UNKNOWN", "unknown[" + disk_state + "]"


def _is_array(ctx, params):
    # Probe sysObjectID to confirm this is a supported Fujitsu array.
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    # rc == 127 -> snmp binary missing; non-zero -> not an array / unreachable.
    if res.rc != 0:
        return None
    sysid = res.stdout.strip()
    if sysid in FJDARYE_DISKS:
        return sysid
    return None


def _fetch_disks(ctx, params, sysid):
    # Walk the disk table for the detected array MIB: oid index ".1", status ".3".
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base = sysid + FJDARYE_DISKS[sysid]
    # Walk column 1 (index) using -Oqn: "<OID>.<idx> <value>".
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"],
        mutates=False,
    )
    disks = {}  # disk_index -> {"state_disk": raw, "state": str, "desc": str}
    if res.rc != 0 or not res.stdout.strip():
        return disks
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        # index is the suffix after "<base>.1."
        suffix = oid[len(base) + 3:]
        disks.setdefault(suffix, {"state_disk": None, "state": "UNKNOWN", "desc": "unknown"})
    # Walk column 3 (status) and correlate by index.
    res2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"],
        mutates=False,
    )
    if res2.rc == 0 and res2.stdout.strip():
        for line in res2.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            suffix = oid[len(base) + 3:]
            if suffix in disks:
                state, desc = _state_for_disk(value)
                disks[suffix]["state_disk"] = value
                disks[suffix]["state"] = state
                disks[suffix]["desc"] = desc
    return disks


def _summary_disks(ctx, params, sysid):
    # Return the per-disk discovery list (single-service check produces item "").
    disks = _fetch_disks(ctx, params, sysid)
    out = []
    for idx in sorted(disks.keys()):
        d = disks[idx]
        if d["state_disk"] == "3":
            # notavailable disks are excluded from discovery (mirror Checkmk).
            continue
        out.append({
            "item": idx,
            "params": {"expected_state": d["desc"]},
            "metrics": [],
        })
    return out, disks


def main(ctx, params):
    # --- Discovery path ---
    if params.get("_discover"):
        sysid = _is_array(ctx, params)
        if sysid == None:
            # Not a Fujitsu array here -> offered on no items.
            return {"changed": False, "msg": "not a supported FJDARY-E storage array",
                    "data": {"discovery": []}}
        out, _ = _summary_disks(ctx, params, sysid)
        return {"changed": False,
                "msg": "discovered %d disks" % len(out),
                "data": {"discovery": out}}

    # --- Single disk check path (check_plugin_fjdarye_disks) ---
    plugin = params.get("plugin", "fjdarye_disks")

    if plugin == "fjdarye_disks":
        sysid = _is_array(ctx, params)
        if sysid == None:
            return {"changed": False,
                    "msg": "not a supported FJDARY-E storage array",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        item = params.get("item", "")
        out, disks = _summary_disks(ctx, params, sysid)
        if item not in disks:
            return {"changed": False,
                    "msg": "no such disk: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        disk = disks[item]
        if disk["state_disk"] == "3":
            return {"changed": False,
                    "msg": "Status: " + disk["desc"] + " (notavailable)",
                    "data": {"state": "WARN", "metrics": {}, "details": ""}}

        use_device_states = params.get("use_device_states", False)
        expected_state = params.get("expected_state")

        if use_device_states and disk["state"] != "OK":
            return {"changed": False,
                    "msg": "Status: " + disk["desc"] + " (using device states)",
                    "data": {"state": disk["state"], "metrics": {},
                             "details": "disk_state=" + str(disk["state_disk"])}}

        if expected_state != None and expected_state != disk["desc"]:
            return {"changed": False,
                    "msg": "Status: " + disk["desc"] + " (expected: " + expected_state + ")",
                    "data": {"state": "CRIT", "metrics": {},
                             "details": "disk_state=" + str(disk["state_disk"])}}

        return {"changed": False,
                "msg": "Status: " + disk["desc"],
                "data": {"state": "OK", "metrics": {},
                         "details": "disk_state=" + str(disk["state_disk"])}}

    # --- Summary check path (check_plugin_fjdarye_disks_summary) ---
    if plugin == "fjdarye_disks_summary":
        sysid = _is_array(ctx, params)
        if sysid == None:
            return {"changed": False,
                    "msg": "not a supported FJDARY-E storage array",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        out, disks = _summary_disks(ctx, params, sysid)
        # Aggregate state counts, excluding notavailable (state_disk == "3").
        counts = {}
        states_for_worst = []
        for idx in disks:
            d = disks[idx]
            if d["state_disk"] == "3":
                continue
            desc = d["desc"]
            counts[desc] = counts.get(desc, 0) + 1
            states_for_worst.append(d["state"])

        text = _print_states(counts)
        use_device_states = params.get("use_device_states", False)

        if use_device_states:
            wstate = _worst_state(states_for_worst) if states_for_worst else "OK"
            msg = text + " (using device states)" if text else "No disks (using device states)"
            return {"changed": False, "msg": msg,
                    "data": {"state": wstate, "metrics": {}, "details": msg}}

        # Compare against expected counts (all params except use_device_states).
        expected = {}
        for k in params:
            if k == "use_device_states":
                continue
            expected[k] = params[k]

        if counts == expected:
            msg = text if text else "No disks"
            return {"changed": False, "msg": msg,
                    "data": {"state": "OK", "metrics": {}, "details": msg}}

        # Mismatch: CRIT if any expected count is below the desired, else WARN.
        msg = text + " (expected: " + _print_states(expected) + ")" if text else \
              " (expected: " + _print_states(expected) + ")"
        for name, want in expected.items():
            if counts.get(name, 0) < want:
                return {"changed": False, "msg": msg,
                        "data": {"state": "CRIT", "metrics": {}, "details": msg}}
        return {"changed": False, "msg": msg,
                "data": {"state": "WARN", "metrics": {}, "details": msg}}

    return {"changed": False,
            "msg": "unsupported plugin: " + str(plugin),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}