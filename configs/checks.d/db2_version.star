# ===== check plugin: checkmk.db2_version =====
# Translated from Checkmk agent_based db2_version.py

def main(ctx, params):
    def _run_db2_instancelist():
        res = ctx.run(["db2pd", "-dbcfg", "-instdbs"], mutates=False)
        if res.rc != 0 and res.rc != 127:
            return res
        r2 = ctx.run(["db2ls", "-v"], mutates=False)
        if r2.rc != 0 and r2.rc != 127:
            return r2
        if res.rc == 127 and r2.rc == 127:
            return res
        return r2 if res.rc == 127 else res

    if params.get("_discover"):
        probe = _run_db2_instancelist()
        if probe.rc == 127:
            return {"changed": False, "msg": "db2 not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if probe.rc != 0:
            return {"changed": False, "msg": "db2 instancelist failed: " + probe.stderr.strip(),
                    "data": {"discovery": []}}
        out = []
        for line in probe.stdout.splitlines():
            s = line.strip()
            if not s:
                continue
            parts = s.split(" ", 1)
            if len(parts) < 1:
                continue
            item = parts[0]
            out.append({"item": item, "params": {},
                        "metrics": [],
                        "service_labels": {}})
        return {"changed": False,
                "msg": "discovered %d db2 instances" % len(out),
                "data": {"discovery": out,
                         "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "")}}}

    item = params.get("item", "")
    probe = _run_db2_instancelist()
    if probe.rc == 127:
        return {"changed": False, "msg": "db2 not installed",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "db2pd/db2ls not installed"}}
    if probe.rc != 0:
        return {"changed": False, "msg": "db2 instancelist failed: " + probe.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for line in probe.stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        tokens = s.split(" ", 1)
        if len(tokens) < 2:
            if item == tokens[0]:
                return {"changed": False, "msg": "No instance information found",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        else:
            instance, version = tokens
            if item == instance:
                return {"changed": False, "msg": version,
                        "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Instance is down",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}