PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}
STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}
OID_BASE = ".1.3.6.1.4.1.232.22.2.4.1.1.1"

def _community(params):
    return params.get("community", "public")

def _host(params):
    return params.get("host", "localhost")

def _walk_columns(ctx, params, suffix):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", _community(params),
         "-Oqn", _host(params), OID_BASE + "." + suffix],
        mutates=False,
    )
    out = {}
    if res.rc != 0 or not res.stdout.strip():
        return out
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        idx = oid[len(OID_BASE) + 1:]
        out[idx] = line[sp + 1:]
    return out

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: detect the HP Blade sysObjectID.
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", _community(params),
             "-Oqv", _host(params), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if probe.rc != 0:
            return {"changed": False, "msg": "HP Blade not detected",
                    "data": {"discovery": []}}
        sys_oid = probe.stdout.strip()
        if sys_oid == "" or not sys_oid.endswith(".11.5.7.1.2"):
            return {"changed": False, "msg": "HP Blade not detected",
                    "data": {"discovery": []}}

        idx_map = _walk_columns(ctx, params, "3")
        present_map = _walk_columns(ctx, params, "12")
        if not idx_map:
            return {"changed": False, "msg": "HP Blade not detected",
                    "data": {"discovery": []}}

        discovery = []
        for idx in idx_map:
            present_raw = present_map.get(idx, "")
            if present_raw.isdigit() and PRESENT_MAP.get(int(present_raw)) == "present":
                discovery.append({
                    "item": idx,
                    "params": {},
                    "metrics": [],
                })
        return {"changed": False,
                "msg": "discovered %d HP Blade items" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK MODE ---
    item = params.get("item", "")

    pres = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params),
         "-Oqv", _host(params), OID_BASE + ".12." + item],
        mutates=False,
    )
    if pres.rc != 0:
        return {"changed": False,
                "msg": "HP Blade item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    present_raw = pres.stdout.strip()
    if not present_raw.isdigit():
        return {"changed": False,
                "msg": "HP Blade item " + item + " present state unparseable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    present_state = PRESENT_MAP.get(int(present_raw))
    if present_state != "present":
        return {"changed": False,
                "msg": "Blade was present but is not available anymore (Present state: %s)" % present_state,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    st = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params),
         "-Oqv", _host(params), OID_BASE + ".21." + item],
        mutates=False,
    )
    pr = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params),
         "-Oqv", _host(params), OID_BASE + ".17." + item],
        mutates=False,
    )
    nm = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params),
         "-Oqv", _host(params), OID_BASE + ".4." + item],
        mutates=False,
    )
    sn = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params),
         "-Oqv", _host(params), OID_BASE + ".16." + item],
        mutates=False,
    )

    raw_state = 2
    if st.rc == 0 and st.stdout.strip() and st.stdout.strip().isdigit():
        raw_state = int(st.stdout.strip())
    if raw_state not in STATUS_MAP:
        raw_state = 2

    state, state_readable = STATUS_MAP[raw_state]
    product = pr.stdout.strip() if pr.rc == 0 else ""
    name = nm.stdout.strip() if nm.rc == 0 else ""
    serial = sn.stdout.strip() if sn.rc == 0 else ""

    details = "Blade status is %s (Product: %s Name: %s S/N: %s)" % (
        state_readable, product, name, serial)

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": {}, "details": details}}