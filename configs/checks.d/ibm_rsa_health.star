# Checkmk check: ibm_rsa_health -> read-only Starlark check module
# Source: cmk/plugins/ibm/agent_based/ibm_rsa_health.py
# System health for IBM Remote Supervisor Adapter (RSA), read over SNMP.

def _strip_type_tag(value):
    v = value
    idx = v.find(": ")
    if idx >= 0:
        v = v[idx + 2:]
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[len(v) - 1] == '"':
        v = v[1:len(v) - 1]
    return v

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = ".1.3.6.1.4.1.2.3.51.1.2"
    column_oid = base_oid + ".7"

    def _do_get(oid):
        return ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )

    def _do_walk():
        return ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
            mutates=False,
        )

    sys_descr = _do_get(".1.3.6.1.2.1.1.1.0")
    is_rsa = False
    if sys_descr.rc == 0 and "Remote Supervisor Adapter" in sys_descr.stdout:
        is_rsa = True

    if not is_rsa:
        if params.get("_discover"):
            return {"changed": False, "msg": "no IBM RSA detected", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "IBM Remote Supervisor Adapter not found on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = []
    walk = _do_walk()
    if walk.rc == 0:
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            val = line[sp + 1:]
            section.append([val])

    if not section:
        if params.get("_discover"):
            return {"changed": False, "msg": "no IBM RSA health data", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "IBM RSA health section empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["alerts"],
                    }
                ],
                "host_labels": {"cmk/os_family": "ibm_rsa"},
            },
        }

    num_alerts = int((len(section) - 1) / 3)
    infotext = ""
    for i in range(num_alerts):
        state_val = section[num_alerts + 1 + i][0]
        text_val = section[num_alerts * 2 + 1 + i][0]
        if infotext != "":
            infotext += ", "
        infotext += "{t}({s})".format(t=text_val, s=state_val)

    state_val = section[0][0]
    if state_val == "255":
        verdict = "OK"
        summary = "no problem found"
    elif state_val == "0" or state_val == "2":
        verdict = "CRIT"
        summary = infotext
    elif state_val == "4":
        verdict = "WARN"
        summary = infotext
    else:
        verdict = "UNKNOWN"
        summary = infotext

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": verdict,
            "metrics": {"alerts": num_alerts},
            "details": infotext,
        },
    }