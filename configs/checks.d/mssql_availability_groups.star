def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mssql-tools", "--version"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "mssql-tools not installed", "data": {"discovery": []}}
        probe = ctx.run(
            ["mssql-tools", "sqlcmd", "-S", "localhost", "-E", "-Q",
             "SET NOCOUNT ON; SELECT name, primary_replica, synchronization_health_desc FROM sys.availability_groups"],
             mutates=False)
        if probe.rc != 0 or not probe.stdout:
            return {"changed": False, "msg": "no availability groups found", "data": {"discovery": []}}
        names = [line.split()[0] for line in probe.stdout.splitlines() if line and not line.startswith("name") and not line.startswith("-")]
        discovery = [{"item": n, "params": {}, "metrics": []} for n in names]
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    probe = ctx.run(
        ["mssql-tools", "sqlcmd", "-S", "localhost", "-E", "-Q",
         "SET NOCOUNT ON; SELECT primary_replica, synchronization_health_desc FROM sys.availability_groups WHERE name = '" + item + "'"],
        mutates=False)
    if probe.rc != 0 or not probe.stdout:
        return {"changed": False, "msg": "availability group %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = [l for l in probe.stdout.splitlines() if l and not l.startswith("primary_replica") and not l.startswith("-")]
    if not lines:
        return {"changed": False, "msg": "availability group %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = lines[0].split()
    if len(parts) < 2:
        return {"changed": False, "msg": "availability group %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    primary_replica = parts[0]
    sync_state = parts[1]
    state = "OK" if sync_state == "HEALTHY" else ("WARN" if sync_state == "PARTIALLY_HEALTHY" else "CRIT")
    return {"changed": False, "msg": "Primary replica: %s, Synchronization state: %s" % (primary_replica, sync_state),
            "data": {"state": state, "metrics": {}, "details": ""}}