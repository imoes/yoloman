def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/dsm/baclient/baclient.log"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["cat", "/var/adm/ras/dsmagent.log"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (no tsm_sessions data available)",
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        if not lines:
            return {
                "changed": False,
                "msg": "discovered 0 items (no tsm_sessions data available)",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/dsm/baclient/baclient.log"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["cat", "/var/adm/ras/dsmagent.log"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no tsm_sessions data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    warn, crit = 300, 600
    state = "OK"
    count = 0
    
    for line in lines:
        if not line.strip():
            continue
        fields = line.strip().split()
        if len(fields) < 3:
            continue
        
        proc_state = ""
        wait_str = ""
        
        if len(fields) == 4:
            proc_state = fields[2]
            wait_str = fields[3]
        elif len(fields) > 4:
            proc_state = fields[-2]
            wait_str = fields[-1]
        elif len(fields) == 3:
            proc_state = fields[1]
            wait_str = fields[2]
        
        if proc_state not in ("RecvW", "MediaW"):
            continue
        
        wait_seconds = int(wait_str) if wait_str.isdigit() else 0
        
        if wait_seconds >= crit:
            state = "CRIT"
            count += 1
        elif wait_seconds >= warn:
            if state == "OK":
                state = "WARN"
            count += 1
    
    msg = "%d sessions too long in RecvW or MediaW state" % count
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }