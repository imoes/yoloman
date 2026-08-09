# ===== translated from checkmk.oracle_version (agent_based/oracle_version.py) =====
# The Checkmk agent plugin runs sqlplus against the DB to emit banner line(s):
#   <<<oracle_version>>>
#   XE Oracle Database 11g Express Edition Release 11.2.0.2.0 - 64bit Production
# We reproduce that probe on-host via sqlplus, then honour the same
# discovery/check logic. READ-ONLY: never mutates, never writes.

def main(ctx, params):
    item = params.get("item", "")
    conn = params.get("connection", {})

    # Probe for the real thing: sqlplus must be present.
    probe = ctx.run(["which", "sqlplus"], mutates=False)
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no sqlplus found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "sqlplus not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery: enumerate each oracle instance reachable.
    if params.get("_discover"):
        res = ctx.run(["sqlplus", "-s", "/", "as", "sysdba", "@", "-"],
                      mutates=False,
                      ok_codes=[0, 1])
        # The above just checks connectivity; real version query below.
        # We use a here-doc-free approach: feed SQL via stdin is not possible
        # with ctx.run (no pipes), so rely on a tiny sql script file path the
        # operator may provide, else use a simple version query string.
        # Since ctx.run takes argv directly (no shell), pass SQL as args.
        res = ctx.run(["sqlplus", "-s", "/", "as", "sysdba",
                       "set heading off pagesize 0 feed off;select banner from v$version;exit"],
                      mutates=False,
                      ok_codes=[0, 1])
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no oracle version info",
                    "data": {"discovery": []}}
        discovery = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            tokens = line.split()
            name = tokens[0] if tokens else ""
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d oracle instances" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: pull the matching banner for `item`.
    res = ctx.run(["sqlplus", "-s", "/", "as", "sysdba",
                   "set heading off pagesize 0 feed off;select banner from v$version;exit"],
                  mutates=False,
                  ok_codes=[0, 1])
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no version information, database might be stopped",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        tokens = line.split()
        name = tokens[0] if tokens else ""
        if item == "" or name == item:
            rest = " ".join(tokens[1:]) if len(tokens) > 1 else ""
            summary = "Version: " + (rest if rest else line)
            return {"changed": False,
                    "msg": summary,
                    "data": {"state": "OK", "metrics": {}, "details": line}}

    return {"changed": False, "msg": "no version information, database might be stopped",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}