# Translated Checkmk check: checkmk.sap_hana_status -> read-only Starlark check module

def main(ctx, params):
    if params.get("_discover"):
        items = _discover_status(ctx)
        return {"changed": False,
                "msg": "discovered %d SAP HANA status items" % len(items),
                "data": {"discovery": items}}
    return _check_status(ctx, params)


def _hdbsql_available(ctx):
    res = ctx.run(["hdbsql", "--version"], mutates=False)
    return res.rc == 0


def _parse_instances(ctx):
    instances = []
    res = ctx.run(["ls", "/hana/shared"], mutates=False)
    if res.rc == 0:
        for line in res.stdout.splitlines():
            sid = line.strip()
            if sid and len(sid) == 3 and sid.isalpha() and sid.isupper():
                instances.append(sid)
    res2 = ctx.run(["ls", "/usr/sap"], mutates=False)
    if res2.rc == 0:
        for line in res2.stdout.splitlines():
            sid = line.strip()
            if sid and len(sid) == 3 and sid.isalpha() and sid.isupper():
                instances.append(sid)
    seen = {}
    out = []
    for i in instances:
        if i not in seen:
            seen[i] = 1
            out.append(i)
    return out


def _probe_instance(ctx, sid):
    key = sid + " KEY"
    res = ctx.run(["hdbsql", "-U", key, "SELECT 1 FROM M_DATABASES"], mutates=False)
    if res.rc == 0 and "all started" in res.stdout:
        parts = res.stdout.strip().split()
        if len(parts) >= 3:
            return {"instance": sid, "state_name": parts[1],
                    "message": " ".join(parts[2:])}
        return {"instance": sid, "state_name": "ok", "message": "all started"}
    if res.rc != 0:
        if res.rc == 127:
            return None
        return {"instance": sid, "state_name": "error",
                "message": res.stdout.strip() + " " + res.stderr.strip()}
    vres = ctx.run(["hdbsql", "-U", key, "SELECT * FROM M_DATABASES"], mutates=False)
    if vres.rc == 0 and vres.stdout.strip():
        parts = vres.stdout.strip().split()
        version = parts[2] if len(parts) >= 3 else parts[0]
        return {"instance": sid, "state_name": "connected",
                "version": version}
    return None


def _discover_status(ctx):
    if not _hdbsql_available(ctx):
        return []
    instances = _parse_instances(ctx)
    if not instances:
        return []
    out = []
    for sid in instances:
        data = _probe_instance(ctx, sid)
        if data == None:
            continue
        out.append({"item": "Status " + sid,
                    "params": {},
                    "metrics": []})
        if "version" in data:
            out.append({"item": data["instance"] + " " + sid,
                        "params": {},
                        "metrics": []})
    return out


def _grade(data):
    state_name = data.get("state_name", "")
    low = state_name.lower()
    if low in ("ok", "connected"):
        state = "OK"
    elif low in ("unknown", "error"):
        state = "CRIT"
    else:
        state = "WARN"
    summary = "Status: %s" % state_name
    if "message" in data:
        summary = summary + ", Details: " + data["message"]
    return state, summary


def _check_status(ctx, params):
    item = params.get("item", "")
    if not _hdbsql_available(ctx):
        return {"changed": False,
                "msg": "no SAP HANA found: hdbsql not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sid = ""
    if item.startswith("Status "):
        sid = item[len("Status "):]
    elif " " in item:
        parts = item.split(" ")
        if len(parts) >= 2:
            sid = parts[-1]
    else:
        sid = item
    if not sid:
        return {"changed": False,
                "msg": "no SAP HANA instance specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = _probe_instance(ctx, sid)
    if data == None:
        return {"changed": False,
                "msg": "no SAP HANA data for instance " + sid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "Status" in item:
        state, summary = _grade(data)
    else:
        if "version" not in data:
            return {"changed": False,
                    "msg": "no version data for " + sid,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state = "OK"
        summary = "Version: %s" % data["version"]
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}