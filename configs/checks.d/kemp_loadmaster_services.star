def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: the Kemp LoadMaster sysObjectID.
        sysOid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysOid.rc != 0 or sysOid.stdout.strip() == "":
            return {"changed": False, "msg": "not a Kemp LoadMaster",
                    "data": {"discovery": []}}
        oid = sysOid.stdout.strip()
        if oid != ".1.3.6.1.4.1.12196.250.10" and oid != ".1.3.6.1.4.1.2021.250.10":
            return {"changed": False, "msg": "not a Kemp LoadMaster",
                    "data": {"discovery": []}}

        names = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.12196.13.1.1.13"],
            mutates=False,
        )
        states = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.12196.13.1.1.14"],
            mutates=False,
        )

        services = _collect_services(names.stdout, states.stdout)
        discovery = []
        for name, state in services:
            stxt = _VS_STATE_MAP.get(state, ("UNKNOWN", "unknown[%s]" % state))[1]
            if stxt not in ["disabled", "unknown[]"]:
                discovery.append({"item": name, "params": {},
                                  "metrics": ["conns"]})
        return {"changed": False,
                "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    name = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.12196.13.1.1.13." + item],
        mutates=False,
    )
    state = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.12196.13.1.1.14." + item],
        mutates=False,
    )
    conns = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.12196.13.1.1.21." + item],
        mutates=False,
    )

    if name.rc != 0 and name.stdout.strip() == "":
        return {"changed": False,
                "msg": "no such virtual service: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sm = state.stdout.strip()
    cm = conns.stdout.strip()
    s_state, s_txt = _VS_STATE_MAP.get(sm, ("UNKNOWN", "unknown[%s]" % sm))
    conns_val = int(cm) if cm.isdigit() else None
    metrics = {}
    if conns_val != None:
        metrics["conns"] = conns_val
    summary = "Status: " + s_txt
    if conns_val != None:
        summary = summary + ", Active connections: %d" % conns_val
    return {"changed": False, "msg": summary,
            "data": {"state": s_state, "metrics": metrics, "details": ""}}


_VS_STATE_MAP = {
    "1": ("OK", "in service"),
    "2": ("CRIT", "out of service"),
    "3": ("CRIT", "failed"),
    "4": ("WARN", "disabled"),
    "5": ("WARN", "sorry"),
    "6": ("OK", "redirect"),
    "7": ("CRIT", "error message"),
}


def _parse_walk(out):
    out = {}
    for line in out.splitlines():
        if line.strip() == "":
            continue
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        out[parts[0]] = parts[1]
    return out


def _collect_services(names_out, states_out):
    nm = _parse_walk(names_out)
    sm = _parse_walk(states_out)
    col_base = ".1.3.6.1.4.1.12196.13.1.1.13"
    state_col = ".1.3.6.1.4.1.12196.13.1.1.14"
    result = []
    for oid, nval in nm.items():
        idx = oid[len(col_base) + 1:]
        stxt = sm.get(state_col + "." + idx, "")
        result.append((nval, stxt))
    return result